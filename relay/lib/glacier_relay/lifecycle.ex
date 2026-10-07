defmodule GlacierRelay.Lifecycle do
  @moduledoc """
  The pure per-adapter-instance lifecycle model (M2 design). No process, no clock, no I/O: it
  folds evidence into an `Instance` and never invents evidence it was not given.

  Three kinds of evidence are kept apart and never converted into one another:

  1. **Game lifecycle evidence** — semantic events from the native adapter: `mission.playing`
     and `mission.stopped`. Only these open and close mission attempts.
  2. **Adapter/process evidence** — the `adapter_instance_id` on each envelope. A new id is a new
     adapter instance (a new game process); it says nothing about the old one's missions.
  3. **Transport evidence** — a connection being attributed to this instance and later closing.
     It changes whether the instance is currently *observable*, nothing else.

  Derivations, and what they deliberately do not say:

  - `mission.playing` opens an attempt. If one is already open, the old one becomes `:superseded`:
    its end was not observed (usually a sequence gap says why). It is not marked stopped.
  - `mission.stopped` closes the open attempt with the fall observation. With no open attempt it is
    kept as an unmatched stop; no attempt is invented for it.
  - A connection closing while an attempt is open records an interruption on that attempt. The
    attempt stays `:playing` (last known) with `observation/1` reporting `:lost`. No stop time is
    fabricated from the close. If the same instance later delivers `mission.stopped`, the attempt
    closes from that evidence.
  - `mission.stopped` after `mission.playing` for the same scene says the predicate fell. It does
    not say completed, failed, restarted, exited or quit. A later `mission.playing` for the same
    scene is a new attempt, not labelled a restart.
  - Actor outcomes (`actor.died`, `actor.pacified`, M2 B1) are attached to the attempt that is
    open when they arrive, by stream order only. With no open attempt they are kept as
    unattributed evidence; they are never attached to a previous or future attempt. A pacified
    then died actor is two outcomes. Nothing is deduplicated and no actor identity is derived.
  """

  alias GlacierRelay.Wire.Envelope

  defmodule Observation do
    @moduledoc "One semantic event as evidence: where it sat in the stream and what it carried."
    defstruct [:sequence, :timestamp, :received_at, :game_session_id]
  end

  defmodule Outcome do
    @moduledoc """
    One actor outcome as the engine recorded it (via the native normalizer). `kind` is
    `:died` or `:pacified`; everything else is the normalized payload plus stream position.
    """
    defstruct [:kind, :sequence, :timestamp, :received_at, :payload]
  end

  defmodule Attempt do
    @moduledoc """
    One mission attempt, bounded by game lifecycle evidence only.

    `mission` is `:playing` (open; last known state), `:stopped` (closed by `mission.stopped`) or
    `:superseded` (another `mission.playing` arrived while this was open; its end was not observed).
    `interruptions` lists the times the instance's connection closed while this attempt was open;
    they are transport evidence and leave `mission` untouched.
    """
    defstruct [
      :number,
      :scene_resource,
      :scene_type,
      :codename_hint,
      :playing,
      :stopped,
      # What the fall frame reported about the scene. Usually the same scene as the rise; empty
      # if observability was lost on that frame. Kept as evidence, never used to re-pair.
      :stopped_scene,
      mission: :playing,
      superseded_by: nil,
      interruptions: [],
      # Actor outcomes in stream order (M2 B1).
      outcomes: []
    ]
  end

  defmodule Connection do
    @moduledoc "A transport connection attributed to this instance (from its first valid envelope)."
    defstruct [:peer, :opened_at, :identified_at, :closed_at, :close_reason]
  end

  defmodule Instance do
    @moduledoc "Everything known about one adapter instance, folded from evidence."
    defstruct id: nil,
              last_sequence: 0,
              received: 0,
              gaps: [],
              last_event: nil,
              attempts: [],
              unmatched_stops: [],
              unattributed_outcomes: [],
              connections: []
  end

  def new(id), do: %Instance{id: id}

  @doc "Folds one validated envelope (game lifecycle evidence) into the instance."
  @spec apply_event(Instance.t(), Envelope.t(), DateTime.t() | nil) :: {Instance.t(), [term()]}
  def apply_event(%Instance{} = instance, %Envelope{} = envelope, received_at) do
    {instance, notes} = track_sequence(instance, envelope)

    observation = %Observation{
      sequence: envelope.sequence,
      timestamp: envelope.timestamp,
      received_at: received_at,
      game_session_id: envelope.payload[:game_session_id]
    }

    {instance, more} =
      cond do
        envelope.event_type == GlacierRelay.Events.mission_playing() ->
          open_attempt(instance, envelope.payload, observation)

        envelope.event_type == GlacierRelay.Events.mission_stopped() ->
          close_attempt(instance, envelope.payload, observation)

        GlacierRelay.Events.actor_outcome?(envelope.event_type) ->
          record_outcome(instance, envelope, received_at)
      end

    {%{instance | last_event: envelope}, notes ++ more}
  end

  @doc "Transport evidence: a connection has been attributed to this instance."
  def connection_identified(%Instance{} = instance, peer, opened_at, identified_at) do
    record = %Connection{peer: peer, opened_at: opened_at, identified_at: identified_at}
    %{instance | connections: [record | instance.connections]}
  end

  @doc """
  Transport evidence: the instance's current connection closed. Records an interruption on the
  open attempt, if any, and nothing else about it.
  """
  def connection_closed(
        %Instance{connections: [%Connection{closed_at: nil} = open | rest]} = instance,
        at,
        reason
      ) do
    closed = %{open | closed_at: at, close_reason: reason}

    attempts =
      case current_attempt(instance) do
        nil ->
          instance.attempts

        attempt ->
          replace_last(instance.attempts, %{
            attempt
            | interruptions: attempt.interruptions ++ [%{at: at, reason: reason}]
          })
      end

    %{instance | connections: [closed | rest], attempts: attempts}
  end

  def connection_closed(%Instance{} = instance, _at, _reason), do: instance

  @doc "Whether evidence from this instance is currently arriving: `:live`, `:lost` or `:never`."
  def observation(%Instance{connections: []}), do: :never
  def observation(%Instance{connections: [%Connection{closed_at: nil} | _]}), do: :live
  def observation(%Instance{}), do: :lost

  @doc "The open attempt (last known playing), or nil."
  def current_attempt(%Instance{attempts: attempts}) do
    case List.last(attempts) do
      %Attempt{mission: :playing} = attempt -> attempt
      _ -> nil
    end
  end

  @doc "Milliseconds between the playing and stopped observations, when both exist and parse."
  def duration_ms(%Attempt{
        playing: %Observation{timestamp: from},
        stopped: %Observation{timestamp: to}
      }) do
    with {:ok, from, _} <- DateTime.from_iso8601(from),
         {:ok, to, _} <- DateTime.from_iso8601(to) do
      DateTime.diff(to, from, :millisecond)
    else
      _ -> nil
    end
  end

  def duration_ms(%Attempt{}), do: nil

  # -- internals -----------------------------------------------------------------------------

  defp track_sequence(instance, envelope) do
    expected = instance.last_sequence + 1

    {gaps, notes} =
      if envelope.sequence == expected or instance.last_sequence == 0 do
        {instance.gaps, []}
      else
        {[{expected, envelope.sequence} | instance.gaps], [{:gap, expected, envelope.sequence}]}
      end

    {%{
       instance
       | last_sequence: max(instance.last_sequence, envelope.sequence),
         received: instance.received + 1,
         gaps: gaps
     }, notes}
  end

  defp open_attempt(instance, payload, observation) do
    number = length(instance.attempts) + 1

    {attempts, notes} =
      case current_attempt(instance) do
        nil ->
          {instance.attempts, []}

        open ->
          {replace_last(instance.attempts, %{open | mission: :superseded, superseded_by: number}),
           [{:superseded, open.number, number}]}
      end

    attempt = %Attempt{
      number: number,
      scene_resource: payload.scene_resource,
      scene_type: payload.scene_type,
      codename_hint: payload.codename_hint,
      playing: observation
    }

    {%{instance | attempts: attempts ++ [attempt]}, notes}
  end

  defp close_attempt(instance, payload, observation) do
    case current_attempt(instance) do
      nil ->
        stray = %{observation: observation, payload: payload}

        {%{instance | unmatched_stops: instance.unmatched_stops ++ [stray]},
         [{:unmatched_stop, observation.sequence}]}

      open ->
        scene = Map.take(payload, [:scene_resource, :scene_type, :codename_hint])
        closed = %{open | mission: :stopped, stopped: observation, stopped_scene: scene}

        notes =
          if scene.scene_resource == open.scene_resource,
            do: [],
            else: [{:fall_scene_differs, open.number, open.scene_resource, scene.scene_resource}]

        {%{instance | attempts: replace_last(instance.attempts, closed)}, notes}
    end
  end

  defp record_outcome(instance, envelope, received_at) do
    outcome = %Outcome{
      kind:
        if(envelope.event_type == GlacierRelay.Events.actor_died(), do: :died, else: :pacified),
      sequence: envelope.sequence,
      timestamp: envelope.timestamp,
      received_at: received_at,
      payload: envelope.payload
    }

    case current_attempt(instance) do
      nil ->
        {%{instance | unattributed_outcomes: instance.unattributed_outcomes ++ [outcome]},
         [{:unattributed_outcome, envelope.sequence}]}

      open ->
        {%{
           instance
           | attempts:
               replace_last(instance.attempts, %{open | outcomes: open.outcomes ++ [outcome]})
         }, []}
    end
  end

  defp replace_last(list, item), do: List.replace_at(list, length(list) - 1, item)
end

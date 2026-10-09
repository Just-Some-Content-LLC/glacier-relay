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
  - Contract lifecycle (`contract.started`, `contract.ended`, M2 B2) is Glacier's own account of
    its contract sessions, kept as first-class evidence on the instance (`contract_sessions`,
    with the full payloads) whether or not it is correlated to an attempt. The attempt ↔ session
    relationship is **a BEAM-derived temporal correlation based on observed event ordering, not
    an identity equivalence guaranteed by Glacier**: a `contract.started` arriving while an
    attempt without a session is open pairs with it (`:open_attempt`); one arriving with no such
    attempt waits, and pairs with the next `mission.playing` only if it is the single candidate
    (`:next_rise`). Several waiting sessions at a rise are ambiguous: none is chosen, all are
    recorded as candidates on the attempt and as unpaired sessions. A `contract.ended` closes the
    session with its id (Glacier's identity, used only within Glacier's domain); with no such
    open session it is kept as an unmatched end, never attached by adjacency. The rise's
    `game_session_id` is compared with the paired session's id as a consistency check: a
    mismatch is an anomaly that is recorded and left visible, and the pairing made by order
    stands. Relay attempt identity is never rewritten by any of this.
  - `Attempt.disposition` is derived only from a paired session's `contract.ended`:
    `:restarted`, `:exited_to_menu` or `{:ended, reason}`; otherwise `:not_observed`. Never from
    `mission.stopped`, the registry id, the transport, the scene or timing.
  - Disguise occurrences (`disguise.equipped`, `disguise.compromised`,
    `disguise.compromise_cleared`, M2 B3) are attached to the open attempt by stream order, like
    outcomes, and kept there as immutable facts (`disguise_events`); with no open attempt they are
    unattributed. Nothing about the worn outfit or its compromise is stored here: `Disguise.derive/2`
    reads it from the facts on demand, with the attempt's gap and interruption evidence.
  - Item occurrences (`item.picked_up`, `item.thrown`, `item.removed_from_inventory`, M2 B4) are
    attached the same way (`item_events`), each occurrence on its own; with no open attempt they are
    unattributed. Nothing is paired, deduplicated or read as an inventory here or anywhere:
    `Items.derive/2` counts the facts on demand, with the same bounded history evidence.
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

  defmodule DisguiseOccurrence do
    @moduledoc """
    One disguise occurrence as the engine recorded it (via the native normalizer). `type` is
    `:equipped`, `:compromised` or `:compromise_cleared`; `kind` is `:initial` or `:change` on an
    equipped occurrence and nil otherwise; everything else is the validated payload plus stream
    position. Facts only: nothing here is derived.
    """
    defstruct [:type, :kind, :sequence, :timestamp, :received_at, :payload]
  end

  defmodule ItemOccurrence do
    @moduledoc """
    One item occurrence as the engine recorded it (via the native normalizer). `type` is
    `:picked_up`, `:thrown` or `:removed_from_inventory`; everything else is the validated payload
    plus stream position. Facts only: nothing here is derived, and no occurrence refers to another.
    """
    defstruct [:type, :sequence, :timestamp, :received_at, :payload]
  end

  defmodule ContractSession do
    @moduledoc """
    One Glacier contract session as the engine reported it (M2 B2). `started` and `ended` are the
    stream positions of `contract.started` / `contract.ended`; `started_payload` and
    `ended_payload` are those events' validated payloads, kept whole so derived state can be
    re-derived. `attempt_number` and `paired_by` (`:open_attempt` | `:next_rise`) record the
    BEAM-derived correlation to a Relay attempt, or nil when none was made. `ended_relative`
    records where the end sat relative to its paired attempt: `:during`, `:after_stop` or nil.
    """
    defstruct [
      :contract_session_id,
      :started,
      :started_payload,
      :ended,
      :ended_payload,
      attempt_number: nil,
      paired_by: nil,
      ended_relative: nil
    ]
  end

  defmodule Attempt do
    @moduledoc """
    One mission attempt, bounded by game lifecycle evidence only.

    `mission` is `:playing` (open; last known state), `:stopped` (closed by `mission.stopped`) or
    `:superseded` (another `mission.playing` arrived while this was open; its end was not observed).
    A superseded attempt records `superseded_at`, the sequence of the rise that superseded it: the
    boundary of its evidence on the stream, which is not a stop and fabricates none.
    `interruptions` lists the times the instance's connection closed while this attempt was open,
    each with `after_sequence`, the last sequence the instance had received at that moment; they
    are transport evidence and leave `mission` untouched.

    `contract_session_id` / `contract_paired_by` record the BEAM-derived correlation to a Glacier
    contract session (M2 B2); `contract_candidates` lists the session ids that were waiting when
    this attempt opened if there was more than one (ambiguous: none paired). `disposition` comes
    only from the paired session's `contract.ended`.
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
      superseded_at: nil,
      interruptions: [],
      # Actor outcomes in stream order (M2 B1).
      outcomes: [],
      # Contract correlation (M2 B2).
      contract_session_id: nil,
      contract_paired_by: nil,
      contract_candidates: [],
      disposition: :not_observed,
      # Disguise occurrences in stream order (M2 B3): facts, never derived state.
      disguise_events: [],
      # Item occurrences in stream order (M2 B4): facts, never derived state.
      item_events: []
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
              connections: [],
              # Contract lifecycle evidence (M2 B2), in stream order, paired or not.
              contract_sessions: [],
              # Started sessions not yet correlated to an attempt (ids, in stream order).
              pending_contracts: [],
              # contract.ended with no open session of that id: kept, never attached by adjacency.
              unmatched_contract_ends: [],
              # Observable discrepancies in the correlated evidence (id mismatch, ambiguity, ...).
              anomalies: [],
              # Disguise occurrences with no open attempt (M2 B3): kept, never attached by adjacency.
              unattributed_disguise_events: [],
              # Item occurrences with no open attempt (M2 B4): kept, never attached by adjacency.
              unattributed_item_events: []
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

        envelope.event_type == GlacierRelay.Events.contract_started() ->
          contract_started(instance, envelope.payload, observation)

        envelope.event_type == GlacierRelay.Events.contract_ended() ->
          contract_ended(instance, envelope.payload, observation)

        GlacierRelay.Events.disguise_event?(envelope.event_type) ->
          record_disguise(instance, envelope, received_at)

        GlacierRelay.Events.item_event?(envelope.event_type) ->
          record_item(instance, envelope, received_at)
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
            | interruptions:
                attempt.interruptions ++
                  [%{at: at, reason: reason, after_sequence: instance.last_sequence}]
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
          {replace_last(instance.attempts, %{
             open
             | mission: :superseded,
               superseded_by: number,
               superseded_at: observation.sequence
           }), [{:superseded, open.number, number}]}
      end

    attempt = %Attempt{
      number: number,
      scene_resource: payload.scene_resource,
      scene_type: payload.scene_type,
      codename_hint: payload.codename_hint,
      playing: observation
    }

    instance = %{instance | attempts: attempts ++ [attempt]}
    {instance, more} = pair_pending_contract(instance, attempt)
    {instance, notes ++ more}
  end

  # -- contract lifecycle (M2 B2) ------------------------------------------------------------

  defp contract_started(instance, payload, observation) do
    id = payload.contract_session_id

    session = %ContractSession{
      contract_session_id: id,
      started: observation,
      started_payload: payload
    }

    notes =
      if Enum.any?(instance.contract_sessions, &(&1.contract_session_id == id)),
        do: [{:contract_started_again, id, observation.sequence}],
        else: []

    instance = %{instance | contract_sessions: instance.contract_sessions ++ [session]}

    case current_attempt(instance) do
      %Attempt{contract_session_id: nil, contract_candidates: []} = open ->
        # The restart path: the new session's start is emitted after the rise.
        {pair(instance, open, session, :open_attempt), notes}

      _ ->
        # The fresh-load path (no attempt open yet), or an open attempt that already has its
        # session or was left ambiguous: wait for the next rise. More than one waiting session is
        # ambiguity to be reported at that rise, not resolved here.
        pending = instance.pending_contracts ++ [id]

        notes =
          if length(pending) > 1,
            do: notes ++ [{:contract_pending_multiple, pending}],
            else: notes

        {%{instance | pending_contracts: pending}, notes}
    end
  end

  defp pair_pending_contract(instance, attempt) do
    case instance.pending_contracts do
      [] ->
        {instance, []}

      [id] ->
        session = find_session(instance, id, :open)
        instance = %{instance | pending_contracts: []}
        {pair(instance, attempt, session, :next_rise), []}

      ids ->
        # Ambiguous: no session is declared authoritative. The candidates stay visible on the
        # attempt and the sessions stay unpaired evidence.
        attempt = %{attempt | contract_candidates: ids}
        anomaly = %{kind: :contract_pairing_ambiguous, attempt: attempt.number, candidates: ids}

        {%{
           instance
           | attempts: replace_last(instance.attempts, attempt),
             pending_contracts: [],
             anomalies: instance.anomalies ++ [anomaly]
         }, [{:contract_pairing_ambiguous, attempt.number, ids}]}
    end
  end

  # Records the correlation on both sides and runs the consistency check. The pairing is made by
  # order; a differing registry id on the rise is recorded as an anomaly and changes nothing.
  defp pair(instance, %Attempt{} = attempt, %ContractSession{} = session, how) do
    attempt = %{
      attempt
      | contract_session_id: session.contract_session_id,
        contract_paired_by: how
    }

    session = %{session | attempt_number: attempt.number, paired_by: how}
    session_id = session.contract_session_id

    anomalies =
      case attempt.playing.game_session_id do
        nil ->
          []

        ^session_id ->
          []

        other ->
          [
            %{
              kind: :contract_session_id_mismatch,
              attempt: attempt.number,
              rise_game_session_id: other,
              contract_session_id: session.contract_session_id,
              paired_by: how
            }
          ]
      end

    %{
      instance
      | attempts: List.replace_at(instance.attempts, attempt.number - 1, attempt),
        contract_sessions: replace_session(instance.contract_sessions, session),
        anomalies: instance.anomalies ++ anomalies
    }
  end

  defp contract_ended(instance, payload, observation) do
    id = payload.contract_session_id

    open_sessions =
      Enum.filter(instance.contract_sessions, &(&1.contract_session_id == id and is_nil(&1.ended)))

    case open_sessions do
      [session] ->
        session = %{session | ended: observation, ended_payload: payload}

        {session, attempts, notes} =
          case session.attempt_number do
            nil ->
              {session, instance.attempts, []}

            number ->
              attempt = Enum.at(instance.attempts, number - 1)

              relative =
                cond do
                  attempt.stopped == nil -> :during
                  observation.sequence > attempt.stopped.sequence -> :after_stop
                  true -> :during
                end

              disposition = disposition_from(payload)
              attempt = %{attempt | disposition: disposition}

              {%{session | ended_relative: relative},
               List.replace_at(instance.attempts, number - 1, attempt),
               [{:attempt_disposition, number, disposition, relative}]}
          end

        {%{
           instance
           | contract_sessions: replace_session(instance.contract_sessions, session),
             attempts: attempts
         }, notes}

      [] ->
        stray = %{observation: observation, payload: payload}

        {%{instance | unmatched_contract_ends: instance.unmatched_contract_ends ++ [stray]},
         [{:unmatched_contract_end, observation.sequence, id}]}

      several ->
        # Two open sessions with the same Glacier id: which one ended is not decidable from
        # evidence. Keep the end unmatched and say so.
        stray = %{observation: observation, payload: payload}

        anomaly = %{
          kind: :contract_end_ambiguous,
          contract_session_id: id,
          sequence: observation.sequence,
          open_sessions: Enum.map(several, & &1.started.sequence)
        }

        {%{
           instance
           | unmatched_contract_ends: instance.unmatched_contract_ends ++ [stray],
             anomalies: instance.anomalies ++ [anomaly]
         }, [{:contract_end_ambiguous, observation.sequence, id}]}
    end
  end

  defp disposition_from(%{reason_kind: "restart"}), do: :restarted
  defp disposition_from(%{reason_kind: "exit_to_menu"}), do: :exited_to_menu
  defp disposition_from(%{reason: reason}), do: {:ended, reason}

  defp find_session(instance, id, :open),
    do: Enum.find(instance.contract_sessions, &(&1.contract_session_id == id and is_nil(&1.ended)))

  # Sessions are identified for replacement by their start position, which is unique per stream.
  defp replace_session(sessions, %ContractSession{started: %{sequence: seq}} = session),
    do: Enum.map(sessions, fn s -> if s.started.sequence == seq, do: session, else: s end)

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

  # -- disguise (M2 B3) ----------------------------------------------------------------------

  defp record_disguise(instance, envelope, received_at) do
    type =
      cond do
        envelope.event_type == GlacierRelay.Events.disguise_equipped() -> :equipped
        envelope.event_type == GlacierRelay.Events.disguise_compromised() -> :compromised
        true -> :compromise_cleared
      end

    kind =
      case envelope.payload[:kind] do
        "initial" -> :initial
        "change" -> :change
        _ -> nil
      end

    occurrence = %DisguiseOccurrence{
      type: type,
      kind: kind,
      sequence: envelope.sequence,
      timestamp: envelope.timestamp,
      received_at: received_at,
      payload: envelope.payload
    }

    case current_attempt(instance) do
      nil ->
        {%{
           instance
           | unattributed_disguise_events: instance.unattributed_disguise_events ++ [occurrence]
         }, [{:unattributed_disguise_event, envelope.sequence}]}

      open ->
        {%{
           instance
           | attempts:
               replace_last(instance.attempts, %{
                 open
                 | disguise_events: open.disguise_events ++ [occurrence]
               })
         }, []}
    end
  end

  # -- items (M2 B4) -------------------------------------------------------------------------

  defp record_item(instance, envelope, received_at) do
    type =
      cond do
        envelope.event_type == GlacierRelay.Events.item_picked_up() -> :picked_up
        envelope.event_type == GlacierRelay.Events.item_thrown() -> :thrown
        true -> :removed_from_inventory
      end

    occurrence = %ItemOccurrence{
      type: type,
      sequence: envelope.sequence,
      timestamp: envelope.timestamp,
      received_at: received_at,
      payload: envelope.payload
    }

    case current_attempt(instance) do
      nil ->
        {%{instance | unattributed_item_events: instance.unattributed_item_events ++ [occurrence]},
         [{:unattributed_item_event, envelope.sequence}]}

      open ->
        {%{
           instance
           | attempts:
               replace_last(instance.attempts, %{open | item_events: open.item_events ++ [occurrence]})
         }, []}
    end
  end

  defp replace_last(list, item), do: List.replace_at(list, length(list) - 1, item)
end

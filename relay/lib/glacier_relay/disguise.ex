defmodule GlacierRelay.Disguise do
  @moduledoc """
  BEAM's reading of an attempt's disguise occurrences (M2 B3, design section 30.8). Pure: a fold
  over `Attempt.disguise_events` plus the attempt's existing gap and interruption evidence, rebuilt
  on demand and never stored. The facts are the events; everything here is labelled derivation.

  What it derives, and what it refuses to:

  - `initial` — the first `equipped/initial` occurrence (the outfit the attempt began in, as the
    engine asserted it at intro end). `contract.started`'s starting disguise never initializes it.
  - `worn` — the current **wearing interval**: started by every `change`, and by an `initial`
    seen before any change. Nothing but an `equipped` occurrence moves it.
  - `compromise_episodes` — a derived grouping of the compromised/cleared occurrences: a
    `compromised X` with no open episode for X opens one; while one is open, further
    `compromised X` are appended as restatements; a `cleared X` closes it; a `cleared X` with none
    open is an anomaly and creates no episode. The occurrences stay in `disguise_events` untouched.
  - `worn_standing` — for the current interval only, in this order: (1) a gap or interruption
    inside the interval makes it unreliable: `:unknown`, and nothing that arrives afterwards can
    re-establish it, not even a compromise or clear naming the (possibly stale) worn id; (2) else
    the latest compromised/cleared occurrence inside the interval decides — `:compromised` or
    `:cleared` if it names the worn id, `:unknown` if it names another; (3) else, if any compromise
    occurrence exists earlier on the attempt — open or cleared, any id — `:unknown` (a change
    invalidates the previous interval's standing, cleared or not); (4) else `:not_observed`.
  - `standing_cut` — why the interval is unreliable and what it said before the cut (shown, not
    asserted).
  - `history` — attempt-level completeness from the same gap and interruption evidence, bounded
    on the stream by the attempt's stop or, for a superseded attempt, by the rise that superseded
    it (`{:superseded, by, at_sequence}`); later attempts' gaps never reach an earlier attempt.

  It never says "clean", never carries a standing across a change, never infers who noticed or
  why a compromise cleared, and never resolves an id to a name.
  """

  alias GlacierRelay.Lifecycle.{Attempt, DisguiseOccurrence, Instance}

  @type standing :: :not_observed | :compromised | :cleared | :unknown

  @doc "The derived disguise view of one attempt, given its instance (for gaps and the paired session)."
  @spec derive(Attempt.t(), Instance.t()) :: map()
  def derive(%Attempt{} = attempt, %Instance{} = instance) do
    events = attempt.disguise_events
    gaps = gaps_in_attempt(instance.gaps, attempt)
    interruptions = Enum.map(attempt.interruptions, &{:interruption, &1.at, &1.reason, &1.after_sequence})

    folded = Enum.reduce(events, initial_state(), &fold/2)

    {standing, reason, cut} = standing(folded, events, gaps, interruptions)

    history_reasons =
      Enum.map(gaps, fn {expected, got} -> {:gap, expected, got} end) ++
        Enum.map(interruptions, fn {:interruption, at, reason, _} -> {:interruption, at, reason} end) ++
        if(attempt.mission == :superseded,
          do: [{:superseded, attempt.superseded_by, attempt.superseded_at}],
          else: []
        )

    %{
      initial: folded.initial,
      worn: folded.worn,
      compromise_episodes: Enum.reverse(folded.episodes),
      worn_standing: standing,
      # Which rule of the order above decided: nil | :cut | :latest_names_worn | :latest_names_other |
      # :earlier_compromise | :none
      standing_reason: reason,
      standing_cut: cut,
      used: Enum.reverse(folded.used),
      changes: folded.changes,
      history: if(history_reasons == [], do: :complete, else: {:incomplete, history_reasons}),
      notes: Enum.reverse(folded.notes),
      anomalies: Enum.reverse(folded.anomalies) ++ contract_anomaly(folded, attempt, instance),
      occurrences: length(events)
    }
  end

  # -- fold over the facts -------------------------------------------------------------------

  defp initial_state do
    %{
      initial: :not_observed,
      worn: :not_observed,
      change_seen?: false,
      episodes: [],
      used: [],
      changes: 0,
      notes: [],
      anomalies: []
    }
  end

  defp fold(%DisguiseOccurrence{type: :equipped, kind: :initial} = o, state) do
    id = o.payload.disguise_repository_id
    state = use_id(state, id)

    cond do
      state.change_seen? ->
        anomaly(state, {:initial_after_change, o.sequence, id})

      state.initial == :not_observed ->
        %{
          state
          | initial: %{repository_id: id, sequence: o.sequence},
            worn: %{repository_id: id, since_sequence: o.sequence, kind: :initial}
        }

      true ->
        state = note(state, {:initial_restated, o.sequence})

        if id == state.initial.repository_id,
          do: state,
          else: anomaly(state, {:initial_conflict, o.sequence, id, state.initial.repository_id})
    end
  end

  defp fold(%DisguiseOccurrence{type: :equipped, kind: :change} = o, state) do
    id = o.payload.disguise_repository_id

    %{
      use_id(state, id)
      | worn: %{repository_id: id, since_sequence: o.sequence, kind: :change},
        change_seen?: true,
        changes: state.changes + 1
    }
  end

  defp fold(%DisguiseOccurrence{type: :compromised} = o, state) do
    id = o.payload.disguise_repository_id

    state =
      case open_episode_index(state.episodes, id) do
        nil ->
          episode = %{repository_id: id, compromised_sequences: [o.sequence], cleared_sequence: nil}
          %{state | episodes: [episode | state.episodes]}

        index ->
          episode = Enum.at(state.episodes, index)
          episode = %{episode | compromised_sequences: episode.compromised_sequences ++ [o.sequence]}

          note(
            %{state | episodes: List.replace_at(state.episodes, index, episode)},
            {:compromised_restated, id, o.sequence}
          )
      end

    case state.worn do
      %{repository_id: ^id} -> state
      _ -> note(state, {:compromised_not_worn, id, o.sequence})
    end
  end

  defp fold(%DisguiseOccurrence{type: :compromise_cleared} = o, state) do
    id = o.payload.disguise_repository_id

    case open_episode_index(state.episodes, id) do
      nil ->
        anomaly(state, {:cleared_without_compromise, id, o.sequence})

      index ->
        episode = %{Enum.at(state.episodes, index) | cleared_sequence: o.sequence}
        %{state | episodes: List.replace_at(state.episodes, index, episode)}
    end
  end

  defp open_episode_index(episodes, id),
    do: Enum.find_index(episodes, &(&1.repository_id == id and is_nil(&1.cleared_sequence)))

  defp use_id(state, id), do: if(id in state.used, do: state, else: %{state | used: [id | state.used]})
  defp note(state, n), do: %{state | notes: [n | state.notes]}
  defp anomaly(state, a), do: %{state | anomalies: [a | state.anomalies]}

  # -- standing of the current wearing interval ----------------------------------------------

  defp standing(%{worn: :not_observed}, _events, _gaps, _interruptions), do: {:not_observed, nil, nil}

  defp standing(%{worn: worn}, events, gaps, interruptions) do
    since = worn.since_sequence

    # Occurrences of the current interval (after the equipped that started it), and whether any
    # compromise was observed before it.
    interval =
      events
      |> Enum.filter(&(&1.sequence > since and &1.type in [:compromised, :compromise_cleared]))

    earlier_compromise? = Enum.any?(events, &(&1.type == :compromised and &1.sequence < since))

    # The earliest cut inside the interval, as a stream position: a gap's first missing sequence,
    # or the position right after an interruption's last received sequence.
    cuts =
      Enum.map(gaps, fn {expected, got} -> {expected, {:gap, expected, got}} end) ++
        Enum.map(interruptions, fn {:interruption, at, reason, after_seq} ->
          {after_seq + 1, {:interruption, at, reason}}
        end)

    case cuts |> Enum.filter(fn {pos, _} -> pos > since end) |> Enum.min_by(&elem(&1, 0), fn -> nil end) do
      nil ->
        {standing, reason} = decide(interval, worn.repository_id, earlier_compromise?)
        {standing, reason, nil}

      {pos, cut} ->
        before = Enum.filter(interval, &(&1.sequence < pos))
        {standing_before, _} = decide(before, worn.repository_id, earlier_compromise?)
        {:unknown, :cut, %{cut: cut, standing_before: standing_before}}
    end
  end

  defp decide([], _worn_id, true), do: {:unknown, :earlier_compromise}
  defp decide([], _worn_id, false), do: {:not_observed, :none}

  defp decide(occurrences, worn_id, _earlier) do
    latest = List.last(occurrences)

    cond do
      latest.payload.disguise_repository_id != worn_id -> {:unknown, :latest_names_other}
      latest.type == :compromised -> {:compromised, :latest_names_worn}
      true -> {:cleared, :latest_names_worn}
    end
  end

  # -- evidence from outside the disguise events ----------------------------------------------

  # Gaps are recorded on the instance as {expected, got}, newest first, detected at `got`. One
  # belongs to this attempt when it was detected after the rise and no later than the attempt's
  # end on the stream: its stop, or — for a superseded attempt, whose stop was never observed —
  # the rise that superseded it (a gap detected at that rise is this attempt's evidence; gaps
  # detected later belong to later attempts). An open attempt has no upper bound.
  defp gaps_in_attempt(gaps, %Attempt{playing: %{sequence: lo}} = attempt) do
    hi =
      cond do
        attempt.stopped -> attempt.stopped.sequence
        attempt.mission == :superseded -> attempt.superseded_at
        true -> nil
      end

    gaps
    |> Enum.reverse()
    |> Enum.filter(fn {_expected, got} -> got > lo and (is_nil(hi) or got <= hi) end)
  end

  # The paired contract session's starting disguise is a session-level statement correlated by
  # order; it never initializes `worn`, but a differing in-attempt initial is worth recording.
  defp contract_anomaly(%{initial: :not_observed}, _attempt, _instance), do: []

  defp contract_anomaly(%{initial: initial}, %Attempt{contract_session_id: nil}, _instance) when not is_nil(initial),
    do: []

  defp contract_anomaly(%{initial: initial}, attempt, instance) do
    session =
      Enum.find(instance.contract_sessions, fn c ->
        c.attempt_number == attempt.number and c.contract_session_id == attempt.contract_session_id
      end)

    case session do
      %{started_payload: %{starting_disguise_repository_id: id}} when id != initial.repository_id ->
        [{:initial_differs_from_contract, initial.sequence, initial.repository_id, id}]

      _ ->
        []
    end
  end
end

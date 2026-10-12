defmodule GlacierRelay.PlayerState do
  @moduledoc """
  BEAM's reading of an attempt's player-state occurrences (M2 B6, design section 46.6). Pure: a
  fold over `Attempt.player_state_events` plus the attempt's bounded gap and interruption evidence,
  rebuilt on demand and never stored. The facts are the occurrences; everything here is a labelled
  derivation of "the last thing the engine said", never a claim about the current state.

  Two subjects, tracked independently (`trespassing`, `illegal_weapon`). Per subject:

  - `last` — `:not_observed` when the attempt carries no occurrence of the subject (the attempt
    began with no assertion: **not `false`**), else the most recent occurrence's value with its
    sequence and the metadata that occurrence carried (`room_id`; `weapon`).
  - `occurrences` — the number of occurrences of the subject on the attempt.
  - `observed_value_changes` — how many consecutive *received* occurrences differed in value.
    A difference between two consecutive received values is an observed change; it is not a
    complete count of engine transitions: the engine may have stated other values that were not
    delivered (a gap), and repeated identical statements count as occurrences, not changes.
  - `standing` — `:not_observed`; `:last_observed` (the last value, labelled as the last thing
    the engine said at that sequence); or `:unknown` when a gap or an observation interruption
    inside the attempt follows the subject's last occurrence — the engine may have said something
    that was not delivered. The last value is preserved beside it as historical evidence.
    `standing_cut` names the earliest such cut. A cut *before* the last occurrence leaves the
    standing `:last_observed`: a later valid occurrence establishes a fresh last-observed value,
    but it cannot reconstruct the missing interval, which the attempt's `history` still reports.
  - `last_weapon` (illegal weapon only) — the most recent occurrence that named a weapon object,
    with its sequence: the last available associated metadata, not an item that is held.
  - `notes` — unexpected combinations recorded as observations: a `true` without a weapon
    object, a `false` with one. Nothing is derived from them.
  - `history` — `AttemptHistory.history/2` (the shared bounding; later attempts cannot alter it).

  One subject's new occurrence never repairs the other subject's unknown standing. Nothing is
  derived across attempts, from the item or disguise families, from timestamps (no durations),
  or about safety, detection, possession, inventory, health or death.
  """

  alias GlacierRelay.AttemptHistory
  alias GlacierRelay.Lifecycle.{Attempt, Instance, PlayerStateOccurrence}

  @type standing :: :not_observed | :last_observed | :unknown

  @doc "The derived player-state view of one attempt, given its instance (for the bounded gaps)."
  @spec derive(Attempt.t(), Instance.t()) :: map()
  def derive(%Attempt{} = attempt, %Instance{} = instance) do
    events = attempt.player_state_events
    gaps = AttemptHistory.gaps_in_attempt(instance.gaps, attempt)

    # Every cut inside the attempt as a stream position: a gap's first missing sequence, or the
    # position right after an interruption's last received sequence (the Disguise rule).
    cuts =
      Enum.map(gaps, fn {expected, got} -> {expected, {:gap, expected, got}} end) ++
        Enum.map(attempt.interruptions, fn i -> {i.after_sequence + 1, {:interruption, i.at, i.reason}} end)

    %{
      trespassing: subject(:trespassing, events, cuts),
      illegal_weapon: subject(:illegal_weapon, events, cuts),
      history: AttemptHistory.history(attempt, instance.gaps),
      occurrences: length(events)
    }
  end

  defp subject(subject, events, cuts) do
    own = Enum.filter(events, &(&1.subject == subject))

    base = %{
      last: :not_observed,
      occurrences: length(own),
      observed_value_changes: observed_value_changes(own),
      standing: :not_observed,
      standing_cut: nil,
      notes: Enum.flat_map(own, &notes/1)
    }

    base = if subject == :illegal_weapon, do: Map.put(base, :last_weapon, last_weapon(own)), else: base

    case List.last(own) do
      nil ->
        base

      %PlayerStateOccurrence{} = last ->
        cut =
          cuts
          |> Enum.filter(fn {pos, _} -> pos > last.sequence end)
          |> Enum.min_by(&elem(&1, 0), fn -> nil end)

        %{
          base
          | last: last_view(last),
            standing: if(cut, do: :unknown, else: :last_observed),
            standing_cut: cut && elem(cut, 1)
        }
    end
  end

  defp value(%PlayerStateOccurrence{subject: :trespassing, payload: p}), do: p.trespassing
  defp value(%PlayerStateOccurrence{subject: :illegal_weapon, payload: p}), do: p.holding

  defp observed_value_changes(own) do
    own
    |> Enum.map(&value/1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> a != b end)
  end

  defp last_view(%PlayerStateOccurrence{subject: :trespassing, payload: p} = o) do
    %{value: p.trespassing, sequence: o.sequence, engine_timestamp_s: p.engine_timestamp_s, room_id: p.room_id}
  end

  defp last_view(%PlayerStateOccurrence{subject: :illegal_weapon, payload: p} = o) do
    %{value: p.holding, sequence: o.sequence, engine_timestamp_s: p.engine_timestamp_s, weapon: p.weapon}
  end

  defp last_weapon(own) do
    case own |> Enum.filter(&(&1.payload.weapon != nil)) |> List.last() do
      nil -> nil
      %PlayerStateOccurrence{} = o -> %{sequence: o.sequence, weapon: o.payload.weapon}
    end
  end

  defp notes(%PlayerStateOccurrence{subject: :illegal_weapon, payload: %{holding: true, weapon: nil}} = o),
    do: [{:no_weapon_named_on_true, o.sequence}]

  defp notes(%PlayerStateOccurrence{subject: :illegal_weapon, payload: %{holding: false, weapon: w}} = o) when not is_nil(w),
    do: [{:weapon_named_on_false, o.sequence}]

  defp notes(_), do: []
end

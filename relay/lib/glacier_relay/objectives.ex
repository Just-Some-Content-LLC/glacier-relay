defmodule GlacierRelay.Objectives do
  @moduledoc """
  BEAM's reading of an attempt's objective occurrences (M2 B5, design section 42.7). Pure: a fold
  over `Attempt.objective_events` plus the attempt's bounded history evidence, rebuilt on demand and
  never stored. It uses the attribution each occurrence recorded at receipt and never re-evaluates
  it against the attempt's current pairing state.

  What it derives:

  - `completed` — the number of occurrences on the attempt (independent of how many distinct ids).
  - `by_objective` — per `objective_id`, first-seen order, a **display grouping** of the occurrences,
    not objective state: every occurrence's sequence; the first non-empty observed `objective_type`
    and `objective_category` (an empty string is no value); `exclude_from_scoring` presence-aware —
    `:not_observed` while never present, otherwise the first observed boolean, `false` preserved as
    `false`; and `conflicts`, every later occurrence whose present, non-empty value differs from the
    row's, kept in order and never resolved.
  - `objective_ids` — the distinct ids, first-seen order.
  - `history` — `AttemptHistory.history/2` (the shared bounding; later attempts cannot alter it).

  What it refuses to derive: how many objectives the contract has; whether any objective is
  outstanding or failed; whether the mission was completed; which actor an objective concerned;
  the "true" metadata of an objective when observations conflict.
  """

  alias GlacierRelay.AttemptHistory
  alias GlacierRelay.Lifecycle.{Attempt, Instance, ObjectiveOccurrence}

  @doc "The derived objective view of one attempt, given its instance (for the bounded gaps)."
  @spec derive(Attempt.t(), Instance.t()) :: map()
  def derive(%Attempt{} = attempt, %Instance{} = instance) do
    events = attempt.objective_events
    rows = events |> Enum.reduce([], &fold/2) |> Enum.reverse()

    %{
      completed: length(events),
      by_objective: rows,
      objective_ids: Enum.map(rows, & &1.objective_id),
      history: AttemptHistory.history(attempt, instance.gaps),
      occurrences: length(events)
    }
  end

  defp fold(%ObjectiveOccurrence{sequence: seq, payload: p}, rows) do
    id = p.objective_id

    case Enum.find_index(rows, &(&1.objective_id == id)) do
      nil ->
        [new_row(id, seq, p) | rows]

      index ->
        row = Enum.at(rows, index)

        row =
          row
          |> Map.update!(:occurrences, &(&1 + 1))
          |> Map.update!(:sequences, &(&1 ++ [seq]))
          |> observe_string(:objective_type, seq, p.objective_type)
          |> observe_string(:objective_category, seq, p.objective_category)
          |> observe_bool(:exclude_from_scoring, seq, p.exclude_from_scoring)

        List.replace_at(rows, index, row)
    end
  end

  defp new_row(id, seq, p) do
    %{
      objective_id: id,
      occurrences: 1,
      sequences: [seq],
      objective_type: nil,
      objective_category: nil,
      exclude_from_scoring: :not_observed,
      conflicts: []
    }
    |> observe_string(:objective_type, seq, p.objective_type)
    |> observe_string(:objective_category, seq, p.objective_category)
    |> observe_bool(:exclude_from_scoring, seq, p.exclude_from_scoring)
  end

  # First non-empty string sticks; a later different non-empty string is a visible conflict.
  defp observe_string(row, _field, _seq, value) when value in [nil, ""], do: row

  defp observe_string(row, field, seq, value) do
    case Map.fetch!(row, field) do
      nil -> Map.put(row, field, value)
      ^value -> row
      _ -> conflict(row, seq, field, value)
    end
  end

  # Presence-aware: absent leaves :not_observed; the first observed boolean sticks (false included);
  # a later different boolean is a visible conflict.
  defp observe_bool(row, _field, _seq, nil), do: row

  defp observe_bool(row, field, seq, value) when is_boolean(value) do
    case Map.fetch!(row, field) do
      :not_observed -> Map.put(row, field, value)
      ^value -> row
      _ -> conflict(row, seq, field, value)
    end
  end

  defp conflict(row, seq, field, observed),
    do: %{row | conflicts: row.conflicts ++ [%{sequence: seq, field: field, observed: observed}]}
end

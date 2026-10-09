defmodule GlacierRelay.Items do
  @moduledoc """
  BEAM's reading of an attempt's item occurrences (M2 B4, design section 38.6). Pure: a fold over
  `Attempt.item_events` plus the attempt's bounded history evidence, rebuilt on demand and never
  stored. The facts are the occurrences; everything here is direct counting.

  What it derives:

  - `picked_up`, `thrown`, `removed_from_inventory` — the number of occurrences of each type.
    `thrown` is counted from `item.thrown` alone, whether or not a removal was observed beside it,
    and `removed_from_inventory` from `item.removed_from_inventory` alone.
  - `by_definition` — per `item_repository_id` in first-seen order: the three counts, and the first
    non-empty `item_name` / `item_type` the engine sent for it (display evidence, not identity).
  - `definitions_used` — the distinct definition ids, first-seen order.
  - `history` — attempt-level completeness from the attempt's gaps (bounded to the attempt by its
    stop or by the rise that superseded it, `AttemptHistory`), interruptions and supersession.
    Counts never infer lost occurrences: an incomplete history is shown beside them, not folded in.

  What it refuses to derive (section 38.6): any pairing of a removal with a throw; a held item;
  inventory contents; whether a thrown item was recovered; whether a pickup was "new" or a
  re-pickup of the same object (undecidable without an instance id); whether a drop at a locker was
  the held item; any link between a throw and an actor outcome; any instance identity from order,
  time or proximity.
  """

  alias GlacierRelay.AttemptHistory
  alias GlacierRelay.Lifecycle.{Attempt, Instance, ItemOccurrence}

  @types [:picked_up, :thrown, :removed_from_inventory]

  @doc "The derived item view of one attempt, given its instance (for the bounded gaps)."
  @spec derive(Attempt.t(), Instance.t()) :: map()
  def derive(%Attempt{} = attempt, %Instance{} = instance) do
    events = attempt.item_events
    by_definition = Enum.reduce(events, [], &fold/2) |> Enum.reverse()

    %{
      picked_up: count(events, :picked_up),
      thrown: count(events, :thrown),
      removed_from_inventory: count(events, :removed_from_inventory),
      by_definition: by_definition,
      definitions_used: Enum.map(by_definition, & &1.item_repository_id),
      history: AttemptHistory.history(attempt, instance.gaps),
      occurrences: length(events)
    }
  end

  defp count(events, type), do: Enum.count(events, &(&1.type == type))

  # Per-definition rows, newest-first while folding (reversed by the caller).
  defp fold(%ItemOccurrence{type: type, payload: p} = _o, rows) when type in @types do
    id = p.item_repository_id

    case Enum.find_index(rows, &(&1.item_repository_id == id)) do
      nil ->
        [new_row(id, type, p) | rows]

      index ->
        row = Enum.at(rows, index)

        row =
          row
          |> Map.update!(type, &(&1 + 1))
          |> Map.update!(:item_name, &first_non_empty(&1, p.item_name))
          |> Map.update!(:item_type, &first_non_empty(&1, p.item_type))

        List.replace_at(rows, index, row)
    end
  end

  defp new_row(id, type, p) do
    %{
      item_repository_id: id,
      picked_up: 0,
      thrown: 0,
      removed_from_inventory: 0,
      item_name: first_non_empty(nil, p.item_name),
      item_type: first_non_empty(nil, p.item_type)
    }
    |> Map.update!(type, &(&1 + 1))
  end

  defp first_non_empty(nil, value) when is_binary(value) and value != "", do: value
  defp first_non_empty(current, _value), do: current
end

defmodule GlacierRelay.Statistics.JSON do
  @moduledoc """
  Deterministic JSON for the statistics results (M4-C): a derived artifact for external tooling,
  never the primary evidence log. Object keys are emitted in sorted order whatever the map's
  internal order, so the same structured result always yields the same bytes. Structs become
  objects, tuples arrays, `DateTime` ISO-8601 strings, atoms strings (`true`, `false` and `nil`
  stay literals). The schema identifier on the result (`glacier-relay.statistics/1`) is versioned
  independently of the Relay wire schema.
  """

  @doc "Encodes a statistics result (or any value built from maps, lists, tuples, atoms, numbers, strings and DateTime values)."
  @spec encode(term()) :: String.t()
  def encode(term), do: term |> value() |> IO.iodata_to_binary()

  defp value(nil), do: "null"
  defp value(true), do: "true"
  defp value(false), do: "false"
  defp value(%DateTime{} = dt), do: JSON.encode!(DateTime.to_iso8601(dt))
  defp value(%_{} = struct), do: struct |> Map.from_struct() |> value()

  defp value(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {key(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))

    [?{, Enum.map_join(pairs, ",", fn {k, v} -> [JSON.encode!(k), ?:, value(v)] end), ?}]
  end

  defp value(list) when is_list(list), do: [?[, Enum.map_join(list, ",", &value/1), ?]]
  defp value(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> value()
  defp value(atom) when is_atom(atom), do: JSON.encode!(Atom.to_string(atom))
  defp value(n) when is_integer(n) or is_float(n), do: JSON.encode!(n)
  defp value(bin) when is_binary(bin), do: JSON.encode!(bin)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k) when is_integer(k), do: Integer.to_string(k)
  defp key(k), do: inspect(k)
end

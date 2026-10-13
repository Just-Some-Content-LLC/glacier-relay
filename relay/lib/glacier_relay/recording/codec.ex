defmodule GlacierRelay.Recording.Codec do
  @moduledoc """
  The recording's line format (M4-A, format 1): one JSON object per line, encoded
  deterministically (object keys in the order given for a record frame; nested maps with keys
  sorted; no whitespace), so that the same evidence always produces the same bytes.

  Session records (`r` present) carry the evidence's own time in `at`. Diagnostic lines written
  by the recorder (header, gap, recovered, footer) have no `r` and carry the recorder's clock in
  `recorder_at`, so the two clocks are never confused.

  The wire object of an envelope (`Envelope.raw`) is written value-exact under `envelope`. An
  envelope built in code (no wire object) is written from its validated fields with
  `"wire": false`, so a reader knows it is not the wire's bytes.
  """

  alias GlacierRelay.Recording.Record
  alias GlacierRelay.Wire.Envelope

  @format 1

  def format, do: @format

  @doc "Encodes one session record as a line (with its newline)."
  @spec encode_record(Record.t()) :: iodata()
  def encode_record(%Record{kind: :connection_opened} = r) do
    line([
      {"r", r.no},
      {"k", "connection.opened"},
      {"at", r.at},
      {"conn", r.conn},
      {"peer", r.peer}
    ])
  end

  def encode_record(%Record{kind: :connection_identified} = r) do
    line([
      {"r", r.no},
      {"k", "connection.identified"},
      {"at", r.at},
      {"conn", r.conn},
      {"peer", r.peer},
      {"instance", r.instance},
      {"previous_instance", r.previous_instance}
    ])
  end

  def encode_record(%Record{kind: :envelope, envelope: %Envelope{} = e} = r) do
    {wire, object} = envelope_object(e)

    line(
      [
        {"r", r.no},
        {"k", "envelope"},
        {"at", r.at},
        {"conn", r.conn},
        {"instance", r.instance},
        {"sequence", e.sequence},
        {"event_type", e.event_type}
      ] ++
        if(wire, do: [], else: [{"wire", false}]) ++
        [{"envelope", object}]
    )
  end

  def encode_record(%Record{kind: :connection_closed} = r) do
    line([
      {"r", r.no},
      {"k", "connection.closed"},
      {"at", r.at},
      {"conn", r.conn},
      {"peer", r.peer},
      {"instance", r.instance},
      {"reason", reason(r.reason)}
    ])
  end

  @doc "Encodes a recorder-written diagnostic line (`kind` and ordered fields)."
  @spec encode_diagnostic(String.t(), DateTime.t(), [{String.t(), term()}]) :: iodata()
  def encode_diagnostic(kind, %DateTime{} = recorder_at, fields) when is_list(fields) do
    line([{"k", kind}, {"recorder_at", recorder_at}] ++ fields)
  end

  @doc "Decodes one line into a string-keyed map (a reader's primitive; the M4-B reader builds on it)."
  @spec decode_line(binary()) :: {:ok, map()} | {:error, term()}
  def decode_line(line) when is_binary(line) do
    case JSON.decode(String.trim_trailing(line, "\n")) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :not_an_object}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  # -- encoding --------------------------------------------------------------------------------

  defp line(pairs), do: [object(pairs), ?\n]

  defp object(pairs) do
    [
      ?{,
      Enum.map_join(pairs, ",", fn {k, v} -> [JSON.encode!(to_string(k)), ?:, value(v)] end),
      ?}
    ]
  end

  defp value(nil), do: "null"
  defp value(true), do: "true"
  defp value(false), do: "false"
  defp value(%DateTime{} = dt), do: JSON.encode!(DateTime.to_iso8601(dt))
  defp value(v) when is_binary(v), do: JSON.encode!(v)
  defp value(v) when is_integer(v) or is_float(v), do: JSON.encode!(v)
  defp value(v) when is_atom(v), do: JSON.encode!(Atom.to_string(v))
  defp value(v) when is_list(v), do: [?[, Enum.map_join(v, ",", &value/1), ?]]

  defp value(v) when is_map(v) and not is_struct(v) do
    v
    |> Enum.map(fn {k, val} -> {to_string(k), val} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> object()
  end

  defp value(v) when is_tuple(v), do: JSON.encode!(inspect(v))
  defp value(v), do: JSON.encode!(inspect(v))

  # The wire object when the envelope was decoded from a line; otherwise the validated fields.
  defp envelope_object(%Envelope{raw: raw}) when is_map(raw), do: {true, raw}

  defp envelope_object(%Envelope{} = e) do
    {false,
     %{
       "protocol_version" => e.protocol_version,
       "adapter_instance_id" => e.adapter_instance_id,
       "sequence" => e.sequence,
       "timestamp" => e.timestamp,
       "event_type" => e.event_type,
       "schema_version" => e.schema_version,
       "payload" => stringify(e.payload)
     }}
  end

  defp stringify(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  defp reason(r) when is_atom(r), do: Atom.to_string(r)
  defp reason({:tcp_error, r}), do: %{"tcp_error" => inspect(r)}
  defp reason({:down, r}), do: %{"down" => inspect(r)}
  defp reason(other), do: inspect(other)
end

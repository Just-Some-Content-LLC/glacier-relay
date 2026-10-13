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

  ## Close reasons (typed vocabulary; M4-B correction B)

  A `connection.closed` record's `reason` is written from a closed vocabulary, so that a reader
  reconstructs the original term exactly where the format can, and otherwise returns a visibly
  qualified value — never a new atom, never an evaluated term:

  | recorded                                   | reconstructed                                   |
  |--------------------------------------------|-------------------------------------------------|
  | `"peer_closed"`, `"line_too_long"`         | `:peer_closed`, `:line_too_long` (exact)        |
  | `{"tcp_error": {"posix": "econnreset"}}`   | `{:tcp_error, :econnreset}` (exact; allow-list) |
  | `{"tcp_error": {"text": "<inspect>"}}`     | `{:tcp_error, {:recorded_text, text}}`          |
  | `{"down": {"exit": "killed"}}`             | `{:down, :killed}` (exact; allow-list)          |
  | `{"down": {"text": "<inspect>"}}`          | `{:down, {:recorded_text, text}}`               |
  | `{"text": "<inspect>"}`                    | `{:recorded_text, text}`                        |
  | pre-correction `{"tcp_error": "<inspect>"}`, `{"down": "<inspect>"}`, other bare string | the same qualified forms (`:legacy_text`) |
  | anything else                              | `{:unrecognized_reason, value}`                 |

  The allow-lists are the POSIX socket error atoms `:inet` reports and the common exit reasons;
  a name outside them is returned as recorded text (`:outside_vocabulary`), not turned into an
  atom. Inspected text is bounded (`inspect/2` limits) and is evidence, not a term.
  """

  alias GlacierRelay.Recording.Record
  alias GlacierRelay.Wire.Envelope

  @format 1

  @posix ~w(eacces eaddrinuse eaddrnotavail eafnosupport ealready econnaborted econnrefused
            econnreset edestaddrreq ehostdown ehostunreach einprogress eisconn emsgsize enetdown
            enetunreach enopkg enoprotoopt enotconn enotty enotsock eproto eprotonosupport
            eprototype esocktnosupport etimedout ewouldblock exbadport exbadseq nxdomain epipe
            closed timeout)a
  @exits ~w(normal shutdown killed noproc noconnection timeout)a
  @posix_names Map.new(@posix, &{Atom.to_string(&1), &1})
  @exit_names Map.new(@exits, &{Atom.to_string(&1), &1})
  @text_opts [limit: 100, printable_limit: 2_048]

  def format, do: @format

  @doc "The close-reason terms the format reconstructs exactly (besides the two atomic reasons)."
  def exact_reason_vocabulary, do: %{tcp_error: @posix, down: @exits}

  @doc "Encodes a close reason into the typed vocabulary (a JSON value)."
  @spec encode_reason(term()) :: String.t() | map()
  def encode_reason(:peer_closed), do: "peer_closed"
  def encode_reason(:line_too_long), do: "line_too_long"

  def encode_reason({:tcp_error, r}) when r in @posix,
    do: %{"tcp_error" => %{"posix" => Atom.to_string(r)}}

  def encode_reason({:tcp_error, r}), do: %{"tcp_error" => %{"text" => text(r)}}
  def encode_reason({:down, r}) when r in @exits, do: %{"down" => %{"exit" => Atom.to_string(r)}}
  def encode_reason({:down, r}), do: %{"down" => %{"text" => text(r)}}
  def encode_reason(other), do: %{"text" => text(other)}

  @doc """
  Decodes a recorded close reason: `{:exact, term}` when the format reconstructs the original
  term, otherwise `{:qualified, term, why}` with `why` one of `:unrepresentable` (the recorder
  could only write text), `:legacy_text` (a pre-correction inspected string),
  `:outside_vocabulary` (a typed name this reader does not know) or `:unrecognized` (a shape
  the format never writes). No atom is created from the recorded value.
  """
  @spec decode_reason(term()) :: {:exact, term()} | {:qualified, term(), atom()}
  def decode_reason("peer_closed"), do: {:exact, :peer_closed}
  def decode_reason("line_too_long"), do: {:exact, :line_too_long}

  def decode_reason(%{"tcp_error" => %{"posix" => name} = m} = v)
      when is_binary(name) and map_size(m) == 1 and map_size(v) == 1 do
    case @posix_names do
      %{^name => atom} -> {:exact, {:tcp_error, atom}}
      _ -> {:qualified, {:tcp_error, {:recorded_text, name}}, :outside_vocabulary}
    end
  end

  def decode_reason(%{"tcp_error" => %{"text" => t} = m} = v)
      when is_binary(t) and map_size(m) == 1 and map_size(v) == 1,
      do: {:qualified, {:tcp_error, {:recorded_text, t}}, :unrepresentable}

  def decode_reason(%{"down" => %{"exit" => name} = m} = v)
      when is_binary(name) and map_size(m) == 1 and map_size(v) == 1 do
    case @exit_names do
      %{^name => atom} -> {:exact, {:down, atom}}
      _ -> {:qualified, {:down, {:recorded_text, name}}, :outside_vocabulary}
    end
  end

  def decode_reason(%{"down" => %{"text" => t} = m} = v)
      when is_binary(t) and map_size(m) == 1 and map_size(v) == 1,
      do: {:qualified, {:down, {:recorded_text, t}}, :unrepresentable}

  def decode_reason(%{"text" => t} = v) when is_binary(t) and map_size(v) == 1,
    do: {:qualified, {:recorded_text, t}, :unrepresentable}

  # Format 1 before correction B: inspected strings.
  def decode_reason(%{"tcp_error" => t} = v) when is_binary(t) and map_size(v) == 1,
    do: {:qualified, {:tcp_error, {:recorded_text, t}}, :legacy_text}

  def decode_reason(%{"down" => t} = v) when is_binary(t) and map_size(v) == 1,
    do: {:qualified, {:down, {:recorded_text, t}}, :legacy_text}

  def decode_reason(s) when is_binary(s), do: {:qualified, {:recorded_text, s}, :legacy_text}
  def decode_reason(other), do: {:qualified, {:unrecognized_reason, other}, :unrecognized}

  defp text(term), do: inspect(term, @text_opts)

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
      {"reason", encode_reason(r.reason)}
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
end

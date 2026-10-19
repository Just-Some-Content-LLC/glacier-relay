defmodule GlacierRelay.Motion.LineCodec do
  @moduledoc """
  M7-B1: the strict line codec shared by the motion link (`Motion.Codec`, `127.0.0.1:4750`) and the
  peer link (`Peer.Codec`; `docs/design/M7_NETWORK_GHOST.md` section 15.6). One UTF-8 JSON object per
  line, at most the codec's byte bound, carrying its protocol-version key and a `kind`. A kind is
  decoded only against its declared field specification: every field known, required ones present,
  each of its declared type and within its bounds; an unknown kind, field or version is an error and
  never execution. Field names map to atoms through the specification only — nothing from the wire
  becomes an atom.

  Field types: `:uuid` (lowercase UUID), `:pos_integer`, `:non_neg_integer`, `{:integer, min, max}`,
  `:boolean`, `{:text, max_bytes}`, `{:enum, [text]}`, `{:words, n}` (n binary32 words, eight
  lowercase hex digits each, comma-joined, every word finite — `Command.TransformWords`), `:hex32`,
  `:mac` (64 lowercase hex digits), `{:list_of_text, max_items, max_bytes}`. Presence is `:required`
  (present and not null) or `:optional` (absent or null decodes to nil).
  """

  alias GlacierRelay.Command.{Schema, TransformWords}

  @hex32 ~r/^[0-9a-f]{32}$/

  @doc """
  Decodes one line (without its newline). `codec`: `%{max_bytes, version_key, versions, specs}`
  where `specs` maps a kind's text to `{kind_atom, [{"field", :atom, type, presence}]}`. Returns
  `{:ok, {kind_atom, fields}}` (fields keyed by the declared atoms, plus `:version`) or
  `{:error, reason}`.
  """
  def decode(line, %{max_bytes: max, version_key: vkey, versions: versions, specs: specs})
      when is_binary(line) do
    with :ok <- if(byte_size(line) <= max, do: :ok, else: {:error, :line_too_long}),
         :ok <- if(String.valid?(line), do: :ok, else: {:error, :invalid_utf8}),
         {:ok, map} <- json(line),
         {:ok, version} <- version(map, vkey, versions),
         {:ok, {kind, fields_spec}} <- kind(map, specs),
         :ok <- known_keys(map, [vkey, "kind" | Enum.map(fields_spec, &elem(&1, 0))]),
         {:ok, fields} <- fields(map, fields_spec) do
      {:ok, {kind, Map.put(fields, :version, version)}}
    end
  end

  def decode(_line, _codec), do: {:error, :not_a_line}

  @doc """
  Encodes one line (with its newline): the version key, the kind and the given string-keyed fields.
  Raises when the encoded line exceeds the codec's bound — the encoder's caller supplies validated
  values only.
  """
  def encode(%{max_bytes: max, version_key: vkey}, version, kind, fields)
      when is_binary(kind) and is_map(fields) do
    line = JSON.encode!(Map.merge(fields, %{vkey => version, "kind" => kind})) <> "\n"
    true = byte_size(line) - 1 <= max
    line
  end

  defp json(line) do
    case JSON.decode(line) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :not_an_object}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp version(map, key, versions) do
    case Map.fetch(map, key) do
      {:ok, v} -> if v in versions, do: {:ok, v}, else: {:error, {:unsupported_version, v}}
      :error -> {:error, :missing_version}
    end
  end

  defp kind(%{"kind" => kind}, specs) when is_binary(kind) do
    case Map.fetch(specs, kind) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_kind, String.slice(kind, 0, 64)}}
    end
  end

  defp kind(%{"kind" => _}, _specs), do: {:error, :kind_not_text}
  defp kind(_, _specs), do: {:error, :missing_kind}

  defp known_keys(map, allowed) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_fields, unknown |> Enum.sort() |> Enum.take(8)}}
    end
  end

  defp fields(map, spec) do
    Enum.reduce_while(spec, {:ok, %{}}, fn {key, atom, type, presence}, {:ok, acc} ->
      case field(map, key, type, presence) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, atom, value)}}
        {:error, why} -> {:halt, {:error, {:invalid_field, key, why}}}
      end
    end)
  end

  defp field(map, key, type, presence) do
    case {Map.fetch(map, key), presence} do
      {:error, :required} -> {:error, :missing}
      {:error, :optional} -> {:ok, nil}
      {{:ok, nil}, :optional} -> {:ok, nil}
      {{:ok, nil}, :required} -> {:error, :missing}
      {{:ok, value}, _} -> check(type, value)
    end
  end

  @doc "Checks one value against a field type: `{:ok, value}` or `{:error, why}`."
  def check(:uuid, v), do: if(Schema.uuid?(v), do: {:ok, v}, else: {:error, :not_a_uuid})

  def check(:pos_integer, v),
    do: if(is_integer(v) and v > 0, do: {:ok, v}, else: {:error, :not_a_positive_integer})

  def check(:non_neg_integer, v),
    do: if(is_integer(v) and v >= 0, do: {:ok, v}, else: {:error, :not_a_non_negative_integer})

  def check({:integer, min, max}, v),
    do:
      if(is_integer(v) and v >= min and v <= max,
        do: {:ok, v},
        else: {:error, {:not_an_integer_within, min, max}}
      )

  def check(:boolean, v), do: if(is_boolean(v), do: {:ok, v}, else: {:error, :not_a_boolean})

  def check({:text, max}, v),
    do:
      if(is_binary(v) and byte_size(v) <= max,
        do: {:ok, v},
        else: {:error, {:not_text_within, max}}
      )

  def check({:enum, allowed}, v),
    do: if(v in allowed, do: {:ok, v}, else: {:error, {:not_one_of, allowed}})

  def check({:words, n}, v) when is_binary(v) do
    case TransformWords.decode(v, n) do
      {:ok, _words} -> {:ok, v}
      {:error, why} -> {:error, {:not_finite_words, n, why}}
    end
  end

  def check({:words, n}, _v), do: {:error, {:not_finite_words, n, :not_text}}

  def check(:hex32, v),
    do:
      if(is_binary(v) and Regex.match?(@hex32, v),
        do: {:ok, v},
        else: {:error, :not_32_lowercase_hex_digits}
      )

  def check(:mac, v), do: if(Schema.mac?(v), do: {:ok, v}, else: {:error, :not_a_mac})

  def check({:list_of_text, max_items, max_bytes}, v) do
    if is_list(v) and length(v) <= max_items and
         Enum.all?(v, &(is_binary(&1) and byte_size(&1) <= max_bytes)),
       do: {:ok, v},
       else: {:error, {:not_a_bounded_list_of_text, max_items, max_bytes}}
  end
end

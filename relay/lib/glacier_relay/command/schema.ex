defmodule GlacierRelay.Command.Schema do
  @moduledoc """
  The command protocol, version 1 (M5-A, ADR 0009): what BEAM writes to the command link and what
  it accepts from it. Versioned independently of the Relay envelope's `protocol_version`.

  Lines are newline-delimited UTF-8 JSON objects of at most #{4_096} bytes. Decoding is strict:
  the protocol version must be 1, the kind must be known, every field must be known and of its
  declared type and within its bounds, and nothing unknown is tolerated — an unknown kind, name,
  version, field or parameter is an error and never execution. Nothing in any schema is a
  function, an address, a pointer, an engine type or a script.

  Messages the native peer sends:

      {"command_protocol_version":1,"kind":"hello","adapter_instance_id":"<uuid4>",
       "native_at":"<text>","mission_generation":"<text>|null","capabilities":["..."]}
      {"command_protocol_version":1,"kind":"command.result","command_id":"<uuid4>","link_generation":N,
       "adapter_instance_id":"<uuid4>|null","status":"received|rejected|busy|duplicate|expired|
       precondition_failed|unavailable|applied|failed","reason":"<text>|null","native_at":"<text>|null",
       "frame":N|null,"observed":{...}|null,"mission_generation":"<text>|null"}

  Messages BEAM sends:

      {"command_protocol_version":1,"kind":"welcome","link_generation":N,"node":"<text>",
       "allowlist":[{"name":"relay.probe","version":1}]}
      {"command_protocol_version":1,"kind":"command","command_id":"<uuid4>","link_generation":N,
       "issued_at":"<ISO-8601>","ttl_ms":N,"name":"...","version":N,"params":{...},"preconditions":{...}}
      {"command_protocol_version":1,"kind":"refused","reason":"busy"}

  The allowlist is compiled in. `relay.probe` v1 has no effect, no parameters and no reversal.
  `player.outfit.set` v1 is documented and validated as a reserved, non-issuable candidate: it
  requires an authenticated peer (a trust state no peer can reach in M5-A) and a
  `mission_generation` precondition whose native source M5-B must establish.
  """

  @protocol_version 1
  @max_line_bytes 4_096
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @statuses ~w(received rejected busy duplicate expired precondition_failed unavailable applied failed)
  @terminal_statuses @statuses -- ["received"]

  @hello_keys ~w(command_protocol_version kind adapter_instance_id native_at mission_generation capabilities)
  @result_keys ~w(command_protocol_version kind command_id link_generation adapter_instance_id status reason native_at frame observed mission_generation)

  @allowlist %{
    {"relay.probe", 1} => %{
      name: "relay.probe",
      version: 1,
      effect: :none,
      issuable: true,
      trust: :identified,
      params: %{},
      preconditions: [],
      reversal: :none,
      doc:
        "no gameplay effect; applied on the native frame thread; its read-back reports scene state and the mission predicate"
    },
    {"player.outfit.set", 1} => %{
      name: "player.outfit.set",
      version: 1,
      effect: :outfit,
      issuable: false,
      trust: :authenticated,
      params: %{"disguise_repository_id" => :uuid, "expect_current" => {:optional, :uuid}},
      preconditions: [:mission_generation],
      reversal:
        "player.outfit.set with the previous disguise_repository_id (from the result's observed.previous)",
      doc:
        "reserved candidate (M5 design section 2); not issuable in M5-A; requires an authenticated peer and a mission-generation precondition"
    }
  }

  def protocol_version, do: @protocol_version
  def max_line_bytes, do: @max_line_bytes
  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses
  def terminal?(status), do: status in @terminal_statuses

  @doc "The compiled allowlist, keyed by `{name, version}`."
  def allowlist, do: @allowlist

  @doc "The allowlist entry for a name and version, or nil."
  def entry(name, version), do: Map.get(@allowlist, {name, version})

  @doc "The issuable entries, for the welcome message."
  def issuable, do: for({{n, v}, e} <- @allowlist, e.issuable, do: %{"name" => n, "version" => v})

  @doc "A random UUID version 4 as text."
  def uuid4 do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)
    hex = &String.pad_leading(Integer.to_string(&1, 16), &2, "0")

    String.downcase(
      "#{hex.(a, 8)}-#{hex.(b, 4)}-#{hex.(Bitwise.bor(0x4000, c), 4)}-#{hex.(Bitwise.bor(0x8000, d), 4)}-#{hex.(e, 12)}"
    )
  end

  def uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)

  # -- parameters -------------------------------------------------------------------------------

  @doc "Validates parameters against an allowlist entry: every key known, required ones present, types and bounds exact."
  @spec validate_params(map(), term()) :: {:ok, map()} | {:error, term()}
  def validate_params(%{params: spec}, params) when is_map(params) do
    unknown = Map.keys(params) -- Map.keys(spec)

    cond do
      unknown != [] ->
        {:error, {:unknown_params, Enum.sort(unknown)}}

      true ->
        Enum.reduce_while(spec, {:ok, %{}}, fn {key, type}, {:ok, acc} ->
          case check_param(type, Map.fetch(params, key)) do
            {:ok, :absent} -> {:cont, {:ok, acc}}
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, why} -> {:halt, {:error, {:invalid_param, key, why}}}
          end
        end)
    end
  end

  def validate_params(_entry, _params), do: {:error, :params_not_an_object}

  defp check_param({:optional, _type}, :error), do: {:ok, :absent}
  defp check_param({:optional, _type}, {:ok, nil}), do: {:ok, :absent}
  defp check_param({:optional, type}, {:ok, value}), do: check_param(type, {:ok, value})
  defp check_param(_type, :error), do: {:error, :missing}

  defp check_param(:uuid, {:ok, value}),
    do: if(uuid?(value), do: {:ok, value}, else: {:error, :not_a_uuid})

  # -- encoding (BEAM → native) -------------------------------------------------------------------

  @doc "The welcome line (with its newline) for a link generation."
  def encode_welcome(generation, node) when is_integer(generation) and generation > 0 do
    line(%{
      "command_protocol_version" => @protocol_version,
      "kind" => "welcome",
      "link_generation" => generation,
      "node" => to_string(node),
      "allowlist" => issuable()
    })
  end

  @doc "The refusal line (with its newline), written to a second connection while one link is up."
  def encode_refusal(reason),
    do:
      line(%{
        "command_protocol_version" => @protocol_version,
        "kind" => "refused",
        "reason" => to_string(reason)
      })

  @doc """
  The command line (with its newline). `cmd`: `%{command_id, link_generation, issued_at, ttl_ms,
  name, version, params, preconditions}`; the caller has validated everything.
  """
  def encode_command(cmd) do
    line(%{
      "command_protocol_version" => @protocol_version,
      "kind" => "command",
      "command_id" => cmd.command_id,
      "link_generation" => cmd.link_generation,
      "issued_at" => cmd.issued_at,
      "ttl_ms" => cmd.ttl_ms,
      "name" => cmd.name,
      "version" => cmd.version,
      "params" => cmd.params,
      "preconditions" => cmd.preconditions
    })
  end

  defp line(map), do: JSON.encode!(map) <> "\n"

  # -- decoding (native → BEAM) -------------------------------------------------------------------

  @doc "Decodes one line from the peer: a hello or a result, strictly, or an error."
  @spec decode_line(binary()) ::
          {:ok, {:hello, map()}} | {:ok, {:result, map()}} | {:error, term()}
  def decode_line(line) when is_binary(line) do
    with :ok <- check_size(line),
         :ok <- check_utf8(line),
         {:ok, map} <- decode_json(line),
         :ok <- check_version(map),
         {:ok, kind} <- kind(map) do
      case kind do
        "hello" -> decode_hello(map)
        "command.result" -> decode_result(map)
      end
    end
  end

  defp check_size(line),
    do: if(byte_size(line) <= @max_line_bytes, do: :ok, else: {:error, :line_too_long})

  defp check_utf8(line), do: if(String.valid?(line), do: :ok, else: {:error, :invalid_utf8})

  defp decode_json(line) do
    case JSON.decode(line) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :not_an_object}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp check_version(%{"command_protocol_version" => @protocol_version}), do: :ok

  defp check_version(%{"command_protocol_version" => other}),
    do: {:error, {:unsupported_protocol_version, other}}

  defp check_version(_), do: {:error, :missing_protocol_version}

  defp kind(%{"kind" => kind}) when kind in ["hello", "command.result"], do: {:ok, kind}
  defp kind(%{"kind" => other}), do: {:error, {:unknown_kind, other}}
  defp kind(_), do: {:error, :missing_kind}

  defp decode_hello(map) do
    with :ok <- known_keys(map, @hello_keys),
         {:ok, id} <- field(map, "adapter_instance_id", :uuid, :required),
         {:ok, at} <- field(map, "native_at", {:text, 64}, :optional),
         {:ok, gen} <- field(map, "mission_generation", {:text, 64}, :optional),
         {:ok, caps} <- field(map, "capabilities", {:list_of_text, 16, 64}, :optional) do
      {:ok,
       {:hello,
        %{
          adapter_instance_id: id,
          native_at: at,
          mission_generation: gen,
          capabilities: caps || []
        }}}
    end
  end

  defp decode_result(map) do
    with :ok <- known_keys(map, @result_keys),
         {:ok, id} <- field(map, "command_id", :uuid, :required),
         {:ok, gen} <- field(map, "link_generation", :pos_integer, :required),
         {:ok, adapter} <- field(map, "adapter_instance_id", :uuid, :optional),
         {:ok, status} <- field(map, "status", {:enum, @statuses}, :required),
         {:ok, reason} <- field(map, "reason", {:text, 200}, :optional),
         {:ok, at} <- field(map, "native_at", {:text, 64}, :optional),
         {:ok, frame} <- field(map, "frame", :non_neg_integer, :optional),
         {:ok, observed} <- field(map, "observed", :observed, :optional),
         {:ok, mgen} <- field(map, "mission_generation", {:text, 64}, :optional) do
      {:ok,
       {:result,
        %{
          command_id: id,
          link_generation: gen,
          adapter_instance_id: adapter,
          status: status,
          reason: reason,
          native_at: at,
          frame: frame,
          observed: observed,
          mission_generation: mgen
        }}}
    end
  end

  defp known_keys(map, allowed) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_fields, Enum.sort(unknown)}}
    end
  end

  defp field(map, key, type, presence) do
    case {Map.fetch(map, key), presence} do
      {:error, :required} -> {:error, {:missing_field, key}}
      {:error, :optional} -> {:ok, nil}
      {{:ok, nil}, :optional} -> {:ok, nil}
      {{:ok, nil}, :required} -> {:error, {:missing_field, key}}
      {{:ok, value}, _} -> check(type, value, key)
    end
  end

  defp check(:uuid, v, key),
    do: if(uuid?(v), do: {:ok, v}, else: {:error, {:invalid_field, key, :not_a_uuid}})

  defp check(:pos_integer, v, key),
    do:
      if(is_integer(v) and v > 0,
        do: {:ok, v},
        else: {:error, {:invalid_field, key, :not_a_positive_integer}}
      )

  defp check(:non_neg_integer, v, key),
    do:
      if(is_integer(v) and v >= 0,
        do: {:ok, v},
        else: {:error, {:invalid_field, key, :not_a_non_negative_integer}}
      )

  defp check({:text, max}, v, key),
    do:
      if(is_binary(v) and byte_size(v) <= max,
        do: {:ok, v},
        else: {:error, {:invalid_field, key, {:not_text_within, max}}}
      )

  defp check({:enum, allowed}, v, key),
    do:
      if(v in allowed,
        do: {:ok, v},
        else: {:error, {:invalid_field, key, {:not_one_of, allowed}}}
      )

  defp check({:list_of_text, max_items, max_len}, v, key) do
    if is_list(v) and length(v) <= max_items and
         Enum.all?(v, &(is_binary(&1) and byte_size(&1) <= max_len)),
       do: {:ok, v},
       else: {:error, {:invalid_field, key, {:not_a_bounded_list_of_text, max_items, max_len}}}
  end

  # observed: at most 16 entries; each value a scalar, or a map of at most 16 scalars (previous / current).
  defp check(:observed, v, key) do
    if is_map(v) and map_size(v) <= 16 and
         Enum.all?(v, fn {k, val} -> text?(k, 64) and (scalar?(val) or scalar_map?(val)) end),
       do: {:ok, v},
       else: {:error, {:invalid_field, key, :not_a_bounded_observation}}
  end

  defp text?(v, max), do: is_binary(v) and byte_size(v) <= max
  defp scalar?(v), do: is_nil(v) or is_boolean(v) or is_number(v) or text?(v, 128)

  defp scalar_map?(v),
    do:
      is_map(v) and map_size(v) <= 16 and
        Enum.all?(v, fn {k, val} -> text?(k, 64) and scalar?(val) end)
end

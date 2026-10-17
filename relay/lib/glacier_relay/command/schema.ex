defmodule GlacierRelay.Command.Schema do
  @moduledoc """
  The command protocol, versions 1 and 2 (M5-A, ADR 0009; M5 C-2A, M5 design sections 25–26):
  what BEAM writes to the command link and what it accepts from it. Versioned independently of
  the Relay envelope's `protocol_version`.

  Lines are newline-delimited UTF-8 JSON objects of at most #{4_096} bytes. Decoding is strict:
  the protocol version must be 1 or 2, the kind must be known for that version, every field must
  be known and of its declared type and within its bounds, and nothing unknown is tolerated — an
  unknown kind, name, version, field or parameter is an error and never execution. Nothing in any
  schema is a function, an address, a pointer, an engine type or a script.

  The peer's hello chooses the version. Version 1 is the frozen C-1 native's protocol and is
  unchanged byte for byte (the welcome carries no new field). Version 2 adds the attestation
  exchange: the welcome carries a fresh random `nonce` and `attest_required`, and the peer answers
  with one `attest` whose `mac` is HMAC-SHA256 over `nonce|link_generation|adapter_instance_id`
  with the run token; a verified attest labels the link `token_verified` (possession of this
  run's token shown over this link — never process identity, never `authenticated`).

  Messages the native peer sends (`V` is 1 or 2):

      {"command_protocol_version":V,"kind":"hello","adapter_instance_id":"<uuid4>",
       "native_at":"<text>","mission_generation":"<text>|null","capabilities":["..."]}
      {"command_protocol_version":2,"kind":"attest","link_generation":N,
       "adapter_instance_id":"<uuid4>","mac":"<64 lowercase hex>"}
      {"command_protocol_version":V,"kind":"command.result","command_id":"<uuid4>","link_generation":N,
       "adapter_instance_id":"<uuid4>|null","status":"received|rejected|busy|duplicate|expired|
       precondition_failed|unavailable|applied|failed","reason":"<text>|null","native_at":"<text>|null",
       "frame":N|null,"observed":{...}|null,"mission_generation":"<text>|null"}

  Messages BEAM sends:

      {"command_protocol_version":1,"kind":"welcome","link_generation":N,"node":"<text>",
       "allowlist":[{"name":"relay.probe","version":1}]}
      {"command_protocol_version":2,"kind":"welcome","link_generation":N,"node":"<text>",
       "allowlist":[...],"nonce":"<32 lowercase hex>","attest_required":true}
      {"command_protocol_version":V,"kind":"command","command_id":"<uuid4>","link_generation":N,
       "issued_at":"<ISO-8601>","ttl_ms":N,"name":"...","version":N,"params":{...},"preconditions":{...}}
      {"command_protocol_version":1,"kind":"refused","reason":"busy"}

  The allowlist is compiled in. `relay.probe` v1 has no effect, no parameters and no reversal.
  `relay.inspect.outfit` v1 (M5 C-1) has no effect, one optional validated repository id and no
  reversal; its read-back is a map of field objects `{"status","value","reason"}` whose status is
  one of observed / unavailable / unsupported / inconsistent / precondition_failed, so a missing
  value is never a default. `player.outfit.set` v1 stays exactly as published: a reserved,
  non-issuable candidate against every peer. `player.outfit.set` v2 (M5 C-2A) carries the complete
  tuple — the target kit id, charset and variation, and a mandatory `expect_current` tuple — and
  requires the `mission_generation` precondition; it is `:effectful`: listed in a welcome only to a
  version-2 peer that advertised the capability while the authority's effectful configuration is
  on, and issuable only under the authority's effectful arming (`Command.Authority`). No real
  native build advertises it.

  M6-B1 adds two inert, read-only entries (M6 design, `docs/design/M6_SECOND_HITMAN.md`):
  `relay.inspect.players` v1 (no parameters: the player registry's four declared slots, the three
  words at its array offset classified, slot 0 beside M5's local-hero path) and
  `relay.inspect.entity` v1 (two optional 16-lowercase-hex-digit ids, `brick` and `entity_id`,
  naming content — a brick's runtime resource id and an authored entity id — never an address:
  the loaded-brick inventory, the local hero's authored identity and stored transform, the
  blueprint-factory round trip and the candidate's resolution). Both are `:identified` trust,
  `:none` effect, no reversal; their read-backs are field objects like the outfit inspection's.

  M6-D1a adds one more inert, read-only entry, `relay.inspect.candidate` v1 (the same two
  optional ids as `relay.inspect.entity`; the spawn target is the native side's compiled
  historical default, never a parameter): on one native frame, the candidate hero's and the local
  hero's STORED spatial fields, member presence and `m_bActive` property, the spawn entity's
  stored transform and authored properties, and registry membership by entity identity. Groups of
  values that share one availability condition travel as one text field with a fixed grammar
  (`Command.CandidateReadback` decodes it); every field object still carries its own status.
  Presence is never initialization, simulation, placement, visibility or playability.

  M6-F adds the exact-transform pair (`docs/design/M6D2_NEXT_STEP_DESIGN.md` sections 12.3–12.9):
  `relay.inspect.candidate_transform` v1 (inert, no parameters: the compiled candidate's and the
  local hero's stored transform as exact binary32 words — a 12-word world group and a 7-word
  parent-relative group, each eight lowercase hex digits per word, every word finite — with the
  dirty flag, the parent id and the identity block; `Command.TransformReadback` decodes it) and
  `candidate.transform.set` v1 (`:effectful`, `:token_verified`: `mode` `lift` — the compiled
  +0.25 world-z displacement computed natively from a freshly validated snapshot — or `restore`,
  with `expect_world` / `expect_local` / `expect_parent` from a recent exact inspection and, for a
  restore only, the journaled `target_world` and the original `restore_of`; a mandatory
  `mission_generation` precondition). No location, direction, rotation, scale, distance, entity,
  pointer or function name is a parameter. One lift per authority process (`Command.Authority`);
  a restore is issuable only through the planner-bound facade (`Command.TransformRestore`).
  """

  @protocol_versions [1, 2]
  @max_line_bytes 4_096
  @max_observed_entries 48
  @nonce_bytes 16
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  @hex16 ~r/^[0-9a-f]{16}$/
  @words12 ~r/^[0-9a-f]{8}(,[0-9a-f]{8}){11}$/
  @words7 ~r/^[0-9a-f]{8}(,[0-9a-f]{8}){6}$/
  @hex32 ~r/^[0-9a-f]{32}$/
  @hex64 ~r/^[0-9a-f]{64}$/

  @statuses ~w(received rejected busy duplicate expired precondition_failed unavailable applied failed)
  @terminal_statuses @statuses -- ["received"]
  # Terminal statuses that assert the command was never applied (used by the late-result
  # refinement: a late one of these may refine an unknown outcome; nothing else may).
  @nonapplication_statuses ~w(rejected expired precondition_failed unavailable)

  @hello_keys ~w(command_protocol_version kind adapter_instance_id native_at mission_generation capabilities)
  @attest_keys ~w(command_protocol_version kind link_generation adapter_instance_id mac)
  @result_keys ~w(command_protocol_version kind command_id link_generation adapter_instance_id status reason native_at frame observed mission_generation)

  @tuple_spec %{
    "disguise_repository_id" => :uuid,
    "charset" => {:integer, 0, 15},
    "variation" => {:integer, 0, 63}
  }

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
    {"relay.inspect.outfit", 1} => %{
      name: "relay.inspect.outfit",
      version: 1,
      effect: :none,
      issuable: true,
      trust: :identified,
      params: %{"disguise_repository_id" => {:optional, :uuid}},
      preconditions: [],
      reversal: :none,
      doc:
        "M5 C-1: read-only, frame-local inspection of the hero's current outfit tuple, the candidate kit's resolution, the setter's availability, the edge-cached / at-receipt / fresh-registry generations, the Relay transition epoch and the hypothetical effectful precondition's verdict; every read-back field carries its own status; no engine write"
    },
    {"relay.inspect.players", 1} => %{
      name: "relay.inspect.players",
      version: 1,
      effect: :none,
      issuable: true,
      trust: :identified,
      params: %{},
      preconditions: [],
      reversal: :none,
      doc:
        "M6-B1: read-only, frame-local inspection of the player registry — availability, the three words at its array offset classified against the inline slots, the four declared slots' plain fields (player id, the local and connected flags as read, net-player / replica / entity-reference availability, the ZHitman5 interface resolution, the session id) and slot 0 beside M5's local-hero path; every read-back field carries its own status; no pointer, no address, no engine write"
    },
    {"relay.inspect.entity", 1} => %{
      name: "relay.inspect.entity",
      version: 1,
      effect: :none,
      issuable: true,
      trust: :identified,
      params: %{"brick" => {:optional, :hex16}, "entity_id" => {:optional, :hex16}},
      preconditions: [],
      reversal: :none,
      doc:
        "M6-B1: read-only, frame-local inspection of the loaded-brick inventory, the local hero's authored identity (entity id, flags, owning brick, character guid, initial outfit, invincibility) and stored transform with its dirty flag, the blueprint-factory round trip of the hero, and the candidate brick / authored entity (the historical hitmen.brick / Agent48 by default; absent without content); the two optional ids are 16 lowercase hex digits naming content, never an address; every read-back field carries its own status; no engine write"
    },
    {"relay.inspect.candidate", 1} => %{
      name: "relay.inspect.candidate",
      version: 1,
      effect: :none,
      issuable: true,
      trust: :identified,
      params: %{"brick" => {:optional, :hex16}, "entity_id" => {:optional, :hex16}},
      preconditions: [],
      reversal: :none,
      doc:
        "M6-D1a: read-only, frame-local inspection of the candidate hero (the historical hitmen.brick / Agent48 by default) beside the local hero as its control — the stored spatial fields (cached world translation with its dirty flag, parent-relative translation and rotation, parent entity id, transform-tree link presence, visibility bits), the presence of the hero's simulation members and controllers (null / present / interface-resolved; never initialization or simulation), the outfit tuple, the m_bActive property through the SDK's property mechanism, the spawn entity's class, stored transform and four authored properties, and the four registry slots classified by entity identity on the same frame; the two optional ids are 16 lowercase hex digits naming content, never an address; the spawn id is fixed natively; packed groups follow the documented grammar; every read-back field carries its own status; no engine write"
    },
    {"relay.inspect.candidate_transform", 1} => %{
      name: "relay.inspect.candidate_transform",
      version: 1,
      effect: :none,
      issuable: true,
      trust: :identified,
      params: %{},
      preconditions: [],
      reversal: :none,
      doc:
        "M6-F: read-only, frame-local exact snapshot of the compiled candidate (hitmen.brick / Agent48; no parameter) and the local hero — the stored world matrix as twelve binary32 words and the parent-relative transform as seven, the dirty flag, the parent id, the visibility bits, the identity block, whether the candidate's spatial interface differs from the hero's, and registry membership by identity; the seven-digit texts beside the words are for reading only; no property allocation, no refreshing getter, no engine write"
    },
    {"candidate.transform.set", 1} => %{
      name: "candidate.transform.set",
      version: 1,
      effect: :transform,
      issuable: :effectful,
      trust: :token_verified,
      params: %{
        "mode" => {:enum, ["lift", "restore"]},
        "expect_world" => :words12,
        "expect_local" => :words7,
        "expect_parent" => :parent_id,
        "target_world" => {:optional, :words12},
        "restore_of" => {:optional, :uuid}
      },
      preconditions: [:mission_generation],
      reversal:
        "a separate candidate.transform.set v1 in mode restore whose target_world is the lift's journaled preimage world group and whose expectation is a later exact inspection's words, planned from the verified journal (Command.TransformRestore), bound to the original lift and to the native operation record, issued only under fresh arming; an engine return to baseline needs no restoration and none is submitted",
      doc:
        "M6-F: the one bounded transform change of the compiled candidate — mode lift: the compiled +0.25 world-z displacement computed natively from the freshly validated snapshot (no target may be supplied); mode restore: the journaled preimage world group of one earlier lift, bound to it; both carry the exact expectation groups (12 and 7 binary32 words) and parent of a recent exact inspection and the mandatory mission_generation precondition; one SetObjectToWorldMatrixFromEditor call behind the applying-frame gate; one lift per process natively and per authority here; issuable only on a token-verified version-2 link under one-shot effectful arming; the setter's runtime semantics on a character are the experiment's question, never assumed"
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
        "reserved candidate (M5 design section 2); not issuable in M5-A; requires an authenticated peer and a mission-generation precondition; superseded by version 2 (M5 C-2A), kept exactly as published and never issuable"
    },
    {"player.outfit.set", 2} => %{
      name: "player.outfit.set",
      version: 2,
      effect: :outfit,
      issuable: :effectful,
      trust: :token_verified,
      params: Map.put(@tuple_spec, "expect_current", {:object, @tuple_spec}),
      preconditions: [:mission_generation],
      reversal:
        "a separate player.outfit.set v2 whose target is the result's previous tuple (previous_outfit_id / previous_charset / previous_variation) and whose expect_current is the result's current tuple, planned from the verified journal (Command.Reversal) and issued only with a fresh current-tuple confirmation",
      doc:
        "M5 C-2A: the complete outfit tuple (target kit id, charset, variation) with a mandatory expect_current tuple and a mandatory mission_generation precondition; HeroA only; the same tuple as the current one is refused as a no-op; issuable only on a version-2 link whose peer attested the run token (token_verified — possession of the run token, not process identity), under one-shot effectful arming; never advertised to a version-1 peer; no real native build implements it in C-2A"
    }
  }

  # The status vocabulary as atoms, fixed at compile time: a status is never converted to an atom
  # dynamically (a fresh VM has not necessarily created it; an unknown one must never be created).
  @status_atoms %{
    "received" => :received,
    "rejected" => :rejected,
    "busy" => :busy,
    "duplicate" => :duplicate,
    "expired" => :expired,
    "precondition_failed" => :precondition_failed,
    "unavailable" => :unavailable,
    "applied" => :applied,
    "failed" => :failed
  }

  @doc "The atom for a decoded status (every status of the vocabulary; nothing else)."
  def status_atom(status), do: Map.fetch!(@status_atoms, status)

  @doc "The protocol version a version-1 peer speaks (the frozen C-1 native's)."
  def protocol_version, do: 1
  def protocol_versions, do: @protocol_versions
  def max_line_bytes, do: @max_line_bytes
  def max_observed_entries, do: @max_observed_entries
  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses
  def nonapplication_statuses, do: @nonapplication_statuses
  def terminal?(status), do: status in @terminal_statuses
  def nonapplication?(status), do: status in @nonapplication_statuses

  @doc "The compiled allowlist, keyed by `{name, version}`."
  def allowlist, do: @allowlist

  @doc "The allowlist entry for a name and version, or nil."
  def entry(name, version), do: Map.get(@allowlist, {name, version})

  @doc "The inert issuable entries (sorted by name and version): the version-1 welcome's allowlist."
  def issuable do
    for({{n, v}, e} <- @allowlist, e.issuable == true, do: %{"name" => n, "version" => v})
    |> Enum.sort_by(&{&1["name"], &1["version"]})
  end

  @doc """
  The entries a welcome may list for a peer: the inert ones always; an `:effectful` entry only
  when the peer negotiated version 2, advertised `name/version` among its capabilities, and the
  authority's effectful configuration is on. A version-1 peer never sees an effectful entry.
  """
  def issuable_for(2, capabilities, true) when is_list(capabilities) do
    effectful =
      for {{n, v}, e} <- @allowlist,
          e.issuable == :effectful,
          "#{n}/#{v}" in capabilities,
          do: %{"name" => n, "version" => v}

    Enum.sort_by(issuable() ++ effectful, &{&1["name"], &1["version"]})
  end

  def issuable_for(_version, _capabilities, _effectful_enabled), do: issuable()

  @doc "A random UUID version 4 as text."
  def uuid4 do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)
    hex = &String.pad_leading(Integer.to_string(&1, 16), &2, "0")

    String.downcase(
      "#{hex.(a, 8)}-#{hex.(b, 4)}-#{hex.(Bitwise.bor(0x4000, c), 4)}-#{hex.(Bitwise.bor(0x8000, d), 4)}-#{hex.(e, 12)}"
    )
  end

  def uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)

  @doc "Exactly 16 lowercase hex digits (a runtime resource id or an authored entity id as text)."
  def hex16?(value), do: is_binary(value) and Regex.match?(@hex16, value)

  @doc "A 12-word world group: twelve eight-lowercase-hex-digit words joined by commas, every word finite."
  def words12?(value),
    do: is_binary(value) and Regex.match?(@words12, value) and finite_words?(value)

  @doc "A 7-word parent-relative group, likewise."
  def words7?(value),
    do: is_binary(value) and Regex.match?(@words7, value) and finite_words?(value)

  defp finite_words?(value) do
    value
    |> String.split(",")
    |> Enum.all?(fn word ->
      Bitwise.band(Bitwise.bsr(String.to_integer(word, 16), 23), 0xFF) != 0xFF
    end)
  end

  # -- attestation (version 2) --------------------------------------------------------------------

  @doc "A fresh cryptographically random nonce (#{@nonce_bytes} bytes) as lowercase hex."
  def nonce, do: @nonce_bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  def nonce?(value), do: is_binary(value) and Regex.match?(@hex32, value)
  def mac?(value), do: is_binary(value) and Regex.match?(@hex64, value)

  @doc """
  The attestation MAC: HMAC-SHA256 with the run token over `nonce|link_generation|adapter_id`
  (lowercase hex). Shared by the verifier and the fake peer so there is exactly one definition.
  """
  def attest_mac(token, nonce, generation, adapter_id)
      when is_binary(token) and is_binary(nonce) and is_integer(generation) and
             is_binary(adapter_id) do
    :hmac
    |> :crypto.mac(:sha256, token, "#{nonce}|#{generation}|#{adapter_id}")
    |> Base.encode16(case: :lower)
  end

  @doc "Constant-time comparison of two lowercase-hex MACs; false for anything malformed."
  def mac_equal?(expected, presented) do
    with true <- mac?(expected) and mac?(presented),
         {:ok, a} <- Base.decode16(expected, case: :lower),
         {:ok, b} <- Base.decode16(presented, case: :lower) do
      :crypto.hash_equals(a, b)
    else
      _ -> false
    end
  end

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

  defp check_param(:hex16, {:ok, value}),
    do: if(hex16?(value), do: {:ok, value}, else: {:error, :not_16_lowercase_hex_digits})

  defp check_param(:parent_id, {:ok, value}),
    do:
      if(value == "none" or hex16?(value),
        do: {:ok, value},
        else: {:error, :not_16_lowercase_hex_digits_or_none}
      )

  defp check_param(:words12, {:ok, value}),
    do: if(words12?(value), do: {:ok, value}, else: {:error, :not_12_finite_float_words})

  defp check_param(:words7, {:ok, value}),
    do: if(words7?(value), do: {:ok, value}, else: {:error, :not_7_finite_float_words})

  defp check_param({:enum, allowed}, {:ok, value}),
    do: if(value in allowed, do: {:ok, value}, else: {:error, {:not_one_of, allowed}})

  defp check_param({:integer, min, max}, {:ok, value}) do
    if is_integer(value) and value >= min and value <= max,
      do: {:ok, value},
      else: {:error, {:not_an_integer_within, min, max}}
  end

  defp check_param({:object, spec}, {:ok, value}) when is_map(value) do
    case validate_params(%{params: spec}, value) do
      {:ok, valid} -> {:ok, valid}
      {:error, why} -> {:error, {:invalid_object, why}}
    end
  end

  defp check_param({:object, _spec}, {:ok, _value}), do: {:error, :not_an_object}

  # -- encoding (BEAM → native) -------------------------------------------------------------------

  @doc """
  The welcome line (with its newline) for a link generation. `opts`: `:version` (1, the
  default, or 2), `:allowlist` (default the inert issuable entries), and for version 2 `:nonce`.
  The version-1 line is unchanged since M5 C-1.
  """
  def encode_welcome(generation, node, opts \\ [])
      when is_integer(generation) and generation > 0 do
    version = Keyword.get(opts, :version, 1)
    allowlist = Keyword.get(opts, :allowlist, issuable())

    base = %{
      "command_protocol_version" => version,
      "kind" => "welcome",
      "link_generation" => generation,
      "node" => to_string(node),
      "allowlist" => allowlist
    }

    case version do
      1 ->
        line(base)

      2 ->
        nonce = Keyword.fetch!(opts, :nonce)
        true = nonce?(nonce)
        line(Map.merge(base, %{"nonce" => nonce, "attest_required" => true}))
    end
  end

  @doc "The refusal line (with its newline), written to a second connection while one link is up."
  def encode_refusal(reason),
    do:
      line(%{
        "command_protocol_version" => 1,
        "kind" => "refused",
        "reason" => to_string(reason)
      })

  @doc """
  The command line (with its newline). `cmd`: `%{command_id, link_generation, issued_at, ttl_ms,
  name, version, params, preconditions}` plus an optional `protocol_version` (the link's
  negotiated version; 1 by default); the caller has validated everything.
  """
  def encode_command(cmd) do
    line(%{
      "command_protocol_version" => Map.get(cmd, :protocol_version, 1),
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

  @doc """
  Decodes one line from the peer: a hello, an attest (version 2 only) or a result, strictly, or
  an error. Every decoded map carries `protocol_version` (the line's own version); the link
  enforces that it equals the negotiated one.
  """
  @spec decode_line(binary()) ::
          {:ok, {:hello, map()}}
          | {:ok, {:attest, map()}}
          | {:ok, {:result, map()}}
          | {:error, term()}
  def decode_line(line) when is_binary(line) do
    with :ok <- check_size(line),
         :ok <- check_utf8(line),
         {:ok, map} <- decode_json(line),
         {:ok, version} <- check_version(map),
         {:ok, kind} <- kind(map, version) do
      case kind do
        "hello" -> decode_hello(map, version)
        "attest" -> decode_attest(map)
        "command.result" -> decode_result(map, version)
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

  defp check_version(%{"command_protocol_version" => v}) when v in @protocol_versions,
    do: {:ok, v}

  defp check_version(%{"command_protocol_version" => other}),
    do: {:error, {:unsupported_protocol_version, other}}

  defp check_version(_), do: {:error, :missing_protocol_version}

  defp kind(%{"kind" => kind}, _version) when kind in ["hello", "command.result"],
    do: {:ok, kind}

  defp kind(%{"kind" => "attest"}, 2), do: {:ok, "attest"}
  defp kind(%{"kind" => other}, _version), do: {:error, {:unknown_kind, other}}
  defp kind(_, _), do: {:error, :missing_kind}

  defp decode_hello(map, version) do
    with :ok <- known_keys(map, @hello_keys),
         {:ok, id} <- field(map, "adapter_instance_id", :uuid, :required),
         {:ok, at} <- field(map, "native_at", {:text, 64}, :optional),
         {:ok, gen} <- field(map, "mission_generation", {:text, 64}, :optional),
         {:ok, caps} <- field(map, "capabilities", {:list_of_text, 16, 64}, :optional) do
      {:ok,
       {:hello,
        %{
          protocol_version: version,
          adapter_instance_id: id,
          native_at: at,
          mission_generation: gen,
          capabilities: caps || []
        }}}
    end
  end

  defp decode_attest(map) do
    with :ok <- known_keys(map, @attest_keys),
         {:ok, gen} <- field(map, "link_generation", :pos_integer, :required),
         {:ok, id} <- field(map, "adapter_instance_id", :uuid, :required),
         {:ok, mac} <- field(map, "mac", :mac, :required) do
      {:ok,
       {:attest, %{protocol_version: 2, link_generation: gen, adapter_instance_id: id, mac: mac}}}
    end
  end

  defp decode_result(map, version) do
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
          protocol_version: version,
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

  defp check(:mac, v, key),
    do: if(mac?(v), do: {:ok, v}, else: {:error, {:invalid_field, key, :not_a_mac}})

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

  # observed: at most 48 entries (16 before M5 C-1; raised with the native encoder so an inspection
  # can report every field with its own status); each value a scalar, or a map of at most 16
  # scalars (an inspection field object {"status", "value", "reason"}, or previous / current).
  defp check(:observed, v, key) do
    if is_map(v) and map_size(v) <= @max_observed_entries and
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

  # -- read-back field objects (M5 C-1 / C-2A) ----------------------------------------------------

  @doc "The observed value of a read-back field object (`{\"status\":\"observed\",\"value\":…}`), or `:unobserved`."
  def observed_value(%{"status" => "observed"} = field) when is_map_key(field, "value"),
    do: {:ok, field["value"]}

  def observed_value(_), do: :unobserved

  @doc "The outfit tuple `prefix_outfit_id / prefix_charset / prefix_variation` of a read-back, when all three are observed."
  def observed_tuple(observed, prefix) when is_map(observed) and is_binary(prefix) do
    with {:ok, id} <- observed_value(observed["#{prefix}_outfit_id"]),
         {:ok, charset} <- observed_value(observed["#{prefix}_charset"]),
         {:ok, variation} <- observed_value(observed["#{prefix}_variation"]),
         true <- uuid?(id) and is_integer(charset) and is_integer(variation) do
      {:ok, %{"disguise_repository_id" => id, "charset" => charset, "variation" => variation}}
    else
      _ -> :unobserved
    end
  end

  def observed_tuple(_, _), do: :unobserved
end

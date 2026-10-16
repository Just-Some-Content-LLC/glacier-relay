defmodule GlacierRelay.Command.CandidateReadback do
  @moduledoc """
  M6-D1a: the pure decoder of `relay.inspect.candidate` v1's read-back (the native
  `CandidateObservation` grammar). The native side packs groups of values that share one
  availability condition into one text field, so the inspection fits the protocol's 48-entry cap
  and 4,096-byte line bound without widening either. This module turns those texts back into
  typed values, strictly: a text that does not match its grammar decodes to `:invalid` (never a
  partial value), and a field object whose status is not `observed` decodes to its status so a
  missing value is never a default.

  The grammar (every text at most 128 bytes):

      <prefix>_world         "x,y,z"                        the cached object-to-world translation as stored
      <prefix>_local         "tx,ty,tz|qx,qy,qz,qw"         parent-relative translation | rotation
      <prefix>_parent        "<16 hex>" | "none"            the parent entity's authored id
      <prefix>_spatial_flags "visible=B,parent_hidden=B,force_visible=B,dynamic=B,scene_child=B,dirty=B,room=N,tparent=B,tchildren=B"
      <prefix>_members       "character=M,animator=M,morpheme=M,ragdoll=M,health=M,kit=M,camera=M,input=M"
      <prefix>_controllers   "guide=M,ik=M,cheat=M,interaction=M,actor_tag=M"
      <prefix>_outfit        "<kit guid>|none,charset,variation"
      spawn_select           "default=B,preferred=B"
      registry_slots         "0:T,1:T,2:T,3:T"   T = empty | local | candidate | other | inconclusive [-nohero]
      targets                "<brick>,<entity>,<spawn>"

  with B = 0|1, N an integer, M a member state (0 null, 1 present, 2 valid: an entity reference
  whose interface resolved). A decoded slot is `%{slot: N, match: T, hero: H}`: `empty` means no
  entity reference (hero: false); a nonempty token means a reference whose ZHitman5 interface
  resolved (hero: true) unless it carries `-nohero` (hero: false); `empty-nohero` is never emitted
  by the native encoder and is rejected. A missing or unavailable `registry_slots` field stays
  missing / unobserved: four empty slots are never synthesized. "Present" is never "initialized"
  or "simulating"; nothing decoded here is an independent observation of the engine.
  """

  @hex16 ~r/^[0-9a-f]{16}$/
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @spatial_flag_keys ~w(visible parent_hidden force_visible dynamic scene_child dirty room tparent tchildren)
  @member_keys ~w(character animator morpheme ragdoll health kit camera input)
  @controller_keys ~w(guide ik cheat interaction actor_tag)
  @select_keys ~w(default preferred)
  @slot_matches ~w(empty local candidate other inconclusive)

  @doc "The grammar's packed field names (without the hero prefix) and the registry / targets fields."
  def packed_fields,
    do: ~w(world local parent spatial_flags members controllers outfit)

  @doc """
  Decodes one read-back field object: `{:ok, value}` for an observed field whose text matches the
  grammar of `kind`, `{:invalid, text}` for an observed text that does not, `{:unobserved, status}`
  for any other status (with the status word), and `:missing` for a nil field. `kind` is one of
  `:vec3`, `:local`, `:parent`, `:spatial_flags`, `:members`, `:controllers`, `:outfit`, `:select`,
  `:slots`, `:targets`, `:hex16`, `:bool`, `:integer`, `:text`.
  """
  def field(nil, _kind), do: :missing

  def field(%{"status" => "observed", "value" => value}, kind) do
    case decode(kind, value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:invalid, value}
    end
  end

  def field(%{"status" => status}, _kind) when is_binary(status), do: {:unobserved, status}
  def field(_other, _kind), do: :missing

  @doc "The observed, decoded value or nil (for the cross-checks that only act on a decoded value)."
  def value(field_object, kind) do
    case field(field_object, kind) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  @doc """
  Decodes the whole candidate read-back map into a map of decoded groups: `:hero` and
  `:candidate` (each with `:world`, `:local`, `:parent`, `:spatial_flags`, `:members`,
  `:controllers`, `:outfit`, `:active`), `:spawn`, `:registry_slots`, `:targets` and the identity
  scalars. Every leaf is the result of `field/2`, so a missing or unobserved value stays visibly
  so. Nothing is inferred.
  """
  def decode_readback(observed) when is_map(observed) do
    hero = fn prefix ->
      %{
        world: field(observed["#{prefix}_world"], :vec3),
        local: field(observed["#{prefix}_local"], :local),
        parent: field(observed["#{prefix}_parent"], :parent),
        spatial_flags: field(observed["#{prefix}_spatial_flags"], :spatial_flags),
        members: field(observed["#{prefix}_members"], :members),
        controllers: field(observed["#{prefix}_controllers"], :controllers),
        outfit: field(observed["#{prefix}_outfit"], :outfit),
        active: field(observed["#{prefix}_active"], :bool)
      }
    end

    %{
      generation_fresh: field(observed["generation_fresh"], :text),
      hero_entity_id: field(observed["hero_entity_id"], :hex16),
      hero_flags: field(observed["hero_flags"], :integer),
      brick_count: field(observed["brick_count"], :integer),
      bricks_scanned: field(observed["bricks_scanned"], :integer),
      targets: field(observed["targets"], :targets),
      cand_brick_present: field(observed["cand_brick_present"], :bool),
      cand_subentity_count: field(observed["cand_subentity_count"], :integer),
      cand_index: field(observed["cand_index"], :integer),
      cand_index_check: field(observed["cand_index_check"], :text),
      cand_resolved: field(observed["cand_resolved"], :bool),
      cand_hitman5: field(observed["cand_hitman5"], :bool),
      cand_flags: field(observed["cand_flags"], :integer),
      cand_id_match: field(observed["cand_id_match"], :bool),
      cand_distinct: field(observed["cand_distinct"], :bool),
      cand_brick_owner: field(observed["cand_brick_owner"], :text),
      registry_slots: field(observed["registry_slots"], :slots),
      candidate: hero.("cand"),
      hero: hero.("hero"),
      spawn: %{
        index: field(observed["spawn_index"], :integer),
        index_check: field(observed["spawn_index_check"], :text),
        resolved: field(observed["spawn_resolved"], :bool),
        class: field(observed["spawn_class"], :text),
        world: field(observed["spawn_world"], :vec3),
        dirty: field(observed["spawn_dirty"], :bool),
        player_id: field(observed["spawn_player_id"], :integer),
        select: field(observed["spawn_select"], :select),
        hitman_ref: field(observed["spawn_hitman_ref"], :parent),
        ref_is_cand: field(observed["spawn_ref_is_cand"], :bool)
      },
      reads_on_frame: field(observed["reads_on_frame"], :bool),
      reduced:
        Map.has_key?(observed, "reasons_dropped") or Map.has_key?(observed, "observed_reduced")
    }
  end

  @doc """
  The entity-flag bits as the SDK declares them (`ZEntityImpl::EEntityFlags`): initialized 1,
  postinitialized 2, activated 4, predeleted 8, editmode 16, readonly_flag_set 32, readonly 64.
  Decoded on the BEAM side from the raw word; the activated bit is NOT a hero gameplay state
  (M6-D research record, question A).
  """
  def entity_flags(flags) when is_integer(flags) and flags >= 0 do
    %{
      initialized: Bitwise.band(flags, 1) != 0,
      postinitialized: Bitwise.band(flags, 2) != 0,
      activated: Bitwise.band(flags, 4) != 0,
      predeleted: Bitwise.band(flags, 8) != 0,
      editmode: Bitwise.band(flags, 16) != 0,
      readonly_flag_set: Bitwise.band(flags, 32) != 0,
      readonly: Bitwise.band(flags, 64) != 0
    }
  end

  def entity_flags(_), do: :invalid

  # -- the grammar --------------------------------------------------------------------------------

  defp decode(:text, v) when is_binary(v), do: {:ok, v}
  defp decode(:bool, v) when is_boolean(v), do: {:ok, v}
  defp decode(:integer, v) when is_integer(v), do: {:ok, v}

  defp decode(:hex16, v) when is_binary(v),
    do: if(Regex.match?(@hex16, v), do: {:ok, v}, else: :error)

  defp decode(:parent, "none"), do: {:ok, :none}
  defp decode(:parent, v) when is_binary(v), do: decode(:hex16, v)

  defp decode(:vec3, v) when is_binary(v) do
    with [x, y, z] <- String.split(v, ","),
         {:ok, fx} <- number(x),
         {:ok, fy} <- number(y),
         {:ok, fz} <- number(z) do
      {:ok, {fx, fy, fz}}
    else
      _ -> :error
    end
  end

  defp decode(:local, v) when is_binary(v) do
    with [t, r] <- String.split(v, "|"),
         {:ok, translation} <- decode(:vec3, t),
         [qx, qy, qz, qw] <- String.split(r, ","),
         {:ok, fx} <- number(qx),
         {:ok, fy} <- number(qy),
         {:ok, fz} <- number(qz),
         {:ok, fw} <- number(qw) do
      {:ok, %{translation: translation, rotation: {fx, fy, fz, fw}}}
    else
      _ -> :error
    end
  end

  defp decode(:spatial_flags, v) when is_binary(v) do
    with {:ok, pairs} <- pairs(v, @spatial_flag_keys),
         {:ok, room} <- integer(pairs["room"]),
         {:ok, bits} <- bits(Map.delete(pairs, "room")) do
      {:ok, Map.put(bits, :room, room)}
    else
      _ -> :error
    end
  end

  defp decode(:members, v) when is_binary(v) do
    with {:ok, pairs} <- pairs(v, @member_keys), {:ok, states} <- states(pairs), do: {:ok, states}
  end

  defp decode(:controllers, v) when is_binary(v) do
    with {:ok, pairs} <- pairs(v, @controller_keys),
         {:ok, states} <- states(pairs),
         do: {:ok, states}
  end

  defp decode(:outfit, v) when is_binary(v) do
    with [kit, charset, variation] <- String.split(v, ","),
         true <- kit == "none" or Regex.match?(@uuid, kit),
         {:ok, c} <- integer(charset),
         {:ok, r} <- integer(variation) do
      {:ok, %{kit_id: if(kit == "none", do: :none, else: kit), charset: c, variation: r}}
    else
      _ -> :error
    end
  end

  defp decode(:select, v) when is_binary(v) do
    with {:ok, pairs} <- pairs(v, @select_keys), {:ok, bits} <- bits(pairs), do: {:ok, bits}
  end

  defp decode(:slots, v) when is_binary(v) do
    parts = String.split(v, ",")

    if length(parts) == 4 do
      parts
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {part, i}, {:ok, acc} ->
        case slot(part, i) do
          {:ok, s} -> {:cont, {:ok, acc ++ [s]}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp decode(:targets, v) when is_binary(v) do
    with [brick, entity, spawn] <- String.split(v, ","),
         true <- Enum.all?([brick, entity, spawn], &Regex.match?(@hex16, &1)) do
      {:ok, %{brick: brick, entity: entity, spawn: spawn}}
    else
      _ -> :error
    end
  end

  defp decode(_kind, _value), do: :error

  # One slot token "N:T[-nohero]". The native encoder (CandidateObservation::EncodeSlots) writes
  # "empty" for a null m_HitmanEntity and appends "-nohero" only to a NONEMPTY reference whose
  # ZHitman5 interface did not resolve, so the hero boolean means "a reference exists and its hero
  # interface resolved": false for an empty slot (no reference at all), false for a suffixed
  # nonempty slot, true for an unsuffixed nonempty slot. "empty-nohero" is never emitted and is
  # rejected as noncanonical (M6-D1a review, correction A: the first decoder read every
  # unsuffixed word, "empty" included, as hero: true).
  defp slot(part, i) do
    with [index, rest] <- String.split(part, ":"),
         true <- index == Integer.to_string(i),
         {match, suffixed} <- split_nohero(rest),
         true <- match in @slot_matches,
         {:ok, hero} <- slot_hero(match, suffixed) do
      {:ok, %{slot: i, match: String.to_existing_atom(match), hero: hero}}
    else
      _ -> :error
    end
  end

  # The match words are fixed above (atoms created at compile time by the ~w list below), so the
  # existing-atom conversion never creates one from the wire.
  @slot_match_atoms [:empty, :local, :candidate, :other, :inconclusive]
  def slot_matches, do: @slot_match_atoms

  defp slot_hero("empty", false), do: {:ok, false}
  defp slot_hero("empty", true), do: :error
  defp slot_hero(_nonempty, suffixed), do: {:ok, not suffixed}

  defp split_nohero(rest) do
    case String.split(rest, "-nohero") do
      [match] -> {match, false}
      [match, ""] -> {match, true}
      _ -> :error
    end
  end

  defp pairs(text, keys) do
    parts = String.split(text, ",")

    with true <- length(parts) == length(keys),
         pairs = Enum.map(parts, &String.split(&1, "=")),
         true <- Enum.all?(pairs, &match?([_, _], &1)),
         true <- Enum.map(pairs, &hd/1) == keys do
      {:ok, Map.new(pairs, fn [k, v] -> {k, v} end)}
    else
      _ -> :error
    end
  end

  defp bits(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {k, "0"}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(k), false)}}
      {k, "1"}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(k), true)}}
      _, _ -> {:halt, :error}
    end)
  end

  # the keys above are fixed at compile time (the ~w lists), so the existing-atom conversion is safe
  @key_atoms Enum.map(
               @spatial_flag_keys ++ @member_keys ++ @controller_keys ++ @select_keys,
               &String.to_atom/1
             )
  def key_atoms, do: @key_atoms

  defp states(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {k, "0"}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(k), :null)}}
      {k, "1"}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(k), :present)}}
      {k, "2"}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(k), :valid)}}
      _, _ -> {:halt, :error}
    end)
  end

  defp integer(nil), do: :error

  defp integer(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp number(text) do
    case Float.parse(text) do
      {f, ""} -> {:ok, f}
      _ -> integer_number(text)
    end
  end

  # "0" and "-1" render without a decimal point; Float.parse accepts them, but an exponent form
  # without a fraction ("1e+10") does not reach Float.parse — accept it explicitly.
  defp integer_number(text) do
    case Regex.run(~r/^(-?\d+)e([+-]?\d+)$/, text) do
      [_, m, e] -> {:ok, String.to_integer(m) * :math.pow(10, String.to_integer(e))}
      _ -> :error
    end
  end
end

# M6-B2 operator actions over RPC against the live relay node (the controlled READ-ONLY runtime inspection;
# also exercised offline by the tooling dry run against the frozen M6-B1 hardening command probe). Only
# these public functions of GlacierRelay.Command are called: status/0, command/1, arm/0, disarm/0,
# inspect_players/1, inspect_entity/2, inspect_outfit/2, and GlacierRelay.Command.Journal.status/0. There
# is NO set, attest, arm-effectful, plan, reverse or observe action: nothing this script can issue changes
# the engine. Every action appends to operator-actions.log and dumps the resulting status and command
# record under <label>-*; every read-back field is logged with its status, value and reason exactly as
# decoded, and the EVIDENCE lines state the run's stop conditions as they are met or not. The run token is
# never read, printed or passed by this script. Operator observations are recorded by hand in
# operator-observations.txt (no Command.observe call).
#
#   elixir --sname op-<label> -S mix run --no-start cmd.exs <evidence-dir> <label> <action> [args]
#
# Actions:
#   status | journal | linkcheck | arm | disarm
#   players [ttl_ms|-]                                         relay.inspect.players/1 (read-only)
#   entity [brick|-] [entity_id|-] [ttl_ms|-]                  relay.inspect.entity/1 (read-only; '-' = the historical defaults)
#   outfit [candidate|-] [expected_generation|-] [ttl_ms|-]    relay.inspect.outfit/1 (read-only; the M5 local-hero cross-check)
#   M6-C3 (this copy): players [ttl|-] [empty|recorded]  — slots 1-3 "recorded" (presence is NOT identity; a populated slot is a
#   FINDING, never a stop; "empty" keeps the M6-B2 stop semantics); entity [brick|-] [entity_id|-] [ttl|-] [absent|present] — the
#   candidate expected present in Paris after the content deployment (its lookup facts become EVIDENCE lines; an unexpected
#   presence under "absent" stays the M6-B2 stop). No set, attest, effectful-arm or reverse action exists.
# the relay node name: GLACIER_RELAY_NODE, or relay@<this host> (the node is started with --sname relay)
node = String.to_atom(System.get_env("GLACIER_RELAY_NODE") || "relay@#{elem(:inet.gethostname(), 1)}")
true = :net_kernel.connect_node(node)
[evid, label, action | rest] = System.argv()

call = fn m, f, a -> :rpc.call(node, m, f, a) end
cmd = GlacierRelay.Command
now = fn -> DateTime.utc_now() |> DateTime.to_iso8601() end
text = fn term -> inspect(term, pretty: true, limit: :infinity, printable_limit: :infinity) <> "\n" end

dump = fn name, term ->
  File.write!(Path.join(evid, "#{label}-#{name}.txt"), text.(term))
  File.write!(Path.join(evid, "#{label}-#{name}.bin"), :erlang.term_to_binary(term))
end

log = fn msg ->
  line = "#{now.()} #{label} #{msg}"
  IO.puts(line)
  File.write!(Path.join(evid, "operator-actions.log"), line <> "\n", [:append])
end

ev = fn name, ok, detail ->
  log.("EVIDENCE #{name}: #{if ok, do: "ok", else: "NOT"} #{detail}")
  ok
end

obs = fn c -> (c && c.result && c.result.observed) || %{} end
ov = fn c, k -> f = obs.(c)[k]; if is_map(f) and Map.has_key?(f, "value"), do: f["value"], else: nil end
st = fn c, k -> f = obs.(c)[k]; if is_map(f), do: f["status"], else: nil end
# the two reduction markers are plain scalars (true), not field objects
mk = fn c, k -> obs.(c)[k] end
reason = fn c -> (c && c.result && c.result.reason) || "" end
short = fn id -> String.slice(id || "", 0, 8) end
nfields = fn c -> map_size(obs.(c)) end
frame = fn c -> c && c.result && c.result.frame end
gen = fn c -> c && c.result && c.result.mission_generation end
fld = fn c, k -> f = obs.(c)[k]; if is_map(f), do: "#{f["status"]}#{if Map.has_key?(f, "value"), do: "=" <> inspect(f["value"]), else: ""}#{if f["reason"], do: "(" <> f["reason"] <> ")", else: ""}", else: inspect(f) end

advertised_names = fn s -> ((s.link && s.link.advertised) || []) |> Enum.map(&"#{&1["name"]}/#{&1["version"]}") |> Enum.sort() end

status_line = fn s ->
  "trust #{inspect(s.trust)}; effectful #{inspect(s.effectful)}; link #{inspect(s.link && Map.take(s.link, [:generation, :protocol_version, :token_verified, :adapter_instance_id, :mission_generation, :capabilities, :advertised]))}; in_flight #{inspect(s.in_flight)}; audit #{inspect(s.audit)}; counters #{inspect(s.counters)}; journal #{inspect(s.journal)}; commands #{length(s.commands)}"
end

wait_terminal = fn id, ms ->
  deadline = System.monotonic_time(:millisecond) + ms

  Stream.repeatedly(fn ->
    Process.sleep(25)
    c = call.(cmd, :command, [id])
    c != nil and c.status not in [:accepted, :transmitted, :received]
  end)
  |> Enum.find(fn done -> done or System.monotonic_time(:millisecond) > deadline end)

  call.(cmd, :command, [id])
end

describe = fn c ->
  "#{short.(c.id)} #{c.name}/#{c.version}: status #{c.status}; ladder #{inspect(c.stages)} (ms since issue); reason #{inspect(reason.(c))}; audit #{inspect(c.audit)}; observed #{inspect(c.observed)}; independent #{inspect(c.independent_observation)}; unknown_reason #{inspect(c.unknown_reason)}; link_generation #{inspect(c.link_generation)}; frame #{inspect(frame.(c))}; generation #{inspect(gen.(c))}"
end

dump_record = fn c ->
  dump.("command-record", c)
  log.(describe.(c))

  if c.result do
    log.("#{short.(c.id)}: result status #{c.result.status} reason #{inspect(c.result.reason)} frame #{inspect(c.result.frame)} native_at #{inspect(c.result.native_at)} mission_generation #{inspect(c.result.mission_generation)} adapter #{c.result.adapter_instance_id}")
    o = obs.(c)
    line = JSON.encode!(o)
    File.write!(Path.join(evid, "#{label}-observed.json"), line <> "\n")

    File.write!(
      Path.join(evid, "#{label}-result.json"),
      JSON.encode!(%{
        "command_id" => c.id, "name" => c.name, "version" => c.version, "command_status" => to_string(c.status),
        "status" => to_string(c.result.status), "reason" => c.result.reason, "frame" => c.result.frame,
        "native_at" => c.result.native_at, "mission_generation" => c.result.mission_generation,
        "adapter_instance_id" => c.result.adapter_instance_id, "link_generation" => c.link_generation,
        "fields" => map_size(o), "observed_bytes" => byte_size(line), "stages" => Enum.map(c.stages, fn {k, v} -> [to_string(k), v] end)
      }) <> "\n"
    )

    log.("#{short.(c.id)}: observed #{map_size(o)} field(s), #{byte_size(line)} bytes as JSON; statuses #{inspect(Enum.frequencies(Enum.map(o, fn {_, f} -> is_map(f) && f["status"] end)))}")

    for name <- Enum.sort(Map.keys(o)) do
      f = o[name]
      log.("#{short.(c.id)}:   #{String.pad_trailing(name, 26)} #{if is_map(f), do: "#{f["status"]}#{if Map.has_key?(f, "value"), do: " = " <> inspect(f["value"]), else: ""}#{if f["reason"], do: " (" <> f["reason"] <> ")", else: ""}", else: inspect(f)}")
    end
  end
end

finish = fn ->
  s = call.(cmd, :status, [])
  dump.("command-status", s)
  log.("after: #{status_line.(s)}")
end

# The invariants every inspection result must satisfy (the stop conditions of section 9 that a result can
# show): applied; reads on the intended frame; no reduction marker; not withheld; within the entry cap.
common_evidence = fn prefix, c, s ->
  ev.("#{prefix}.applied", c.status == :applied and to_string(c.result && c.result.status) == "applied", "status #{c.status} result #{inspect(c.result && c.result.status)} reason #{inspect(reason.(c))}")
  ev.("#{prefix}.reads-on-frame", ov.(c, "reads_on_frame") == true, "reads_on_frame #{inspect(ov.(c, "reads_on_frame"))} receipt_to_frame_ms #{inspect(ov.(c, "receipt_to_frame_ms"))} frame #{inspect(frame.(c))}")
  ev.("#{prefix}.no-reduction-marker", mk.(c, "reasons_dropped") == nil and mk.(c, "observed_reduced") == nil, "reasons_dropped #{inspect(mk.(c, "reasons_dropped"))} observed_reduced #{inspect(mk.(c, "observed_reduced"))} result reason #{inspect(reason.(c))}")
  ev.("#{prefix}.not-withheld-within-cap", to_string(c.result && c.result.status) != "failed" and nfields.(c) <= 48, "#{nfields.(c)} fields; result status #{inspect(c.result && c.result.status)}")
  ev.("#{prefix}.link-v2-token-verified", s.link != nil and s.link.protocol_version == 2 and s.trust.token_verified == true and s.trust.authenticated == false, "protocol_version #{inspect(s.link && s.link.protocol_version)} token_verified #{inspect(s.trust.token_verified)} authenticated #{inspect(s.trust.authenticated)}")
  ev.("#{prefix}.audit-intact-no-anomaly", s.audit == :intact and s.counters.anomalies == 0 and s.counters.audit_failures == 0, "audit #{inspect(s.audit)} counters #{inspect(s.counters)}")
end

players_line = fn c ->
  slots = Enum.map_join(0..3, " | ", fn i -> "slot#{i}: id #{fld.(c, "slot#{i}_player_id")} local #{fld.(c, "slot#{i}_local_flag")} conn #{fld.(c, "slot#{i}_connected")} net #{fld.(c, "slot#{i}_net_player")} replica #{fld.(c, "slot#{i}_replica")} entity #{fld.(c, "slot#{i}_entity")} hero #{fld.(c, "slot#{i}_hero")} flags_a0 #{fld.(c, "slot#{i}_flags_a0")} session #{fld.(c, "slot#{i}_session")}" end)
  "players: registry_available #{fld.(c, "registry_available")} words #{fld.(c, "registry_words")} #{slots} | slot0 outfit #{fld.(c, "slot0_outfit_id")} char #{fld.(c, "slot0_character_id")} hero_kit #{fld.(c, "slot0_hero_kit_id")} matches_m5 #{fld.(c, "slot0_matches_m5")} | mission_playing #{fld.(c, "mission_playing")} scene_type #{fld.(c, "scene_type")} receipt_to_frame_ms #{fld.(c, "receipt_to_frame_ms")} reads_on_frame #{fld.(c, "reads_on_frame")} reasons_dropped #{inspect(mk.(c, "reasons_dropped"))} reduced #{inspect(mk.(c, "observed_reduced"))} fields #{nfields.(c)} frame #{inspect(frame.(c))} generation #{inspect(gen.(c))}"
end

entity_line = fn c ->
  "entity: bricks #{fld.(c, "brick_count")} scanned #{fld.(c, "bricks_scanned")} id fields #{Enum.count(obs.(c), fn {k, _} -> String.starts_with?(k, "brick_ids_") end)} truncated #{fld.(c, "bricks_truncated")} | hero resolved #{fld.(c, "hero_resolved")} id #{fld.(c, "hero_entity_id")} flags #{fld.(c, "hero_entity_flags")} activated #{fld.(c, "hero_activated")} predeleted #{fld.(c, "hero_predeleted")} owning_brick #{fld.(c, "hero_owning_brick")} char #{fld.(c, "hero_character_id")} initial_outfit #{fld.(c, "hero_initial_outfit_id")} invincible #{fld.(c, "hero_invincible")} x #{fld.(c, "hero_x")} y #{fld.(c, "hero_y")} z #{fld.(c, "hero_z")} dirty #{fld.(c, "hero_transform_dirty")} room #{fld.(c, "hero_room_behaviour")} | rt #{fld.(c, "rt_outcome")} owner #{fld.(c, "rt_owner_found")} template #{fld.(c, "rt_factory_template")} count #{fld.(c, "rt_subentity_count")} index #{fld.(c, "rt_index")} check #{fld.(c, "rt_index_check")} resolved #{fld.(c, "rt_resolved")} same #{fld.(c, "rt_same_entity")} | cand brick #{fld.(c, "cand_brick")} entity #{fld.(c, "cand_entity_id")} present #{fld.(c, "cand_brick_present")} count #{fld.(c, "cand_subentity_count")} index #{fld.(c, "cand_index")} check #{fld.(c, "cand_index_check")} resolved #{fld.(c, "cand_resolved")} hitman5 #{fld.(c, "cand_hitman5")} distinct #{fld.(c, "cand_distinct_from_local")} | reads_on_frame #{fld.(c, "reads_on_frame")} reasons_dropped #{inspect(mk.(c, "reasons_dropped"))} reduced #{inspect(mk.(c, "observed_reduced"))} fields #{nfields.(c)} frame #{inspect(frame.(c))} generation #{inspect(gen.(c))} reason #{inspect(reason.(c))}"
end

outfit_line = fn c ->
  "outfit: hero #{fld.(c, "hero_outfit_id")}/#{fld.(c, "hero_charset")}/#{fld.(c, "hero_variation")} suit #{fld.(c, "hero_suit")} heroa_valid #{fld.(c, "hero_heroa_valid")}; candidate #{fld.(c, "candidate_id")} found #{fld.(c, "candidate_found")} kits_scanned #{fld.(c, "kits_scanned")}; mission_playing #{fld.(c, "mission_playing")} prev_frame_playing #{fld.(c, "prev_frame_playing")} scene #{fld.(c, "scene_type")} same_as_rise #{fld.(c, "scene_same_as_rise")} stage #{fld.(c, "loading_stage")}; generations expected #{fld.(c, "generation_expected")} receipt #{fld.(c, "generation_at_receipt")} cached #{fld.(c, "generation_cached")} fresh #{fld.(c, "generation_fresh")}; contract_started_seen #{fld.(c, "contract_started_seen")} contract_ended_seen #{fld.(c, "contract_ended_seen")}; epoch #{fld.(c, "relay_transition_epoch")}/#{fld.(c, "epoch_at_receipt")}; rise_age_ms #{fld.(c, "rise_age_ms")} frames #{fld.(c, "rise_age_frames")}; set_outfit_available #{fld.(c, "set_outfit_available")}; precondition_ok #{fld.(c, "precondition_ok")} reasons #{fld.(c, "precondition_reasons")}; reads_on_frame #{fld.(c, "reads_on_frame")} fields #{nfields.(c)} frame #{inspect(frame.(c))} generation #{inspect(gen.(c))}"
end

ttl_opts = fn ttl_arg, opts -> if ttl_arg == "-", do: opts, else: Keyword.put(opts, :ttl_ms, String.to_integer(ttl_arg)) end

case action do
  "status" ->
    s = call.(cmd, :status, [])
    dump.("command-status", s)
    log.("status: #{status_line.(s)}")

  "journal" ->
    j = call.(GlacierRelay.Command.Journal, :status, [])
    dump.("journal-status", j)
    log.("journal: #{inspect(j)}")

  "linkcheck" ->
    s = call.(cmd, :status, [])
    dump.("command-status", s)
    log.("linkcheck: #{status_line.(s)}")
    names = advertised_names.(s)
    ev.("link.identified-v2-token-verified", s.link != nil and s.trust.peer == :identified and s.link.protocol_version == 2 and s.trust.token_verified == true, "peer #{inspect(s.trust.peer)} protocol_version #{inspect(s.link && s.link.protocol_version)} token_verified #{inspect(s.trust.token_verified)} generation #{inspect(s.link && s.link.generation)} adapter #{inspect(s.link && s.link.adapter_instance_id)}")
    ev.("link.four-inert-entries-advertised", names == ["relay.inspect.entity/1", "relay.inspect.outfit/1", "relay.inspect.players/1", "relay.probe/1"], inspect(names))
    ev.("link.effectful-entry-absent", "player.outfit.set/2" not in names and "player.outfit.set/2" not in ((s.link && s.link.capabilities) || []), "advertised #{inspect(names)} peer capabilities #{inspect(s.link && s.link.capabilities)}")
    ev.("link.effectful-authority-disabled", s.effectful.enabled == false and s.trust.effectful_armed == false and s.effectful.armed == nil, inspect(s.effectful))
    ev.("link.never-authenticated", s.trust.authenticated == false, inspect(s.trust))
    ev.("link.token-from-file", s.effectful.token_source == :file and s.effectful.token_configured == true, "token_source #{inspect(s.effectful.token_source)} token_configured #{inspect(s.effectful.token_configured)}")
    ev.("link.audit-intact", s.audit == :intact and s.in_flight == nil, "audit #{inspect(s.audit)} in_flight #{inspect(s.in_flight)}")

  "arm" ->
    r = call.(cmd, :arm, [])
    log.("arm (inert) -> #{inspect(r)}")
    s = call.(cmd, :status, [])
    ev.("arm.inert-only", r == :ok and s.trust.armed == true and s.trust.effectful_armed == false and s.effectful.armed == nil, "armed #{inspect(s.trust.armed)} effectful_armed #{inspect(s.trust.effectful_armed)}")
    finish.()

  "disarm" ->
    r = call.(cmd, :disarm, [])
    log.("disarm -> #{inspect(r)}")
    finish.()

  "players" ->
    [ttl_arg, slots_expect | _] = rest ++ ["-", "recorded"]
    slots_expect = if slots_expect in ["empty", "recorded"], do: slots_expect, else: "recorded"
    opts = ttl_opts.(ttl_arg, [])
    before = call.(cmd, :status, [])
    log.("players opts #{inspect(opts)}: before: #{status_line.(before)}")

    case call.(cmd, :inspect_players, [opts]) do
      {:ok, id} ->
        log.("players issued #{id}")
        File.write!(Path.join(evid, "#{label}-command-id.txt"), id <> "\n")
        c = wait_terminal.(id, 15_000)
        dump_record.(c)
        s = call.(cmd, :status, [])
        common_evidence.("players", c, s)
        ev.("players.registry-available", ov.(c, "registry_available") == true, fld.(c, "registry_available"))
        ev.("players.words-as-experiment-4", ov.(c, "registry_words") == "slot0,0,0x4000000000000101", "registry_words #{fld.(c, "registry_words")} (a different classification is a FINDING, not a stop: record)")
        ev.("players.slot0-entity-and-hero", ov.(c, "slot0_entity") == true and ov.(c, "slot0_hero") == true, "slot0 entity #{fld.(c, "slot0_entity")} hero #{fld.(c, "slot0_hero")} player_id #{fld.(c, "slot0_player_id")} flags_a0 #{fld.(c, "slot0_flags_a0")} (a finding if not)")
        if slots_expect == "empty" do
          ev.("players.slots-1-3-no-entity-no-hero", Enum.all?(1..3, fn i -> ov.(c, "slot#{i}_entity") != true and ov.(c, "slot#{i}_hero") != true end), "STOP CONDITION if NOT (an unexpected registry entity): " <> Enum.map_join(1..3, "; ", fn i -> "slot#{i} entity #{fld.(c, "slot#{i}_entity")} hero #{fld.(c, "slot#{i}_hero")}" end))
        else
          populated = Enum.filter(1..3, fn i -> ov.(c, "slot#{i}_entity") == true or ov.(c, "slot#{i}_hero") == true end)
          ev.("players.slots-1-3-recorded", true, "presence recorded, NOT identity (M6-C3: a populated slot is a FINDING to attribute only through the candidate entry's authored identity; never a stop by itself): populated #{inspect(populated)}; " <> Enum.map_join(1..3, "; ", fn i -> "slot#{i} entity #{fld.(c, "slot#{i}_entity")} hero #{fld.(c, "slot#{i}_hero")} id #{fld.(c, "slot#{i}_player_id")} flags_a0 #{fld.(c, "slot#{i}_flags_a0")}" end))
        end
        ev.("players.slots-1-3-as-experiment-4", Enum.all?(1..3, fn i -> ov.(c, "slot#{i}_player_id") == -1 and ov.(c, "slot#{i}_flags_a0") == -1 and st.(c, "slot#{i}_session") == "unavailable" end), "player id -1, flags_a0 -1, no session on each of slots 1-3 (a finding if not): " <> Enum.map_join(1..3, "; ", fn i -> "slot#{i} id #{fld.(c, "slot#{i}_player_id")} flags_a0 #{fld.(c, "slot#{i}_flags_a0")} session #{fld.(c, "slot#{i}_session")} local #{fld.(c, "slot#{i}_local_flag")}" end))
        ev.("players.local-flag-not-treated-as-authoritative", true, "local_flag per slot: " <> Enum.map_join(0..3, ", ", fn i -> "slot#{i} #{fld.(c, "slot#{i}_local_flag")}" end) <> " (recorded; experiment 4 saw true on every slot)")
        ev.("players.generation-consistent-with-session", (gen.(c) == nil and st.(c, "slot0_session") != "observed") or (gen.(c) != nil and ov.(c, "slot0_session") == gen.(c)) or (gen.(c) == nil and ov.(c, "mission_playing") == false), "result generation #{inspect(gen.(c))} slot0 session #{fld.(c, "slot0_session")} mission_playing #{fld.(c, "mission_playing")} (at the menu a persisting registry id is the C-1 finding, not a mission)")
        log.("players summary #{short.(id)}: " <> players_line.(c))

      other ->
        log.("players refused locally: #{inspect(other)} (nothing transmitted)")
    end

    finish.()

  "entity" ->
    [brick, eid, ttl_arg, cand_expect | _] = rest ++ ["-", "-", "-", "absent"]
    cand_expect = if cand_expect in ["present", "absent"], do: cand_expect, else: "absent"
    params = %{}
    params = if brick == "-", do: params, else: Map.put(params, "brick", brick)
    params = if eid == "-", do: params, else: Map.put(params, "entity_id", eid)
    opts = ttl_opts.(ttl_arg, [])
    before = call.(cmd, :status, [])
    log.("entity params #{inspect(params)} opts #{inspect(opts)}: before: #{status_line.(before)}")

    case call.(cmd, :inspect_entity, [params, opts]) do
      {:ok, id} ->
        log.("entity issued #{id}")
        File.write!(Path.join(evid, "#{label}-command-id.txt"), id <> "\n")
        c = wait_terminal.(id, 15_000)
        dump_record.(c)
        s = call.(cmd, :status, [])
        common_evidence.("entity", c, s)
        ev.("entity.bricks-read", st.(c, "brick_count") == "observed" and st.(c, "bricks_scanned") == "observed", "brick_count #{fld.(c, "brick_count")} bricks_scanned #{fld.(c, "bricks_scanned")} truncated #{fld.(c, "bricks_truncated")}")
        ev.("entity.scan-complete", ov.(c, "brick_count") != nil and ov.(c, "bricks_scanned") == ov.(c, "brick_count"), "scanned #{fld.(c, "bricks_scanned")} of #{fld.(c, "brick_count")} (an incomplete scan is a FINDING: absence then not established)")
        ev.("entity.hero-resolved", ov.(c, "hero_resolved") == true, "hero_resolved #{fld.(c, "hero_resolved")} entity_id #{fld.(c, "hero_entity_id")} owning_brick #{fld.(c, "hero_owning_brick")} (a finding if not)")
        ev.("entity.hero-not-predeleted", ov.(c, "hero_predeleted") != true, "activated #{fld.(c, "hero_activated")} predeleted #{fld.(c, "hero_predeleted")} flags #{fld.(c, "hero_entity_flags")}")
        ev.("entity.transform-reported", st.(c, "hero_x") == "observed" and st.(c, "hero_transform_dirty") == "observed", "x #{fld.(c, "hero_x")} y #{fld.(c, "hero_y")} z #{fld.(c, "hero_z")} dirty #{fld.(c, "hero_transform_dirty")}#{if ov.(c, "hero_transform_dirty") == true, do: " — STORED transform potentially stale (dirty)", else: ""}")
        ev.("entity.rt-index-check-not-inconsistent", ov.(c, "rt_index_check") not in ["out_of_range", "count_invalid"], "STOP-AND-RECORD if NOT (an invalid or inconsistent factory answer): rt_index_check #{fld.(c, "rt_index_check")} count #{fld.(c, "rt_subentity_count")} index #{fld.(c, "rt_index")} resolved #{fld.(c, "rt_resolved")}")
        ev.("entity.rt-outcome-recorded", ov.(c, "rt_outcome") in ["same_entity", "different_entity", "owner_unresolved", "hero_not_representable", "factory_unavailable", "unsupported"], "rt_outcome #{fld.(c, "rt_outcome")} owner #{fld.(c, "rt_owner_found")} template #{fld.(c, "rt_factory_template")} count #{fld.(c, "rt_subentity_count")} index #{fld.(c, "rt_index")} check #{fld.(c, "rt_index_check")} resolved #{fld.(c, "rt_resolved")} same #{fld.(c, "rt_same_entity")}")
        ev.("entity.rt-not-different-entity", ov.(c, "rt_outcome") != "different_entity", "a different_entity outcome is the one specific lookup failure (record the mismatch): rt_outcome #{fld.(c, "rt_outcome")} same #{fld.(c, "rt_same_entity")}")
        if cand_expect == "present" do
          flags = ov.(c, "cand_entity_flags")
          activated = if is_integer(flags), do: Bitwise.band(flags, 4) != 0, else: nil
          predeleted = if is_integer(flags), do: Bitwise.band(flags, 8) != 0, else: nil
          ev.("entity.candidate-present-as-expected", ov.(c, "cand_brick_present") == true, "FINDING if NOT (the content not loaded, or absence not established): cand_brick #{fld.(c, "cand_brick")} cand_entity_id #{fld.(c, "cand_entity_id")} present #{fld.(c, "cand_brick_present")} brick_count #{fld.(c, "brick_count")} scanned #{fld.(c, "bricks_scanned")}")
          ev.("entity.candidate-index-in-range", ov.(c, "cand_index_check") == "in_range", "STOP-AND-RECORD if out_of_range / count_invalid (an inconsistent factory answer); a FINDING if negative (authored id not represented): cand_index_check #{fld.(c, "cand_index_check")} count #{fld.(c, "cand_subentity_count")} index #{fld.(c, "cand_index")} factory_template #{fld.(c, "cand_factory_template")}")
          ev.("entity.candidate-resolved", ov.(c, "cand_resolved") == true, "FINDING if NOT (content present, entity NOT instantiated): cand_resolved #{fld.(c, "cand_resolved")}")
          ev.("entity.candidate-hero-interface", ov.(c, "cand_hitman5") == true, "FINDING if NOT (the entity resolved without a ZHitman5 interface): cand_hitman5 #{fld.(c, "cand_hitman5")}")
          ev.("entity.candidate-distinct-from-local", ov.(c, "cand_distinct_from_local") == true, "STOP-AND-RECORD if NOT with the candidate resolved (the lookup returned the local hero: a different_entity-class failure): cand_distinct_from_local #{fld.(c, "cand_distinct_from_local")} (pointer inequality on this frame; identity is decided by xcheck from the authored elements)")
          ev.("entity.candidate-flags-observed", st.(c, "cand_entity_flags") == "observed" and predeleted != true, "cand_entity_flags #{fld.(c, "cand_entity_flags")} activated(bit 4) #{inspect(activated)} predeleted(bit 8) #{inspect(predeleted)} (predeleted set = a FINDING; activated clear is recorded, its meaning for a hero unknown)")
          ev.("entity.candidate-character-id-authored", ov.(c, "cand_character_id") == "787c1ff2-467c-421d-98f4-6bbb92e5fc99", "the authored Agent48 m_CharacterId (a FINDING if not; the FAKE probe is expected NOT here): cand_character_id #{fld.(c, "cand_character_id")}")
          ev.("entity.candidate-transform-observed", st.(c, "cand_x") == "observed" and st.(c, "cand_transform_dirty") == "observed", "x #{fld.(c, "cand_x")} y #{fld.(c, "cand_y")} z #{fld.(c, "cand_z")} dirty #{fld.(c, "cand_transform_dirty")}#{if ov.(c, "cand_transform_dirty") == true, do: " — STORED transform potentially stale (dirty)", else: ""} (the authored Dartmoor spawn is (-40.99882, -24.293657, 0.4925565): an arbitrary point in Paris, recorded, never corrected)")
        else
          ev.("entity.candidate-not-present", ov.(c, "cand_brick_present") != true, "STOP CONDITION if NOT (the candidate brick present where absence is expected): cand_brick #{fld.(c, "cand_brick")} cand_entity_id #{fld.(c, "cand_entity_id")} present #{fld.(c, "cand_brick_present")}" <> (cond do ov.(c, "cand_brick_present") == false -> " — absent on a complete scan"; st.(c, "cand_brick_present") == "unavailable" -> " — absence NOT established (inconclusive scan)"; true -> "" end))
          ev.("entity.candidate-lookup-not-performed", obs.(c)["cand_index_check"] == nil and obs.(c)["cand_index"] == nil, "STOP CONDITION if NOT: cand_index_check #{inspect(obs.(c)["cand_index_check"])} cand_index #{inspect(obs.(c)["cand_index"])}")
        end
        log.("entity summary #{short.(id)}: " <> entity_line.(c))

      other ->
        log.("entity refused locally: #{inspect(other)} (nothing transmitted)")
    end

    finish.()

  "outfit" ->
    [cand, expected, ttl_arg | _] = rest ++ ["-", "-", "-"]
    params = if cand == "-", do: %{}, else: %{"disguise_repository_id" => cand}
    opts = if expected == "-", do: [], else: [expected_generation: expected]
    opts = ttl_opts.(ttl_arg, opts)
    before = call.(cmd, :status, [])
    log.("outfit params #{inspect(params)} opts #{inspect(opts)}: before: #{status_line.(before)}")

    case call.(cmd, :inspect_outfit, [params, opts]) do
      {:ok, id} ->
        log.("outfit issued #{id}")
        File.write!(Path.join(evid, "#{label}-command-id.txt"), id <> "\n")
        c = wait_terminal.(id, 15_000)
        dump_record.(c)
        s = call.(cmd, :status, [])
        common_evidence.("outfit", c, s)
        ev.("outfit.hero-tuple-observed", st.(c, "hero_outfit_id") == "observed" and st.(c, "hero_charset") == "observed" and st.(c, "hero_variation") == "observed", "hero #{fld.(c, "hero_outfit_id")}/#{fld.(c, "hero_charset")}/#{fld.(c, "hero_variation")}")
        ev.("outfit.setter-not-invoked", obs.(c)["setter_called"] == nil and obs.(c)["invocation"] == nil and obs.(c)["apply_log"] == nil, "an inspection carries no setter fields: setter_called #{inspect(obs.(c)["setter_called"])} invocation #{inspect(obs.(c)["invocation"])}")
        log.("outfit summary #{short.(id)}: " <> outfit_line.(c))

      other ->
        log.("outfit refused locally: #{inspect(other)} (nothing transmitted)")
    end

    finish.()
end

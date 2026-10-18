# M6-F operator actions over RPC against the live relay node (the M6-F1b attended transform experiment under its own
# authorization; exercised offline by the M6-F1a tooling dry run against the M6-F1a command probe). Only
# GlacierRelay.Command's own public functions are called. The only effectful operations this script can issue are the
# authorization's: ONE compiled lift of the compiled candidate (candidate.transform.set/1 mode lift — the native side computes
# the +0.25 world-z target; no target, location, direction, rotation, scale, distance, entity, pointer or function name can be
# supplied here) behind a local guard over the qualifying exact inspection, and its restoration only through
# Command.restore_candidate/2 (the journal's plan bound to a later exact inspection; "already at baseline" means none is
# submitted). M6-F1a binding correction: both pass the inspection's id; the issuing authority verifies that inspection from
# its own journal and journals the binding with the accepted command ("inspection_binding", verified_by "authority"); the
# local guard below is an early operator check, never the authority. Every action appends to operator-actions.log and dumps the resulting status and command record under
# <label>-*. The run token is never read, printed or passed by this script.
#
#   elixir --sname op-<label> -S mix run --no-start cmd-m6f.exs <evidence-dir> <label> <action> [args]
#
# Actions:
#   status | journal | arm | disarm
#   ctransform [ttl_ms|-]                                            relay.inspect.candidate_transform/1 (read-only; the exact words)
#   attest <adapter_instance_id> <evidence_ref>                      the operator's telemetry attestation
#   own [expected_exe]                                               collect socket-ownership evidence only
#   arm-effectful [expected_exe] [ttl_ms]                            collect ownership evidence, then one-shot arm
#   lift <inspection_id> <expected_generation> [ttl_ms]              the ONE compiled lift, expectation = that inspection's exact words
#   plan-restore <command_id>                                        Command.plan_transform_restore (performs nothing)
#   restore <command_id> <inspection_id> <expected_generation> [ttl_ms]   the planner-bound restoration (or already_at_baseline)
#   observe-later <command_id> <inspection_id> <text...>             the later exact observation classified (held / returned / ...)
#   observe <command_id> <type> <inspection_id|-> <text...>          operator testimony (journaled)
node = String.to_atom(System.get_env("GLACIER_RELAY_NODE") || "relay@#{elem(:inet.gethostname(), 1)}")
true = :net_kernel.connect_node(node)
[evid, label, action | rest] = System.argv()

alias GlacierRelay.Command.TransformReadback
alias GlacierRelay.Command.TransformWords

Code.require_file("cmd_m6f_args.exs", __DIR__)

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
fld = fn c, k -> f = obs.(c)[k]; if is_map(f), do: "#{f["status"]}#{if Map.has_key?(f, "value"), do: "=" <> inspect(f["value"]), else: ""}#{if f["reason"], do: "(" <> f["reason"] <> ")", else: ""}", else: inspect(f) end
gens = fn c -> {ov.(c, "generation_expected"), ov.(c, "generation_at_receipt"), ov.(c, "generation_cached"), ov.(c, "generation_fresh"), ov.(c, "generation_post")} end
reason = fn c -> (c && c.result && c.result.reason) || "" end
eff = fn c -> c && c.effect && c.effect.effect end
inv = fn c -> c && c.effect && c.effect.invocation end
short = fn id -> String.slice(id || "", 0, 8) end
frame = fn c -> c && c.result && c.result.frame end
words = fn c, k, kind -> case TransformReadback.words(obs.(c)[k], kind) do {:ok, w} -> w; _ -> nil end end
wtext = fn w -> if is_list(w), do: TransformWords.encode(w), else: "unavailable" end

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
  "#{short.(c.id)} #{c.name}/#{c.version}: status #{c.status}; ladder #{inspect(c.stages)} (ms since issue); reason #{inspect(reason.(c))}; effect #{inspect(c.effect)}; restored #{inspect(c.restored)}; consequences #{inspect(c.consequences)}; unknown_reason #{inspect(c.unknown_reason)}; audit #{inspect(c.audit)}; observed #{inspect(c.observed)}; reversal_of #{inspect(c.reversal_of)}; link_generation #{inspect(c.link_generation)} | mode #{fld.(c, "mode")} preimage #{wtext.(words.(c, "preimage_world_words", :world))} requested #{wtext.(words.(c, "requested_world_words", :world))} postimage #{wtext.(words.(c, "postimage_world_words", :world))} world_match #{fld.(c, "world_match")} local_match #{fld.(c, "local_match")} hero_control #{fld.(c, "hero_control")} restore_facts #{fld.(c, "restore_facts")} | generations expected/receipt/cached/fresh/post #{inspect(gens.(c))} | setter_called #{inspect(ov.(c, "setter_called"))} invocation #{inspect(ov.(c, "invocation"))} apply_log #{inspect(ov.(c, "apply_log"))} precondition_ok #{inspect(ov.(c, "precondition_ok"))} reasons #{inspect(ov.(c, "precondition_reasons"))} budget #{inspect(ov.(c, "budget_remaining"))} frame #{inspect(frame.(c))}"
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
        "reversal_of" => c.reversal_of, "fields" => map_size(o), "observed_bytes" => byte_size(line),
        "stages" => Enum.map(c.stages, fn {k, v} -> [to_string(k), v] end)
      }) <> "\n"
    )

    log.("#{short.(c.id)}: observed #{map_size(o)} field(s), #{byte_size(line)} bytes as JSON; statuses #{inspect(Enum.frequencies(Enum.map(o, fn {_, f} -> is_map(f) && f["status"] end)))}")

    for name <- Enum.sort(Map.keys(o)) do
      f = o[name]
      log.("#{short.(c.id)}:   #{String.pad_trailing(name, 24)} #{if is_map(f), do: "#{f["status"]}#{if Map.has_key?(f, "value"), do: " = " <> inspect(f["value"]), else: ""}#{if f["reason"], do: " (" <> f["reason"] <> ")", else: ""}", else: inspect(f)}")
    end
  end
end

finish = fn ->
  s = call.(cmd, :status, [])
  dump.("command-status", s)
  log.("after: #{status_line.(s)}")
end

# Socket-ownership evidence from the Windows side (the C-3 shape): every ESTABLISHED TCP connection whose foreign address
# is 127.0.0.1:4749 and the image name of the owning process; validated as "exactly_one_hitman" only when exactly one such
# connection exists and its owner's image is the expected one (HITMAN3.exe for the run; the probe's image for the dry run).
collect_ownership = fn expected_exe ->
  {ns, _} = System.cmd("netstat.exe", ["-ano"], stderr_to_stdout: true)

  rows =
    ns
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "TCP"))
    |> Enum.map(&String.split(&1, ~r/\s+/))
    |> Enum.filter(fn
      [_, _local, foreign, "ESTABLISHED", _pid] -> String.ends_with?(foreign, ":4749")
      _ -> false
    end)

  File.write!(Path.join(evid, "#{label}-netstat.txt"), Enum.map_join(rows, "\n", &Enum.join(&1, " ")) <> "\n")

  owners =
    for [_, local, _foreign, _state, pid] <- rows do
      {tl, _} = System.cmd("tasklist.exe", ["/FI", "PID eq #{pid}", "/FO", "CSV", "/NH"], stderr_to_stdout: true)
      image = tl |> String.split(~r/\r?\n/) |> Enum.find("", &String.starts_with?(&1, "\"")) |> String.split("\",\"") |> List.first() |> String.trim_leading("\"")
      lport = local |> String.split(":") |> List.last() |> Integer.parse() |> then(fn {n, _} -> n; :error -> nil end)
      {String.to_integer(pid), image, lport}
    end

  n = length(owners)
  {pid, image, lport} = List.first(owners) || {0, "none", nil}
  ok = n == 1 and image == expected_exe
  validation = if ok, do: "exactly_one_hitman", else: String.slice("rejected: #{n} connection(s), owner #{image}", 0, 64)
  source = "netstat.exe -ano + tasklist.exe /FI PID (Windows; foreign 127.0.0.1:4749 ESTABLISHED)" <> if(expected_exe == "HITMAN3.exe", do: "", else: " [dry run: #{expected_exe}]")

  o = %{
    "collected_at" => now.(), "owner_pid" => pid, "executable" => image, "local_port" => lport, "remote_port" => 4749,
    "connections" => n, "validation" => validation, "source" => String.slice(source, 0, 128), "max_age_ms" => 60_000
  }

  File.write!(Path.join(evid, "#{label}-ownership.json"), JSON.encode!(o) <> "\n")
  log.("ownership evidence (expected owner #{expected_exe}): #{inspect(o)}; rows #{inspect(rows)}")
  o
end

ttl_of = fn more, default -> case more do [t | _] -> String.to_integer(t); _ -> default end end

# The local guard over a qualifying exact inspection before a lift: the inspection must be this link's, applied, playing on
# a stable mission, the candidate resolved / distinct / spatial-distinct / in no slot, the snapshot clean, the generation the
# operator's argument. The native applying-frame gate stays the final protection.
lift_guard = fn ins, gen, s ->
  d = if ins, do: TransformReadback.decode_inspection(obs.(ins)), else: nil
  okv = fn t -> match?({:ok, _}, t) end
  link_gen = s.link && s.link.generation
  [
    {"inspection-found", ins != nil},
    {"inspection-is-candidate-transform", ins != nil and ins.name == "relay.inspect.candidate_transform"},
    {"inspection-applied", ins != nil and ins.status == :applied},
    {"inspection-on-current-link", ins != nil and ins.link_generation == link_gen},
    {"inspection-generation-is-argument", ins != nil and ins.result.mission_generation == gen and ov.(ins, "generation_fresh") == gen},
    {"mission-playing", ov.(ins, "mission_playing") == true and ov.(ins, "scene_type") == "mission"},
    {"candidate-present-resolved-in-range", ov.(ins, "cand_brick_present") == true and ov.(ins, "cand_index_check") == "in_range" and ov.(ins, "cand_resolved") == true},
    {"candidate-hero-interface-id-owner", ov.(ins, "cand_hitman5") == true and ov.(ins, "cand_id_match") == true and ov.(ins, "cand_brick_owner") == "007c57a6ea581f8c"},
    {"candidate-distinct-and-spatial-distinct", ov.(ins, "cand_distinct") == true and ov.(ins, "cand_spatial") == true and ov.(ins, "cand_spatial_distinct") == true},
    {"candidate-in-no-registry-slot", ov.(ins, "cand_in_registry") == false},
    {"exact-snapshot-observed-and-clean", d != nil and okv.(d.candidate.world_words) and okv.(d.candidate.local_words) and okv.(d.candidate.parent) and d.candidate.dirty == {:ok, false}},
    {"hero-control-observed", d != nil and okv.(d.hero.world_words) and okv.(d.hero.local_words) and okv.(d.hero.parent)},
    {"reads-on-frame", ov.(ins, "reads_on_frame") == true},
    {"link-token-verified", s.trust.token_verified == true},
    {"effectful-armed", s.trust.effectful_armed == true},
    {"lift-budget-available", s.effectful.transform_lift_budget == 1},
    {"nothing-in-flight", s.in_flight == nil},
    {"audit-intact", s.audit == :intact}
  ]
end

apply_evidence = fn prefix, c, gen ->
  ev.("#{prefix}.terminal-applied", c.status == :applied, "status #{c.status} reason #{inspect(reason.(c))} (precondition_failed / unavailable = refused natively with its reasons; failed = a fault; unknown = link lost)")
  ev.("#{prefix}.setter-called-true", ov.(c, "setter_called") == true, inspect(ov.(c, "setter_called")))
  ev.("#{prefix}.invocation-completed", ov.(c, "invocation") == "called" and inv.(c) == :reported, "#{inspect(ov.(c, "invocation"))} / #{inspect(inv.(c))}")
  ev.("#{prefix}.effect-changed-all-twelve-words", eff.(c) == :changed and ov.(c, "world_match") == "target", "effect #{inspect(eff.(c))} world_match #{fld.(c, "world_match")} (unchanged / uncertain / indeterminate_dirty are valid, reported outcomes — findings, not instrumentation failures)")
  ev.("#{prefix}.postimage-equals-requested-bits", words.(c, "postimage_world_words", :world) != nil and words.(c, "postimage_world_words", :world) == words.(c, "requested_world_words", :world), "postimage #{wtext.(words.(c, "postimage_world_words", :world))} requested #{wtext.(words.(c, "requested_world_words", :world))}")
  ev.("#{prefix}.postimage-clean-same-entity-parent", ov.(c, "postimage_dirty") == false and ov.(c, "post_same_entity") == true and ov.(c, "postimage_parent") == ov.(c, "preimage_parent"), "postimage_dirty #{fld.(c, "postimage_dirty")} post_same_entity #{fld.(c, "post_same_entity")} parent #{fld.(c, "preimage_parent")} -> #{fld.(c, "postimage_parent")}")
  ev.("#{prefix}.local-match-recorded", st.(c, "local_match") == "observed", "parent-relative words after the call vs the preimage: #{fld.(c, "local_match")} (recorded: whether the setter updates the parent-relative fields is the experiment's question)")
  ev.("#{prefix}.hero-control-unchanged", ov.(c, "hero_control") == "unchanged", "STOP CONDITION if NOT (an immediate control change invalidates the native ledger; no further write): hero_control #{fld.(c, "hero_control")}")
  ev.("#{prefix}.post-call-generation-consistent", ov.(c, "generation_post") == gen and ov.(c, "generation_fresh") == gen and ov.(c, "generation_expected") == gen, inspect(gens.(c)))
  ev.("#{prefix}.apply-log-written", ov.(c, "apply_log") == "written", inspect(ov.(c, "apply_log")))
  ev.("#{prefix}.no-fault", c.status != :failed and not String.contains?(reason.(c), "fault"), "status #{c.status}")
  ev.("#{prefix}.no-reduction", obs.(c)["observed_reduced"] == nil, "observed_reduced #{inspect(obs.(c)["observed_reduced"])} fields #{map_size(obs.(c))}")
end

case action do
  "status" ->
    s = call.(cmd, :status, [])
    dump.("command-status", s)
    log.("status: #{status_line.(s)}")

  "journal" ->
    j = call.(GlacierRelay.Command.Journal, :status, [])
    dump.("journal-status", j)
    log.("journal: #{inspect(j)}")

  "arm" ->
    r = call.(cmd, :arm, [])
    log.("arm -> #{inspect(r)}")
    finish.()

  "disarm" ->
    r = call.(cmd, :disarm, [])
    log.("disarm -> #{inspect(r)}")
    finish.()

  "ctransform" ->
    [ttl_arg | _] = rest ++ ["-"]
    opts = if ttl_arg == "-", do: [], else: [ttl_ms: String.to_integer(ttl_arg)]

    case call.(cmd, :inspect_candidate_transform, [opts]) do
      {:ok, id} ->
        log.("ctransform issued #{id}")
        File.write!(Path.join(evid, "#{label}-command-id.txt"), id <> "\n")
        c = wait_terminal.(id, 15_000)
        dump_record.(c)
        d = TransformReadback.decode_inspection(obs.(c))
        ev.("ctransform.applied", c.status == :applied, "status #{c.status} reason #{inspect(reason.(c))}")
        ev.("ctransform.exact-words-observed", match?({:ok, _}, d.candidate.world_words) and match?({:ok, _}, d.candidate.local_words) and match?({:ok, _}, d.candidate.parent) and match?({:ok, _}, d.candidate.dirty), "cand world_words #{wtext.(words.(c, "cand_world_words", :world))} local_words #{wtext.(words.(c, "cand_local_words", :local))} dirty #{fld.(c, "cand_dirty")} parent #{fld.(c, "cand_parent")} | hero world_words #{wtext.(words.(c, "hero_world_words", :world))} dirty #{fld.(c, "hero_dirty")} parent #{fld.(c, "hero_parent")} | distinct #{fld.(c, "cand_distinct")} spatial_distinct #{fld.(c, "cand_spatial_distinct")} in_registry #{fld.(c, "cand_in_registry")} slots #{fld.(c, "registry_slots")}")

      other ->
        log.("ctransform refused locally: #{inspect(other)} (nothing transmitted)")
    end

    finish.()

  "attest" ->
    [adapter, ref | _] = rest ++ ["-", "-"]
    s = call.(cmd, :status, [])

    att = %{
      "adapter_instance_id" => adapter,
      "observed_at" => now.(),
      "basis" => "operator read the MissionSession 'CONNECTION identified instance_id' line in beam.log and the native log's 'adapter instance' line, and typed the id here",
      "evidence_ref" => ref,
      "max_age_ms" => 60_000
    }

    File.write!(Path.join(evid, "#{label}-attestation.json"), JSON.encode!(att) <> "\n")
    r = call.(cmd, :attest_telemetry, [att])
    log.("attest_telemetry #{inspect(att)} -> #{inspect(r)}; the command link's own hello id #{inspect(s.link && s.link.adapter_instance_id)} #{if s.link && s.link.adapter_instance_id == adapter, do: "equals", else: "DIFFERS FROM"} the attested id (informational; the attestation is the operator's, never derived from the peer)")
    finish.()

  "own" ->
    [exe | _] = rest ++ ["HITMAN3.exe"]
    collect_ownership.(exe)
    finish.()

  "arm-effectful" ->
    # M6-F2a: the documented owner-only form supplies the existing default TTL (it raised before its RPC); an explicit TTL must
    # be a plain millisecond count; the range is the authority's (CmdM6fArgs)
    case CmdM6fArgs.arm_effectful(rest) do
      {:ok, exe, ttl} ->
        o = collect_ownership.(exe)
        r = call.(cmd, :arm_effectful, [[ownership: o, ttl_ms: ttl]])
        log.("arm_effectful (ttl #{ttl} ms) -> #{inspect(r)}")

      {:error, e} ->
        log.("arm-effectful refused locally: #{inspect(e)} (nothing collected, nothing sent)")
        finish.()
        System.halt(2)
    end

    finish.()

  "lift" ->
    [insp, gen | more] = rest
    ttl = ttl_of.(more, 5_000)
    s = call.(cmd, :status, [])
    ins = call.(cmd, :command, [insp])
    log.("lift: the compiled +0.25 world-z displacement of the compiled candidate (the native side computes the target; nothing supplied); expectation = inspection #{insp}'s exact words; expected_generation #{gen} ttl #{ttl} ms; the inspection: #{if ins, do: describe.(ins), else: "NOT FOUND"}")
    guard = lift_guard.(ins, gen, s)
    failed = for {name, ok} <- guard, !ok, do: name
    for {name, ok} <- guard, do: log.("lift guard #{name}: #{if ok, do: "ok", else: "FAILED"}")

    if failed != [] do
      log.("LOCAL GUARD REFUSED: #{inspect(failed)}; nothing issued")
      finish.()
      System.halt(2)
    end

    params = %{"expect_world" => ov.(ins, "cand_world_words"), "expect_local" => ov.(ins, "cand_local_words"), "expect_parent" => ov.(ins, "cand_parent")}
    log.("lift expectation (bit for bit, from the inspection, never from its seven-digit text): #{inspect(params)}; the expected native target (replicated for the cross-check only): #{TransformWords.encode(TransformWords.lift_target(elem(TransformWords.decode_world(params["expect_world"]), 1)))}")
    r = call.(cmd, :lift_candidate, [params, [inspection_command_id: insp, expected_generation: gen, ttl_ms: ttl]])

    case r do
      {:ok, id} ->
        log.("lift issued #{id} (candidate.transform.set/1 mode lift; generation #{gen}; ttl #{ttl} ms)")
        File.write!(Path.join(evid, "#{label}-command-id.txt"), id <> "\n")
        c = wait_terminal.(id, 20_000)
        dump_record.(c)
        apply_evidence.("lift", c, gen)
        ev.("lift.preimage-equals-expectation-bits", ov.(c, "preimage_world_words") == params["expect_world"] and ov.(c, "preimage_local_words") == params["expect_local"] and ov.(c, "preimage_parent") == params["expect_parent"] and ov.(c, "preimage_dirty") == false, "preimage #{wtext.(words.(c, "preimage_world_words", :world))} dirty #{fld.(c, "preimage_dirty")} parent #{fld.(c, "preimage_parent")}")
        expected_target = words.(c, "preimage_world_words", :world) && TransformWords.lift_target(words.(c, "preimage_world_words", :world))
        ev.("lift.requested-is-compiled-lift-of-preimage", expected_target != nil and words.(c, "requested_world_words", :world) == expected_target, "requested #{wtext.(words.(c, "requested_world_words", :world))} vs preimage z + 0.25 in binary32 #{wtext.(expected_target)} (every other word copied)")
        ev.("lift.budget-consumed", ov.(c, "budget_remaining") == 0 and call.(cmd, :status, []).effectful.transform_lift_budget == 0, "native budget_remaining #{fld.(c, "budget_remaining")}; BEAM lift budget #{inspect(call.(cmd, :status, []).effectful.transform_lift_budget)}")
        j = call.(GlacierRelay.Command.Journal, :status, [])

        accepted =
          case call.(GlacierRelay.Command.Journal, :read, [j.path]) do
            {:ok, read} -> Enum.find(read.entries, &(&1["event"] == "command.accepted" and &1["command_id"] == id))
            other -> log.("journal read for the binding failed: #{inspect(other)}"); nil
          end

        b = (accepted && accepted["inspection_binding"]) || %{}
        ev.("lift.binding-verified-by-authority", b["verified_by"] == "authority" and b["inspection_command_id"] == insp and b["expect_world"] == params["expect_world"] and b["expect_local"] == params["expect_local"] and b["expect_parent"] == params["expect_parent"] and is_integer(b["age_ms"]) and b["age_ms"] <= b["max_age_ms"], inspect(Map.drop(b, ["label"])))
        ev.("lift.journaled-params-equal-transmitted", accepted != nil and accepted["params"] == c.params, inspect(accepted && accepted["params"]))
        log.("lift consequences: #{inspect(c.consequences)} (a changed stored matrix is not collision-proven safety, not a rendered position and not a visual-presence result; the later exact observations decide held / returned / drifted)")

      other ->
        log.("lift refused locally: #{inspect(other)} (nothing transmitted)")
    end

    finish.()

  "plan-restore" ->
    [id | _] = rest
    p = call.(cmd, :plan_transform_restore, [id])
    dump.("plan", p)
    log.("plan_transform_restore #{id} -> #{inspect(p)}")
    finish.()

  "restore" ->
    [orig, insp, gen | more] = rest
    ttl = ttl_of.(more, 5_000)
    p = call.(cmd, :plan_transform_restore, [orig])
    dump.("plan", p)
    log.("restore of #{orig} bound to the later exact inspection #{insp}, expected_generation #{gen}, ttl #{ttl} ms; plan -> #{inspect(p)}")
    r = call.(cmd, :restore_candidate, [orig, [inspection_command_id: insp, expected_generation: gen, ttl_ms: ttl]])

    case r do
      {:ok, rid} ->
        log.("restoration issued #{rid}")
        File.write!(Path.join(evid, "#{label}-command-id.txt"), rid <> "\n")
        c = wait_terminal.(rid, 20_000)
        dump_record.(c)
        ev.("restore.separate-command-id", rid != orig, rid)
        apply_evidence.("restore", c, gen)
        {:ok, plan} = p
        ev.("restore.requested-is-journaled-preimage", ov.(c, "requested_world_words") == plan.target_world, "requested #{wtext.(words.(c, "requested_world_words", :world))} vs the plan's preimage #{plan.target_world}")
        facts = TransformReadback.restore_facts(obs.(c)["restore_facts"])
        ev.("restore.world-restored-exact-observed", match?({:ok, %{world: true}}, facts), "restore_facts #{fld.(c, "restore_facts")} (world / local / parent / dirty / snapshot / within_tol are separate observed facts; only what the post read showed is claimed)")
        ev.("restore.snapshot-facts-recorded", match?({:ok, _}, facts), "#{inspect(facts)} — full exact snapshot restoration is reported only if observed (snapshot=1); the parent-relative fields, the parent and the dirty flag were re-observed, never assigned")
        ev.("restore.bound-to-original", c.reversal_of == orig and c.restored != nil, "reversal_of #{inspect(c.reversal_of)} restored #{inspect(c.restored)}")
        j = call.(GlacierRelay.Command.Journal, :status, [])

        bound =
          case call.(GlacierRelay.Command.Journal, :read, [j.path]) do
            {:ok, read} -> Enum.find(read.entries, &(&1["event"] == "command.accepted" and &1["command_id"] == rid))
            other -> log.("journal read for the binding failed: #{inspect(other)}"); nil
          end

        ev.("restore.binding-journaled", bound != nil and bound["reversal_of"] == orig and bound["reversal_inspection"]["inspection_command_id"] == insp and bound["reversal_inspection"]["later_class"] == "held", inspect(bound && Map.take(bound, ["reversal_of", "reversal_inspection", "seq"])))
        rb = (bound && bound["inspection_binding"]) || %{}
        ev.("restore.binding-verified-by-authority", rb["verified_by"] == "authority" and rb["inspection_command_id"] == insp and rb["restore_of"] == orig and rb["target_world"] == plan.target_world and rb["later_class"] == "held", inspect(Map.drop(rb, ["label"])))
        log.("restore consequences: #{inspect(c.consequences)} (restoring observed transform values is not a rollback of physics, perception, script, animation or other gameplay consequences)")

      {:error, :already_at_baseline} ->
        log.("restore NOT submitted: the later exact inspection #{insp} already shows the lift's preimage words (an engine return to baseline — a distinct outcome from a commanded restoration; recorded, nothing written)")
        ev.("restore.already-at-baseline-recorded", true, "no restoration call needed; none submitted to obtain a refusal")

      other ->
        log.("restore refused locally: #{inspect(other)} (nothing transmitted; drift, an indeterminate cache, a changed parent or generation, or an ambiguous original effect stop effectful issuance)")
    end

    finish.()

  "observe-later" ->
    [cid, insp | words_] = rest
    r = call.(cmd, :observe, [cid, "later_frame_read_back", Enum.join(words_, " "), [inspection_command_id: insp]])
    log.("observe-later #{cid} via #{insp} -> #{inspect(r)}")

    case r do
      {:ok, o} ->
        ev.("observe-later.classified", o["conclusion"] in ["held", "returned_to_baseline", "near_target", "near_baseline", "drifted", "indeterminate", "unavailable"], "conclusion #{inspect(o["conclusion"])} at frame #{inspect(o["inspection_frame"])} vs the command's #{inspect(o["command_frame"])} (a sampled state; never continuous behaviour, never a cause): #{inspect(o["comparison"])}")
      _ -> :ok
    end

    finish.()

  "observe" ->
    [cid, type, insp | words_] = rest
    opts = if insp == "-", do: [], else: [inspection_command_id: insp]
    r = call.(cmd, :observe, [cid, type, Enum.join(words_, " "), opts])
    log.("observe #{cid} #{type} #{inspect(opts)} #{inspect(Enum.join(words_, " "))} -> #{inspect(r)}")
    finish.()
end

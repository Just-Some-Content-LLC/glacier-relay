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
#   lift-follow <inspection_id> <expected_generation> [lift_ttl_ms|-] [schedule_ms|-] [request_timeout_ms|-] [inspection_ttl_ms|-]
#                                                                    M6-F2a: the same ONE lift behind the same local guard, with a
#                                                                    bounded READ-ONLY follow-up schedule validated and armed BEFORE
#                                                                    the lift is sent (m6f_follow.exs: at most six exact inspections,
#                                                                    default 0 / 250 / 1000 / 2000 / 5000 / 10000 ms after this process
#                                                                    observes the lift's terminal, one in flight, missed slots recorded,
#                                                                    never a substitute, never a write); every heavy report — the lift's
#                                                                    EVIDENCE lines and the sample dumps — after the schedule ends.
#                                                                    Writes <label>-follow.ndjson (created exclusively before the lift:
#                                                                    the plan, then the issuance at once, one line per sample as it
#                                                                    completes, the end) and <label>-s<N>-* afterwards. Refuses, before
#                                                                    anything is written, a directory under a sealed root (it or an
#                                                                    ancestor holds sha256.txt) and a label that already holds any
#                                                                    capture this action writes.
#                                                                    Every RPC is bounded (CmdM6fArgs: the issuance 3 s, the others
#                                                                    10 s, the follow-up reads the request timeout); an issuance that
#                                                                    times out or loses its reply is UNCERTAIN, never "nothing
#                                                                    transmitted": no read follows, no retry. Its stop marker is
#                                                                    <evidence-dir>/stop.marker, checked before EVERY read's dispatch
#                                                                    (the immediate first read included) and fail-closed: a marker
#                                                                    that cannot be looked at is a stop.
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
Code.require_file("m6f_follow.exs", __DIR__)

# M6-F2b preparation (item A): every RPC of lift-follow — before the lift, the issuance, the follow-up, the deferred report — is
# bounded, so a blocked authority cannot hold the tool indefinitely; the other actions keep the unbounded call they were qualified
# with, except their issuances (lift, restore, ctransform: bounded, and classified by CmdM6fArgs.issuance/1)
rpc_ms = if action == "lift-follow", do: CmdM6fArgs.rpc_timeout_ms(), else: :infinity
call = fn m, f, a -> :rpc.call(node, m, f, a, rpc_ms) end
# M6-F2a: a bounded RPC with an explicit bound (the follow-up's calls; the issuances)
call_t = fn m, f, a, t -> :rpc.call(node, m, f, a, t) end
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
    # a terminal record ends the wait; so does an RPC failure (a non-map reply other than nil: never waited on forever)
    (is_map(c) and c.status not in [:accepted, :transmitted, :received]) or not (is_map(c) or c == nil)
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
  log.("after: #{if is_map(s), do: status_line.(s), else: "the status RPC failed: #{inspect(s)}"}")
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

# M6-F2b preparation (item A): the operator's stop marker <evidence-dir>/stop.marker, checked fail-closed (CmdM6fArgs.stop_marker/1:
# true / false / {:error, _}; lift-follow's guard refuses anything but false and M6fFollow treats anything but false as a stop)
stop_marker = fn -> CmdM6fArgs.stop_marker(evid) end

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

# The lift's local guard and parameters (shared by "lift" and "lift-follow"; `extra` adds the caller's own refusals): halts with 2
# when the guard refuses, before anything is issued.
lift_prepare = fn insp, gen, ttl, extra ->
  s = call.(cmd, :status, [])
  ins = call.(cmd, :command, [insp])

  if not is_map(s) or not (is_map(ins) or ins == nil) do
    log.("LOCAL GUARD REFUSED: an RPC before the lift failed (status #{inspect(s)}; inspection #{inspect(ins)}); nothing issued")
    finish.()
    System.halt(2)
  end

  log.("lift: the compiled +0.25 world-z displacement of the compiled candidate (the native side computes the target; nothing supplied); expectation = inspection #{insp}'s exact words; expected_generation #{gen} ttl #{ttl} ms; the inspection: #{if ins, do: describe.(ins), else: "NOT FOUND"}")
  guard = lift_guard.(ins, gen, s) ++ extra.(s)
  failed = for {name, ok} <- guard, !ok, do: name
  for {name, ok} <- guard, do: log.("lift guard #{name}: #{if ok, do: "ok", else: "FAILED"}")

  if failed != [] do
    log.("LOCAL GUARD REFUSED: #{inspect(failed)}; nothing issued")
    finish.()
    System.halt(2)
  end

  params = %{"expect_world" => ov.(ins, "cand_world_words"), "expect_local" => ov.(ins, "cand_local_words"), "expect_parent" => ov.(ins, "cand_parent")}
  log.("lift expectation (bit for bit, from the inspection, never from its seven-digit text): #{inspect(params)}; the expected native target (replicated for the cross-check only): #{TransformWords.encode(TransformWords.lift_target(elem(TransformWords.decode_world(params["expect_world"]), 1)))}")
  {s, ins, params}
end

# The lift's record and its EVIDENCE lines after its terminal (shared by "lift" and "lift-follow"); returns the journal entries
# read for the binding (nil when the read failed).
lift_report = fn id, c, insp, gen, params ->
  dump_record.(c)
  apply_evidence.("lift", c, gen)
  ev.("lift.preimage-equals-expectation-bits", ov.(c, "preimage_world_words") == params["expect_world"] and ov.(c, "preimage_local_words") == params["expect_local"] and ov.(c, "preimage_parent") == params["expect_parent"] and ov.(c, "preimage_dirty") == false, "preimage #{wtext.(words.(c, "preimage_world_words", :world))} dirty #{fld.(c, "preimage_dirty")} parent #{fld.(c, "preimage_parent")}")
  expected_target = words.(c, "preimage_world_words", :world) && TransformWords.lift_target(words.(c, "preimage_world_words", :world))
  ev.("lift.requested-is-compiled-lift-of-preimage", expected_target != nil and words.(c, "requested_world_words", :world) == expected_target, "requested #{wtext.(words.(c, "requested_world_words", :world))} vs preimage z + 0.25 in binary32 #{wtext.(expected_target)} (every other word copied)")
  st = call.(cmd, :status, [])
  bud = if is_map(st), do: st.effectful.transform_lift_budget, else: {:status_rpc_failed, st}
  ev.("lift.budget-consumed", ov.(c, "budget_remaining") == 0 and bud == 0, "native budget_remaining #{fld.(c, "budget_remaining")}; BEAM lift budget #{inspect(bud)}")
  j = call.(GlacierRelay.Command.Journal, :status, [])

  entries =
    case is_map(j) && call.(GlacierRelay.Command.Journal, :read, [j.path]) do
      {:ok, read} -> read.entries
      other -> log.("journal read for the binding failed: #{inspect(other)}"); nil
    end

  accepted = entries && Enum.find(entries, &(&1["event"] == "command.accepted" and &1["command_id"] == id))
  b = (accepted && accepted["inspection_binding"]) || %{}
  ev.("lift.binding-verified-by-authority", b["verified_by"] == "authority" and b["inspection_command_id"] == insp and b["expect_world"] == params["expect_world"] and b["expect_local"] == params["expect_local"] and b["expect_parent"] == params["expect_parent"] and is_integer(b["age_ms"]) and b["age_ms"] <= b["max_age_ms"], inspect(Map.drop(b, ["label"])))
  ev.("lift.journaled-params-equal-transmitted", accepted != nil and accepted["params"] == c.params, inspect(accepted && accepted["params"]))
  log.("lift consequences: #{inspect(c.consequences)} (a changed stored matrix is not collision-proven safety, not a rendered position and not a visual-presence result; the later exact observations decide held / returned / drifted)")
  entries
end

# M6-F2a: the cheap identity snapshot the follow-up sequence compares before each later slot (a few RPCs; the run's full
# identity monitor stays the run wrapper's): node, authority, journal, link generation, adapter, and the state they must keep.
follow_ident = fn ->
  s = call_t.(cmd, :status, [], 2_000)
  j = call_t.(GlacierRelay.Command.Journal, :status, [], 2_000)
  # a reply that is not a status map is an RPC failure (M6fFollow.identity_check stops with rpc_failed), not a changed identity
  sv = fn f -> if is_map(s), do: f.(s), else: {:badrpc, {:status_reply, s}} end
  jv = fn f -> if is_map(j), do: f.(j), else: {:badrpc, {:journal_reply, j}} end

  %{
    node_os_pid: call_t.(:os, :getpid, [], 2_000),
    authority_pid: call_t.(Process, :whereis, [GlacierRelay.Command.Authority], 2_000),
    journal_pid: call_t.(Process, :whereis, [GlacierRelay.Command.Journal], 2_000),
    journal_id: jv.(& &1.journal_id),
    journal_status: jv.(& &1.status),
    link_generation: sv.(&(&1.link && &1.link.generation)),
    adapter_instance_id: sv.(&(&1.link && &1.link.adapter_instance_id)),
    protocol_version: sv.(&(&1.link && &1.link.protocol_version)),
    token_verified: sv.(&(&1.link && &1.link.token_verified)),
    peer: sv.(& &1.trust.peer),
    audit: sv.(& &1.audit)
  }
end

# M6-F2a: the follow-up's report, written only after the schedule ended: one line per slot, the EVIDENCE lines, every sample's
# command record and read-back under <label>-s<N>-*, and the whole result as <label>-follow-result.json.
follow_report = fn id, r, entries, lift_call_ms, marks ->
  slots = r.slots
  req = Enum.filter(slots, &(&1.outcome == "requested"))
  s0 = List.first(slots)
  p = r.plan
  classes = M6fFollow.classes() ++ ["not_a_later_frame"]
  log.("follow: schedule #{inspect(p.schedule_ms)} ms after this process observed the lift's terminal (windows #{inspect(p.windows_ms)} ms; on time <= #{p.on_time_ms} ms late; overall deadline #{p.overall_deadline_ms} ms; inspection ttl #{p.inspection_ttl_ms} ms; request timeout #{p.request_timeout_ms} ms); lift_candidate returned after #{lift_call_ms} ms; the terminal observed #{r.terminal_wait_ms} ms after the wait began (#{r.terminal_polls} polls); the lift's native frame #{inspect(r.original && r.original.frame)} at #{inspect(r.original && r.original.native_at)} (native clock); the authority's ladder #{inspect(r.original && r.original.authority_stages)} (ms since issue, the authority's clock)")

  for sl <- slots do
    log.("follow slot #{sl.slot}: planned +#{sl.planned_ms} ms (window #{sl.window_ms} ms): #{sl.outcome} #{sl.timing}#{if sl[:lateness_ms], do: " late #{sl.lateness_ms} ms", else: ""}#{if sl[:request_ms], do: "; requested +#{sl.request_ms} ms, result +#{sl[:result_ms]} ms (round trip #{sl[:round_trip_ms]} ms, #{sl[:result_polls]} polls)", else: ""}#{if sl[:inspection_id], do: "; #{short.(sl.inspection_id)} #{sl[:status]}", else: ""}#{if sl[:frame], do: "; native frame #{sl.frame} (+#{sl[:frames_after_lift]} frames, +#{inspect(sl[:native_ms_after_lift])} ms native)", else: ""}#{if sl[:class], do: "; class #{sl.class} (journal: #{inspect(sl[:conclusion])})", else: ""}#{if sl[:refusal], do: "; refused #{sl.refusal}", else: ""}")
  end

  ev.("follow.plan-armed-before-lift", marks.plan_written == :ok and is_integer(marks.t_plan_us) and marks.t_plan_us < marks.t_send_us,
    "the schedule #{inspect(p.schedule_ms)} validated, the follow file created exclusively and its follow.plan line written (#{inspect(marks.plan_written)}) at #{inspect(marks.t_plan_us)} us, before lift_candidate was called at #{inspect(marks.t_send_us)} us (this process's monotonic clock)")
  ev.("follow.original-applied", r.original != nil and r.original.status == "applied", "status #{inspect(r.original && r.original.status)} (anything else: no follow-up read, no retry)")
  ev.("follow.at-most-six-requests", r.requests <= M6fFollow.max_requests() and r.requests <= length(p.schedule_ms), "#{r.requests} request(s), #{r.missed} missed slot(s), #{length(slots)} slot(s)")
  pairs = Enum.zip(req, Enum.drop(req, 1))
  ev.("follow.one-in-flight", Enum.all?(pairs, fn {a1, b1} -> is_number(a1[:result_ms]) and b1.request_ms >= a1.result_ms end), "every request sent after the previous result was received (#{length(pairs)} pair(s))")
  ev.("follow.no-catch-up", Enum.all?(req, &(&1.lateness_ms >= 0 and &1.lateness_ms <= &1.window_ms)) and Enum.all?(slots, &(&1.outcome != "missed" or &1[:inspection_id] == nil)), "each request inside its own slot window, never early; a missed slot has no request and no substitute")
  ev.("follow.first-request-within-target", s0 != nil and s0.outcome == "requested" and s0.planned_ms == 0 and s0.request_ms <= p.first_request_target_ms, "first request +#{inspect(s0 && s0[:request_ms])} ms after the observed terminal (this process's clock; target <= #{p.first_request_target_ms} ms)")
  ev.("follow.first-observation-later-frame", s0 != nil and s0[:later_frame] == true, "first read on native frame #{inspect(s0 && s0[:frame])} vs the lift's #{inspect(r.original && r.original.frame)} (+#{inspect(s0 && s0[:frames_after_lift])} frames; a same-frame read is not a later-frame sample)")
  ev.("follow.first-observation-within-target", s0 != nil and s0[:later_frame] == true and is_integer(s0[:native_ms_after_lift]) and s0.native_ms_after_lift <= p.first_observation_target_ms, "first later observation +#{inspect(s0 && s0[:native_ms_after_lift])} ms after the lift on the native clock (target <= #{p.first_observation_target_ms} ms; an observation time, not a return time)")
  ev.("follow.classes-committed", Enum.all?(req, &(&1[:class] == nil or &1.class in classes)), "classes #{inspect(Enum.map(req, & &1[:class]))}")
  ev.("follow.journal-agrees", Enum.all?(req, &(&1[:class] == nil or &1[:conclusion_agrees] == true)), "the authority's Command.observe conclusion equals the local class at every classified slot: #{inspect(Enum.map(req, & &1[:conclusion]))}")

  after_lift =
    case entries && Enum.find_index(entries, &(&1["event"] == "command.accepted" and &1["command_id"] == id)) do
      nil -> nil
      i -> entries |> Enum.drop(i + 1) |> Enum.filter(&(&1["event"] == "command.accepted"))
    end

  ev.("follow.only-reads-after-the-lift", after_lift != nil and Enum.all?(after_lift, &(&1["name"] == "relay.inspect.candidate_transform")) and length(after_lift) == r.requests, "commands accepted after the lift (journal): #{inspect(after_lift && Enum.map(after_lift, & &1["name"]))} (#{r.requests} follow-up request(s); no restoration, no second lift, no outfit command)")
  journaled =
    for e <- entries || [], e["event"] == "operator.observation", e["type"] == "later_frame_read_back", e["command_id"] == id, do: e["inspection_command_id"]

  classified = for sl <- req, sl[:conclusion] != nil, do: sl.inspection_id
  ev.("follow.observations-journaled", entries != nil and Enum.sort(journaled) == Enum.sort(classified), "the journal holds #{length(journaled)} later_frame_read_back observation(s) of the lift; #{length(classified)} classified slot(s) were journaled through Command.observe/4")
  ev.("follow.completed", r.stop == nil, "stop #{inspect(r.stop)} (nil = the schedule ran to its end; any stop is a recorded outcome, never retried)")
  ev.("follow.evidence-lines-written", r.emit_errors == [], "follow file lines: #{inspect(r.emit_errors)}")

  for sl <- req, is_binary(sl[:inspection_id]) do
    rec = call.(cmd, :command, [sl.inspection_id])
    n = "#{label}-s#{sl.slot}"
    File.write!(Path.join(evid, "#{n}-command-id.txt"), sl.inspection_id <> "\n")
    File.write!(Path.join(evid, "#{n}-command-record.txt"), text.(rec))
    File.write!(Path.join(evid, "#{n}-command-record.bin"), :erlang.term_to_binary(rec))

    if is_map(rec) and rec.result do
      File.write!(Path.join(evid, "#{n}-observed.json"), JSON.encode!(obs.(rec)) <> "\n")
      File.write!(Path.join(evid, "#{n}-result.json"), JSON.encode!(%{
        "command_id" => rec.id, "name" => rec.name, "version" => rec.version, "command_status" => to_string(rec.status),
        "status" => to_string(rec.result.status), "reason" => rec.result.reason, "frame" => rec.result.frame,
        "native_at" => rec.result.native_at, "mission_generation" => rec.result.mission_generation,
        "adapter_instance_id" => rec.result.adapter_instance_id, "link_generation" => rec.link_generation,
        "fields" => map_size(obs.(rec)), "stages" => Enum.map(rec.stages, fn {k, v} -> [to_string(k), v] end)
      }) <> "\n")
    end
  end

  File.write!(Path.join(evid, "#{label}-follow-result.json"), JSON.encode!(%{
    "original_id" => id, "stop" => M6fFollow.text(r.stop), "requests" => r.requests, "missed" => r.missed,
    "terminal_wait_ms" => r.terminal_wait_ms, "terminal_polls" => r.terminal_polls, "lift_call_ms" => lift_call_ms,
    "clock" => %{"basis" => "this operator process's monotonic clock, microseconds (never compared with another process's clock)",
      "vm_age_ms_at_plan" => marks.vm_age_ms, "t_plan_us" => marks.t_plan_us, "t_send_us" => marks.t_send_us, "t_ret_us" => marks.t_ret_us,
      "t_follow_start_us" => r.t0_us, "t_terminal_observed_us" => r.terminal_observed_us},
    "original" => Map.new(r.original || %{}, fn {k, v} -> {to_string(k), v} end),
    "plan" => Map.new(p, fn {k, v} -> {to_string(k), v} end),
    "slots" => Enum.map(slots, fn sl -> Map.new(sl, fn {k, v} -> {to_string(k), if(is_tuple(v), do: inspect(v), else: v)} end) end)
  }) <> "\n")
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

    case CmdM6fArgs.issuance(call_t.(cmd, :inspect_candidate_transform, [opts], CmdM6fArgs.issue_timeout_ms())) do
      {:issued, id} ->
        log.("ctransform issued #{id}")
        File.write!(Path.join(evid, "#{label}-command-id.txt"), id <> "\n")
        c = wait_terminal.(id, 15_000)
        dump_record.(c)
        d = TransformReadback.decode_inspection(obs.(c))
        ev.("ctransform.applied", c.status == :applied, "status #{c.status} reason #{inspect(reason.(c))}")
        ev.("ctransform.exact-words-observed", match?({:ok, _}, d.candidate.world_words) and match?({:ok, _}, d.candidate.local_words) and match?({:ok, _}, d.candidate.parent) and match?({:ok, _}, d.candidate.dirty), "cand world_words #{wtext.(words.(c, "cand_world_words", :world))} local_words #{wtext.(words.(c, "cand_local_words", :local))} dirty #{fld.(c, "cand_dirty")} parent #{fld.(c, "cand_parent")} | hero world_words #{wtext.(words.(c, "hero_world_words", :world))} dirty #{fld.(c, "hero_dirty")} parent #{fld.(c, "hero_parent")} | distinct #{fld.(c, "cand_distinct")} spatial_distinct #{fld.(c, "cand_spatial_distinct")} in_registry #{fld.(c, "cand_in_registry")} slots #{fld.(c, "registry_slots")}")

      {:refused, reason} ->
        log.("ctransform refused locally: #{inspect(reason)} (refused before transmission: nothing transmitted)")

      {:uncertain, why} ->
        log.("ctransform issuance UNCERTAIN: #{inspect(why)} (a timeout, a lost reply or a send failure: the read MAY have been transmitted; not retried)")
        ev.("ctransform.issuance-determined", false, "uncertain: #{inspect(why)}")
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
    {_s, _ins, params} = lift_prepare.(insp, gen, ttl, fn _ -> [] end)
    r = call_t.(cmd, :lift_candidate, [params, [inspection_command_id: insp, expected_generation: gen, ttl_ms: ttl]], CmdM6fArgs.issue_timeout_ms())

    case CmdM6fArgs.issuance(r) do
      {:issued, id} ->
        log.("lift issued #{id} (candidate.transform.set/1 mode lift; generation #{gen}; ttl #{ttl} ms)")
        File.write!(Path.join(evid, "#{label}-command-id.txt"), id <> "\n")
        c = wait_terminal.(id, 20_000)
        lift_report.(id, c, insp, gen, params)

      {:refused, reason} ->
        log.("lift refused locally: #{inspect(reason)} (refused before transmission: nothing transmitted)")

      {:uncertain, why} ->
        log.("LIFT ISSUANCE UNCERTAIN: lift_candidate's bounded RPC (#{CmdM6fArgs.issue_timeout_ms()} ms) returned #{inspect(why)} — the lift MAY have been accepted and transmitted; no retry, no second lift; the journal is the record")
        ev.("lift.issuance-determined", false, "uncertain: #{inspect(why)} (HARD STOP for the run's effectful issuance)")
    end

    finish.()

  "lift-follow" ->
    # 1 everything that can be refused is refused before the lift: the arguments and the follow plan, the destination, the
    #   follow file (created exclusively), the warm-up of the code the timed sequence uses, the identity baseline, the guard
    # a sealed destination — the directory or any ancestor holding sha256.txt (a sealed root keeps its manifest at its top) — is
    # refused first, and nothing at all is written into it (not even the log line)
    sealed =
      Path.expand(evid)
      |> Stream.iterate(&Path.dirname/1)
      |> Enum.reduce_while(nil, fn d, _ -> if File.exists?(Path.join(d, "sha256.txt")), do: {:halt, d}, else: if(d == Path.dirname(d), do: {:halt, nil}, else: {:cont, nil}) end)

    if sealed do
      IO.puts("#{now.()} #{label} lift-follow REFUSED: #{sealed} holds sha256.txt (a sealed evidence root is never written, nor any directory under it); nothing issued, nothing written")
      System.halt(2)
    end

    # a reused label: any capture THIS action would write under the label already existing is refused, before anything is
    # written (the run wrapper's own captures under longer labels — op.sh's identity gate <label>-pre-* — are not this action's)
    existing =
      (for n <- ~w(follow.ndjson follow-result.json command-id.txt command-record.txt command-record.bin observed.json result.json command-status.txt command-status.bin),
          File.exists?(Path.join(evid, "#{label}-#{n}")), do: Path.join(evid, "#{label}-#{n}")) ++
        Path.wildcard(Path.join(evid, "#{label}-s[0-9]-*"))

    if existing != [] do
      IO.puts("#{now.()} #{label} lift-follow REFUSED: label '#{label}' already has #{length(existing)} capture(s) this action writes, in #{evid} (e.g. #{Path.basename(hd(existing))}); choose a new label; nothing issued, nothing written")
      System.halt(2)
    end

    {a, plan} =
      with {:ok, a} <- CmdM6fArgs.lift_follow(rest), {:ok, plan} <- M6fFollow.plan(a.follow) do
        {a, plan}
      else
        e ->
          log.("lift-follow refused locally before anything was issued: #{inspect(e)}")
          System.halt(2)
      end

    ffile = Path.join(evid, "#{label}-follow.ndjson")

    # the follow file is created exclusively (a race with another writer of the same label is refused here too)
    fd =
      case File.open(ffile, [:write, :exclusive, :binary]) do
        {:ok, fd} -> fd
        {:error, e} ->
          log.("lift-follow REFUSED: the follow file #{ffile} cannot be created exclusively (#{inspect(e)}); nothing issued")
          System.halt(2)
      end

    wjson = fn m -> IO.binwrite(fd, JSON.encode!(m) <> "\n") end
    us = fn -> System.monotonic_time(:microsecond) end
    msd = fn d -> Float.round(d / 1000, 3) end
    tw0 = us.()
    for m <- [M6fFollow, TransformReadback, TransformWords, GlacierRelay.Command.CandidateReadback, JSON, DateTime, Float, Regex], do: Code.ensure_loaded!(m)
    warm = TransformReadback.decode_inspection(%{})
    _ = TransformReadback.classify_later(warm.candidate, [], [])
    _ = TransformReadback.classify_control(warm.hero, warm.hero)
    _ = TransformReadback.decode_apply(%{})
    _ = JSON.encode!(%{"warm" => [1, "x", 2.5]})
    ident0 = follow_ident.()
    warm_ms = msd.(us.() - tw0)

    run_base =
      case File.read(Path.join(evid, "ident-baseline.bin")) do
        {:ok, bin} -> :erlang.binary_to_term(bin)
        _ -> nil
      end

    run_changed = if run_base, do: for(k <- M6fFollow.identity_keys(), Map.get(run_base, k) != Map.get(ident0, k), do: k), else: []
    log.("lift-follow: the run's identity baseline (ident-baseline.bin) #{if run_base, do: "compared: changed #{inspect(run_changed)}", else: "NOT present in #{evid}: not compared (the cheap follow-up baseline is taken now)"}")

    {s, ins, params} =
      lift_prepare.(a.inspection, a.generation, a.lift_ttl_ms, fn s ->
        [
          {"follow-plan-validated", true},
          {"follow-inert-armed-for-the-reads", s.trust.armed == true},
          {"follow-no-stop-marker", stop_marker.() == false},
          {"follow-identity-baseline-captured", M6fFollow.identity_check(%{identity: fn -> ident0 end}, ident0) == :ok},
          {"follow-identity-equals-run-baseline-when-present", run_base == nil or run_changed == []}
        ]
      end)

    {vm_age_ms, _} = :erlang.statistics(:wall_clock)
    t_plan_us = us.()

    plan_written =
      wjson.(%{"event" => "follow.plan", "label" => label, "utc" => now.(), "t_plan_us" => t_plan_us, "vm_age_ms" => vm_age_ms, "inspection_binding" => a.inspection,
      "expected_generation" => a.generation, "lift_ttl_ms" => a.lift_ttl_ms, "link_generation" => s.link.generation, "adapter_instance_id" => s.link.adapter_instance_id,
      "plan" => Map.new(Map.drop(plan, [:first_request_target_ms, :first_observation_target_ms]), fn {k, v} -> {to_string(k), v} end),
      "targets" => %{"first_request_ms" => plan.first_request_target_ms, "first_observation_native_ms" => plan.first_observation_target_ms},
      "warm_up_ms" => warm_ms, "run_baseline_compared" => run_base != nil,
      "baseline_identity" => Map.new(ident0, fn {k, v} -> {to_string(k), inspect(v)} end)})

    if plan_written != :ok do
      log.("lift-follow REFUSED: the follow.plan line was not written (#{inspect(plan_written)}); nothing issued")
      System.halt(2)
    end

    rt = plan.request_timeout_ms

    client = %{
      now_us: us,
      sleep_ms: &Process.sleep/1,
      inspect: fn ttl -> call_t.(cmd, :inspect_candidate_transform, [[ttl_ms: ttl]], rt) end,
      command: fn id -> call_t.(cmd, :command, [id], rt) end,
      identity: follow_ident,
      observe: fn orig, insp, t -> call_t.(cmd, :observe, [orig, "later_frame_read_back", t, [inspection_command_id: insp]], rt) end,
      stop?: stop_marker,
      emit: wjson
    }

    # 2 the ONE lift; 3 the schedule, started by the observed terminal; 4 the deferred reports
    t_send = us.()
    r = call_t.(cmd, :lift_candidate, [params, [inspection_command_id: a.inspection, expected_generation: a.generation, ttl_ms: a.lift_ttl_ms]], CmdM6fArgs.issue_timeout_ms())
    t_ret = us.()

    case CmdM6fArgs.issuance(r) do
      {:issued, id} ->
        # the issuance is recorded at once, while the lift is in flight (before its terminal is observed — never between the
        # terminal and the first follow-up request): a crash during the terminal wait cannot leave an issued lift unrecorded
        issued = wjson.(%{"event" => "follow.issued", "original_id" => id, "t_send_us" => t_send, "t_ret_us" => t_ret, "utc" => now.()})
        idw = File.write(Path.join(evid, "#{label}-command-id.txt"), id <> "\n")
        log.("lift issued #{id} (candidate.transform.set/1 mode lift; generation #{a.generation}; ttl #{a.lift_ttl_ms} ms); the follow-up schedule #{inspect(plan.schedule_ms)} ms was armed before it#{if issued == :ok and idw == :ok, do: "", else: "; WARNING: issuance record writes #{inspect({issued, idw})}"}")

        ctx = %{
          original_id: id, expected_generation: a.generation, link_generation: s.link.generation, adapter_instance_id: s.link.adapter_instance_id,
          baseline_identity: ident0, binding_observed: obs.(ins)
        }

        result = M6fFollow.run(client, plan, ctx)
        c = call.(cmd, :command, [id])
        c = if is_map(c) and c.status in [:accepted, :transmitted, :received], do: wait_terminal.(id, 20_000), else: c

        entries =
          if is_map(c) do
            lift_report.(id, c, a.inspection, a.generation, params)
          else
            # e.g. the authority restarted during the schedule (nil: its records are gone; the journal file keeps them) or the
            # bounded RPC failed ({:badrpc, _}); the lift's EVIDENCE lines need the live record and are NOT produced; the follow
            # result's original summary (taken when the terminal was observed) and the journal stand; nothing is reconstructed
            log.("the lift's record #{id} could not be read (#{inspect(c)}: nil = the authority no longer holds it, {:badrpc, _} = the bounded RPC failed): the lift's EVIDENCE lines are not produced; the follow result's original summary (taken at the observed terminal) and the journal file are the record")
            j = call.(GlacierRelay.Command.Journal, :status, [])

            case is_map(j) && call.(GlacierRelay.Command.Journal, :read, [j.path]) do
              {:ok, read} -> read.entries
              other -> log.("journal read failed: #{inspect(other)}"); nil
            end
          end

        follow_report.(id, result, entries, msd.(t_ret - t_send), %{plan_written: plan_written, t_plan_us: t_plan_us, t_send_us: t_send, t_ret_us: t_ret, vm_age_ms: vm_age_ms})

      {:refused, reason} ->
        log.("lift refused locally: #{inspect(reason)} (refused before transmission: nothing transmitted; no follow-up read)")
        wjson.(%{"event" => "follow.end", "stop" => "lift_not_issued", "detail" => inspect(r), "requests" => 0, "t_send_us" => t_send, "t_ret_us" => t_ret})
        ev.("follow.lift-not-issued-no-read", true, "lift_candidate returned #{inspect(r)}: a refusal decided before transmission; no follow-up request was or will be issued; no retry")

      {:uncertain, why} ->
        # a timeout, a lost reply or a send failure is NOT a refusal: the lift may be in the engine; nothing here follows it, retries
        # it or issues anything else — the run wrapper makes it a HARD STOP and the journal is the record of what happened
        log.("LIFT ISSUANCE UNCERTAIN: lift_candidate's bounded RPC (#{CmdM6fArgs.issue_timeout_ms()} ms) returned #{inspect(why)} after #{msd.(t_ret - t_send)} ms — the lift MAY have been accepted and transmitted; no follow-up read, no retry, no second lift")
        wjson.(%{"event" => "follow.end", "stop" => "lift_issuance_uncertain", "detail" => inspect(why), "requests" => 0, "t_send_us" => t_send, "t_ret_us" => t_ret})
        ev.("follow.lift-issuance-determined", false, "UNCERTAIN: #{inspect(why)} (HARD STOP for the run's effectful issuance; the journal is the record)")
        ev.("follow.no-read-after-uncertain-issuance", true, "no follow-up request was or will be issued; no retry")
    end

    File.close(fd)
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
    r = call_t.(cmd, :restore_candidate, [orig, [inspection_command_id: insp, expected_generation: gen, ttl_ms: ttl]], CmdM6fArgs.issue_timeout_ms())

    case CmdM6fArgs.issuance(r) do
      {:issued, rid} ->
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

      {:refused, :already_at_baseline} ->
        log.("restore NOT submitted: the later exact inspection #{insp} already shows the lift's preimage words (an engine return to baseline — a distinct outcome from a commanded restoration; recorded, nothing written)")
        ev.("restore.already-at-baseline-recorded", true, "no restoration call needed; none submitted to obtain a refusal")

      {:refused, reason} ->
        log.("restore refused locally: #{inspect(reason)} (refused before transmission: nothing transmitted; drift, an indeterminate cache, a changed parent or generation, a stale inspection, or an ambiguous original effect stop effectful issuance)")

      {:uncertain, why} ->
        log.("RESTORATION ISSUANCE UNCERTAIN: restore_candidate's bounded RPC (#{CmdM6fArgs.issue_timeout_ms()} ms) returned #{inspect(why)} — the restoration MAY have been accepted and transmitted; no retry")
        ev.("restore.issuance-determined", false, "uncertain: #{inspect(why)} (HARD STOP for the run's effectful issuance)")
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

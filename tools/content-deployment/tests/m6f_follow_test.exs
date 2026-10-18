# M6-F2a: deterministic TOOL-LEVEL tests of the follow-up sampler's orchestration (m6f_follow.exs) against a SCRIPTED fake client
# with a VIRTUAL clock. Nothing here is engine behaviour, probe behaviour or a timing measurement: every frame, word, latency and
# identity below is scripted (synthetic values in the read-backs' real formats), so these tests prove what the tool DOES with
# each sequence of answers — the deadlines, the missed / delayed slots, the stops, the classes it reports and the calls it makes.
# The real classification code (GlacierRelay.Command.TransformReadback) is used, not a copy.
#
#   (cd relay && elixir -S mix run --no-start ../tools/content-deployment/tests/m6f_follow_test.exs)
ExUnit.start(autorun: false)
Code.require_file("../m6f_follow.exs", __DIR__)

defmodule FakeRelay do
  @moduledoc false
  # Virtual time in microseconds. Every client call costs `rpc_us`; sleep_ms advances the clock.
  @rpc_us 300
  @pre_w "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfc5099a"
  @req_w "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfa5099a"
  @drift_w "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bf25099a"
  @near_w "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfa5099b"
  @pre_l "00000000,00000000,bfc5099a,80000000,00000000,80000000,3f800000"
  @post_l "00000000,00000000,bfa5099a,80000000,00000000,80000000,3f800000"
  @hero_w "3e2b7674,bf7c62bd,00000000,3f7c62bd,3e2b7674,00000000,00000000,00000000,3f800000,c2a7b790,416bea67,bfc2b6ff"
  @hero_l "c2a7b790,416bea67,bfc2b6ff,80000000,00000000,3f252b92,3f43969f"
  @gen "synthetic-generation-1"
  @adapter "00000000-0000-4000-8000-000000000001"
  @lift_frame 1000
  @lift_native "2026-01-01T00:00:00.000Z"

  def pre_w, do: @pre_w
  def req_w, do: @req_w
  def gen, do: @gen
  def adapter, do: @adapter
  def lift_frame, do: @lift_frame

  defp o(v), do: %{"status" => "observed", "value" => v}

  def inspection_obs(world, local, extra \\ %{}) do
    %{
      "targets" => o("007c57a6ea581f8c,feede715906f747f"), "cand_brick_owner" => o("007c57a6ea581f8c"), "cand_brick_present" => o(true),
      "cand_index_check" => o("in_range"), "cand_resolved" => o(true), "cand_hitman5" => o(true), "cand_id_match" => o(true), "cand_spatial" => o(true),
      "cand_distinct" => o(true), "cand_spatial_distinct" => o(true), "cand_in_registry" => o(false), "registry_slots" => o("0:local,1:empty,2:empty,3:empty"),
      "cand_world_words" => o(world), "cand_local_words" => o(local), "cand_dirty" => o(false), "cand_parent" => o("007c57a6ea581f8c"),
      "hero_world_words" => o(@hero_w), "hero_local_words" => o(@hero_l), "hero_dirty" => o(false), "hero_parent" => o("00b6cedd6778f19c"),
      "reads_on_frame" => o(true), "receipt_to_frame_ms" => o(0), "generation_fresh" => o(@gen), "mission_playing" => o(true), "scene_type" => o("mission")
    }
    |> Map.merge(extra)
  end

  def binding_obs, do: inspection_obs(@pre_w, @pre_l)

  def lift_record(status \\ :applied, extra \\ %{}) do
    obs = %{"mode" => o("lift"), "preimage_world_words" => o(@pre_w), "preimage_local_words" => o(@pre_l), "preimage_parent" => o("007c57a6ea581f8c"),
      "preimage_dirty" => o(false), "requested_world_words" => o(@req_w), "postimage_world_words" => o(@req_w), "postimage_local_words" => o(@post_l),
      "postimage_parent" => o("007c57a6ea581f8c"), "postimage_dirty" => o(false), "effect" => o("changed"), "world_match" => o("target"),
      "local_match" => o("changed"), "setter_called" => o(true), "hero_control" => o("unchanged")}

    Map.merge(%{id: "lift-1", name: "candidate.transform.set", status: status, link_generation: 1, stages: [accepted: 0, transmitted: 1, received: 2, applied: 55],
      result: %{status: status, reason: if(status == :applied, do: nil, else: "scripted #{status}"), frame: @lift_frame, native_at: @lift_native,
        mission_generation: @gen, adapter_instance_id: @adapter, observed: obs}}, extra)
  end

  def baseline_identity, do: %{node_os_pid: ~c"4242", authority_pid: :authority_a, journal_pid: :journal_a, journal_id: "journal-1", journal_status: :open,
    link_generation: 1, adapter_instance_id: @adapter, protocol_version: 2, token_verified: true, peer: :identified, audit: :intact}

  # A read's scripted answer: %{latency_ms, frames, words: :held | :returned | :drifted | :near | :dirty | :unavailable | :malformed,
  #   obs: extra observed fields, status, link_generation, generation, adapter, refuse: reason, withhold: true, badrpc: true}
  def read(kind \\ :held, extra \\ %{}), do: Map.merge(%{latency_ms: 50, frames: 6, words: kind}, extra)

  def start(opts) do
    state = %{now: 0, terminal_at: Keyword.get(opts, :terminal_at_ms, 60) * 1000, original: Keyword.get(opts, :original, lift_record()),
      original_never: Keyword.get(opts, :original_never, false), original_badrpc: Keyword.get(opts, :original_badrpc, false),
      reads: Keyword.get(opts, :reads, List.duplicate(read(), 6)), issued: [], calls: [], emits: [], violations: [], hook_at: [],
      identity_change_at: Keyword.get(opts, :identity_change_at_ms) && Keyword.get(opts, :identity_change_at_ms) * 1000,
      identity_change: Keyword.get(opts, :identity_change, %{authority_pid: :authority_b}), stop_at: Keyword.get(opts, :stop_at_ms) && Keyword.get(opts, :stop_at_ms) * 1000,
      stop_error_at: Keyword.get(opts, :stop_error_at_ms) && Keyword.get(opts, :stop_error_at_ms) * 1000, stop_error: Keyword.get(opts, :stop_error, {:error, :eio}),
      emit_fail: Keyword.get(opts, :emit_fail, false), disagree: Keyword.get(opts, :disagree, false)}

    {:ok, pid} = Agent.start_link(fn -> state end)
    pid
  end

  def state(pid), do: Agent.get(pid, & &1)
  defp tick(pid, name), do: Agent.update(pid, &%{&1 | now: &1.now + @rpc_us, calls: [{name, &1.now} | &1.calls]})

  def client(pid) do
    %{
      now_us: fn -> Agent.get(pid, & &1.now) end,
      sleep_ms: fn ms -> Agent.update(pid, &%{&1 | now: &1.now + ms * 1000, calls: [{:sleep_ms, &1.now} | &1.calls]}) end,
      inspect: fn ttl -> tick(pid, :inspect); Agent.get_and_update(pid, &issue(&1, ttl)) end,
      command: fn id -> tick(pid, :command); Agent.get_and_update(pid, &blocked_record(&1, id)) end,
      identity: fn -> tick(pid, :identity); Agent.get(pid, &identity/1) end,
      observe: fn orig, insp, _t -> tick(pid, :observe); Agent.get(pid, &observe(&1, orig, insp)) end,
      stop?: fn -> tick(pid, :stop?); stop_answer(Agent.get(pid, & &1)) end,
      emit: fn m -> Agent.get_and_update(pid, fn s -> {if(s.emit_fail, do: {:error, :enospc}, else: :ok), %{s | emits: s.emits ++ [m]}} end) end
    }
  end

  # the stop marker as the caller's check reports it: true (present), false (affirmatively absent) or, from `stop_error_at`, the
  # scripted failure (`stop_error`: an error tuple, :raise for an exception, or any other non-boolean answer)
  defp stop_answer(s) do
    cond do
      s.stop_error_at != nil and s.now >= s.stop_error_at -> if s.stop_error == :raise, do: raise("scripted stop-check exception"), else: s.stop_error
      true -> s.stop_at != nil and s.now >= s.stop_at
    end
  end

  def hook(pid), do: fn -> Agent.update(pid, &%{&1 | hook_at: &1.hook_at ++ [&1.now]}) end

  defp issue(s, ttl) do
    n = length(s.issued)
    spec = Enum.at(s.reads, n) || read()
    pending = Enum.filter(s.issued, &(not &1.withheld and &1.done_at > s.now))
    s = if pending != [] or Enum.any?(s.issued, & &1.withheld), do: %{s | violations: s.violations ++ [{:in_flight_at_issue, n, s.now}]}, else: s

    cond do
      spec[:refuse] -> {{:error, spec.refuse}, s}
      true ->
        id = "insp-#{n}"
        e = %{id: id, n: n, ttl: ttl, at: s.now, done_at: s.now + spec.latency_ms * 1000, withheld: spec[:withhold] == true, spec: spec}
        {{:ok, id}, %{s | issued: s.issued ++ [e]}}
    end
  end

  # a scripted RPC that blocks: the first poll of a read with block_ms advances the virtual clock by that much before answering
  defp blocked_record(s, id) do
    case Enum.find(s.issued, &(&1.id == id and &1.spec[:block_ms] != nil and not Map.get(&1, :blocked, false))) do
      nil -> {record(s, id), s}
      e ->
        s = %{s | now: s.now + e.spec.block_ms * 1000, issued: Enum.map(s.issued, fn x -> if x.id == id, do: Map.put(x, :blocked, true), else: x end)}
        {record(s, id), s}
    end
  end

  defp record(s, "lift-1") do
    cond do
      s.original_badrpc -> {:badrpc, :nodedown}
      s.original_never or s.now < s.terminal_at -> %{s.original | status: :transmitted}
      true -> s.original
    end
  end

  defp record(s, id) do
    case Enum.find(s.issued, &(&1.id == id)) do
      nil -> nil
      %{spec: %{badrpc: true}} -> {:badrpc, :timeout}
      %{withheld: true} = e -> %{id: e.id, name: "relay.inspect.candidate_transform", status: :transmitted, link_generation: 1, stages: [accepted: 0, transmitted: 1], result: nil}
      e when s.now < e.done_at -> %{id: e.id, name: "relay.inspect.candidate_transform", status: :received, link_generation: 1, stages: [accepted: 0, transmitted: 1, received: 2], result: nil}
      e -> inspection_record(e)
    end
  end

  defp inspection_record(e) do
    sp = e.spec
    {w, l, extra} =
      case sp.words do
        :held -> {@req_w, @post_l, %{}}
        :returned -> {@pre_w, @pre_l, %{}}
        :drifted -> {@drift_w, @post_l, %{}}
        :near -> {@near_w, @post_l, %{}}
        :dirty -> {@req_w, @post_l, %{"cand_dirty" => o(true)}}
        :unavailable -> {nil, nil, %{"cand_world_words" => %{"status" => "unavailable", "reason" => "scripted"}, "cand_local_words" => %{"status" => "unavailable", "reason" => "scripted"}}}
        :malformed -> {"zz", @post_l, %{}}
      end

    obs = inspection_obs(w, l, extra) |> Map.merge(sp[:obs] || %{})
    frame = @lift_frame + sp.frames
    {:ok, base, _} = DateTime.from_iso8601(@lift_native)
    native = DateTime.add(base, round(sp.frames * 10.7), :millisecond) |> DateTime.to_iso8601()
    status = sp[:status] || :applied

    %{id: e.id, name: "relay.inspect.candidate_transform", status: status, link_generation: sp[:link_generation] || 1,
      stages: [accepted: 0, transmitted: 1, received: 2, applied: sp.latency_ms],
      result: %{status: status, reason: nil, frame: frame, native_at: native, mission_generation: sp[:generation] || @gen,
        adapter_instance_id: sp[:adapter] || @adapter, observed: obs}}
  end

  defp identity(s) do
    if s.identity_change_at != nil and s.now >= s.identity_change_at, do: Map.merge(baseline_identity(), s.identity_change), else: baseline_identity()
  end

  # the authority's conclusion, computed with the same committed code (so agreement is expected; `disagree` scripts a mismatch)
  defp observe(s, "lift-1", insp) do
    e = Enum.find(s.issued, &(&1.id == insp))
    rec = inspection_record(e)
    d = GlacierRelay.Command.TransformReadback.decode_inspection(rec.result.observed)
    {:ok, pre} = GlacierRelay.Command.TransformWords.decode_world(@pre_w)
    {:ok, req} = GlacierRelay.Command.TransformWords.decode_world(@req_w)

    c =
      cond do
        rec.result.frame <= @lift_frame -> "not_a_later_frame"
        true -> to_string(GlacierRelay.Command.TransformReadback.classify_later(d.candidate, pre, req))
      end

    # the real Authority's reply shape: the observation as journaled, without a journal sequence number
    {:ok, %{"conclusion" => if(s.disagree, do: "held", else: c), "inspection_command_id" => insp}}
  end
end

defmodule M6fFollowTest do
  use ExUnit.Case, async: false

  @effectful ~r/\b(lift_candidate|restore_candidate|arm_effectful|set_outfit|plan_transform_restore|plan_reversal|attest_telemetry|disarm)\b|:arm\b|(?<!Enum\.)\breverse\(|GlacierRelay\.Command\.(?!TransformReadback)/

  defp run_case(opts, plan_opts \\ []) do
    pid = FakeRelay.start(opts)
    {:ok, plan} = M6fFollow.plan(plan_opts)
    ctx = %{original_id: "lift-1", expected_generation: FakeRelay.gen(), link_generation: 1, adapter_instance_id: FakeRelay.adapter(),
      baseline_identity: FakeRelay.baseline_identity(), binding_observed: FakeRelay.binding_obs(), after_first_request: FakeRelay.hook(pid)}
    r = M6fFollow.run(FakeRelay.client(pid), plan, ctx)
    s = FakeRelay.state(pid)
    assert s.violations == [], "the fake saw a request while another was in flight: #{inspect(s.violations)}"
    assert length(s.issued) <= 6
    # the invariant of every sequence (item A): each read's dispatch is IMMEDIATELY preceded by an operator-stop check that said
    # "no stop" — no other client call, no sleep, between them
    order = s.calls |> Enum.reverse()
    for {{:inspect, t}, k} <- Enum.with_index(order), do: assert(match?({:stop?, _}, Enum.at(order, k - 1)) and k > 0, "the dispatch at #{t} us was not immediately preceded by a stop check: #{inspect(Enum.slice(order, max(k - 3, 0), 4))}")
    {r, s}
  end

  defp classes(r), do: Enum.map(r.slots, & &1.class)
  defp outcomes(r), do: Enum.map(r.slots, & &1.outcome)

  test "the engine source names no effectful API (static)" do
    src = File.read!(Path.join(__DIR__, "../m6f_follow.exs"))
    code = src |> String.split("\n") |> Enum.reject(&String.match?(&1, ~r/^\s*#/)) |> Enum.join("\n")
    assert Regex.scan(@effectful, code) == []
    # positive controls: the pattern does detect each effectful form (the check is not vacuous)
    for probe <- ["Command.lift_candidate(p, o)", "call.(cmd, :restore_candidate, [])", "arm_effectful(x)", ":arm", "reverse(id, o)", "GlacierRelay.Command.status()", "set_outfit(p)"] do
      assert Regex.match?(@effectful, probe), probe
    end
    refute Regex.match?(@effectful, "Enum.reverse(acc)")
  end

  test "held at every slot: six on-time requests, the first right after the observed terminal" do
    {r, s} = run_case([])
    assert r.stop == nil and r.requests == 6 and r.missed == 0
    assert classes(r) == List.duplicate("held", 6)
    assert Enum.all?(r.slots, &(&1.timing == "on_time" and &1.conclusion_agrees == true and &1.later_frame == true))
    [s0 | _] = r.slots
    # on the virtual clock exactly ONE call happens between the observed terminal and the immediate first request: the operator's
    # stop check (one scripted RPC cost, 0.3 ms); no identity check, no sleep, no write
    assert s0.request_ms == 0.3
    order = s.calls |> Enum.reverse() |> Enum.map(&elem(&1, 0))
    i = Enum.find_index(order, &(&1 == :inspect))
    assert Enum.slice(order, i - 2, 3) == [:command, :stop?, :inspect], "the calls before the first request: #{inspect(Enum.slice(order, max(i - 3, 0), 4))}"
    assert Enum.map(r.slots, & &1.planned_ms) == [0, 250, 1000, 2000, 5000, 10000]
    # requests never before their deadline
    assert Enum.all?(r.slots, &(&1.lateness_ms >= 0))
    # the deferred caller work ran once, after the first request was issued
    first_inspect = s.calls |> Enum.reverse() |> Enum.find_value(fn {:inspect, t} -> t; _ -> nil end)
    assert [h] = s.hook_at
    assert h > first_inspect
    assert Enum.map(s.emits, & &1["event"]) == ["follow.original"] ++ List.duplicate("follow.slot", 6) ++ ["follow.end"]
  end

  test "returned before the first later sample" do
    {r, _} = run_case(reads: List.duplicate(FakeRelay.read(:returned), 6))
    assert r.stop == nil and classes(r) == List.duplicate("returned_to_baseline", 6)
    assert hd(r.slots).local_vs_preimage == "bit-equal"
  end

  test "a return between sampled observations (scripted; the frozen probe cannot model it)" do
    reads = List.duplicate(FakeRelay.read(:held), 3) ++ List.duplicate(FakeRelay.read(:returned), 3)
    {r, _} = run_case(reads: reads)
    assert classes(r) == ~w(held held held returned_to_baseline returned_to_baseline returned_to_baseline)
    assert r.stop == nil
  end

  test "drifted, near, dirty and unavailable keep their committed meanings and do not stop the schedule" do
    for {kind, want} <- [drifted: "drifted", near: "near_target", dirty: "indeterminate", unavailable: "unavailable"] do
      {r, _} = run_case(reads: List.duplicate(FakeRelay.read(kind), 6))
      assert r.stop == nil, "#{kind}: #{inspect(r.stop)}"
      assert classes(r) == List.duplicate(want, 6), "#{kind}: #{inspect(classes(r))}"
    end
  end

  test "a failed, refused, expired or unknown original is not followed: no read, no retry" do
    for st <- [:failed, :precondition_failed, :unavailable, :expired, :unknown] do
      {r, s} = run_case(original: FakeRelay.lift_record(st))
      assert s.issued == [], "#{st}: a read was issued"
      assert match?({:original_not_applied, ^st, _}, r.stop)
      assert r.requests == 0 and Enum.all?(r.slots, &(&1.outcome == "not_reached"))
      assert length(s.hook_at) == 1
    end
  end

  test "an original that never reaches a terminal is waited for within its bound, then not followed" do
    {r, s} = run_case(original_never: true)
    assert r.stop == :original_terminal_timeout and s.issued == []
    assert s.now <= 20_100_000
  end

  test "an RPC failure while waiting for the original stops before any read" do
    {r, s} = run_case(original_badrpc: true)
    assert match?({:rpc_failed, _}, r.stop) and s.issued == []
  end

  test "slow results: missed slots are recorded, never substituted; no catch-up burst" do
    {r, s} = run_case(reads: List.duplicate(FakeRelay.read(:held, %{latency_ms: 1300}), 6))
    assert outcomes(r) == ~w(requested missed missed requested requested requested)
    assert r.missed == 2 and r.requests == 4 and r.stop == nil
    # requests at (about) 0, 2000, 5000 and 10000 ms after the observed terminal — each at its own deadline, none back to back
    req = Enum.filter(r.slots, &(&1.outcome == "requested"))
    assert Enum.map(req, & &1.planned_ms) == [0, 2000, 5000, 10000]
    assert Enum.all?(req, &(&1.request_ms >= &1.planned_ms and &1.request_ms <= &1.planned_ms + 25))
    assert length(s.issued) == 4
    assert Enum.filter(r.slots, &(&1.outcome == "missed")) |> Enum.all?(&(&1[:inspection_id] == nil))
  end

  test "a result that arrives after the next deadline makes that slot delayed (inside its window) and marks it so" do
    {r, _} = run_case(reads: [FakeRelay.read(:held, %{latency_ms: 300})] ++ List.duplicate(FakeRelay.read(:held), 5))
    [s0, s1 | _] = r.slots
    assert s1.outcome == "requested" and s1.timing == "delayed" and s1.lateness_ms > 25 and s1.lateness_ms <= s1.window_ms
    assert s1.request_ms >= s0.result_ms
  end

  test "a withheld result stops the sequence after the request timeout; nothing follows it" do
    reads = [FakeRelay.read(), FakeRelay.read(), FakeRelay.read(:held, %{withhold: true})] ++ List.duplicate(FakeRelay.read(), 3)
    {r, s} = run_case(reads: reads)
    assert r.stop == :result_withheld and length(s.issued) == 3
    assert outcomes(r) == ~w(requested requested requested not_reached not_reached not_reached)
  end

  test "a refused request (the link is gone) stops the sequence" do
    reads = List.duplicate(FakeRelay.read(), 3) ++ [FakeRelay.read(:held, %{refuse: :no_link})] ++ List.duplicate(FakeRelay.read(), 2)
    {r, _} = run_case(reads: reads)
    assert r.stop == {:request_refused, :no_link}
    assert outcomes(r) == ~w(requested requested requested refused not_reached not_reached)
  end

  test "a read that is not applied (link lost: unknown; expired) stops the sequence" do
    for st <- [:unknown, :expired, :precondition_failed] do
      {r, _} = run_case(reads: [FakeRelay.read(), FakeRelay.read(:held, %{status: st})] ++ List.duplicate(FakeRelay.read(), 4))
      assert r.stop == {:inspection_not_applied, st}
      assert Enum.count(r.slots, &(&1.outcome == "not_reached")) == 4
    end
  end

  test "an authority restart between slots (identity changed) stops before the next request" do
    {r, s} = run_case(identity_change_at_ms: 1500)
    assert r.stop == {:identity_changed, [:authority_pid]}
    assert length(s.issued) == 3 and outcomes(r) == ~w(requested requested requested not_reached not_reached not_reached)
  end

  test "a degraded audit or a changed link / journal stops the sequence" do
    {r, _} = run_case(identity_change_at_ms: 600, identity_change: %{audit: {:gap, [:applied]}})
    assert r.stop == :audit_degraded
    {r, _} = run_case(identity_change_at_ms: 600, identity_change: %{link_generation: 2})
    assert r.stop == {:identity_changed, [:link_generation]}
    {r, _} = run_case(identity_change_at_ms: 600, identity_change: %{journal_status: :closed})
    assert r.stop == {:identity_state, [:journal_open]}
  end

  test "the operator's stop marker ends the sequence before the next request" do
    {r, s} = run_case(stop_at_ms: 700)
    assert r.stop == :operator_stop and length(s.issued) == 2
    {r, s} = run_case(stop_at_ms: 0)
    assert r.stop == :operator_stop and s.issued == [] and r.original.status == "applied"
  end

  test "a changed link, adapter or generation context in a result stops the sequence" do
    for {k, v, want} <- [{:link_generation, 2, :link_generation}, {:adapter, "00000000-0000-4000-8000-000000000002", :adapter_instance_id}, {:generation, "synthetic-generation-2", :mission_generation}] do
      {r, _} = run_case(reads: [FakeRelay.read(), FakeRelay.read(:held, %{k => v})] ++ List.duplicate(FakeRelay.read(), 4))
      assert r.stop == {:context_changed, want}
    end
  end

  test "an aliased candidate, a changed identity block, a registry slot or a reduced / malformed result stops the sequence" do
    o = fn v -> %{"status" => "observed", "value" => v} end
    cases = [
      {%{obs: %{"cand_distinct" => o.(false)}}, :candidate_aliasing},
      {%{obs: %{"cand_spatial_distinct" => o.(false)}}, :candidate_aliasing},
      {%{obs: %{"cand_brick_owner" => o.("0000000000000001")}}, {:identity_invalid, ["cand_brick_owner"]}},
      {%{obs: %{"cand_in_registry" => o.(true)}}, {:identity_invalid, [:cand_in_registry]}},
      {%{obs: %{"observed_reduced" => true}}, :result_reduced},
      {%{obs: %{"reads_on_frame" => o.(false)}}, :reads_not_on_one_frame},
      {%{obs: %{"cand_distinct" => %{"status" => "unavailable", "reason" => "scripted"}}}, {:qualification_unobserved, [:cand_distinct]}},
      {%{obs: %{"reads_on_frame" => %{"status" => "unavailable"}}}, {:qualification_unobserved, [:reads_on_frame]}},
      {%{words: :malformed}, :result_malformed}
    ]

    for {extra, want} <- cases do
      {r, _} = run_case(reads: [FakeRelay.read(), FakeRelay.read(:held, extra)] ++ List.duplicate(FakeRelay.read(), 4))
      assert r.stop == want, "#{inspect(extra)}: #{inspect(r.stop)}"
      assert Enum.at(r.slots, 1).class == nil
    end
  end

  test "a stop marker written during a long wait for the lift's terminal prevents every read" do
    {r, s} = run_case(terminal_at_ms: 1000, stop_at_ms: 400)
    assert r.stop == :operator_stop and s.issued == [] and r.original.status == "applied"
    # it was looked at during the wait (after 250 ms), not only when the wait began
    assert Enum.count(s.calls, &(elem(&1, 0) == :stop?)) >= 2
  end

  test "item A: a stop written during the final part of a SHORT terminal wait (after its only check) prevents the immediate read" do
    # the wait's own checks run at its start and every 250 ms; a stop at 30 ms with the terminal at 60 ms is seen by none of them —
    # the check immediately before the first dispatch sees it (M6-F2a's documented residual let this one read out)
    {r, s} = run_case(terminal_at_ms: 60, stop_at_ms: 30)
    assert r.stop == :operator_stop and s.issued == [] and r.requests == 0 and r.original.status == "applied"
    assert Enum.all?(r.slots, &(&1.outcome == "not_reached"))
  end

  test "item A: a stop written during the final part of a LONG terminal wait (after its last 250 ms check) prevents every read" do
    # checks at 0, 250, 500 and 750 ms; the stop at 990 ms; the terminal observed at about 1000 ms
    {r, s} = run_case(terminal_at_ms: 1000, stop_at_ms: 990)
    assert r.stop == :operator_stop and s.issued == []
  end

  test "item A: a stop that becomes visible exactly at the terminal / first-request boundary prevents the immediate read" do
    # the marker appears at the very instant the terminal is observed: no wait check can see it; the pre-dispatch check does
    {r, s} = run_case(terminal_at_ms: 60, stop_at_ms: 60)
    assert r.stop == :operator_stop and s.issued == []
    order = s.calls |> Enum.reverse() |> Enum.map(&elem(&1, 0))
    assert List.last(Enum.take_while(order, &(&1 != :emit))) != :inspect
    assert Enum.count(order, &(&1 == :stop?)) >= 2, "the pre-dispatch check ran after the wait's start check"
  end

  test "item A: a stop before a later slot — also one visible only after that slot's last sleep — prevents that slot's read" do
    # slot 2's deadline is 1000 ms after the observed terminal (about 60.6 ms); the marker appears 0.5 ms before that dispatch,
    # after the slot's identity check and its last sleep chunk
    {r, s} = run_case(stop_at_ms: 1060)
    assert r.stop == :operator_stop and length(s.issued) == 2
    assert outcomes(r) == ~w(requested requested not_reached not_reached not_reached not_reached)
  end

  test "item A: a stop while a read is in flight: that read's result is still awaited, recorded and journaled; nothing follows" do
    # slot 1 is dispatched at about 310 ms (250 ms after the terminal) and answered 50 ms later; the stop appears at 320 ms
    {r, s} = run_case(stop_at_ms: 320)
    assert r.stop == :operator_stop and length(s.issued) == 2
    s1 = Enum.at(r.slots, 1)
    assert s1.outcome == "requested" and s1.class == "held" and s1.conclusion_agrees == true
    assert Enum.count(s.calls, &(elem(&1, 0) == :observe)) == 2
    assert Enum.drop(outcomes(r), 2) |> Enum.all?(&(&1 == "not_reached"))
  end

  test "item A: a FAILED stop check is a stop, never 'no stop' — at the wait's start, at the boundary and before a later slot" do
    # an error tuple at the very start: nothing is read, the reason is kept
    {r, s} = run_case(stop_error_at_ms: 0)
    assert match?({:stop_check_failed, _}, r.stop) and s.issued == []
    # an exception from the check, first seen at the terminal / first-request boundary
    {r, s} = run_case(terminal_at_ms: 60, stop_error_at_ms: 60, stop_error: :raise)
    assert match?({:stop_check_failed, _}, r.stop) and s.issued == []
    # a non-boolean answer (nil: no evidence either way) before slot 2
    {r, s} = run_case(stop_error_at_ms: 1060, stop_error: nil)
    assert match?({:stop_check_failed, _}, r.stop) and length(s.issued) == 2
  end

  test "a later first slot (no immediate read) makes the identity and stop checks before its request" do
    {r, s} = run_case([identity_change_at_ms: 200], schedule_ms: [500, 1000])
    assert r.stop == {:identity_changed, [:authority_pid]} and s.issued == []
  end

  test "a result whose poll blocked past the request bound is recorded as a late receipt and ends the sequence" do
    {r, s} = run_case(reads: [FakeRelay.read(), FakeRelay.read(:held, %{block_ms: 3000})] ++ List.duplicate(FakeRelay.read(), 4))
    assert match?({:result_late, _}, r.stop)
    s1 = Enum.at(r.slots, 1)
    assert s1.late_receipt == true and s1.class == "held" and length(s.issued) == 2
    assert Enum.count(r.slots, &(&1.outcome == "not_reached")) == 4
  end

  test "a same-frame read is marked not_a_later_frame and is not retried" do
    {r, s} = run_case(reads: [FakeRelay.read(:held, %{frames: 0})] ++ List.duplicate(FakeRelay.read(), 5))
    assert hd(r.slots).class == "not_a_later_frame" and hd(r.slots).later_frame == false
    assert r.stop == nil and length(s.issued) == 6
  end

  test "an RPC failure on a result poll stops the sequence" do
    {r, _} = run_case(reads: [FakeRelay.read(), FakeRelay.read(:held, %{badrpc: true})] ++ List.duplicate(FakeRelay.read(), 4))
    assert match?({:rpc_failed, _}, r.stop)
  end

  test "a disagreement between the local class and the journaled conclusion is reported, not hidden" do
    {r, _} = run_case(reads: List.duplicate(FakeRelay.read(:returned), 6), disagree: true)
    assert Enum.all?(r.slots, &(&1.conclusion_agrees == false))
  end

  test "an evidence-line write failure is recorded and does not alter the schedule" do
    {r, _} = run_case(emit_fail: true)
    assert r.stop == nil and r.requests == 6 and length(r.emit_errors) > 0
  end

  test "the per-request bound holds even when a result never comes (a one-slot plan)" do
    {r, s} = run_case([reads: [FakeRelay.read(:held, %{latency_ms: 5000})]], schedule_ms: [0], request_timeout_ms: 100)
    assert r.stop == :result_withheld
    assert s.now - s.terminal_at <= 115_000
  end

  test "the plan is validated before anything is issued" do
    assert {:error, {:schedule_longer_than, 6}} = M6fFollow.plan(schedule_ms: [0, 1, 2, 3, 4, 5, 6])
    assert {:error, :schedule_not_strictly_increasing} = M6fFollow.plan(schedule_ms: [0, 250, 250])
    assert {:error, :schedule_values_out_of_range} = M6fFollow.plan(schedule_ms: [-1, 250])
    assert {:error, :schedule_empty} = M6fFollow.plan(schedule_ms: [])
    assert {:error, {:unknown_options, [:retries]}} = M6fFollow.plan(retries: 3)
    assert {:error, :inspection_ttl_out_of_range} = M6fFollow.plan(inspection_ttl_ms: 50)
    assert {:error, :request_timeout_out_of_range} = M6fFollow.plan(request_timeout_ms: 60_000)
    assert {:ok, p} = M6fFollow.plan()
    assert p.windows_ms == [125, 250, 250, 250, 250, 250] and p.overall_deadline_ms == 12_250
  end
end

result = ExUnit.run()
System.halt(if result.failures == 0, do: 0, else: 1)

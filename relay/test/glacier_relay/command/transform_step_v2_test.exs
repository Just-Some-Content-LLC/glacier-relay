defmodule GlacierRelay.Command.TransformStepV2Test do
  @moduledoc """
  M6-G1: `candidate.transform.set` v2 (`step_y` | `restore`) against the fake native peer, beside an
  unchanged v1 (`lift` | `restore`): the `{name, version}` capability identity (a v1-only peer, the
  effectful setting off and a transport-v1 peer never enable v2), the step's canonical parameters
  bound to one exact inspection, the ONE forward budget shared by the lift and the step in both
  orders (a verified refusal leaves it; an in-flight or unknown forward consumes it; fresh ids,
  re-arming, reconnects and restorations never refill it), the journal-derived restoration issued
  at the plan's version (v2 for a step, v1 for a lift), and the refusals of forged, version-
  substituted or altered restorations inside the authority. Every assertion the fake peer makes is
  fake-native evidence; nothing here touches Glacier.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command

  alias GlacierRelay.Command.{
    Authority,
    Journal,
    Listener,
    Schema,
    TransformBinding,
    TransformRestore,
    TransformWords
  }

  alias GlacierRelay.Test.{FakeNative, FixturePlayer}

  @token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @gen "2516099488895124066-977411ea-01df-435f-b375-efa4cf625963"
  @brick "007c57a6ea581f8c"
  @entity "feede715906f747f"
  # M6-E3's r3 words: the candidate at P (identity axes) and its signed-zero parent-relative quaternion
  @pre "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2b2fae1,416d47ae,bfc2d6ba"
  @step "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2b2fae1,417147ae,bfc2d6ba"
  @lifted "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2b2fae1,416d47ae,bfa2d6ba"
  # one bit away from @pre's y: the same seven-digit display, different words
  @twin "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2b2fae1,416d47af,bfc2d6ba"
  @local "c2b2fae1,416d47ae,bfc2d6ba,80000000,00000000,80000000,3f800000"
  @hero_world "3e2b7674,bf7c62bd,00000000,3f7c62bd,3e2b7674,00000000,00000000,00000000,3f800000,c2a77ccf,416b27e8,bfc2d6ba"
  @hero_local "c2a77ccf,416b27e8,bfc2d6ba,80000000,00000000,3f252b92,3f43969f"
  @expect %{"expect_world" => @pre, "expect_local" => @local, "expect_parent" => @brick}
  @caps_both [
    "relay.probe/1",
    "relay.inspect.candidate_transform/1",
    "candidate.transform.set/1",
    "candidate.transform.set/2"
  ]
  @caps_v1 ["relay.probe/1", "relay.inspect.candidate_transform/1", "candidate.transform.set/1"]

  setup context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-step-v2-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)

    start_supervised!(
      {Command.Supervisor,
       port: 0,
       journal_dir: dir,
       ack_timeout_ms: 300,
       grace_ms: 200,
       default_ttl_ms: 500,
       min_ttl_ms: 50,
       hello_timeout_ms: 400,
       effectful: Map.get(context, :effectful, true),
       token: @token,
       effectful_ttl_max_ms: 120_000,
       evidence_max_age_ms: 120_000,
       reversal_inspection_max_age_ms: Map.get(context, :max_age_ms, 60_000)}
    )

    %{port: Listener.port(), dir: dir}
  end

  defp wait(fun), do: FixturePlayer.wait_until(fun, 100, 10)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp field(status, value), do: FakeNative.field(status, value)
  defp budget, do: Command.status().effectful.transform_lift_budget
  defp consumer, do: Command.status().effectful.transform_lift_consumer

  defp journal_entries do
    %{path: path} = Journal.status()
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp ownership,
    do: %{
      "collected_at" => now(),
      "owner_pid" => 46604,
      "executable" => "HITMAN3.exe",
      "local_port" => 51234,
      "remote_port" => 4749,
      "connections" => 1,
      "validation" => "exactly_one_hitman",
      "source" => "Get-NetTCPConnection -RemotePort 4749 -State Established",
      "max_age_ms" => 60_000
    }

  defp v2_peer(port, opts \\ []) do
    {socket, adapter, welcome} =
      FakeNative.handshake_v2(port, @token, Keyword.merge([capabilities: @caps_both], opts))

    assert wait(fn -> Command.status().trust.token_verified end)
    {socket, adapter, welcome}
  end

  defp arm_eff(adapter) do
    assert :ok =
             Command.attest_telemetry(%{
               "adapter_instance_id" => adapter,
               "observed_at" => now(),
               "basis" => "MissionSession.state/0 over RPC (operator tooling)",
               "evidence_ref" => "r2-check.txt",
               "max_age_ms" => 60_000
             })

    assert :ok = Command.arm_effectful(ownership: ownership())
  end

  defp qualifying(world, overrides) do
    Map.merge(
      %{
        "generation_fresh" => field("observed", @gen),
        "targets" => field("observed", "#{@brick},#{@entity}"),
        "snapshot_version" => field("observed", 1),
        "cand_brick_present" => field("observed", true),
        "cand_index_check" => field("observed", "in_range"),
        "cand_resolved" => field("observed", true),
        "cand_hitman5" => field("observed", true),
        "cand_id_match" => field("observed", true),
        "cand_distinct" => field("observed", true),
        "cand_brick_owner" => field("observed", @brick),
        "cand_spatial" => field("observed", true),
        "cand_spatial_distinct" => field("observed", true),
        "registry_slots" => field("observed", "0:local,1:empty,2:empty,3:empty"),
        "cand_in_registry" => field("observed", false),
        "cand_world_words" => field("observed", world),
        "cand_local_words" => field("observed", @local),
        "cand_dirty" => field("observed", false),
        "cand_parent" => field("observed", @brick),
        "cand_world" =>
          field(
            "observed",
            TransformWords.translation_text(elem(TransformWords.decode_world(world), 1))
          ),
        "hero_entity_id" => field("observed", "69bdf7f855ea15e0"),
        "hero_world_words" => field("observed", @hero_world),
        "hero_local_words" => field("observed", @hero_local),
        "hero_dirty" => field("observed", false),
        "hero_parent" => field("observed", "00b6cedd6778f19c"),
        "reads_on_frame" => field("observed", true)
      },
      overrides
    )
  end

  defp inspect_exact(socket, adapter, world, frame, opts \\ []) do
    :ok = if Command.status().trust.armed, do: :ok, else: Command.arm()
    {:ok, id} = Command.inspect_candidate_transform()
    {:ok, icmd} = FakeNative.recv(socket)
    assert icmd["name"] == "relay.inspect.candidate_transform"

    FakeNative.respond(socket, icmd, adapter, "applied", %{
      "observed" => qualifying(world, Keyword.get(opts, :overrides, %{})),
      "frame" => frame,
      "mission_generation" => Keyword.get(opts, :generation, @gen)
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    id
  end

  defp apply_observed(mode, pre, requested, post) do
    %{
      "mode" => field("observed", mode),
      "generation_fresh" => field("observed", @gen),
      "generation_post" => field("observed", @gen),
      "preimage_world_words" => field("observed", pre),
      "preimage_local_words" => field("observed", @local),
      "preimage_parent" => field("observed", @brick),
      "preimage_dirty" => field("observed", false),
      "requested_world_words" => field("observed", requested),
      "postimage_world_words" => field("observed", post),
      "postimage_local_words" => field("observed", @local),
      "postimage_parent" => field("observed", @brick),
      "postimage_dirty" => field("observed", false),
      "post_same_entity" => field("observed", true),
      "world_match" => field("observed", if(post == requested, do: "target", else: "preimage")),
      "local_match" => field("observed", "unchanged"),
      "hero_control" => field("observed", "unchanged"),
      "setter_called" => field("observed", true),
      "apply_log" => field("observed", "written"),
      "invocation" => field("observed", "called"),
      "effect" => field("observed", if(post == requested, do: "changed", else: "unchanged")),
      "precondition_ok" => field("observed", true),
      "budget_remaining" => field("observed", 0)
    }
  end

  defp step(params, opts),
    do: Command.step_candidate(params, Keyword.merge([expected_generation: @gen], opts))

  defp lift(params, opts),
    do: Command.lift_candidate(params, Keyword.merge([expected_generation: @gen], opts))

  # The reply of `fun` and whatever the fake peer received in a short window afterwards.
  defp attempt(socket, fun) do
    reply = fun.()

    transmitted =
      case FakeNative.recv(socket, 150) do
        {:ok, line} -> Map.take(line, ["name", "version", "command_id", "params"])
        {:error, :timeout} -> nil
      end

    %{reply: reply, transmitted: transmitted}
  end

  # A forward carried to applied/changed; returns its id.
  defp applied_forward(socket, adapter, insp, :step) do
    assert {:ok, id} = step(@expect, inspection_command_id: insp)
    assert {:ok, cmd} = FakeNative.recv(socket)
    assert cmd["name"] == "candidate.transform.set" and cmd["version"] == 2
    assert cmd["params"] == Map.put(@expect, "mode", "step_y")

    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" => apply_observed("step_y", @pre, @step, @step),
      "frame" => 20_000,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    id
  end

  defp applied_forward(socket, adapter, insp, :lift) do
    assert {:ok, id} = lift(@expect, inspection_command_id: insp)
    assert {:ok, cmd} = FakeNative.recv(socket)
    assert cmd["name"] == "candidate.transform.set" and cmd["version"] == 1

    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" => apply_observed("lift", @pre, @lifted, @lifted),
      "frame" => 20_000,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    id
  end

  defp restore_params(original, post),
    do: %{
      "mode" => "restore",
      "expect_world" => post,
      "expect_local" => @local,
      "expect_parent" => @brick,
      "target_world" => @pre,
      "restore_of" => original
    }

  # The authority's own binding context, rebuilt from its journal and state exactly as its
  # `binding_context/2` builds it, so that `TransformBinding.restore/5` can be called directly:
  # through the authority, its record check refuses a substituted version before the binding's
  # own journal-plan check is reached.
  defp binding_ctx do
    js = Journal.status()
    {:ok, read} = Journal.read(js.path)
    st = :sys.get_state(Authority)

    %{
      journal: read,
      now_mono_ms: js.elapsed_ms,
      max_age_ms: st.config[:reversal_inspection_max_age_ms],
      link: %{
        generation: st.link.generation,
        adapter_instance_id: st.link.adapter_instance_id,
        token_verified: st.link.token_verified
      },
      mission_generation: @gen,
      records: st.commands
    }
  end

  defp direct_restore(version, original, post, opts),
    do:
      Authority.issue(
        "candidate.transform.set",
        version,
        Keyword.get(opts, :params, restore_params(original, post)),
        opts
        |> Keyword.drop([:params])
        |> Keyword.put_new(:reversal_of, original)
        |> Keyword.put_new(:preconditions, %{"mission_generation" => @gen})
      )

  test "the schema: v2 is its own {name, version} entry (step_y | restore); issuable only to a version-2 peer that advertised it with the effectful setting on; v1 unchanged" do
    v2 = Schema.entry("candidate.transform.set", 2)

    assert %{issuable: :effectful, trust: :token_verified, effect: :transform, version: 2} = v2

    assert %{params: %{"mode" => {:enum, ["lift", "restore"]}}} =
             Schema.entry("candidate.transform.set", 1)

    assert %{params: %{"mode" => {:enum, ["step_y", "restore"]}}} = v2
    assert Schema.entry("candidate.transform.set", 3) == nil

    v2_ref = %{"name" => "candidate.transform.set", "version" => 2}
    v1_ref = %{"name" => "candidate.transform.set", "version" => 1}

    assert v2_ref in Schema.issuable_for(2, @caps_both, true) and
             v1_ref in Schema.issuable_for(2, @caps_both, true)

    refute v2_ref in Schema.issuable_for(2, @caps_v1, true)
    assert v1_ref in Schema.issuable_for(2, @caps_v1, true)

    refute v2_ref in Schema.issuable_for(2, @caps_both, false) or
             v1_ref in Schema.issuable_for(2, @caps_both, false)

    refute v2_ref in Schema.issuable_for(1, @caps_both, true) or
             v1_ref in Schema.issuable_for(1, @caps_both, true)

    refute Enum.any?(Schema.issuable(), &(&1["name"] == "candidate.transform.set"))

    assert {:ok, _} = Schema.validate_params(v2, Map.put(@expect, "mode", "step_y"))

    assert {:error, {:invalid_param, "mode", {:not_one_of, ["step_y", "restore"]}}} =
             Schema.validate_params(v2, Map.put(@expect, "mode", "lift"))

    assert {:error, {:invalid_param, "mode", {:not_one_of, ["lift", "restore"]}}} =
             Schema.validate_params(
               Schema.entry("candidate.transform.set", 1),
               Map.put(@expect, "mode", "step_y")
             )

    assert {:error, {:unknown_params, ["axis"]}} =
             Schema.validate_params(v2, Map.merge(@expect, %{"mode" => "step_y", "axis" => "x"}))

    assert {:error, {:unknown_params, ["distance"]}} =
             Schema.validate_params(
               v2,
               Map.merge(@expect, %{"mode" => "step_y", "distance" => "1"})
             )
  end

  test "the replicated step target: only word 10 (Trans.y) changes, y + 0.25 in binary32; the forward target of each pair" do
    {:ok, pre} = TransformWords.decode_world(@pre)
    target = TransformWords.step_y_target(pre)
    assert TransformWords.encode(target) == @step
    assert Enum.at(target, 10) == 0x417147AE and Enum.at(pre, 10) == 0x416D47AE

    for i <- Enum.to_list(0..11) -- [10], do: assert(Enum.at(target, i) == Enum.at(pre, i))

    assert TransformWords.forward_target(2, "step_y", pre) == target
    assert TransformWords.encode(TransformWords.forward_target(1, "lift", pre)) == @lifted
    assert TransformWords.forward_target(1, "step_y", pre) == nil
    assert TransformWords.forward_target(2, "lift", pre) == nil
    assert TransformWords.step_y() == 0.25
  end

  test "a peer that advertised only v1 never enables v2: the step is refused before transmission; the v1 lift path is unchanged",
       %{port: port} do
    {socket, adapter, welcome} = v2_peer(port, capabilities: @caps_v1)
    refute %{"name" => "candidate.transform.set", "version" => 2} in welcome["allowlist"]
    assert %{"name" => "candidate.transform.set", "version" => 1} in welcome["allowlist"]
    insp = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)

    assert %{reply: {:error, :entry_not_advertised_to_peer}, transmitted: nil} =
             attempt(socket, fn -> step(@expect, inspection_command_id: insp) end)

    assert Command.status().trust.effectful_armed and budget() == 1
    FakeNative.close(socket)
  end

  @tag effectful: false
  test "with the effectful setting off both versions are refused and neither is in the welcome",
       %{
         port: port
       } do
    {socket, adapter, welcome} = v2_peer(port)
    refute Enum.any?(welcome["allowlist"], &(&1["name"] == "candidate.transform.set"))
    insp = inspect_exact(socket, adapter, @pre, 19_000)

    assert %{reply: {:error, :effectful_disabled}, transmitted: nil} =
             attempt(socket, fn -> step(@expect, inspection_command_id: insp) end)

    assert %{reply: {:error, :effectful_disabled}, transmitted: nil} =
             attempt(socket, fn -> lift(@expect, inspection_command_id: insp) end)

    FakeNative.close(socket)
  end

  test "a transport-v1 peer stays inert-only: the step is refused", %{port: port} do
    {socket, _adapter, welcome} =
      FakeNative.handshake(port, Schema.uuid4(), capabilities: @caps_both)

    assert wait(fn -> Command.status().trust.peer == :identified end)
    refute Enum.any?(welcome["allowlist"], &(&1["name"] == "candidate.transform.set"))

    assert %{reply: {:error, reason}, transmitted: nil} =
             attempt(socket, fn -> step(@expect, inspection_command_id: Schema.uuid4()) end)

    assert reason == :peer_protocol_version_1
    FakeNative.close(socket)
  end

  test "the step: canonical parameters from ONE exact inspection, transmitted as v2 step_y with no target; the shared budget consumed; a later lift and a later step refused under fresh arming",
       %{port: port} do
    {socket, adapter, welcome} = v2_peer(port)
    assert %{"name" => "candidate.transform.set", "version" => 2} in welcome["allowlist"]
    insp = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)

    # local refusals before transmission (no target, no restore binding, no caller binding)
    assert %{reply: {:error, :step_carries_no_target}, transmitted: nil} =
             attempt(socket, fn ->
               step(Map.put(@expect, "target_world", @step), inspection_command_id: insp)
             end)

    assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
             attempt(socket, fn ->
               step(@expect, inspection_command_id: insp, reversal_inspection: %{"frame" => 1})
             end)

    assert Command.status().trust.effectful_armed and budget() == 1

    id = applied_forward(socket, adapter, insp, :step)
    assert budget() == 0 and consumer() == id

    accepted =
      Enum.find(
        journal_entries(),
        &(&1["event"] == "command.accepted" and &1["command_id"] == id)
      )

    assert accepted["version"] == 2 and accepted["params"]["mode"] == "step_y"
    assert accepted["inspection_binding"]["inspection_command_id"] == insp

    c = Command.command(id)
    assert c.effect.effect == :changed and c.version == 2

    # fresh ids and fresh arming never produce a second forward of either version
    later = inspect_exact(socket, adapter, @step, 20_300)
    arm_eff(adapter)

    assert %{reply: {:error, {:transform_budget_exhausted, ^id}}, transmitted: nil} =
             attempt(socket, fn ->
               lift(Map.put(@expect, "expect_world", @step), inspection_command_id: later)
             end)

    assert %{reply: {:error, {:transform_budget_exhausted, ^id}}, transmitted: nil} =
             attempt(socket, fn ->
               step(Map.put(@expect, "expect_world", @step), inspection_command_id: later)
             end)

    FakeNative.close(socket)
  end

  test "the other order: a v1 lift consumes the shared budget and a v2 step is refused", %{
    port: port
  } do
    {socket, adapter, _} = v2_peer(port)
    insp = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)
    id = applied_forward(socket, adapter, insp, :lift)
    assert budget() == 0 and consumer() == id
    later = inspect_exact(socket, adapter, @lifted, 20_300)
    arm_eff(adapter)

    assert %{reply: {:error, {:transform_budget_exhausted, ^id}}, transmitted: nil} =
             attempt(socket, fn ->
               step(Map.put(@expect, "expect_world", @lifted), inspection_command_id: later)
             end)

    FakeNative.close(socket)
  end

  test "a verified pre-call refusal leaves the shared budget; an unknown step consumes it across a reconnect and a fresh arming",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    insp = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)
    assert {:ok, refused} = step(@expect, inspection_command_id: insp)
    assert {:ok, rcmd} = FakeNative.recv(socket)

    FakeNative.respond(socket, rcmd, adapter, "precondition_failed", %{
      "reason" => "not applied (precondition failed): expect_world_mismatch",
      "frame" => 19_500,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(refused).status == :precondition_failed end)
    assert budget() == 1 and consumer() == nil

    # an in-flight step consumes the budget at once; its link lost before any result: unknown, still consumed
    insp2 = inspect_exact(socket, adapter, @pre, 19_600)
    arm_eff(adapter)
    assert {:ok, lost} = step(@expect, inspection_command_id: insp2)
    assert budget() == 0 and consumer() == lost
    assert {:ok, _line} = FakeNative.recv(socket)
    FakeNative.close(socket)
    assert wait(fn -> Command.command(lost).status == :unknown end)
    assert budget() == 0 and consumer() == lost

    # a reconnect and a fresh arming create no new allowance for either version
    {socket2, ^adapter, _} = v2_peer(port, adapter_id: adapter)
    insp3 = inspect_exact(socket2, adapter, @pre, 19_900)
    arm_eff(adapter)

    assert %{reply: {:error, {:transform_budget_exhausted, ^lost}}, transmitted: nil} =
             attempt(socket2, fn -> lift(@expect, inspection_command_id: insp3) end)

    assert %{reply: {:error, {:transform_budget_exhausted, ^lost}}, transmitted: nil} =
             attempt(socket2, fn -> step(@expect, inspection_command_id: insp3) end)

    FakeNative.close(socket2)
  end

  test "the restoration of a v2 step is planned from the journal at version 2 and transmitted as a v2 restore; a restoration never refills the budget",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    insp = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)
    id = applied_forward(socket, adapter, insp, :step)

    assert {:ok, plan} = Command.plan_transform_restore(id)
    assert plan.version == 2 and plan.forward_mode == "step_y" and plan.target_world == @pre

    later = inspect_exact(socket, adapter, @step, 20_300)
    arm_eff(adapter)

    assert {:ok, rid} =
             Command.restore_candidate(id,
               inspection_command_id: later,
               expected_generation: @gen
             )

    assert {:ok, rcmd} = FakeNative.recv(socket)
    assert rcmd["name"] == "candidate.transform.set" and rcmd["version"] == 2
    assert rcmd["params"] == restore_params(id, @step)

    FakeNative.respond(socket, rcmd, adapter, "applied", %{
      "observed" =>
        Map.merge(apply_observed("restore", @step, @pre, @pre), %{
          "restore_of" => field("observed", id),
          "restore_facts" =>
            field("observed", "world=1,local=1,parent=1,dirty=1,snapshot=1,within_tol=1")
        }),
      "frame" => 20_400,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(rid).status == :applied end)
    assert Command.command(rid).version == 2
    assert budget() == 0 and consumer() == id

    accepted =
      Enum.find(
        journal_entries(),
        &(&1["event"] == "command.accepted" and &1["command_id"] == rid)
      )

    assert accepted["version"] == 2 and accepted["inspection_binding"]["restore_of"] == id

    # a second step after the restoration: still refused
    after_restore = inspect_exact(socket, adapter, @pre, 20_600)
    arm_eff(adapter)

    assert %{reply: {:error, {:transform_budget_exhausted, ^id}}, transmitted: nil} =
             attempt(socket, fn -> step(@expect, inspection_command_id: after_restore) end)

    FakeNative.close(socket)
  end

  test "a v1 lift's plan still carries version 1 and its restoration is transmitted as a v1 restore",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    insp = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)
    id = applied_forward(socket, adapter, insp, :lift)
    assert {:ok, plan} = Command.plan_transform_restore(id)
    assert plan.version == 1 and plan.forward_mode == "lift"
    later = inspect_exact(socket, adapter, @lifted, 20_300)
    arm_eff(adapter)

    assert {:ok, _rid} =
             Command.restore_candidate(id,
               inspection_command_id: later,
               expected_generation: @gen
             )

    assert {:ok, rcmd} = FakeNative.recv(socket)
    assert rcmd["version"] == 1 and rcmd["params"] == restore_params(id, @lifted)
    FakeNative.close(socket)
  end

  test "forged, version-substituted or altered restorations fail inside the authority before transmission",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    insp = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)
    step_id = applied_forward(socket, adapter, insp, :step)
    later = inspect_exact(socket, adapter, @step, 20_300)
    arm_eff(adapter)

    # a v1 restore of the v2 step (bypassing the facade)
    assert %{reply: {:error, {:restore_version_mismatch, 2, 1}}, transmitted: nil} =
             attempt(socket, fn ->
               direct_restore(1, step_id, @step, inspection_command_id: later)
             end)

    # an altered target
    assert %{reply: {:error, {:expectation_mismatch, "target_world"}}, transmitted: nil} =
             attempt(socket, fn ->
               direct_restore(2, step_id, @step,
                 inspection_command_id: later,
                 params: Map.put(restore_params(step_id, @step), "target_world", @twin)
               )
             end)

    # a caller-asserted binding is never authority
    assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
             attempt(socket, fn ->
               direct_restore(2, step_id, @step,
                 inspection_command_id: later,
                 reversal_inspection: %{"inspection_command_id" => later}
               )
             end)

    # the journal plan carries the step's version, and the binding's own check refuses a
    # substituted version against it (reached directly; the version is a required argument)
    {:ok, read} = Journal.read(Journal.status().path)
    assert {:ok, %{version: 2}} = TransformRestore.plan_journal(read, step_id)
    supplied = restore_params(step_id, @step)

    assert {:error, {:restore_version_mismatch, 2, 1}} =
             TransformBinding.restore(binding_ctx(), step_id, later, supplied, 1)

    assert {:ok, %{"mode" => "restore", "restore_of" => ^step_id}, %{"later_class" => "held"}} =
             TransformBinding.restore(binding_ctx(), step_id, later, supplied, 2)

    assert Command.status().trust.effectful_armed
    FakeNative.close(socket)
  end

  test "a v2 restore of a v1 lift fails inside the authority", %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    insp = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)
    lift_id = applied_forward(socket, adapter, insp, :lift)
    later = inspect_exact(socket, adapter, @lifted, 20_300)
    arm_eff(adapter)

    assert %{reply: {:error, {:restore_version_mismatch, 1, 2}}, transmitted: nil} =
             attempt(socket, fn ->
               direct_restore(2, lift_id, @lifted, inspection_command_id: later)
             end)

    # the binding's own journal-plan check, reached directly
    assert {:error, {:restore_version_mismatch, 1, 2}} =
             TransformBinding.restore(
               binding_ctx(),
               lift_id,
               later,
               restore_params(lift_id, @lifted),
               2
             )

    FakeNative.close(socket)
  end

  test "v2 inspection binding refusals: missing, unknown, wrong generation, unqualified and twin-bit expectations never bind a step",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    good = inspect_exact(socket, adapter, @pre, 19_000)
    other_gen = inspect_exact(socket, adapter, @pre, 19_100, generation: "other-generation")

    in_registry =
      inspect_exact(socket, adapter, @pre, 19_200,
        overrides: %{"cand_in_registry" => field("observed", true)}
      )

    dirty =
      inspect_exact(socket, adapter, @pre, 19_300,
        overrides: %{"cand_dirty" => field("observed", true)}
      )

    arm_eff(adapter)

    for {opts, reason} <- [
          {[], :inspection_command_id_required},
          {[inspection_command_id: Schema.uuid4()], :inspection_not_in_journal},
          {[inspection_command_id: other_gen], :inspection_generation_mismatch},
          {[inspection_command_id: in_registry], :inspection_candidate_in_registry},
          {[inspection_command_id: dirty], :inspection_cache_dirty}
        ] do
      assert %{reply: {:error, ^reason}, transmitted: nil} =
               attempt(socket, fn -> step(@expect, opts) end)
    end

    assert %{reply: {:error, {:expectation_mismatch, "expect_world"}}, transmitted: nil} =
             attempt(socket, fn ->
               step(Map.put(@expect, "expect_world", @twin), inspection_command_id: good)
             end)

    assert Command.status().trust.effectful_armed and budget() == 1
    FakeNative.close(socket)
  end

  @tag max_age_ms: 300
  test "a stale inspection and an inspection from an old link never bind a step", %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    insp = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)
    Process.sleep(500)

    assert %{reply: {:error, :inspection_stale}, transmitted: nil} =
             attempt(socket, fn -> step(@expect, inspection_command_id: insp) end)

    FakeNative.close(socket)
    assert wait(fn -> Command.status().trust.transport == :none end)
    {socket2, ^adapter, _} = v2_peer(port, adapter_id: adapter)
    arm_eff(adapter)

    assert %{reply: {:error, :inspection_link_not_current}, transmitted: nil} =
             attempt(socket2, fn -> step(@expect, inspection_command_id: insp) end)

    assert budget() == 1
    FakeNative.close(socket2)
  end
end

defmodule GlacierRelay.Command.TransformEffectfulTest do
  @moduledoc """
  M6-F: the transform entries against the fake native peer — the exact inspection and its
  decoding, the lift's issuance rules (the compiled target never supplied, the one-lift budget
  per authority, refusals that leave the budget), the lift ladder with the peer's twelve-word
  classification recorded as fake-native evidence, the later exact observation classified under
  the declared policy, and the planner-bound restoration (already at baseline, drift, the binding,
  its own arming, the restoration facts). Every assertion the fake peer makes is fake-native
  evidence; nothing here touches Glacier.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Journal, Listener, Schema, TransformWords}
  alias GlacierRelay.Test.{FakeNative, FixturePlayer}

  @token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @gen "2516103519921974492-5fd4f3e1-0fa5-408f-bce8-b58923581360"
  @brick "007c57a6ea581f8c"
  @entity "feede715906f747f"
  @pre "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfc5099e"
  @target "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfa5099e"
  @local "00000000,00000000,bfc5099e,00000000,00000000,00000000,3f800000"
  @hero_world "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2a77ccf,416b27f0,bfc2d6bb"
  @hero_local "c2a77ccf,416b27f0,bfc2d6bb,00000000,00000000,00000000,3f800000"
  @expect %{"expect_world" => @pre, "expect_local" => @local, "expect_parent" => @brick}
  @caps ["relay.probe/1", "relay.inspect.candidate_transform/1", "candidate.transform.set/1"]

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-transform-#{System.pid()}-#{System.unique_integer([:positive])}"
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
       effectful: true,
       token: @token,
       effectful_ttl_max_ms: 120_000,
       evidence_max_age_ms: 120_000}
    )

    %{port: Listener.port(), dir: dir}
  end

  defp wait(fun), do: FixturePlayer.wait_until(fun, 100, 10)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

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

  defp v2_peer(port) do
    {socket, adapter, welcome} = FakeNative.handshake_v2(port, @token, capabilities: @caps)
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

  defp field(status, value), do: FakeNative.field(status, value)

  # A fake exact inspection of the candidate at `world` on `frame`; returns its id.
  defp inspect_exact(socket, adapter, world, frame, overrides \\ %{}) do
    :ok = if Command.status().trust.armed, do: :ok, else: Command.arm()
    {:ok, id} = Command.inspect_candidate_transform()
    {:ok, icmd} = FakeNative.recv(socket)
    assert icmd["name"] == "relay.inspect.candidate_transform" and icmd["params"] == %{}

    observed =
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

    FakeNative.respond(socket, icmd, adapter, "applied", %{
      "observed" => observed,
      "frame" => frame,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    id
  end

  defp apply_observed(mode, pre, requested, post, overrides) do
    Map.merge(
      %{
        "mode" => field("observed", mode),
        "mission_playing" => field("observed", true),
        "generation_expected" => field("observed", @gen),
        "generation_fresh" => field("observed", @gen),
        "generation_post" => field("observed", @gen),
        "targets" => field("observed", "#{@brick},#{@entity}"),
        "cand_index_check" => field("observed", "in_range"),
        "cand_resolved" => field("observed", true),
        "cand_distinct" => field("observed", true),
        "cand_spatial_distinct" => field("observed", true),
        "registry_slots" => field("observed", "0:local,1:empty,2:empty,3:empty"),
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
        "world_match" =>
          field(
            "observed",
            if(post == requested,
              do: "target",
              else: if(post == pre, do: "preimage", else: "neither")
            )
          ),
        "local_match" => field("observed", "unchanged"),
        "hero_control" => field("observed", "unchanged"),
        "setter_called" => field("observed", true),
        "apply_log" => field("observed", "written"),
        "invocation" => field("observed", "called"),
        "effect" =>
          field(
            "observed",
            if(post == requested,
              do: "changed",
              else: if(post == pre, do: "unchanged", else: "uncertain")
            )
          ),
        "precondition_ok" => field("observed", true),
        "budget_remaining" => field("observed", 0)
      },
      overrides
    )
  end

  defp applied(socket, cmd, adapter, mode, pre, requested, post, opts \\ []) do
    FakeNative.respond(socket, cmd, adapter, Keyword.get(opts, :status, "applied"), %{
      "observed" =>
        apply_observed(mode, pre, requested, post, Keyword.get(opts, :overrides, %{})),
      "frame" => Keyword.get(opts, :frame, 20_000),
      "mission_generation" => @gen
    })
  end

  defp lift(params \\ @expect, opts \\ []),
    do: Command.lift_candidate(params, Keyword.merge([expected_generation: @gen], opts))

  test "the schema lists the two entries; the exact inspection is inert and decodes; the lift's parameters are validated locally" do
    assert %{issuable: true, trust: :identified, effect: :none, params: %{}} =
             Schema.entry("relay.inspect.candidate_transform", 1)

    assert %{
             issuable: :effectful,
             trust: :token_verified,
             effect: :transform,
             preconditions: [:mission_generation]
           } = Schema.entry("candidate.transform.set", 1)

    assert %{"name" => "relay.inspect.candidate_transform", "version" => 1} in Schema.issuable()
    refute Enum.any?(Schema.issuable(), &(&1["name"] == "candidate.transform.set"))

    assert %{"name" => "candidate.transform.set", "version" => 1} in Schema.issuable_for(
             2,
             @caps,
             true
           )

    refute Enum.any?(
             Schema.issuable_for(1, @caps, true),
             &(&1["name"] == "candidate.transform.set")
           )

    entry = Schema.entry("candidate.transform.set", 1)
    assert {:ok, _} = Schema.validate_params(entry, Map.put(@expect, "mode", "lift"))

    assert {:error, {:invalid_param, "mode", {:not_one_of, ["lift", "restore"]}}} =
             Schema.validate_params(entry, Map.put(@expect, "mode", "teleport"))

    assert {:error, {:invalid_param, "expect_world", :not_12_finite_float_words}} =
             Schema.validate_params(
               entry,
               Map.merge(@expect, %{"mode" => "lift", "expect_world" => @local})
             )

    assert {:error, {:invalid_param, "expect_world", :not_12_finite_float_words}} =
             Schema.validate_params(
               entry,
               Map.merge(@expect, %{
                 "mode" => "lift",
                 "expect_world" => String.replace(@pre, "bfc5099e", "7f800000")
               })
             )

    assert {:error, {:invalid_param, "expect_local", :not_7_finite_float_words}} =
             Schema.validate_params(
               entry,
               Map.merge(@expect, %{"mode" => "lift", "expect_local" => @pre})
             )

    assert {:error, {:invalid_param, "expect_parent", :not_16_lowercase_hex_digits_or_none}} =
             Schema.validate_params(
               entry,
               Map.merge(@expect, %{"mode" => "lift", "expect_parent" => "007C57A6EA581F8C"})
             )

    assert {:ok, %{"expect_parent" => "none"}} =
             Schema.validate_params(
               entry,
               Map.merge(@expect, %{"mode" => "lift", "expect_parent" => "none"})
             )

    assert {:error, {:unknown_params, ["entity_id"]}} =
             Schema.validate_params(
               entry,
               Map.merge(@expect, %{"mode" => "lift", "entity_id" => @entity})
             )

    assert {:error, {:invalid_param, "restore_of", :not_a_uuid}} =
             Schema.validate_params(
               entry,
               Map.merge(@expect, %{
                 "mode" => "restore",
                 "target_world" => @pre,
                 "restore_of" => "x"
               })
             )
  end

  test "the lift: no supplied target, one budget per authority consumed by an accepted lift that was not verifiably unapplied; the ladder records the twelve-word classification; a later exact inspection is classified under the declared policy",
       %{port: port} do
    {socket, adapter, welcome} = v2_peer(port)
    assert %{"name" => "candidate.transform.set", "version" => 1} in welcome["allowlist"]
    assert Command.status().effectful.transform_lift_budget == 1

    # the expectation source: an exact inspection (inert arming)
    insp0 = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)

    # local refusals that do not consume the arming or the budget
    assert {:error, :lift_carries_no_target} = lift(Map.put(@expect, "target_world", @target))
    assert {:error, :lift_carries_no_target} = lift(Map.put(@expect, "restore_of", insp0))
    assert {:error, :mission_generation_required} = Command.lift_candidate(@expect)

    assert {:error, {:invalid_param, "expect_world", :not_12_finite_float_words}} =
             lift(Map.put(@expect, "expect_world", "x"))

    assert {:error, :restore_requires_plan} =
             Command.Authority.issue(
               "candidate.transform.set",
               1,
               Map.merge(@expect, %{
                 "mode" => "restore",
                 "target_world" => @target,
                 "restore_of" => insp0
               }),
               preconditions: %{"mission_generation" => @gen}
             )

    assert {:error, :already_at_restore_target} =
             Command.Authority.issue(
               "candidate.transform.set",
               1,
               Map.merge(@expect, %{
                 "mode" => "restore",
                 "target_world" => @pre,
                 "restore_of" => insp0
               }),
               preconditions: %{"mission_generation" => @gen}
             )

    assert Command.status().trust.effectful_armed and
             Command.status().effectful.transform_lift_budget == 1

    assert {:error, :timeout} = FakeNative.recv(socket, 100)

    # a lift the peer refuses (precondition_failed) leaves the budget; its arming is consumed
    assert {:ok, refused} = lift()
    assert {:ok, rcmd} = FakeNative.recv(socket)

    assert rcmd["params"] == Map.put(@expect, "mode", "lift") and
             rcmd["preconditions"] == %{"mission_generation" => @gen}

    refute Map.has_key?(rcmd["params"], "target_world")

    FakeNative.respond(socket, rcmd, adapter, "precondition_failed", %{
      "reason" => "not applied (precondition failed): expect_world_mismatch",
      "frame" => 19_500,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(refused).status == :precondition_failed end)

    assert Command.status().effectful.transform_lift_budget == 1 and
             Command.status().effectful.transform_lift_consumer == nil

    refute Command.status().trust.effectful_armed
    assert {:error, :not_armed_effectful} = lift()

    # the lift ladder
    arm_eff(adapter)
    assert {:ok, id} = lift()

    assert Command.status().effectful.transform_lift_budget == 0 and
             Command.status().effectful.transform_lift_consumer == id

    assert {:ok, cmd} = FakeNative.recv(socket)

    assert cmd["name"] == "candidate.transform.set" and cmd["version"] == 1 and
             cmd["command_protocol_version"] == 2

    applied(socket, cmd, adapter, "lift", @pre, @target, @target)
    assert wait(fn -> Command.command(id).status == :applied end)
    c = Command.command(id)

    assert c.effect == %{
             invocation: :reported,
             effect: :changed,
             read_back: :native_same_frame,
             read_back_later: nil,
             engine_consistent: false,
             operator: nil
           }

    assert c.consequences == :unknown and c.observed == :native and c.effectful

    terminal =
      Enum.find(
        journal_entries(),
        &(&1["event"] == "command.terminal" and &1["command_id"] == id)
      )

    assert terminal["effect"] == "changed" and
             terminal["observed"]["postimage_world_words"]["value"] == @target

    # a second lift, fresh id, fresh arming: the budget refuses it
    arm_eff(adapter)

    assert {:error, {:transform_budget_exhausted, ^id}} =
             lift(Map.put(@expect, "expect_world", @target))

    assert {:error, :timeout} = FakeNative.recv(socket, 100)
    assert Command.status().trust.effectful_armed
    assert :ok = Command.disarm()

    # later exact inspections classified against the lift's exact groups
    held = inspect_exact(socket, adapter, @target, 20_300)

    assert {:ok, _} =
             Command.observe(id, "later_frame_read_back", "the lift held at the sampled frame",
               inspection_command_id: held
             )

    assert Command.command(id).effect.read_back_later == "held"
    near = inspect_exact(socket, adapter, String.replace(@target, "bfa5099e", "bfa5099f"), 20_400)

    assert {:ok, _} =
             Command.observe(id, "later_frame_read_back", "one bit away",
               inspection_command_id: near
             )

    assert Command.command(id).effect.read_back_later == "near_target"
    returned = inspect_exact(socket, adapter, @pre, 20_500)

    assert {:ok, _} =
             Command.observe(id, "later_frame_read_back", "the engine put it back",
               inspection_command_id: returned
             )

    assert Command.command(id).effect.read_back_later == "returned_to_baseline"

    dirty =
      inspect_exact(socket, adapter, @target, 20_600, %{"cand_dirty" => field("observed", true)})

    assert {:ok, _} =
             Command.observe(id, "later_frame_read_back", "dirty cache",
               inspection_command_id: dirty
             )

    assert Command.command(id).effect.read_back_later == "indeterminate"
    earlier = inspect_exact(socket, adapter, @target, 19_900)

    assert {:ok, _} =
             Command.observe(id, "later_frame_read_back", "not later",
               inspection_command_id: earlier
             )

    assert Command.command(id).effect.read_back_later == "not_a_later_frame"

    assert {:error, :inspection_unknown} =
             Command.observe(id, "later_frame_read_back", "x",
               inspection_command_id: Schema.uuid4()
             )

    obs =
      Enum.filter(
        journal_entries(),
        &(&1["event"] == "operator.observation" and &1["command_id"] == id)
      )

    assert Enum.map(obs, & &1["conclusion"]) ==
             ~w(held near_target returned_to_baseline indeterminate not_a_later_frame)

    assert Enum.all?(obs, &(&1["label"] =~ "testimony"))

    FakeNative.close(socket)
  end

  test "the restoration is planned from the journal, bound to a later exact inspection, refused when the engine already shows the baseline or drifted, needs its own arming and reports the restore facts",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    _insp0 = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)
    assert {:ok, id} = lift()
    assert {:ok, cmd} = FakeNative.recv(socket)
    assert {:error, {:received_entries, 0}} = Command.plan_transform_restore(id)
    applied(socket, cmd, adapter, "lift", @pre, @target, @target)
    assert wait(fn -> Command.command(id).status == :applied end)

    assert {:ok, plan} = Command.plan_transform_restore(id)

    assert plan.target_world == @pre and plan.restore_of == id and plan.mission_generation == @gen and
             plan.frame == 20_000

    assert TransformWords.encode(plan.postimage_world) == @target

    assert {:error, :inspection_command_id_required} =
             Command.restore_candidate(id, expected_generation: @gen)

    assert {:error, :inspection_not_in_journal} =
             Command.restore_candidate(id,
               inspection_command_id: Schema.uuid4(),
               expected_generation: @gen
             )

    # the engine already shows the baseline: no restoration is submitted
    back = inspect_exact(socket, adapter, @pre, 20_200)

    assert {:error, :already_at_baseline} =
             Command.restore_candidate(id, inspection_command_id: back, expected_generation: @gen)

    # drift: effectful issuance stops
    drifted =
      inspect_exact(socket, adapter, String.replace(@target, "bfa5099e", "bf000000"), 20_250)

    assert {:error, {:state_drifted, :drifted}} =
             Command.restore_candidate(id,
               inspection_command_id: drifted,
               expected_generation: @gen
             )

    # an inspection from before the lift never binds
    assert {:error, :inspection_not_later} =
             Command.restore_candidate(id,
               inspection_command_id: inspect_exact(socket, adapter, @target, 19_900),
               expected_generation: @gen
             )

    # the postimage binds; the generation and the arming still apply
    insp = inspect_exact(socket, adapter, @target, 20_300)

    assert {:error, :expected_generation_required} =
             Command.restore_candidate(id, inspection_command_id: insp)

    assert {:error, {:generation_mismatch, @gen}} =
             Command.restore_candidate(id,
               inspection_command_id: insp,
               expected_generation: "other"
             )

    assert {:error, :not_armed_effectful} =
             Command.restore_candidate(id, inspection_command_id: insp, expected_generation: @gen)

    assert {:error, :timeout} = FakeNative.recv(socket, 100)

    arm_eff(adapter)

    assert {:ok, rid} =
             Command.restore_candidate(id, inspection_command_id: insp, expected_generation: @gen)

    assert {:ok, rcmd} = FakeNative.recv(socket)

    assert rcmd["params"] == %{
             "mode" => "restore",
             "expect_world" => @target,
             "expect_local" => @local,
             "expect_parent" => @brick,
             "target_world" => @pre,
             "restore_of" => id
           }

    assert rcmd["preconditions"] == %{"mission_generation" => @gen}
    assert Command.command(rid).reversal_of == id

    accepted =
      Enum.find(
        journal_entries(),
        &(&1["event"] == "command.accepted" and &1["command_id"] == rid)
      )

    assert accepted["reversal_of"] == id and
             accepted["reversal_inspection"]["inspection_command_id"] == insp and
             accepted["reversal_inspection"]["later_class"] == "held"

    # the budget stays consumed: a restore is not a second lift
    assert Command.status().effectful.transform_lift_budget == 0

    applied(socket, rcmd, adapter, "restore", @target, @pre, @pre,
      frame: 21_000,
      overrides: %{
        "restore_of" => field("observed", id),
        "restore_facts" =>
          field("observed", "world=1,local=1,parent=1,dirty=1,snapshot=1,within_tol=1")
      }
    )

    assert wait(fn -> Command.command(rid).status == :applied end)
    r = Command.command(rid)

    assert r.restored == :native_same_frame and r.effect.effect == :changed and
             r.consequences == :unknown

    terminal =
      Enum.find(
        journal_entries(),
        &(&1["event"] == "command.terminal" and &1["command_id"] == rid)
      )

    assert terminal["restored"] == "native_same_frame" and terminal["reversal_of"] == id

    assert terminal["observed"]["restore_facts"]["value"] ==
             "world=1,local=1,parent=1,dirty=1,snapshot=1,within_tol=1"

    FakeNative.close(socket)
  end

  test "an uncertain lift consumes the budget and is never planned; an unapplied restore result is recorded as not restored",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    _ = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)
    assert {:ok, id} = lift()
    assert {:ok, cmd} = FakeNative.recv(socket)

    applied(
      socket,
      cmd,
      adapter,
      "lift",
      @pre,
      @target,
      String.replace(@target, "bfa5099e", "bfa5099f")
    )

    assert wait(fn -> Command.command(id).status == :applied end)
    assert Command.command(id).effect.effect == :uncertain
    assert {:error, :effect_uncertain} = Command.plan_transform_restore(id)
    assert Command.status().effectful.transform_lift_budget == 0
    arm_eff(adapter)
    assert {:error, {:transform_budget_exhausted, ^id}} = lift()
    FakeNative.close(socket)
  end
end

defmodule GlacierRelay.Command.TransformBindingTest do
  @moduledoc """
  M6-F1a binding correction: the issuing authority — not the operator facade — binds a
  `candidate.transform.set` v1 lift to one specific, recent, qualifying exact inspection of its
  own journal, and binds a restoration to the journal's plan of the original lift and a later
  qualifying inspection; caller-supplied binding metadata is never authority. Every refusal is
  proven before transmission: the fake peer (the setter's stand-in here) receives no command
  line. Every assertion the fake peer makes is fake-native evidence; nothing here touches Glacier.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command

  alias GlacierRelay.Command.{
    Authority,
    Journal,
    Listener,
    Schema,
    TransformRestore,
    TransformWords
  }

  alias GlacierRelay.Test.{CountingWriter, FakeNative, FixturePlayer}

  @token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @gen "2516103519921974492-5fd4f3e1-0fa5-408f-bce8-b58923581360"
  @brick "007c57a6ea581f8c"
  @entity "feede715906f747f"
  @pre "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfc5099e"
  # one bit away from @pre's z: the same seven-digit display (-1.539356), different words
  @twin "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfc5099f"
  @target "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfa5099e"
  @local "00000000,00000000,bfc5099e,00000000,00000000,00000000,3f800000"
  @hero_world "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2a77ccf,416b27f0,bfc2d6bb"
  @hero_local "c2a77ccf,416b27f0,bfc2d6bb,00000000,00000000,00000000,3f800000"
  @expect %{"expect_world" => @pre, "expect_local" => @local, "expect_parent" => @brick}
  @caps ["relay.probe/1", "relay.inspect.candidate_transform/1", "candidate.transform.set/1"]

  setup context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-binding-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, agent} = CountingWriter.start()

    start_supervised!(
      {Command.Supervisor,
       port: 0,
       journal_dir: dir,
       writer: {CountingWriter, agent},
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

    %{port: Listener.port(), dir: dir, agent: agent}
  end

  defp wait(fun), do: FixturePlayer.wait_until(fun, 100, 10)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp field(status, value, reason \\ nil), do: FakeNative.field(status, value, reason)

  defp journal_entries do
    %{path: path} = Journal.status()
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp accepted_entry(id),
    do:
      Enum.find(
        journal_entries(),
        &(&1["event"] == "command.accepted" and &1["command_id"] == id)
      )

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
      FakeNative.handshake_v2(port, @token, Keyword.merge([capabilities: @caps], opts))

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

  # A fake exact inspection of the candidate at `world` on `frame`; returns its id. `opts`:
  # `:overrides` (field objects), `:status` (the terminal), `:generation` (the terminal's).
  defp inspect_exact(socket, adapter, world, frame, opts \\ []) do
    :ok = if Command.status().trust.armed, do: :ok, else: Command.arm()
    {:ok, id} = Command.inspect_candidate_transform()
    {:ok, icmd} = FakeNative.recv(socket)
    assert icmd["name"] == "relay.inspect.candidate_transform"
    status = Keyword.get(opts, :status, "applied")

    FakeNative.respond(socket, icmd, adapter, status, %{
      "observed" => qualifying(world, Keyword.get(opts, :overrides, %{})),
      "frame" => frame,
      "mission_generation" => Keyword.get(opts, :generation, @gen)
    })

    assert wait(fn -> Command.command(id).status == Schema.status_atom(status) end)
    id
  end

  defp apply_observed(mode, pre, requested, post, overrides \\ %{}) do
    Map.merge(
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

  defp lift(params, opts),
    do: Command.lift_candidate(params, Keyword.merge([expected_generation: @gen], opts))

  # The reply of `fun` and whatever the fake peer received in a short window afterwards: a
  # refusal must be `{:error, _}` with nothing transmitted (no line → no setter stand-in reached).
  defp attempt(socket, fun) do
    reply = fun.()

    transmitted =
      case FakeNative.recv(socket, 150) do
        {:ok, line} ->
          Map.take(line, [
            "name",
            "command_id",
            "params",
            "preconditions",
            "link_generation",
            "command_protocol_version"
          ])

        {:error, :timeout} ->
          nil
      end

    %{reply: reply, transmitted: transmitted}
  end

  defp budget, do: Command.status().effectful.transform_lift_budget
  defp armed_eff?, do: Command.status().trust.effectful_armed

  # A lift carried to `applied` with the changed effect; returns its id.
  defp applied_lift(socket, adapter, insp) do
    assert {:ok, id} = lift(@expect, inspection_command_id: insp)
    assert {:ok, cmd} = FakeNative.recv(socket)

    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" => apply_observed("lift", @pre, @target, @target),
      "frame" => 20_000,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    id
  end

  # The restoration parameters an operator (or a forger) might hand the authority directly.
  defp restore_params(original),
    do: %{
      "mode" => "restore",
      "expect_world" => @target,
      "expect_local" => @local,
      "expect_parent" => @brick,
      "target_world" => @pre,
      "restore_of" => original
    }

  defp direct_restore(original, opts),
    do:
      Authority.issue(
        "candidate.transform.set",
        1,
        Keyword.get(opts, :params, restore_params(original)),
        opts
        |> Keyword.drop([:params])
        |> Keyword.put_new(:reversal_of, original)
        |> Keyword.put_new(:preconditions, %{"mission_generation" => @gen})
      )

  describe "finding A — the initial lift" do
    test "a lift with every common arming and trust condition satisfied but no inspection at all is refused before transmission; arming and budget are kept",
         %{port: port} do
      {socket, adapter, _} = v2_peer(port)
      arm_eff(adapter)
      assert Command.status().trust.token_verified and armed_eff?() and budget() == 1

      assert %{reply: {:error, :inspection_command_id_required}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, []) end)

      assert armed_eff?() and budget() == 1
      FakeNative.close(socket)
    end

    test "an unrelated qualifying inspection never substitutes for the missing explicit id (no implicit latest inspection)",
         %{port: port} do
      {socket, adapter, _} = v2_peer(port)
      _unrelated = inspect_exact(socket, adapter, @pre, 19_000)
      arm_eff(adapter)

      assert %{reply: {:error, :inspection_command_id_required}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, []) end)

      assert %{reply: {:error, :inspection_command_id_required}, transmitted: nil} =
               attempt(socket, fn -> lift(%{}, inspection_command_id: nil) end)

      assert %{reply: {:error, :inspection_command_id_required}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: 42) end)

      assert armed_eff?() and budget() == 1
      FakeNative.close(socket)
    end

    test "unknown, wrong-type, failed, contradictory-outcome and in-flight inspections never bind a lift",
         %{port: port} do
      {socket, adapter, _} = v2_peer(port)

      # wrong type: a completed relay.probe and a completed relay.inspect.candidate
      :ok = Command.arm()
      {:ok, probe} = Command.probe()
      {:ok, pcmd} = FakeNative.recv(socket)
      FakeNative.respond(socket, pcmd, adapter, "applied", %{"frame" => 18_000})
      assert wait(fn -> Command.command(probe).status == :applied end)

      # failed: the native side could not read the snapshot
      failed = inspect_exact(socket, adapter, @pre, 18_500, status: "unavailable")

      # contradictory: the acknowledgement arrived, the terminal never did (unknown), and a late
      # applied claim followed — never a qualifying inspection
      {:ok, lost} = Command.inspect_candidate_transform(ttl_ms: 60)
      {:ok, lcmd} = FakeNative.recv(socket)
      FakeNative.send_json(socket, FakeNative.result(lcmd, adapter, "received"))
      assert wait(fn -> Command.command(lost).status == :unknown end)

      FakeNative.send_json(
        socket,
        FakeNative.result(lcmd, adapter, "applied", %{
          "observed" => qualifying(@pre, %{}),
          "frame" => 18_700,
          "mission_generation" => @gen
        })
      )

      assert wait(fn -> Command.command(lost).late_applied_claim end)

      arm_eff(adapter)

      for {id, reason} <- [
            {Schema.uuid4(), :inspection_not_in_journal},
            {probe, :not_an_exact_inspection},
            {failed, {:inspection_not_applied, "unavailable"}},
            {lost, :inspection_outcome_unknown}
          ] do
        assert %{reply: {:error, ^reason}, transmitted: nil} =
                 attempt(socket, fn -> lift(@expect, inspection_command_id: id) end)
      end

      # in flight: an inspection without its terminal; the one-in-flight rule refuses first
      {:ok, pending} = Command.inspect_candidate_transform(ttl_ms: 2_000)
      {:ok, _} = FakeNative.recv(socket)

      assert %{reply: {:error, {:in_flight, ^pending}}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: pending) end)

      assert armed_eff?() and budget() == 1
      FakeNative.close(socket)
    end

    @tag max_age_ms: 400
    test "a stale inspection (the journal's own monotonic clock, the configured bound) never binds",
         %{port: port} do
      {socket, adapter, _} = v2_peer(port)
      insp = inspect_exact(socket, adapter, @pre, 19_000)
      arm_eff(adapter)
      Process.sleep(500)

      assert %{reply: {:error, :inspection_stale}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: insp) end)

      # an age or a timestamp the caller claims is not an input
      assert %{reply: {:error, :inspection_stale}, transmitted: nil} =
               attempt(socket, fn ->
                 lift(@expect, inspection_command_id: insp, inspection_age_ms: 1)
               end)

      assert armed_eff?() and budget() == 1
      FakeNative.close(socket)
    end

    test "an inspection from an old link (the same adapter reconnected, or another adapter) or of another mission generation never binds",
         %{port: port} do
      {socket, adapter, _} = v2_peer(port)
      old = inspect_exact(socket, adapter, @pre, 19_000)
      other_gen = inspect_exact(socket, adapter, @pre, 19_100, generation: "other-generation")

      stale_fresh =
        inspect_exact(socket, adapter, @pre, 19_200,
          overrides: %{"generation_fresh" => field("observed", "other-generation")}
        )

      arm_eff(adapter)

      assert %{reply: {:error, :inspection_generation_mismatch}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: other_gen) end)

      assert %{reply: {:error, :inspection_generation_mismatch}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: stale_fresh) end)

      FakeNative.close(socket)
      assert wait(fn -> Command.status().trust.transport == :none end)

      # the same adapter on a new link
      {socket2, ^adapter, _} = v2_peer(port, adapter_id: adapter)
      arm_eff(adapter)

      assert %{reply: {:error, :inspection_link_not_current}, transmitted: nil} =
               attempt(socket2, fn -> lift(@expect, inspection_command_id: old) end)

      FakeNative.close(socket2)
      assert wait(fn -> Command.status().trust.transport == :none end)

      # another adapter
      {socket3, adapter3, _} = v2_peer(port)
      arm_eff(adapter3)

      assert %{reply: {:error, :inspection_link_not_current}, transmitted: nil} =
               attempt(socket3, fn -> lift(@expect, inspection_command_id: old) end)

      assert armed_eff?() and budget() == 1
      FakeNative.close(socket3)
    end

    test "an inspection whose compiled target, identity, ownership, interfaces, distinction or registry evidence does not qualify never binds",
         %{port: port} do
      {socket, adapter, _} = v2_peer(port)

      cases = [
        {%{"targets" => field("observed", "#{@brick},0000000000000001")},
         :inspection_target_not_compiled},
        {%{"snapshot_version" => field("observed", 2)}, :inspection_snapshot_version},
        {%{"cand_brick_present" => field("observed", false)}, :inspection_candidate_brick_absent},
        {%{"cand_index_check" => field("observed", "out_of_range")},
         :inspection_candidate_index_not_in_range},
        {%{"cand_resolved" => field("unavailable", nil, "lookup faulted")},
         :inspection_candidate_unresolved},
        {%{"cand_hitman5" => field("observed", false)}, :inspection_candidate_not_hitman5},
        {%{"cand_id_match" => field("observed", false)}, :inspection_candidate_id_mismatch},
        {%{"cand_brick_owner" => field("observed", "00097aa87b144150")},
         :inspection_candidate_owner_mismatch},
        {%{"cand_distinct" => field("observed", false)}, :inspection_candidate_not_distinct},
        {%{"cand_spatial" => field("unavailable", nil, "no spatial interface")},
         :inspection_candidate_spatial_unavailable},
        {%{"cand_spatial_distinct" => field("observed", false)},
         :inspection_candidate_spatial_not_distinct},
        {%{"cand_in_registry" => field("observed", true)}, :inspection_candidate_in_registry},
        {%{"cand_in_registry" => field("unavailable", nil, "registry unreadable")},
         :inspection_registry_unobserved},
        {%{"hero_parent" => field("unavailable", nil, "hero unreadable")},
         :inspection_hero_control_unobserved},
        {%{"reads_on_frame" => field("observed", false)}, :inspection_not_on_one_frame}
      ]

      ids =
        cases
        |> Enum.with_index()
        |> Enum.map(fn {{overrides, reason}, i} ->
          {inspect_exact(socket, adapter, @pre, 19_000 + i, overrides: overrides), reason}
        end)

      arm_eff(adapter)

      for {id, reason} <- ids do
        assert %{reply: {:error, ^reason}, transmitted: nil} =
                 attempt(socket, fn -> lift(@expect, inspection_command_id: id) end)
      end

      assert armed_eff?() and budget() == 1
      FakeNative.close(socket)
    end

    test "a dirty, unavailable, non-finite or malformed snapshot never binds", %{port: port} do
      {socket, adapter, _} = v2_peer(port)

      cases = [
        {%{"cand_dirty" => field("observed", true)}, :inspection_cache_dirty},
        {%{"cand_dirty" => field("unavailable", nil, "dirty flag unreadable")},
         :inspection_dirty_unobserved},
        {%{"cand_world_words" => field("unavailable", nil, "spatial read faulted")},
         :inspection_world_unobserved},
        {%{"cand_world_words" => field("observed", String.replace(@pre, "bfc5099e", "7f800000"))},
         :inspection_world_invalid},
        {%{"cand_world_words" => field("observed", String.upcase(@pre))},
         :inspection_world_invalid},
        {%{"cand_local_words" => field("observed", "00000000,00000000")},
         :inspection_local_invalid},
        {%{"cand_parent" => field("unavailable", nil, "parent unreadable")},
         :inspection_parent_unobserved}
      ]

      ids =
        cases
        |> Enum.with_index()
        |> Enum.map(fn {{overrides, reason}, i} ->
          {inspect_exact(socket, adapter, @pre, 19_000 + i, overrides: overrides), reason}
        end)

      arm_eff(adapter)

      for {id, reason} <- ids do
        assert %{reply: {:error, ^reason}, transmitted: nil} =
                 attempt(socket, fn -> lift(@expect, inspection_command_id: id) end)
      end

      assert armed_eff?() and budget() == 1
      FakeNative.close(socket)
    end

    test "a fresh inspection whose exact words differ from the caller's groups is refused although the seven-digit display is identical",
         %{port: port} do
      {socket, adapter, _} = v2_peer(port)
      twin = inspect_exact(socket, adapter, @twin, 19_000)
      arm_eff(adapter)

      assert TransformWords.translation_text(elem(TransformWords.decode_world(@twin), 1)) ==
               TransformWords.translation_text(elem(TransformWords.decode_world(@pre), 1))

      assert %{reply: {:error, {:expectation_mismatch, "expect_world"}}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: twin) end)

      assert %{reply: {:error, {:expectation_mismatch, "expect_local"}}, transmitted: nil} =
               attempt(socket, fn ->
                 lift(%{"expect_local" => String.replace(@local, "3f800000", "3f800001")},
                   inspection_command_id: twin
                 )
               end)

      assert %{reply: {:error, {:expectation_mismatch, "expect_parent"}}, transmitted: nil} =
               attempt(socket, fn ->
                 lift(%{"expect_parent" => "none"}, inspection_command_id: twin)
               end)

      assert armed_eff?() and budget() == 1

      # the inspection's exact bits, derived by the authority, are what is accepted and sent
      assert %{reply: {:ok, id}, transmitted: line} =
               attempt(socket, fn -> lift(%{}, inspection_command_id: twin) end)

      assert line["params"] == %{
               "mode" => "lift",
               "expect_world" => @twin,
               "expect_local" => @local,
               "expect_parent" => @brick
             }

      assert accepted_entry(id)["params"] == line["params"]
      FakeNative.close(socket)
    end

    test "a valid recent exact inspection binds: canonical parameters accepted and transmitted identically, the verified binding journaled, the budget consumed once",
         %{port: port} do
      {socket, adapter, _} = v2_peer(port)
      insp = inspect_exact(socket, adapter, @pre, 19_000)
      arm_eff(adapter)

      # the caller's groups, when given, must equal the inspection's exactly
      assert %{reply: {:ok, id}, transmitted: line} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: insp) end)

      assert line["name"] == "candidate.transform.set" and line["command_id"] == id
      assert line["params"] == Map.put(@expect, "mode", "lift")
      assert line["preconditions"] == %{"mission_generation" => @gen}

      accepted = accepted_entry(id)
      assert accepted["params"] == line["params"]
      binding = accepted["inspection_binding"]
      %{journal_id: journal_id} = Journal.status()

      inspection_terminal =
        Enum.find(
          journal_entries(),
          &(&1["event"] == "command.terminal" and &1["command_id"] == insp)
        )

      assert binding["inspection_command_id"] == insp and binding["journal_id"] == journal_id and
               binding["journal_seq"] == inspection_terminal["seq"] and binding["frame"] == 19_000 and
               binding["link_generation"] == Command.status().link.generation and
               binding["adapter_instance_id"] == adapter and binding["mission_generation"] == @gen and
               binding["max_age_ms"] == 60_000 and is_integer(binding["age_ms"]) and
               binding["age_ms"] >= 0 and binding["age_ms"] <= 60_000 and
               binding["expect_world"] == @pre and binding["expect_local"] == @local and
               binding["expect_parent"] == @brick and binding["verified_by"] == "authority"

      assert Command.command(id).binding["inspection_command_id"] == insp
      assert budget() == 0 and not armed_eff?()

      FakeNative.respond(socket, line, adapter, "applied", %{
        "observed" => apply_observed("lift", @pre, @target, @target),
        "frame" => 20_000,
        "mission_generation" => @gen
      })

      assert wait(fn -> Command.command(id).status == :applied end)

      # a second lift on the same inspection: the budget refuses it first
      arm_eff(adapter)

      assert %{reply: {:error, {:transform_budget_exhausted, ^id}}, transmitted: nil} =
               attempt(socket, fn -> lift(%{}, inspection_command_id: insp) end)

      FakeNative.close(socket)
    end

    @tag max_age_ms: 400
    test "an inspection that expires or is invalidated after the facade checked it is refused at the authority",
         %{port: port} do
      {socket, adapter, _} = v2_peer(port)
      insp = inspect_exact(socket, adapter, @pre, 19_000)
      arm_eff(adapter)

      # the facade-side view (the operator tool's local guard) found it qualifying moments ago
      assert Command.command(insp).status == :applied
      Process.sleep(500)

      assert %{reply: {:error, :inspection_stale}, transmitted: nil} =
               attempt(socket, fn -> lift(%{}, inspection_command_id: insp) end)

      # invalidated by a link loss: the arming goes with the link; after a reconnect and a new
      # arming the old inspection is not this link's
      fresh = inspect_exact(socket, adapter, @pre, 19_100)
      FakeNative.close(socket)
      assert wait(fn -> Command.status().trust.transport == :none end)
      {socket2, ^adapter, _} = v2_peer(port, adapter_id: adapter)
      arm_eff(adapter)

      assert %{reply: {:error, :inspection_link_not_current}, transmitted: nil} =
               attempt(socket2, fn -> lift(%{}, inspection_command_id: fresh) end)

      assert budget() == 1
      FakeNative.close(socket2)
    end
  end

  # A lift carried to `applied`, a later inspection holding its target, a fresh effectful arming:
  # the state in which the native ledger would accept the restoration of the original matrix.
  defp restorable(port) do
    {socket, adapter, _} = v2_peer(port)
    insp0 = inspect_exact(socket, adapter, @pre, 19_000)
    arm_eff(adapter)
    lift_id = applied_lift(socket, adapter, insp0)
    held = inspect_exact(socket, adapter, @target, 20_300)
    %{socket: socket, adapter: adapter, insp0: insp0, lift_id: lift_id, held: held}
  end

  # The forger's call: binding metadata asserted by the caller instead of an inspection id.
  defp forged(socket, lift_id, binding, params \\ nil) do
    attempt(socket, fn ->
      direct_restore(lift_id,
        params: params || restore_params(lift_id),
        reversal_inspection: binding
      )
    end)
  end

  describe "finding B — restoration at the authority boundary" do
    test "an empty binding map asserted by the caller is refused before transmission, although the matrix is exactly the one the native ledger would accept",
         %{port: port} do
      %{socket: socket, adapter: adapter, lift_id: lift_id} = restorable(port)
      arm_eff(adapter)

      assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
               forged(socket, lift_id, %{})

      assert armed_eff?()
      FakeNative.close(socket)
    end

    test "a plausible binding with false frame and age claims is refused before transmission", %{
      port: port
    } do
      %{socket: socket, adapter: adapter, lift_id: lift_id, held: held} = restorable(port)
      arm_eff(adapter)

      assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
               forged(socket, lift_id, %{
                 inspection_command_id: held,
                 frame: 999_999,
                 age_ms: 0,
                 later_class: :held
               })

      assert armed_eff?()
      FakeNative.close(socket)
    end

    test "a string-keyed binding claiming verified: true is refused, and so is a fabricated binding beside a genuinely qualifying inspection id",
         %{port: port} do
      %{socket: socket, adapter: adapter, lift_id: lift_id, held: held} = restorable(port)
      arm_eff(adapter)

      assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
               forged(socket, lift_id, %{"inspection_command_id" => held, "verified" => true})

      assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
               attempt(socket, fn ->
                 direct_restore(lift_id,
                   inspection_command_id: held,
                   reversal_inspection: %{inspection_command_id: held}
                 )
               end)

      # no binding and no inspection id at all
      assert %{reply: {:error, :inspection_command_id_required}, transmitted: nil} =
               attempt(socket, fn -> direct_restore(lift_id, []) end)

      assert armed_eff?()
      FakeNative.close(socket)
    end

    test "the correct original with a substituted target or mismatching expected words is refused, forged or inspection-bound",
         %{port: port} do
      %{socket: socket, adapter: adapter, insp0: insp0, lift_id: lift_id, held: held} =
        restorable(port)

      arm_eff(adapter)
      substituted = String.replace(@pre, "bfc5099e", "c1200000")

      # the forger's substituted target
      assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
               forged(
                 socket,
                 lift_id,
                 %{inspection_command_id: held, frame: 20_300, age_ms: 10, later_class: :held},
                 %{restore_params(lift_id) | "target_world" => substituted}
               )

      for {params, reason} <- [
            {%{restore_params(lift_id) | "target_world" => substituted},
             {:expectation_mismatch, "target_world"}},
            {%{restore_params(lift_id) | "expect_world" => @twin},
             {:expectation_mismatch, "expect_world"}},
            {%{restore_params(lift_id) | "expect_local" => @hero_local},
             {:expectation_mismatch, "expect_local"}},
            {%{restore_params(lift_id) | "expect_parent" => "none"},
             {:expectation_mismatch, "expect_parent"}},
            {%{restore_params(lift_id) | "restore_of" => insp0}, :restore_requires_plan}
          ] do
        assert %{reply: {:error, ^reason}, transmitted: nil} =
                 attempt(socket, fn ->
                   direct_restore(lift_id, params: params, inspection_command_id: held)
                 end)
      end

      # a wrong original id: an inspection is not a lift
      assert %{reply: {:error, :restore_of_not_a_lift}, transmitted: nil} =
               attempt(socket, fn ->
                 direct_restore(insp0, params: restore_params(insp0), inspection_command_id: held)
               end)

      assert %{reply: {:error, {:generation_mismatch, @gen}}, transmitted: nil} =
               attempt(socket, fn ->
                 direct_restore(lift_id,
                   inspection_command_id: held,
                   preconditions: %{"mission_generation" => "other"}
                 )
               end)

      assert armed_eff?()
      FakeNative.close(socket)
    end

    test "a pre-lift (copied) inspection, an unknown or wrong-type id, drift and a dirty cache never bind a direct authority restore",
         %{port: port} do
      %{socket: socket, adapter: adapter, insp0: insp0, lift_id: lift_id} = restorable(port)

      drifted =
        inspect_exact(socket, adapter, String.replace(@target, "bfa5099e", "bf000000"), 20_400)

      dirty =
        inspect_exact(socket, adapter, @target, 20_450,
          overrides: %{"cand_dirty" => field("observed", true)}
        )

      arm_eff(adapter)

      # the forger copies the pre-lift inspection's id into a binding with a later frame
      assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
               forged(socket, lift_id, %{
                 inspection_command_id: insp0,
                 frame: 20_300,
                 age_ms: 5,
                 later_class: :held
               })

      for {id, reason} <- [
            {Schema.uuid4(), :inspection_not_in_journal},
            {insp0, :inspection_not_later},
            {lift_id, :not_an_exact_inspection},
            {drifted, {:state_drifted, :drifted}},
            {dirty, :inspection_cache_dirty}
          ] do
        assert %{reply: {:error, ^reason}, transmitted: nil} =
                 attempt(socket, fn -> direct_restore(lift_id, inspection_command_id: id) end)
      end

      assert armed_eff?()
      FakeNative.close(socket)
    end

    @tag max_age_ms: 400
    test "a binding the facade prepared is not reusable once its inspection is stale", %{
      port: port
    } do
      %{socket: socket, adapter: adapter, lift_id: lift_id, held: held} = restorable(port)
      arm_eff(adapter)

      # the facade's own pure check, as the facade performs it, passes now…
      %{path: path, elapsed_ms: elapsed} = Journal.status()
      {:ok, plan} = TransformRestore.plan(path, lift_id, record: Command.command(lift_id))
      {:ok, read} = Journal.read(path)

      assert {:ok, binding} =
               TransformRestore.verify_inspection(read.entries, plan, held,
                 now_mono_ms: elapsed,
                 link_generation: Command.status().link.generation,
                 max_age_ms: 400
               )

      Process.sleep(500)

      # …and is not authority by the time the authority issues: neither the prepared binding…
      assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
               forged(
                 socket,
                 lift_id,
                 Map.take(binding, [:inspection_command_id, :frame, :age_ms, :later_class])
               )

      # …nor the inspection it named
      assert %{reply: {:error, :inspection_stale}, transmitted: nil} =
               attempt(socket, fn -> direct_restore(lift_id, inspection_command_id: held) end)

      assert armed_eff?()
      FakeNative.close(socket)
    end

    test "a valid planned restoration after a new qualifying inspection is accepted with the authority's own binding and canonical parameters",
         %{port: port} do
      %{socket: socket, adapter: adapter, lift_id: lift_id, held: held} = restorable(port)
      arm_eff(adapter)

      # the authority fills what the caller omits from the plan and the inspection
      assert %{reply: {:ok, rid}, transmitted: line} =
               attempt(socket, fn ->
                 direct_restore(lift_id,
                   params: %{"mode" => "restore", "restore_of" => lift_id},
                   inspection_command_id: held
                 )
               end)

      assert line["params"] == restore_params(lift_id)
      accepted = accepted_entry(rid)
      assert accepted["params"] == line["params"] and accepted["reversal_of"] == lift_id
      b = accepted["inspection_binding"]

      assert b["inspection_command_id"] == held and b["frame"] == 20_300 and
               b["command_frame"] == 20_000 and b["later_class"] == "held" and
               b["restore_of"] == lift_id and b["target_world"] == @pre and
               b["verified_by"] == "authority"

      assert accepted["reversal_inspection"]["inspection_command_id"] == held and
               accepted["reversal_inspection"]["later_class"] == "held"

      assert Command.command(rid).reversal_of == lift_id and budget() == 0
      FakeNative.close(socket)
    end

    test "the facade's restoration goes through the same authority check", %{port: port} do
      %{socket: socket, adapter: adapter, lift_id: lift_id, held: held} = restorable(port)
      arm_eff(adapter)

      assert %{reply: {:ok, rid}, transmitted: line} =
               attempt(socket, fn ->
                 Command.restore_candidate(lift_id,
                   inspection_command_id: held,
                   expected_generation: @gen
                 )
               end)

      assert line["params"] == restore_params(lift_id)
      assert accepted_entry(rid)["inspection_binding"]["verified_by"] == "authority"
      FakeNative.close(socket)
    end

    test "already at baseline transmits no restoration, forged or inspection-bound, directly or through the facade",
         %{port: port} do
      %{socket: socket, adapter: adapter, lift_id: lift_id} = restorable(port)
      back = inspect_exact(socket, adapter, @pre, 20_400)

      near =
        inspect_exact(socket, adapter, String.replace(@target, "bfa5099e", "bfa5099f"), 20_450)

      arm_eff(adapter)

      assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
               forged(socket, lift_id, %{inspection_command_id: back, frame: 20_400, age_ms: 1})

      assert %{reply: {:error, :already_at_baseline}, transmitted: nil} =
               attempt(socket, fn -> direct_restore(lift_id, inspection_command_id: back) end)

      assert %{reply: {:error, :already_at_baseline}, transmitted: nil} =
               attempt(socket, fn ->
                 Command.restore_candidate(lift_id,
                   inspection_command_id: back,
                   expected_generation: @gen
                 )
               end)

      assert %{reply: {:error, {:state_drifted, :near_target}}, transmitted: nil} =
               attempt(socket, fn -> direct_restore(lift_id, inspection_command_id: near) end)

      assert armed_eff?()
      FakeNative.close(socket)
    end

    test "an uncertain lift is never restorable at the authority, forged or inspection-bound", %{
      port: port
    } do
      {socket, adapter, _} = v2_peer(port)
      insp0 = inspect_exact(socket, adapter, @pre, 19_000)
      arm_eff(adapter)
      assert {:ok, id} = lift(@expect, inspection_command_id: insp0)
      assert {:ok, cmd} = FakeNative.recv(socket)
      off = String.replace(@target, "bfa5099e", "bfa5099f")

      FakeNative.respond(socket, cmd, adapter, "applied", %{
        "observed" => apply_observed("lift", @pre, @target, off),
        "frame" => 20_000,
        "mission_generation" => @gen
      })

      assert wait(fn -> Command.command(id).status == :applied end)
      later = inspect_exact(socket, adapter, off, 20_300)
      arm_eff(adapter)
      params = %{restore_params(id) | "expect_world" => off}

      assert %{reply: {:error, :caller_binding_not_accepted}, transmitted: nil} =
               forged(
                 socket,
                 id,
                 %{inspection_command_id: later, frame: 20_300, age_ms: 1},
                 params
               )

      assert %{reply: {:error, :effect_uncertain}, transmitted: nil} =
               attempt(socket, fn ->
                 direct_restore(id, params: params, inspection_command_id: later)
               end)

      FakeNative.close(socket)
    end
  end

  describe "retained policies" do
    @tag effectful: false
    test "default-disabled: the binding never makes a transform issuable", %{port: port} do
      {socket, adapter, _} = v2_peer(port)
      insp = inspect_exact(socket, adapter, @pre, 19_000)

      assert %{reply: {:error, :effectful_disabled}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: insp) end)

      FakeNative.close(socket)
    end

    test "disarmed, one-shot arming, journal degradation and link loss are unchanged", %{
      port: port
    } do
      {socket, adapter, _} = v2_peer(port)
      insp = inspect_exact(socket, adapter, @pre, 19_000)

      assert %{reply: {:error, :not_armed_effectful}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: insp) end)

      # one shot: a lift the peer refuses consumes the arming, not the budget
      arm_eff(adapter)
      assert {:ok, refused} = lift(@expect, inspection_command_id: insp)
      assert {:ok, rcmd} = FakeNative.recv(socket)

      FakeNative.respond(socket, rcmd, adapter, "precondition_failed", %{
        "reason" => "not applied (precondition failed): expect_world_mismatch",
        "frame" => 19_500,
        "mission_generation" => @gen
      })

      assert wait(fn -> Command.command(refused).status == :precondition_failed end)
      refute armed_eff?()
      assert budget() == 1

      assert %{reply: {:error, :not_armed_effectful}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: insp) end)

      # link loss revokes the arming; nothing is issuable without a link (the authority answers
      # :no_link before it reaches the arming)
      arm_eff(adapter)
      FakeNative.close(socket)
      assert wait(fn -> Command.status().trust.transport == :none end)
      refute armed_eff?()
      assert {:error, :no_link} = lift(@expect, inspection_command_id: insp)
    end

    test "journal degradation: a valid binding whose consumption entry cannot be persisted is refused, nothing sent, and the authority stays degraded",
         %{port: port, agent: agent} do
      {socket, adapter, _} = v2_peer(port)
      insp = inspect_exact(socket, adapter, @pre, 19_000)
      arm_eff(adapter)
      CountingWriter.fail_after(agent, 0, :eio)

      assert %{reply: {:error, {:journal_unavailable, :eio}}, transmitted: nil} =
               attempt(socket, fn -> lift(@expect, inspection_command_id: insp) end)

      refute armed_eff?()

      assert %{
               reply: {:error, {:audit_degraded, "authority.effectful_consumed"}},
               transmitted: nil
             } =
               attempt(socket, fn -> lift(@expect, inspection_command_id: insp) end)

      assert budget() == 1
      FakeNative.close(socket)
    end
  end
end

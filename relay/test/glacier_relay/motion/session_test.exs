defmodule GlacierRelay.Motion.SessionTest do
  @moduledoc """
  M7-B1: the motion session and share end to end against the fake native and the in-VM headless
  peer (design sections 15.3–15.8), on loopback: local approval and arming before any effect, the
  stream binding, the native's confirmation, application and close, restoration and its
  eligibility, exclusivity with the M6 transform commands and the budgets, the first uncertainty and
  the critical failures ending application, stall and delayed traffic, audit degradation, link and
  authority loss, and the native's autonomous closes while BEAM's motion process is suspended.
  Every native answer here is **fake-native evidence**; none of it shows what the DLL does.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.{Command, Motion}
  alias GlacierRelay.Command.TransformWords
  alias GlacierRelay.HeadlessPeer
  alias GlacierRelay.HeadlessPeer.Driver
  alias GlacierRelay.Motion.{Course, Hub}
  alias GlacierRelay.Peer.{Connection, Endpoint}
  alias GlacierRelay.Test.{CountingWriter, FakeMotionNative, MotionStack}

  @gen FakeMotionNative.generation()
  @p FakeMotionNative.anchor_words()

  defp wait(fun, attempts \\ 400), do: MotionStack.wait(fun, attempts, 10)
  defp session, do: Hub.status().session
  defp done?, do: match?(%{status: :done}, session())
  defp summary, do: session().summary
  defp registry(sid), do: Enum.find(Command.status().motion.sessions, &(&1.session_id == sid))

  defp applies(fake),
    do: for({:applied, seq, _frame, pos} <- FakeMotionNative.events(fake), do: {seq, pos})

  defp journal_events(name), do: Enum.filter(MotionStack.journal(), &(&1["event"] == name))

  # a course that ends 0.2 m from the anchor (so the candidate is displaced at the close)
  defp away_course do
    {ax, ay} = {TransformWords.to_float(elem(@p, 0)), TransformWords.to_float(elem(@p, 1))}

    Course.build([{:hold, 1_000}, {:line, {ax + 0.2, ay}}, {:hold, 300}],
      origin_words: @p,
      speed_mps: 0.5
    )
  end

  describe "lifecycle" do
    test "share to the sink, then a session from a course: approved, confirmed, applied, closed, released" do
      st = MotionStack.start()
      :ok = MotionStack.arm()

      {:ok, %{share_id: share}} =
        Motion.open_share(
          duration_ms: 1_000,
          expected_generation: @gen,
          label: "B1 fake native — not a game"
        )

      wait(fn -> Driver.status().sink_done != [] end, 500)
      [done | _] = Driver.status().sink_done

      assert done.stream_id == share and done.source_kind == "game" and
               done.label =~ "fake native"

      # nothing relayed was lost on the peer link; a native sample that reached the hub before the
      # authority's confirmation activated the share is dropped there (counted) and shows as a gap
      r = done.reconciliation

      assert r["received"] == r["source_sent"] and r["last_seq_received"] == r["source_last_seq"],
             inspect(done)

      assert r["gaps"] == r["source_last_seq"] - r["source_sent"] and r["gaps"] <= 2
      assert done.received > 10 and done.unqualified == 0

      stream = MotionStack.start_course(MotionStack.short_course())
      {sid, cid} = MotionStack.open_session(st.adapter, stream)
      wait(&done?/0, 800)

      s = summary()
      assert s.close.state == :confirmed and s.close.reason =~ "stream_end"
      assert s.restorable and s.counts.uncertain == 0
      assert s.counts.applied > 5 and s.counts.forwarded == s.counts.applied + s.counts.skipped
      assert s.native_close.clean
      # what the fake applied is exactly what was forwarded and confirmed, in order
      seqs = applies(st.fake) |> Enum.map(&elem(&1, 0))
      assert seqs == Enum.sort(seqs) and length(seqs) == s.counts.applied

      # the journal holds the approval, the binding and the native-confirmed close
      [accepted] = Enum.filter(journal_events("command.accepted"), &(&1["command_id"] == cid))

      assert accepted["motion"]["kind"] == "session_open" and
               accepted["motion"]["source_kind"] == "synthetic"

      assert accepted["motion"]["stream_id"] == stream and
               accepted["inspection_binding"]["verified_by"] == "authority"

      assert accepted["params"]["silence_close_ms"] == 1_000 and
               accepted["params"]["max_speed_mmps"] == 2_000

      assert [%{"summary" => %{"restorable" => true}}] = journal_events("motion.session.closed")

      # exclusivity until released: the course returned to the anchor, so the release is a baseline
      assert registry(sid).state == :closed_clean
      :ok = MotionStack.arm_effectful(st.adapter)
      insp = MotionStack.inspect_exact()

      assert {:error, {:motion_session_not_restored, ^sid, :closed_clean}} =
               Command.step_candidate(%{}, inspection_command_id: insp, expected_generation: @gen)

      assert {:error, :already_at_baseline} =
               Motion.restore_session(sid, inspection_command_id: insp, expected_generation: @gen)

      assert :ok =
               Motion.confirm_baseline(sid,
                 inspection_command_id: insp,
                 expected_generation: @gen
               )

      assert registry(sid).state == :at_baseline
      assert [_] = journal_events("motion.session.at_baseline")
      assert Command.status().motion.exclusivity == :ok
    end

    test "restore of a displaced candidate: the journaled opening preimage, a later inspection, fresh arming" do
      st = MotionStack.start()
      stream = MotionStack.start_course(away_course())
      {sid, cid} = MotionStack.open_session(st.adapter, stream)
      wait(&done?/0, 800)
      assert summary().restorable
      displaced = FakeMotionNative.status(st.fake).world
      assert displaced != FakeMotionNative.pre()

      # an inspection from BEFORE the close does not qualify
      early =
        Command.status().commands
        |> Enum.filter(&(&1.name == "relay.inspect.candidate_transform"))
        |> List.last()

      :ok = MotionStack.arm_effectful(st.adapter)

      assert {:error, :inspection_not_after_close} =
               Motion.restore_session(sid,
                 inspection_command_id: early.id,
                 expected_generation: @gen
               )

      insp = MotionStack.inspect_exact()
      # the arming was consumed by the refused attempt (fail closed): arm again
      _ = MotionStack.arm_effectful(st.adapter)

      {:ok, rid} =
        Motion.restore_session(sid, inspection_command_id: insp, expected_generation: @gen)

      wait(fn -> Command.command(rid).status == :applied end)
      assert registry(sid).state == :restored
      assert FakeMotionNative.status(st.fake).world == FakeMotionNative.pre()
      # M7-B1 correction B: the judgement against the restoration-result contract is journaled
      assert [%{"state" => "restored", "releases" => true, "reasons" => []}] =
               journal_events("motion.session.restore_judged")

      [acc] = Enum.filter(journal_events("command.accepted"), &(&1["command_id"] == rid))
      assert acc["params"]["target_world"] == FakeMotionNative.pre()
      assert acc["params"]["restore_of"] == cid
      assert acc["inspection_binding"]["final_world"] == displaced
      # one restore per session; the budget is not reset
      insp2 = MotionStack.inspect_exact()
      _ = MotionStack.arm_effectful(st.adapter)

      assert {:error, {:session_not_restorable, :restored}} =
               Motion.restore_session(sid,
                 inspection_command_id: insp2,
                 expected_generation: @gen
               )

      # the budget, judged on a fresh live stream (the old one is spent: stream_already_used)
      stream2 = MotionStack.start_course(MotionStack.short_course(prefix_ms: 3_000))

      assert {:error, :stream_already_used} =
               Motion.open_session(
                 inspection_command_id: insp2,
                 expected_generation: @gen,
                 stream_id: stream,
                 source_kind: "synthetic"
               )

      assert {:error, {:motion_session_budget_exhausted, 1}} =
               Motion.open_session(
                 inspection_command_id: insp2,
                 expected_generation: @gen,
                 stream_id: stream2,
                 source_kind: "synthetic"
               )
    end

    test "a candidate moved since the close is not restored over" do
      st = MotionStack.start()
      stream = MotionStack.start_course(away_course())
      {sid, _} = MotionStack.open_session(st.adapter, stream)
      wait(&done?/0, 800)
      # the 'engine' moves the candidate after the close
      :ok =
        FakeMotionNative.set_world(
          st.fake,
          String.replace(FakeMotionNative.status(st.fake).world, "416d47ae", "416d47b0")
        )

      insp = MotionStack.inspect_exact()
      :ok = MotionStack.arm_effectful(st.adapter)

      assert {:error, :candidate_moved_since_close} =
               Motion.restore_session(sid, inspection_command_id: insp, expected_generation: @gen)
    end
  end

  describe "local approval and binding" do
    test "a peer stream alone drives nothing: no session, no target" do
      st = MotionStack.start()
      _stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 300))
      Process.sleep(1_500)
      assert applies(st.fake) == []

      refute Enum.any?(
               FakeMotionNative.events(st.fake),
               &match?({:target_without_session, _, _}, &1)
             )

      assert Hub.status().counts.unrouted_samples > 10
      assert Hub.status().session == nil
    end

    test "opening needs the effectful arming; a refusal transmits nothing and forgets the prepared session" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 3_000))
      insp = MotionStack.inspect_exact()

      assert {:error, :not_armed_effectful} =
               Motion.open_session(
                 inspection_command_id: insp,
                 expected_generation: @gen,
                 stream_id: stream,
                 source_kind: "synthetic"
               )

      assert Hub.status().session == nil

      refute Enum.any?(
               FakeMotionNative.events(st.fake),
               &match?({:command, "candidate.motion.session", _, _, _}, &1)
             )
    end

    test "the approval must match the stream: a wrong source kind or an unknown stream is refused locally" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 3_000))
      insp = MotionStack.inspect_exact()
      :ok = MotionStack.arm_effectful(st.adapter)

      assert {:error, {:source_kind_mismatch, "synthetic"}} =
               Motion.open_session(
                 inspection_command_id: insp,
                 expected_generation: @gen,
                 stream_id: stream,
                 source_kind: "game"
               )

      assert {:error, :stream_not_open} =
               Motion.open_session(
                 inspection_command_id: insp,
                 expected_generation: @gen,
                 stream_id: "00000000-0000-4000-8000-000000000000",
                 source_kind: "synthetic"
               )

      assert {:error, {:limit_out_of_range, :max_speed_mmps, 9_000}} =
               Motion.open_session(
                 inspection_command_id: insp,
                 expected_generation: @gen,
                 stream_id: stream,
                 source_kind: "synthetic",
                 limits: %{max_speed_mmps: 9_000}
               )
    end

    test "a session is bound to one stream: a source restart's new stream never feeds it" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {_sid, _} = MotionStack.open_session(st.adapter, stream)
      # the source restarts: its stream ends (closing the session) and a new one opens
      :ok = Driver.stop_course(:restart)
      wait(&done?/0)
      assert summary().close.reason =~ "stream_end"
      n = length(applies(st.fake))
      _new = MotionStack.start_course(MotionStack.short_course(prefix_ms: 300))
      Process.sleep(1_200)
      assert length(applies(st.fake)) == n
    end

    test "without a bound motion link nothing opens" do
      st = MotionStack.start(bind_motion: false)
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 3_000))
      insp = MotionStack.inspect_exact()
      :ok = MotionStack.arm_effectful(st.adapter)

      assert {:error, :no_bound_motion_link} =
               Motion.open_session(
                 inspection_command_id: insp,
                 expected_generation: @gen,
                 stream_id: stream,
                 source_kind: "synthetic"
               )
    end
  end

  describe "the first uncertainty and critical failures end application" do
    defp failing_run(fault) do
      st = MotionStack.start()
      :ok = FakeMotionNative.fault(st.fake, fault)
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 300))
      {sid, _} = MotionStack.open_session(st.adapter, stream)
      wait(&done?/0, 800)
      {st, sid}
    end

    test "an inexact postimage: no target after it; not restorable" do
      {st, sid} = failing_run({:postimage_mismatch_from_seq, 15})
      s = summary()
      assert s.close.reason == "postimage_mismatch" and s.counts.uncertain == 1
      # the inexact apply is the last one: nothing was sent after it
      [{last, _} | _] = Enum.reverse(applies(st.fake))
      assert last >= 15 and s.unresolved_seq == last
      assert s.counts.applied == length(applies(st.fake)) - 1
      refute s.restorable
      assert registry(sid).state == :closed_unclean
    end

    test "an uncertain post-call result ends at once" do
      {st, _sid} = failing_run({:uncertain_from_seq, 15})
      assert summary().close.reason =~ "uncertain"
      assert summary().counts.uncertain == 1 and summary().unresolved_seq >= 15

      assert applies(st.fake)
             |> Enum.map(&elem(&1, 0))
             |> Enum.all?(&(&1 < summary().unresolved_seq))

      refute summary().restorable
    end

    test "an unexplained change of an untouched word is refused natively, never forced back" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 4_000))
      {_sid, _} = MotionStack.open_session(st.adapter, stream)
      frame = FakeMotionNative.status(st.fake) |> then(fn _ -> :sys.get_state(st.fake).frame end)
      :ok = FakeMotionNative.fault(st.fake, {:z_drift_at_frame, frame + 20})
      wait(&done?/0, 800)
      assert summary().close.reason =~ "untouched_field_changed"
      # the drifted z is still there: nothing wrote it back
      [_, _, _, _, _, _, _, _, _, _, _, z] =
        String.split(FakeMotionNative.status(st.fake).world, ",")

      assert z != "bfc2d6ba"
    end

    test "a native generation change closes natively; BEAM records the native's reason" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 4_000))
      {_sid, _} = MotionStack.open_session(st.adapter, stream)
      frame = :sys.get_state(st.fake).frame
      :ok = FakeMotionNative.fault(st.fake, {:generation_change_at_frame, frame + 30})
      wait(&done?/0, 800)

      assert summary().close.by == :native and summary().close.reason =~ "generation_changed",
             inspect({summary().close, Enum.take(FakeMotionNative.events(st.fake), -4)})
    end

    test "a report that disagrees with the acknowledgements closes" do
      {_st, _sid} = failing_run(:report_disagrees)
      assert summary().close.reason == "report_disagrees"
    end

    test "a report gap closes" do
      {_st, _sid} = failing_run({:skip_report, 1})
      assert summary().close.reason == "report_gap"
    end
  end

  describe "freshness: stalls and delayed traffic" do
    test "delayed traffic held in the transport is never played out after a stall" do
      st = MotionStack.start()

      stream =
        MotionStack.start_course(
          MotionStack.short_course(prefix_ms: 300, distance_m: 0.4, hold_ms: 1_500)
        )

      {_sid, _} = MotionStack.open_session(st.adapter, stream)
      Process.sleep(300)
      # the game host's peer connection stops reading: samples pile up in the TLS and socket
      # buffers and in the headless sender's queue while the hub's stall timer runs
      %{pid: conn} = Endpoint.status(GlacierRelay.Motion.PeerEndpoint).connection
      :sys.suspend(conn)
      wait(&done?/0, 400)
      applied_at_stall = length(applies(st.fake))
      assert summary().close.reason == "stall"
      :sys.resume(conn)
      Process.sleep(800)
      # the backlog arrived and was refused, none of it reached the native
      assert length(applies(st.fake)) == applied_at_stall
      assert Hub.status().counts.unrouted_samples + summary().counts.refused.not_open >= 1
    end

    test "the native stops on its own while BEAM's motion hub is suspended" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {sid, _} = MotionStack.open_session(st.adapter, stream)
      Process.sleep(200)
      :sys.suspend(Process.whereis(Hub))

      # with the hub suspended no target is sent; the motion link's reader then gives up on the hub
      # (500 ms) and drops the link, and the fake closes on that loss — or on target silence
      wait(
        fn ->
          Enum.any?(FakeMotionNative.events(st.fake), &match?({:session_closed, ^sid, _, _}, &1))
        end,
        300
      )

      [{:session_closed, ^sid, reason, _}] =
        for {:session_closed, ^sid, _, _} = e <- FakeMotionNative.events(st.fake), do: e

      assert reason in ["motion_link_lost", "target_silence"]
      :sys.resume(Process.whereis(Hub))
    end

    test "the native closes at the session's duration on its own clock" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {sid, _} = MotionStack.open_session(st.adapter, stream, limits: %{duration_ms: 1_000})
      wait(&done?/0, 400)

      assert Enum.any?(
               FakeMotionNative.events(st.fake),
               &match?({:session_closed, ^sid, _, _}, &1)
             )

      assert summary().close.state == :confirmed
    end
  end

  describe "close" do
    test "close works with a command in flight and needs no arming" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {_sid, _} = MotionStack.open_session(st.adapter, stream)
      :ok = FakeMotionNative.fault(st.fake, :hold_commands)
      {:ok, insp} = Command.inspect_candidate_transform()
      assert Command.status().in_flight.id == insp
      assert :ok = Motion.close_session(:operator)
      wait(&done?/0)
      assert summary().close.state == :confirmed and summary().close.reason == "operator"
    end

    test "close works with a degraded audit; the degradation itself closes the session" do
      {:ok, agent} = CountingWriter.start()
      st = MotionStack.start(command: [writer: {CountingWriter, agent}])
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {sid, _} = MotionStack.open_session(st.adapter, stream)
      CountingWriter.fail_after(agent, 0)

      # the next journal entry (the hub's next event, an inspection's acceptance) degrades the audit
      _ = Command.inspect_candidate_transform()
      wait(&done?/0, 400)
      assert summary().close.reason == "audit_degraded" and summary().close.state == :confirmed
      # the close could not be journaled: the session is never restorable from lost history
      assert registry(sid).state == :open
      assert {:error, {:audit_degraded, _}} = Command.arm_effectful([])
    end

    test "an unanswered close becomes unknown and the motion link is dropped" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {sid, _} = MotionStack.open_session(st.adapter, stream)
      :ok = FakeMotionNative.fault(st.fake, :stop_reading_motion)
      :ok = FakeMotionNative.fault(st.fake, :mute_motion)
      assert :ok = Motion.close_session(:operator)
      wait(&done?/0, 300)
      assert summary().close.state == :unknown
      wait(fn -> Hub.status().link == nil end)
      wait(fn -> registry(sid).state == :close_unknown end)
      refute summary().restorable
    end

    test "peer-link loss closes the session; the native confirms" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {_sid, _} = MotionStack.open_session(st.adapter, stream)
      %{pid: conn} = Endpoint.status(HeadlessPeer.endpoint()).connection
      Connection.close(%{connection: conn}, :test)
      wait(&done?/0)
      assert summary().close.reason == "peer_link_lost" and summary().close.state == :confirmed
    end

    test "command-link loss drops the motion link; the close is unknown; the native closes on its own" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {sid, _} = MotionStack.open_session(st.adapter, stream)
      :ok = FakeMotionNative.drop_command(st.fake)
      wait(&done?/0)
      assert summary().close.state == :unknown

      assert Enum.any?(
               FakeMotionNative.events(st.fake),
               &match?({:session_closed, ^sid, _, _}, &1)
             )

      wait(fn -> registry(sid).state == :close_unknown end)
      assert Command.status().motion.link == nil
    end
  end

  describe "exclusivity and budgets" do
    test "an unrestored M6 forward refuses a motion open" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      insp = MotionStack.inspect_exact()
      :ok = MotionStack.arm_effectful(st.adapter)

      {:ok, step} =
        Command.step_candidate(%{}, inspection_command_id: insp, expected_generation: @gen)

      wait(fn -> Command.command(step).status == :applied end)
      insp2 = MotionStack.inspect_exact()
      :ok = MotionStack.arm_effectful(st.adapter)

      assert {:error, {:m6_forward_unrestored, ^step}} =
               Motion.open_session(
                 inspection_command_id: insp2,
                 expected_generation: @gen,
                 stream_id: stream,
                 source_kind: "synthetic"
               )
    end

    test "an open session refuses M6 forwards and restores; two sessions need the first restored" do
      st = MotionStack.start(max_sessions: 2)
      stream = MotionStack.start_course(away_course())
      {sid, _} = MotionStack.open_session(st.adapter, stream)
      insp = MotionStack.inspect_exact()
      :ok = MotionStack.arm_effectful(st.adapter)

      assert {:error, {:motion_session_not_restored, ^sid, :open}} =
               Command.step_candidate(%{}, inspection_command_id: insp, expected_generation: @gen)

      # v1 and v2 restores straight to the authority: the motion exclusivity is its first transform
      # check, before any plan, binding or parameter (the facade's own journal plan would refuse a
      # made-up original earlier)
      for version <- [1, 2] do
        assert {:error, {:motion_session_not_restored, ^sid, :open}} =
                 Command.Authority.issue(
                   "candidate.transform.set",
                   version,
                   %{"mode" => "restore", "restore_of" => "00000000-0000-4000-8000-000000000000"},
                   inspection_command_id: insp,
                   reversal_of: "00000000-0000-4000-8000-000000000000",
                   preconditions: %{"mission_generation" => @gen}
                 )
      end

      wait(&done?/0, 800)
      stream2 = MotionStack.start_course(MotionStack.short_course(prefix_ms: 3_000))
      insp2 = MotionStack.inspect_exact()
      _ = MotionStack.arm_effectful(st.adapter)

      assert {:error, {:earlier_session_not_restored, ^sid, :closed_clean}} =
               Motion.open_session(
                 inspection_command_id: insp2,
                 expected_generation: @gen,
                 stream_id: stream2,
                 source_kind: "synthetic"
               )
    end

    test "an authority restart ends the run's motion commands: the old session is unknown to it" do
      st = MotionStack.start()
      stream = MotionStack.start_course(away_course())
      {sid, _} = MotionStack.open_session(st.adapter, stream)
      wait(&done?/0, 800)
      Process.exit(Process.whereis(Command.Authority), :kill)

      wait(fn ->
        try do
          Command.status().motion.sessions == [] and Motion.enabled?()
        catch
          :exit, _ -> false
        end
      end)

      assert {:error, _} =
               Motion.restore_session(sid,
                 inspection_command_id: "00000000-0000-4000-8000-000000000000",
                 expected_generation: @gen
               )
    end
  end

  test "the share labels dirty samples; the sink counts them unqualified" do
    st = MotionStack.start()
    :ok = FakeMotionNative.fault(st.fake, {:dirty_hero_seq, 3})
    :ok = MotionStack.arm()
    {:ok, %{share_id: share}} = Motion.open_share(duration_ms: 1_000, expected_generation: @gen)
    wait(fn -> Driver.status().sink_done != [] end, 500)
    [done | _] = Driver.status().sink_done
    assert done.stream_id == share and done.unqualified == 1
  end
end

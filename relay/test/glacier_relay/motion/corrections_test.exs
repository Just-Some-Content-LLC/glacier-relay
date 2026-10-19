defmodule GlacierRelay.Motion.CorrectionsTest do
  @moduledoc """
  M7-B1: the verifier's findings on the draft bfe69d6 (m7b1-offline\\verifier-report-attempt2.txt), each
  as a test of its correction — trace or audit loss while an open is in flight (A), close while the
  open is in flight and uncertain opens (B), the authority-restart latch (C), the session's own
  mission generation for a restore (D), restorability after a disagreement (E), the share's close
  states (F), a baseline release without a command link (G), the headless source's spacing (I), one
  session per stream (J), the motion-link cap (K), inline keys (L), the RTT's own clock (M) and the
  session budget's validation (O). Fake-native evidence only.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.{Command, Motion}
  alias GlacierRelay.Command.{Listener, TransformWords}
  alias GlacierRelay.HeadlessPeer.Driver
  alias GlacierRelay.Motion.{Course, Destination, Hub, Source}
  alias GlacierRelay.Peer.{Codec, Endpoint, TLS}
  alias GlacierRelay.Test.{CountingWriter, FakeMotionNative, MotionStack, PeerCredentials}

  @gen FakeMotionNative.generation()
  @p FakeMotionNative.anchor_words()

  defp wait(fun, attempts \\ 400), do: MotionStack.wait(fun, attempts, 10)
  defp done?, do: match?(%{status: :done}, Hub.status().session)
  defp summary, do: Hub.status().session.summary
  defp applies(fake), do: for({:applied, _, _, _} = a <- FakeMotionNative.events(fake), do: a)
  defp registry(sid), do: Enum.find(Command.status().motion.sessions, &(&1.session_id == sid))

  # inspect and arm, then inject the fault (it must not touch the inspection), then open
  defp open_async(st, stream, fault, opts \\ []) do
    insp = MotionStack.inspect_exact()
    :ok = MotionStack.arm_effectful(st.adapter)
    :ok = FakeMotionNative.fault(st.fake, fault)

    {:ok, %{session_id: sid, command_id: cid}} =
      Motion.open_session(
        Keyword.merge(
          [
            inspection_command_id: insp,
            expected_generation: @gen,
            stream_id: stream,
            source_kind: "synthetic"
          ],
          opts
        )
      )

    {sid, cid}
  end

  describe "A: trace or audit loss" do
    test "audit degraded while the open is in flight: the session activates closed; nothing applied" do
      {:ok, agent} = CountingWriter.start()
      st = MotionStack.start(command: [writer: {CountingWriter, agent}])
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {_sid, _} = open_async(st, stream, {:delay_commands, 300})
      # the open is accepted and transmitted; its terminal will not be journaled
      CountingWriter.fail_after(agent, 0)
      wait(&done?/0)
      assert summary().close.reason == "audit_degraded" and summary().close.state == :confirmed
      assert summary().counts.forwarded == 0
      assert applies(st.fake) == []
    end

    test "the trace reaching its bound during a session closes it; nothing is sent after" do
      st = MotionStack.start(motion_extra: [trace_max_records: 60])
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {_sid, _} = MotionStack.open_session(st.adapter, stream)
      wait(&done?/0)
      assert summary().close.reason == "trace_unhealthy"
      n = length(applies(st.fake))
      Process.sleep(400)
      assert length(applies(st.fake)) == n
      refute Hub.status().trace_ok
      assert Hub.status().counts.trace_dropped > 0

      assert {:error, :trace_unhealthy} =
               Motion.open_share(duration_ms: 1_000, expected_generation: @gen)
    end
  end

  describe "B: close and uncertain opens" do
    test "a close requested while the open is in flight is applied at activation" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {_sid, _} = open_async(st, stream, {:delay_commands, 300})
      assert :ok = Motion.close_session(:operator)
      wait(&done?/0)
      assert summary().close.reason == "operator" and summary().close.state == :confirmed
      assert applies(st.fake) == []
    end

    test "an open whose answer never comes is ended on the motion link; the native confirms" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      {sid, cid} = open_async(st, stream, :swallow_results)
      wait(fn -> Command.command(cid).status == :unknown end)
      wait(&done?/0)

      assert summary().close.reason == "open_unknown" and summary().close.state == :confirmed,
             inspect({summary(), Enum.take(FakeMotionNative.events(st.fake), -5)})

      assert Enum.any?(
               FakeMotionNative.events(st.fake),
               &match?({:session_closed, ^sid, "beam:open_unknown", _}, &1)
             )

      # still never released: the open's outcome is unknown, and the close is not restorable
      refute summary().restorable
      assert registry(sid).state == :open_unknown

      assert {:error, {:motion_session_not_restored, ^sid, :open_unknown}} =
               Command.status().motion.exclusivity
    end

    test "a native close that arrives before the open's terminal is honoured at activation" do
      st = MotionStack.start()
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 5_000))
      # the terminal waits 1.2 s; the native's 1 s silence close comes first
      {_sid, cid} = open_async(st, stream, {:delay_terminal, 1_200}, ttl_ms: 1_000)
      wait(fn -> Command.command(cid).status == :applied end)
      wait(&done?/0)
      assert summary().close.by == :native and summary().close.state == :confirmed
      assert summary().close.reason =~ "target_silence"
    end
  end

  test "C: an authority restart latches motion and transform entries until the node restarts" do
    st = MotionStack.start()
    Process.exit(Process.whereis(Command.Authority), :kill)

    wait(fn ->
      try do
        Command.status().motion.restart_latched and Motion.enabled?()
      catch
        :exit, _ -> false
      end
    end)

    assert Command.status().motion.authority_starts == 2
    _ = st
    # (a new command link would be needed for any command; the latch refuses before that matters)
    assert {:error, {:authority_restarted, 2}} =
             Command.Authority.issue("player.pose.share", 1, %{}, [])

    assert {:error, {:authority_restarted, 2}} =
             Command.Authority.issue("candidate.transform.set", 2, %{}, [])

    assert {:error, {:authority_restarted, 2}} =
             Command.Authority.issue("candidate.motion.session", 1, %{}, [])

    assert Enum.any?(MotionStack.journal(), &(&1["event"] == "motion.restart_latched"))
  end

  test "D: a restore is judged on the session's own mission generation" do
    st = MotionStack.start()
    {ax, ay} = {TransformWords.to_float(elem(@p, 0)), TransformWords.to_float(elem(@p, 1))}

    away =
      Course.build([{:hold, 1_000}, {:line, {ax + 0.2, ay}}, {:hold, 300}],
        origin_words: @p,
        speed_mps: 0.5
      )

    stream = MotionStack.start_course(away)
    {sid, _} = MotionStack.open_session(st.adapter, stream)
    wait(&done?/0, 800)
    other = "2516099488895124067-00000000-0000-4000-8000-000000000000"
    :ok = FakeMotionNative.set_generation(st.fake, other)
    :ok = MotionStack.arm()
    {:ok, insp} = Command.inspect_candidate_transform()
    wait(fn -> Command.command(insp).status == :applied end)
    :ok = MotionStack.arm_effectful(st.adapter)

    assert {:error, :inspection_generation_not_the_sessions} =
             Motion.restore_session(sid, inspection_command_id: insp, expected_generation: other)
  end

  describe "E: restorability" do
    defp e_session do
      {:ok, l} = Destination.limits(%{})
      pre = FakeMotionNative.pre()

      Destination.new(%{
        session_id: "6b9c8f0e-3d1a-4c2b-9e7f-0a1b2c3d4e5f",
        stream_id: "s",
        limits: l,
        opening_world: pre,
        opened_at: 0
      })
    end

    defp closed(applied, last),
      do: %{
        reason: "beam:x",
        native_mono_ms: 1,
        clean: true,
        final_world: FakeMotionNative.pre(),
        last_applied_seq: last,
        applied: applied
      }

    test "a close on a report disagreement is never restorable, whatever the native reports" do
      st = e_session()

      rep = %{
        report_seq: 1,
        native_mono_ms: 1,
        frame: 1,
        received: 0,
        applied: 1,
        skipped: 0,
        refused: 0,
        uncertain: 0,
        superseded: 0,
        last_applied_seq: 0
      }

      {st, _} = Destination.report(st, rep, 10)
      {st, _} = Destination.native_closed(st, closed(0, 0), 20)
      refute Destination.summary(st).restorable
    end

    test "the native's close counts must agree with the acknowledgements" do
      {st, _} = Destination.close(e_session(), :operator, 10)
      {st2, _} = Destination.native_closed(st, closed(1, 7), 20)
      refute Destination.summary(st2).restorable
      {st3, _} = Destination.native_closed(st, closed(0, 0), 20)
      assert Destination.summary(st3).restorable
    end
  end

  test "F: a share close that is never answered becomes unknown after 1,000 ms (pure)" do
    src =
      Source.new(%{
        share_id: "2a3b4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d",
        interval_ms: 50,
        duration_ms: 10_000,
        opened_at: 0
      })

    {src, a} = Source.close(src, :operator, 100)
    assert {:send_share_close, :operator} in a

    refute Enum.any?(a, &match?({:send_peer, "stream.end", _}, &1)),
           "a stream never announced is not ended"

    {src, _} = Source.close_transmitted(src, 101)
    assert src.close.state == :transmitted
    assert Source.next_deadline(src) == 1_100
    {src, a} = Source.tick(src, 1_100)
    assert src.close.state == :unknown and {:drop_link, :share_close_unconfirmed} in a
  end

  test "G: a baseline release with no command link refuses instead of crashing the authority" do
    st = MotionStack.start()
    stream = MotionStack.start_course(MotionStack.short_course())
    {sid, _} = MotionStack.open_session(st.adapter, stream)
    wait(&done?/0, 800)
    insp = MotionStack.inspect_exact()
    pid = Process.whereis(Command.Authority)
    :ok = FakeMotionNative.drop_command(st.fake)
    wait(fn -> Command.status().link == nil end)

    assert {:error, :no_token_verified_link} =
             Motion.confirm_baseline(sid, inspection_command_id: insp, expected_generation: @gen)

    assert Process.whereis(Command.Authority) == pid
  end

  test "I: the headless source sends at most one sample per 45 ms per stream; overdue ones are dropped" do
    _st = MotionStack.start()

    {:ok, _} =
      Driver.start_course(Course.out_and_back(@p, prefix_ms: 600, distance_m: 0.1),
        label: "spacing"
      )

    Process.sleep(100)
    :sys.suspend(Process.whereis(Driver))
    Process.sleep(300)
    :sys.resume(Process.whereis(Driver))
    wait(fn -> Driver.status().sources_done != [] end, 600)
    [done] = Driver.status().sources_done
    assert done.spaced > 0
    assert Hub.status().peer != nil
  end

  test "J: a stream bound once is never bound to a second session" do
    st = MotionStack.start(max_sessions: 2)
    stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 8_000))
    {sid, _} = MotionStack.open_session(st.adapter, stream)
    :ok = Motion.close_session(:operator)
    wait(&done?/0)
    insp = MotionStack.inspect_exact()
    :ok = Motion.confirm_baseline(sid, inspection_command_id: insp, expected_generation: @gen)
    _ = MotionStack.arm_effectful(st.adapter)
    insp2 = MotionStack.inspect_exact()

    assert {:error, :stream_already_used} =
             Motion.open_session(
               inspection_command_id: insp2,
               expected_generation: @gen,
               stream_id: stream,
               source_kind: "synthetic"
             )
  end

  test "K: at most two motion-link processes, bound or not" do
    _st = MotionStack.start(bind_motion: false)
    port = GlacierRelay.Motion.Listener.port()
    socks = for _ <- 1..3, do: FakeMotionNative.connect_line(port)
    Process.sleep(100)
    results = for s <- socks, do: :gen_tcp.recv(s, 0, 300)
    # the third connection is closed at once; the two others wait for their hello
    assert Enum.count(results, &(&1 == {:error, :closed})) == 1
    assert Enum.count(results, &(&1 == {:error, :timeout})) == 2
  end

  test "L: an inline private key is accepted only through a function" do
    c = PeerCredentials.pair()
    assert {:error, :inline_key_only_through_a_function} = TLS.credentials(c.host)
    assert {:ok, _} = TLS.credentials(fn -> c.host end)
    dir = Path.join(System.tmp_dir!(), "glacier-relay-l-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    assert {:ok, _} = TLS.credentials(PeerCredentials.write_files(c.host, dir, "h"))
  end

  test "M: an RTT is computed from this node's own send time, never the peer's echo" do
    st = MotionStack.start(headless: false, peer_port: 1)
    _ = st
    # a raw headless 'peer' that answers pings with a forged echo
    c = PeerCredentials.pair()

    {:ok, ls} =
      :ssl.listen(
        0,
        TLS.listen_options(elem(TLS.credentials(fn -> c.headless end), 1), {127, 0, 0, 1})
      )

    {:ok, {_, port}} = :ssl.sockname(ls)

    start_supervised!(
      {Endpoint,
       role: :connect,
       name: :m_conn,
       port: port,
       credentials: fn -> c.host end,
       local: %{label: "host-test", client_kind: "game"},
       expected: %{label: "headless-test", client_kind: "headless"},
       handler: {Hub, Hub}},
      id: :m_conn
    )

    {:ok, t} = :ssl.transport_accept(ls, 3_000)
    {:ok, s} = :ssl.handshake(t, 3_000)
    {:ok, _hello} = :ssl.recv(s, 0, 3_000)

    :ok =
      :ssl.send(s, Codec.hello("headless-test", "headless", GlacierRelay.Command.Schema.uuid4()))

    {:ok, ping_line} = :ssl.recv(s, 0, 3_000)
    {:ok, {:ping, ping}} = ping_line |> String.trim() |> Codec.decode()
    :ok = :ssl.send(s, Codec.encode("pong", %{"ping_seq" => ping.ping_seq, "echo_mono_ms" => 0}))
    %{pid: conn} = Endpoint.status(:m_conn).connection
    wait(fn -> GlacierRelay.Peer.Connection.status(conn).last_rtt_ms != nil end)
    rtt = GlacierRelay.Peer.Connection.status(conn).last_rtt_ms
    assert rtt >= 0 and rtt < 1_000
  end

  test "O: the session budget must be an integer 1..4" do
    Process.flag(:trap_exit, true)
    dir = Path.join(System.tmp_dir!(), "glacier-relay-o-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, _} =
             Command.Supervisor.start_link(
               port: 0,
               journal_dir: dir,
               motion: [enabled: true, port: 0, trace_dir: dir, max_sessions: :infinity]
             )

    assert Process.whereis(Listener) == nil
  end
end

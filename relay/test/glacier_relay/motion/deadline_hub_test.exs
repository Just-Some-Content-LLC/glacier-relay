defmodule GlacierRelay.Motion.DeadlineHubTest do
  @moduledoc """
  M7-B1 correction, finding A (the hub): the same deadline rules at the process boundary, with the
  message order controlled rather than guessed. Peer samples are production-decoded
  (`Peer.Codec`) events handed to `Motion.Hub` through its handler API on a stream opened the same
  way (the real headless peer stays connected; nothing else feeds the stream); the fake native and
  the motion socket are real. The order "an event queued before the deadline's timer message,
  processed after the deadline" is made by suspending the hub, checking its mailbox order
  explicitly, and resuming it; the trace delay at the send boundary is a stand-in trace server
  (`Test.TraceProxy`) injected into the hub's state, held and released at chosen times. Evidence is
  socket-level: the fake's log of every `ghost.target` line it read, and the headless sink's
  reconciliation of the `pose.sample` lines it received. Every case first shows a legitimate
  effect before its deadline. Fake-native evidence only.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command.{Schema, TransformWords}
  alias GlacierRelay.HeadlessPeer.Driver
  alias GlacierRelay.Motion
  alias GlacierRelay.Motion.{Clock, Hub}
  alias GlacierRelay.Peer.Codec
  alias GlacierRelay.Test.{FakeMotionNative, MotionStack, TraceProxy}

  @gen FakeMotionNative.generation()
  @p FakeMotionNative.anchor_words()

  defp wait(fun, attempts \\ 400, sleep \\ 10), do: MotionStack.wait(fun, attempts, sleep)
  defp done?, do: match?(%{status: :done}, Hub.status().session)
  defp summary, do: Hub.status().session.summary
  defp dest, do: :sys.get_state(Hub).session.dest

  defp targets(fake),
    do: for({:target_line, _sid, seq, _t} <- FakeMotionNative.events(fake), do: seq)

  defp mailbox(pid), do: elem(Process.info(pid, :messages), 1)
  defp index(msgs, pred), do: Enum.find_index(msgs, pred)
  defp tick?(m), do: m == :tick

  defp sleep_until(t) do
    d = t - Clock.now_ms()
    if d > 0, do: Process.sleep(d)
  end

  defp peer_info, do: :sys.get_state(Hub).peer.info

  defp decode!(line) do
    {:ok, decoded} = Codec.decode(String.trim_trailing(line, "\n"))
    decoded
  end

  # a synthetic stream opened on the hub the way the peer connection opens one
  defp inject_stream do
    id = Schema.uuid4()

    {:stream_open, f} =
      decode!(
        Codec.encode("stream.open", %{
          "stream_id" => id,
          "source_kind" => "synthetic",
          "interval_ms" => 50,
          "src_clock" => "beam",
          "label" => "m7b1 correction: injected test stream",
          "course" => nil
        })
      )

    :ok = Hub.peer_event(Hub, {:stream_open, peer_info(), f}, 1_000)
    id
  end

  # a production-decoded pose.sample `dx` metres from P, stamped with this node's clock
  defp sample(stream, seq, dx) do
    {ax, ay} = {TransformWords.to_float(elem(@p, 0)), TransformWords.to_float(elem(@p, 1))}

    {:pose_sample, f} =
      decode!(
        Codec.encode("pose.sample", %{
          "stream_id" => stream,
          "seq" => seq,
          "src_mono_ms" => Clock.now_ms(),
          "src_frame" => nil,
          "pos" =>
            TransformWords.encode([
              TransformWords.to_word(ax + dx),
              TransformWords.to_word(ay),
              0xBFC2D6BA
            ]),
          "qualified" => true,
          "reason" => nil
        })
      )

    {:sample, peer_info(), f}
  end

  defp inject(event), do: Hub.peer_event(Hub, event, 1_000)

  defp open(st, stream, limits),
    do: MotionStack.open_session(st.adapter, stream, limits: limits)

  test "H-A1: a sample queued before the stall timer but processed after the deadline sends no target" do
    st = MotionStack.start()
    stream = inject_stream()
    {_sid, _} = open(st, stream, %{duration_ms: 20_000, stall_ms: 400})

    # control: a sample before the deadline is forwarded; its bytes reach the native
    :ok = inject(sample(stream, 1, 0.01))
    wait(fn -> summary().counts.applied == 1 end)
    assert targets(st.fake) == [1]

    d = dest()
    deadline = d.last_forward_r + d.limits.stall_ms
    hub = Process.whereis(Hub)
    sleep_until(deadline - 60)
    :sys.suspend(hub)
    task = Task.async(fn -> inject(sample(stream, 2, 0.02)) end)

    queued? = fn m -> match?({:"$gen_call", _, {:peer, {:sample, _, %{seq: 2}}}}, m) end
    wait(fn -> index(mailbox(hub), queued?) != nil end, 200, 2)
    assert Clock.now_ms() < deadline, "the sample was not queued before the deadline"
    wait(fn -> index(mailbox(hub), &tick?/1) != nil end, 200, 2)
    msgs = mailbox(hub)
    assert index(msgs, queued?) < index(msgs, &tick?/1)
    :sys.resume(hub)
    :ok = Task.await(task)
    wait(&done?/0, 300)

    assert targets(st.fake) == [1],
           "target bytes after the stall deadline: #{inspect(targets(st.fake))} #{inspect(summary())}"

    s = summary()
    assert s.close.reason == "stall" and s.counts.refused.not_open == 1
    assert s.counts.forwarded == 1
  end

  test "H-A3: an exact acknowledgement queued before the 200 ms timer but processed after it releases nothing" do
    st = MotionStack.start()
    stream = inject_stream()
    {_sid, _} = open(st, stream, %{duration_ms: 20_000, stall_ms: 400})

    :ok = inject(sample(stream, 1, 0.01))
    wait(fn -> summary().counts.applied == 1 end)
    assert targets(st.fake) == [1]

    # target 2 is applied by the fake, whose motion-link output is then held; target 3 waits
    :ok = FakeMotionNative.fault(st.fake, :hold_motion_out)
    sleep_until(dest().last_forward_r + 60)
    :ok = inject(sample(stream, 2, 0.02))
    wait(fn -> Enum.any?(FakeMotionNative.events(st.fake), &match?({:applied, 2, _, _}, &1)) end)
    :ok = inject(sample(stream, 3, 0.03))
    d = dest()
    assert d.in_flight.seq == 2 and d.pending.seq == 3
    deadline = d.in_flight.r_sent + Motion.Destination.ack_timeout_ms()

    hub = Process.whereis(Hub)
    sleep_until(deadline - 50)
    :sys.suspend(hub)
    assert FakeMotionNative.release_motion_out(st.fake) >= 1

    acked? = fn m ->
      match?({:"$gen_call", _, {:native, _, {:ghost_applied, %{seq: 2}}}}, m)
    end

    wait(fn -> index(mailbox(hub), acked?) != nil end, 200, 2)
    assert Clock.now_ms() < deadline, "the acknowledgement was not queued before the deadline"
    wait(fn -> index(mailbox(hub), &tick?/1) != nil end, 200, 2)
    msgs = mailbox(hub)
    assert index(msgs, acked?) < index(msgs, &tick?/1)
    :sys.resume(hub)
    wait(&done?/0, 300)

    assert targets(st.fake) == [1, 2],
           "a pending target was released by a late answer: #{inspect(targets(st.fake))} #{inspect(summary())}"

    s = summary()
    assert s.close.reason == "ack_timeout"
    assert s.counts.uncertain == 1 and s.counts.applied == 1 and s.unresolved_seq == 2
    assert Map.get(s.counts, :late_acks) == 1
    refute s.restorable
  end

  test "H-A4: a hero sample queued before the share's duration timer but processed after it is never relayed" do
    st = MotionStack.start()
    # the fake keeps sampling past its own duration, so samples reach the hub around BEAM's bound
    :ok = FakeMotionNative.fault(st.fake, {:share_overrun_ms, 600})
    :ok = MotionStack.arm()

    {:ok, %{share_id: share}} =
      Motion.open_share(
        duration_ms: 1_000,
        expected_generation: @gen,
        label: "m7b1 correction — fake native"
      )

    wait(fn -> match?(%{status: :active}, Hub.status().share) end)
    src = :sys.get_state(Hub).share.src
    deadline = src.opened_at + src.duration_ms
    hub = Process.whereis(Hub)
    sleep_until(deadline - 70)
    :sys.suspend(hub)

    hero = fn m -> match?({:"$gen_call", _, {:native, _, {:hero_sample, _}}}, m) end
    wait(fn -> index(mailbox(hub), hero) != nil end, 200, 2)
    assert Clock.now_ms() < deadline, "no hero sample was queued before the deadline"

    k =
      mailbox(hub)
      |> Enum.flat_map(fn
        {:"$gen_call", _, {:native, _, {:hero_sample, hs}}} -> [hs.seq]
        _ -> []
      end)
      |> Enum.min()

    wait(fn -> index(mailbox(hub), &tick?/1) != nil end, 200, 2)
    msgs = mailbox(hub)
    assert index(msgs, hero) < index(msgs, &tick?/1)
    :sys.resume(hub)

    wait(fn -> Enum.any?(Driver.status().sink_done, &(&1.stream_id == share)) end, 500)
    done = Enum.find(Driver.status().sink_done, &(&1.stream_id == share))
    r = done.reconciliation
    # control: the samples relayed before the bound reached the headless peer
    assert done.received >= 10

    assert r["last_seq_received"] == k - 1,
           "sample #{k} (queued before, processed after the bound) reached the peer: #{inspect(done)}"

    sh = Hub.status().share.summary
    assert sh.close.reason == "duration" and sh.counts.not_open >= 1
  end

  test "H-A5: a forward decided before the duration bound whose trace write crosses it sends no bytes" do
    st = MotionStack.start()
    stream = inject_stream()
    {_sid, _} = open(st, stream, %{duration_ms: 1_000, stall_ms: 1_000})
    proxy = start_supervised!({TraceProxy, real: GlacierRelay.Motion.Trace, notify: self()})
    :sys.replace_state(Hub, &%{&1 | trace: proxy})
    deadline = dest().opened_at + 1_000

    forward = fn recs -> Enum.find(recs, &(&1["event"] == "destination.forward")) end

    # control: a forward whose trace write is held briefly and released before the bound is sent
    :ok = TraceProxy.hold_next(proxy, "destination.forward")
    t1 = Task.async(fn -> inject(sample(stream, 1, 0.01)) end)
    assert_receive {:held, recs, _}, 1_000
    assert forward.(recs)["seq"] == 1
    Process.sleep(20)
    :ok = TraceProxy.release(proxy)
    :ok = Task.await(t1)
    wait(fn -> summary().counts.applied == 1 end)
    assert targets(st.fake) == [1]

    # the decision is made before the bound; its required trace write is released after it
    sleep_until(deadline - 60)
    :ok = TraceProxy.hold_next(proxy, "destination.forward")
    t2 = Task.async(fn -> inject(sample(stream, 2, 0.02)) end)
    assert_receive {:held, recs, held_at}, 1_000
    fwd = forward.(recs)
    assert fwd["seq"] == 2 and fwd["beam_mono_ms"] < deadline
    sleep_until(deadline + 15)
    # still inside the hub's 200 ms trace deadline: this is a slow trace, not a lost one
    assert Clock.now_ms() - held_at < 150
    :ok = TraceProxy.release(proxy)
    :ok = Task.await(t2)
    wait(&done?/0, 300)
    :sys.replace_state(Hub, &%{&1 | trace: GlacierRelay.Motion.Trace})

    assert targets(st.fake) == [1],
           "target bytes written after the duration bound: #{inspect(targets(st.fake))} #{inspect(summary())}"

    s = summary()
    assert s.close.reason == "duration" and s.counts.forwarded == 1
    assert Map.get(s.counts, :cancelled_before_send) == 1
  end
end

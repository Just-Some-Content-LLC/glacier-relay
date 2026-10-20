defmodule GlacierRelay.Motion.DeadlineShareHubTest do
  @moduledoc """
  M7-B1 correction, finding A (the hub, a share; added for the verifier's test gap T1): the
  share's send boundary end to end. (1) A sample decided before the share's bound whose required
  trace write (`source.relayed`) is held across the bound by `Test.TraceProxy` is not handed to
  the peer connection, and the stream's end names only what was handed (F1). (2) A sample handed
  to the host's peer connection before the bound, while that connection is suspended, is dropped
  by the connection at the bound (`not_after`) and never reaches the headless peer. Evidence is
  the headless sink's reconciliation and the connection's counters; each case shows the samples
  relayed before the bound arriving. Fake-native evidence only.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.HeadlessPeer.Driver
  alias GlacierRelay.Motion
  alias GlacierRelay.Motion.{Clock, Hub}
  alias GlacierRelay.Peer.{Connection, Endpoint}
  alias GlacierRelay.Test.{FakeMotionNative, MotionStack, TraceProxy}

  @gen FakeMotionNative.generation()

  defp wait(fun, attempts \\ 400, sleep \\ 10), do: MotionStack.wait(fun, attempts, sleep)
  defp mailbox(pid), do: elem(Process.info(pid, :messages), 1)

  defp sleep_until(t) do
    d = t - Clock.now_ms()
    if d > 0, do: Process.sleep(d)
  end

  # a 1 s share whose fake keeps sampling past its own duration; returns the share's bound
  defp share(st) do
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
    {share, src.opened_at + src.duration_ms}
  end

  defp sink_done(share) do
    wait(fn -> Enum.any?(Driver.status().sink_done, &(&1.stream_id == share)) end, 500)
    Enum.find(Driver.status().sink_done, &(&1.stream_id == share))
  end

  # Explicit control of the fake's samples around the bound (the M7-L1 correction; the gate's two
  # failures were this test's own timing assumptions: a hold armed after the last sample decided
  # before the bound, and a sample before k withheld by the share's 45 ms rate guard): from
  # @hold_from ms before the bound the fake's motion lines are held, the hub is seen to have decided
  # every line written before, and exactly ONE held line is released @release_at ms before the
  # bound (and at least 50 ms after the last relayed decision) — so the sample under test is a known
  # one, decided before the bound, whatever the fake's cadence and the test process's wake-ups.
  @hold_from 300
  @release_at 120

  defp hold_fake_output(st) do
    {:ok, n} = FakeMotionNative.hold_motion_out(st.fake)
    # barrier: the hub has decided every sample written before the hold (relayed or refused)
    wait(fn -> :sys.get_state(Hub).share.src.last_seq == n end, 300, 2)
    wait(fn -> FakeMotionNative.status(st.fake).held_motion_out >= 1 end, 300, 2)
    src = :sys.get_state(Hub).share.src
    %{n: n, handed: src.last_handed_seq, last_sent_r: src.last_sent_r}
  end

  defp release_one_before(st, bound, held) do
    sleep_until(max(bound - @release_at, held.last_sent_r + 50))
    assert Clock.now_ms() < bound - 40, "the release came too late to precede the bound"
    1 = FakeMotionNative.release_motion_out(st.fake, 1)
  end

  test "T1: a sample whose trace write is held across the share's bound is not handed over" do
    st = MotionStack.start()
    proxy = start_supervised!({TraceProxy, real: GlacierRelay.Motion.Trace, notify: self()})
    {share, bound} = share(st)
    :sys.replace_state(Hub, &%{&1 | trace: proxy})
    link = Hub.status().link
    %{pid: conn} = Endpoint.status(GlacierRelay.Motion.PeerEndpoint).connection

    sleep_until(bound - @hold_from)
    held = hold_fake_output(st)
    :ok = TraceProxy.hold_next(proxy, "source.relayed")
    release_one_before(st, bound, held)
    assert_receive {:held, recs, held_at}, 1_000
    rel = Enum.find(recs, &(&1["event"] == "source.relayed"))
    k = rel["seq"]
    # the precondition, established: the one released sample, decided before the bound
    assert k == held.n + 1 and rel["beam_mono_ms"] < bound
    sleep_until(bound + 15)
    hold_ms = Clock.now_ms() - held_at
    :ok = TraceProxy.release(proxy)
    # the rest of the fake's samples reach the hub only after the bound
    _ = FakeMotionNative.release_motion_out(st.fake)

    done = sink_done(share)
    :sys.replace_state(Hub, &%{&1 | trace: GlacierRelay.Motion.Trace})
    r = done.reconciliation
    cs = Connection.status(conn).counts

    # the hold left the hub's callers undisturbed (the motion link waits 500 ms for the hub, and the
    # fake wrote nothing more meanwhile): the same motion link and peer connection
    assert Hub.status().link == link and Connection.status(conn).phase == :identified,
           "the #{hold_ms} ms hold disturbed the hub's callers"

    # control: the samples relayed before the bound arrived; the held one never did
    assert done.received >= 10

    assert r["last_seq_received"] <= held.handed and held.handed < k,
           "sample #{k} reached the peer after the share's bound: #{inspect(done)}"

    # the stream's end names only what was handed over, and every handed sample arrived or was
    # counted by the connection itself (exact; a native sample that reached the hub before the share
    # activated is a counted gap: B1 8.2)
    assert r["source_last_seq"] == held.handed, inspect(r)
    assert r["source_sent"] == r["received"] + cs.samples_stale + cs.samples_expired, inspect(r)
    sh = Hub.status().share.summary
    assert sh.close.reason == "duration" and sh.counts.cancelled_before_send == 1
    assert sh.counts.handed == sh.counts.relayed
  end

  test "T1: a sample handed over before the bound and written after it is dropped by the connection" do
    st = MotionStack.start()
    {share, bound} = share(st)
    %{pid: conn} = Endpoint.status(GlacierRelay.Motion.PeerEndpoint).connection

    queued = fn ->
      Enum.flat_map(mailbox(conn), fn
        {:"$gen_cast", {:sample, f, enqueued, not_after}} -> [{f["seq"], enqueued, not_after}]
        _ -> []
      end)
    end

    sleep_until(bound - @hold_from)
    held = hold_fake_output(st)
    # barrier: the connection has taken every sample handed before (written, or counted dropped)
    c0 = Connection.status(conn).counts
    :sys.suspend(conn)
    release_one_before(st, bound, held)
    # the hub hands the released sample to the suspended connection, before the bound
    wait(fn -> :sys.get_state(Hub).share.src.last_handed_seq == held.n + 1 end, 300, 2)
    assert [{k, enqueued, not_after}] = queued.()
    assert k == held.n + 1 and enqueued < bound and not_after == bound
    sleep_until(bound + 10)
    :sys.resume(conn)
    wait(fn -> Connection.status(conn).counts.samples_expired == c0.samples_expired + 1 end)
    _ = FakeMotionNative.release_motion_out(st.fake)
    done = sink_done(share)
    r = done.reconciliation
    cs = Connection.status(conn).counts
    assert done.received >= 10

    assert r["last_seq_received"] <= held.handed and held.handed < k,
           "sample #{k} was written after the share's bound: #{inspect(done)}"

    # the share handed it over, so its end names it: the sink records the connection's drop as a
    # gap — "sent" means handed to the connection, not written to TLS; every handed sample arrived
    # or was counted by the connection (exactly this one expired)
    assert r["source_last_seq"] == k, inspect(r)
    assert cs.samples_expired - c0.samples_expired == 1
    assert r["source_sent"] == r["received"] + cs.samples_stale + cs.samples_expired, inspect(r)
    refute r["complete"]
  end
end

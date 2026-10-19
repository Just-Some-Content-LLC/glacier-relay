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

  test "T1: a sample whose trace write is held across the share's bound is not handed over" do
    st = MotionStack.start()
    proxy = start_supervised!({TraceProxy, real: GlacierRelay.Motion.Trace, notify: self()})
    {share, bound} = share(st)
    :sys.replace_state(Hub, &%{&1 | trace: proxy})

    sleep_until(bound - 60)
    :ok = TraceProxy.hold_next(proxy, "source.relayed")
    assert_receive {:held, recs, held_at}, 1_000
    rel = Enum.find(recs, &(&1["event"] == "source.relayed"))
    k = rel["seq"]
    assert rel["beam_mono_ms"] < bound
    sleep_until(bound + 15)
    assert Clock.now_ms() - held_at < 150
    :ok = TraceProxy.release(proxy)

    done = sink_done(share)
    :sys.replace_state(Hub, &%{&1 | trace: GlacierRelay.Motion.Trace})
    r = done.reconciliation
    # control: the samples relayed before the bound arrived; the held one never did
    assert done.received >= 10

    assert r["last_seq_received"] == k - 1,
           "sample #{k} reached the peer after the share's bound: #{inspect(done)}"

    # the stream's end names only what was handed over, and everything handed over arrived (a
    # native sample that reached the hub before the share activated is a counted gap: B1 8.2)
    assert r["source_last_seq"] == k - 1 and r["source_sent"] == r["received"], inspect(r)
    sh = Hub.status().share.summary
    assert sh.close.reason == "duration" and sh.counts.cancelled_before_send == 1
    assert sh.counts.handed == sh.counts.relayed
  end

  test "T1: a sample handed over before the bound and written after it is dropped by the connection" do
    st = MotionStack.start()
    {share, bound} = share(st)
    %{pid: conn} = Endpoint.status(GlacierRelay.Motion.PeerEndpoint).connection

    # 80 ms before the bound: at least one sample of the 50 ms cadence is handed over meanwhile
    sleep_until(bound - 80)
    :sys.suspend(conn)

    queued = fn ->
      Enum.flat_map(mailbox(conn), fn
        {:"$gen_cast", {:sample, f, _enqueued, not_after}} -> [{f["seq"], not_after}]
        _ -> []
      end)
    end

    wait(fn -> queued.() != [] end, 200, 2)
    assert Clock.now_ms() < bound, "no sample was handed over before the bound"
    sleep_until(bound + 10)
    # every sample handed over before the bound, all still waiting in the suspended connection
    handed = queued.()
    assert Enum.all?(handed, fn {_seq, not_after} -> not_after == bound end)
    seqs = Enum.map(handed, &elem(&1, 0))
    k = Enum.min(seqs)
    :sys.resume(conn)

    wait(fn -> Connection.status(conn).counts.samples_expired == length(seqs) end)
    done = sink_done(share)
    r = done.reconciliation
    assert done.received >= 10

    assert r["last_seq_received"] == k - 1,
           "sample #{k} was written after the share's bound: #{inspect(done)}"

    # the share handed it over, so its end names it: the sink records the connection's drop as a
    # gap — "sent" means handed to the connection, not written to TLS
    assert r["source_last_seq"] == Enum.max(seqs), inspect(r)
    assert r["source_sent"] == r["received"] + length(seqs), inspect(r)
    refute r["complete"]
  end
end

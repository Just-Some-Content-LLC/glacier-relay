defmodule GlacierRelay.Motion.DeadlineOrderTest do
  @moduledoc """
  M7-B1 correction, finding A (pure): a deadline is a rule about the time an event is processed,
  not about which message arrives first. Each case hands the production machines
  (`Motion.Destination`, `Motion.Source`) an event whose processing time is at or past a deadline
  **without** calling `tick/2` first — the order in which a queued timer message can lose to
  other traffic — and requires that no new effect (`send_target`, a relayed `pose.sample`) is
  produced, that a late acknowledgement never undoes an elapsed timeout, and that a late close
  confirmation never turns an `unknown` close into a confirmed one. Each case keeps a control just
  before its deadline that does produce the effect, so a machine that sends nothing cannot pass.
  Samples have the shape `Peer.Codec` decodes; times are explicit.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.TransformWords
  alias GlacierRelay.Motion.{Destination, Source}

  @pre "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2b2fae1,416d47ae,bfc2d6ba"
  @sid "6b9c8f0e-3d1a-4c2b-9e7f-0a1b2c3d4e5f"
  @stream "1f2e3d4c-5b6a-4978-8a9b-0c1d2e3f4a5b"
  @share "2a3b4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d"
  @ax TransformWords.to_float(0xC2B2FAE1)
  @ay TransformWords.to_float(0x416D47AE)

  defp new(limits \\ %{}) do
    {:ok, l} = Destination.limits(limits)

    Destination.new(%{
      session_id: @sid,
      stream_id: @stream,
      limits: l,
      opening_world: @pre,
      opened_at: 0
    })
  end

  defp s(seq, src, dx) do
    %{
      stream_id: @stream,
      seq: seq,
      src_mono_ms: src,
      src_frame: nil,
      pos:
        TransformWords.encode([
          TransformWords.to_word(@ax + dx),
          TransformWords.to_word(@ay),
          0xBFC2D6BA
        ]),
      qualified: true,
      reason: nil
    }
  end

  defp pos2(dx),
    do: TransformWords.encode([TransformWords.to_word(@ax + dx), TransformWords.to_word(@ay)])

  defp applied(st, seq, dx, now),
    do:
      Destination.applied(
        st,
        %{
          seq: seq,
          outcome: "applied",
          reason: nil,
          post: pos2(dx),
          exact: true,
          frame: 1,
          native_mono_ms: 1
        },
        now
      )

  defp sent(actions), do: for({:send_target, t} <- actions, do: t.seq)
  defp closes(actions), do: for({:send_close, r} <- actions, do: r)
  defp relayed(actions), do: for({:send_peer, "pose.sample", f} <- actions, do: f["seq"])

  defp native_close(reason \\ "beam:operator"),
    do: %{
      reason: reason,
      native_mono_ms: 1,
      clean: true,
      final_world: @pre,
      last_applied_seq: 0,
      applied: 0
    }

  describe "destination: a sample processed at or after the stall deadline" do
    test "A1: the first valid in-area sample at t=300 (stall 250, no tick) forwards nothing" do
      # control: the same first sample at t=249 is forwarded (bounded against the opening snapshot)
      {_st, a} = Destination.sample(new(), s(1, 0, 0.01), 249)
      assert sent(a) == [1]

      {st, a} = Destination.sample(new(), s(1, 0, 0.01), 300)
      assert sent(a) == [], "a target was produced after the stall deadline: #{inspect(a)}"
      assert closes(a) == [:stall]
      assert st.phase == :closing and st.counts.refused.not_open == 1
      assert st.counts.forwarded == 0 and st.in_flight == nil
    end

    test "A1 boundary: the stall deadline is inclusive (t=250 expires)" do
      {st, a} = Destination.sample(new(), s(1, 0, 0.0), 250)
      assert sent(a) == [] and closes(a) == [:stall] and st.counts.forwarded == 0
    end
  end

  describe "destination: traffic processed at or after the duration deadline" do
    setup do
      st = new(%{duration_ms: 1_000, stall_ms: 1_000})
      {st, a} = Destination.sample(st, s(1, 900, 0.0), 900)
      assert sent(a) == [1]
      %{st: st}
    end

    test "A2: a valid sample at the duration bound forwards nothing", %{st: st} do
      {st, _} = applied(st, 1, 0.0, 910)
      # control: at 999 the next sample is forwarded
      {_st, a} = Destination.sample(st, s(2, 999, 0.02), 999)
      assert sent(a) == [2]

      {st, a} = Destination.sample(st, s(2, 1_000, 0.02), 1_000)
      assert sent(a) == [], "a target was produced at the duration bound: #{inspect(a)}"
      assert closes(a) == [:duration] and st.counts.forwarded == 1
    end

    test "A2: an in-time acknowledgement at the duration bound releases no pending target", %{
      st: st
    } do
      {st, a} = Destination.sample(st, s(2, 920, 0.02), 920)
      assert sent(a) == [] and st.pending.seq == 2
      # control: the acknowledgement at 999 releases the pending target
      {_st, a} = applied(st, 1, 0.0, 999)
      assert sent(a) == [2]

      {st, a} = applied(st, 1, 0.0, 1_000)
      assert sent(a) == [], "the pending target was released at the duration bound: #{inspect(a)}"
      assert closes(a) == [:duration]
      # the acknowledgement itself was in time (sent at 900, deadline 1,100): it is evidence of an
      # apply, not a late answer
      assert st.counts.applied == 1 and st.ref.seq == 1 and st.counts.dropped_on_close == 1
    end
  end

  describe "destination: an exact acknowledgement processed after its 200 ms deadline" do
    setup do
      {st, a} = Destination.sample(new(), s(1, 0, 0.0), 50)
      assert sent(a) == [1]
      {st, a} = Destination.sample(st, s(2, 20, 0.01), 60)
      assert sent(a) == [] and st.pending.seq == 2
      %{st: st}
    end

    test "A3 control: the acknowledgement at t=249 releases the pending target", %{st: st} do
      {st, a} = applied(st, 1, 0.0, 249)
      assert sent(a) == [2] and st.counts.applied == 1
    end

    test "A3: the acknowledgement at t=251 (no tick) neither erases the timeout nor releases", %{
      st: st
    } do
      {st, a} = applied(st, 1, 0.0, 251)
      assert sent(a) == [], "the pending target was released by a late answer: #{inspect(a)}"
      assert closes(a) == [:ack_timeout]
      # the elapsed timeout stands: the target's outcome was unknown at its deadline
      assert st.counts.uncertain == 1 and st.counts.unacknowledged == 1
      assert st.unresolved.seq == 1
      # the late answer is retained as evidence, never as a resolution
      assert st.counts.applied == 0 and st.ref.seq == nil and st.last_applied_seq == 0
      assert Map.get(st.counts, :late_acks) == 1
      assert st.counts.dropped_on_close == 1
      # nothing resumes afterwards
      {st, a} = Destination.tick(st, 300)
      assert sent(a) == [] and st.phase == :closing
      {st, _} = Destination.native_closed(st, native_close(), 310)
      refute Destination.summary(st).restorable
    end

    test "A3 boundary: the acknowledgement deadline is inclusive (t=250 is late)", %{st: st} do
      {st, a} = applied(st, 1, 0.0, 250)
      assert sent(a) == [] and closes(a) == [:ack_timeout] and st.counts.applied == 0
    end

    test "A3 closing: an answer more than 200 ms after its send is late while closing too", %{
      st: st
    } do
      {st, _} = Destination.close(st, :operator, 100)
      {st, a} = applied(st, 1, 0.0, 260)
      assert sent(a) == []
      assert st.counts.applied == 0 and st.counts.uncertain == 1 and st.unresolved.seq == 1
    end
  end

  describe "destination: close confirmation processed after its 1,000 ms deadline" do
    test "A6: a ghost.closed processed at the deadline (no tick) leaves the close unknown" do
      {st, _} = Destination.close(new(), :operator, 100)
      # control: a confirmation at 1,099 confirms
      {st_ok, _} = Destination.native_closed(st, native_close(), 1_099)
      assert st_ok.close.state == :confirmed

      {st, a} = Destination.native_closed(st, native_close(), 1_100)
      assert st.close.state == :unknown, "a late confirmation confirmed the close: #{inspect(a)}"
      assert {:drop_link, :close_unconfirmed} in a
      refute Destination.summary(st).restorable
    end

    test "A6: a ghost.closed after the close became unknown never overwrites it" do
      {st, _} = Destination.close(new(), :operator, 100)
      {st, a} = Destination.tick(st, 1_100)
      assert st.close.state == :unknown and {:drop_link, :close_unconfirmed} in a
      {st, a} = Destination.native_closed(st, native_close(), 1_200)
      assert st.close.state == :unknown, "an unknown close was overwritten: #{inspect(a)}"
      assert for({:closed, _} = c <- a, do: c) == []
      refute Destination.summary(st).restorable
    end
  end

  describe "share: a hero sample processed at or after the share's duration" do
    defp share(duration_ms \\ 1_000),
      do:
        Source.new(%{share_id: @share, interval_ms: 50, duration_ms: duration_ms, opened_at: 0})
        |> Source.announced()

    defp hs(seq, native_ms),
      do: %{
        share_id: @share,
        seq: seq,
        frame: 100 + seq,
        native_mono_ms: native_ms,
        pos: "c2a77ccf,416b27e8,bfc2d6ba",
        dirty: false
      }

    test "A4: hero_sample at t=1,001 (duration 1,000, no tick) is not relayed" do
      # control: at 999 it is relayed
      {_st, a} = Source.hero_sample(share(), hs(1, 10), 999)
      assert relayed(a) == [1]

      {st, a} = Source.hero_sample(share(), hs(1, 10), 1_001)
      assert relayed(a) == [], "a sample was relayed after the share expired: #{inspect(a)}"
      assert {:send_share_close, :duration} in a
      assert st.phase == :closing and st.counts.relayed == 0
    end

    test "A4 boundary: the share's duration is inclusive (t=1,000 expires)" do
      {st, a} = Source.hero_sample(share(), hs(1, 10), 1_000)
      assert relayed(a) == [] and st.counts.relayed == 0
    end

    test "A6 share: a share.closed after the 1,000 ms confirmation deadline leaves it unknown" do
      {st, _} = Source.close(share(), :operator, 100)
      c = %{share_id: @share, reason: "beam:operator", last_seq: 0, sent: 0}
      {st, a} = Source.native_closed(st, c, 1_100)
      assert st.close.state == :unknown, "a late confirmation confirmed the share: #{inspect(a)}"

      {st2, _} = Source.close(share(), :operator, 100)
      {st2, _} = Source.tick(st2, 1_100)
      assert st2.close.state == :unknown
      {st2, a} = Source.native_closed(st2, c, 1_200)
      assert st2.close.state == :unknown, "an unknown share close was overwritten: #{inspect(a)}"
      assert for({:closed, _} = x <- a, do: x) == []
    end
  end
end

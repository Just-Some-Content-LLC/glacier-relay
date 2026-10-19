defmodule GlacierRelay.Motion.DeadlineSendTest do
  @moduledoc """
  M7-B1 correction, finding A (pure, after the fix): the send boundary. `Destination.before_send/3`
  and `Source.before_send/3` are what the hub calls after a batch's required trace write and
  immediately before the bytes; these cases pin their decisions and accounting on explicit times:
  a target or sample past its eligibility is cancelled before any byte (not uncertain), the
  session or share closes, and a target that is sent starts its acknowledgement deadline, pacing
  and stall at the actual send. The trace-refused withdrawal's count is pinned too (its increment
  was lost before the correction).
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

  defp new(limits) do
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

  defp closes(actions), do: for({:send_close, r} <- actions, do: r)

  defp ack(st, seq, dx, now),
    do:
      Destination.applied(
        st,
        %{
          seq: seq,
          outcome: "applied",
          reason: nil,
          post:
            TransformWords.encode([TransformWords.to_word(@ax + dx), TransformWords.to_word(@ay)]),
          exact: true,
          frame: 1,
          native_mono_ms: 1
        },
        now
      )

  describe "destination: the target's eligibility at its send" do
    setup do
      {st, a} = Destination.sample(new(%{duration_ms: 1_000, stall_ms: 1_000}), s(1, 0, 0.0), 990)
      assert [{:send_target, %{seq: 1}}] = for({:send_target, _} = t <- a, do: t)
      %{st: st}
    end

    test "inside the duration: sent; its send time is the actual send", %{st: st} do
      assert {:send, st} = Destination.before_send(st, 1, 999)
      assert st.in_flight.r_sent == 999 and st.last_forward_r == 999
      assert st.counts.forwarded == 1 and st.counts.cancelled_before_send == 0
    end

    test "at the duration bound: cancelled before any byte, not uncertain; the session closes", %{
      st: st
    } do
      assert {:cancel, st, actions} = Destination.before_send(st, 1, 1_000)
      assert closes(actions) == [:duration]
      assert st.in_flight == nil and st.unresolved == nil
      assert st.counts.cancelled_before_send == 1 and st.counts.forwarded == 0
      assert st.counts.uncertain == 0 and st.counts.unacknowledged == 0

      assert [%{"seq" => 1, "why" => "duration", "decided_mono_ms" => 990}] =
               for({:trace, %{"event" => "destination.send_cancelled"} = r} <- actions, do: r)
    end

    test "a target that is not the one in flight is never sent (no state change)", %{st: st} do
      assert {:cancel, ^st, [{:trace, %{"why" => "not_the_target_in_flight"}}]} =
               Destination.before_send(st, 7, 995)
    end
  end

  describe "destination: the stall measured from the previous send" do
    test "a send at or after the previous send + stall_ms is cancelled; just before, sent" do
      # opened at 0 (the first reference time), stall 250: a target decided at 200 and written at
      # 249 is sent; written at 250 it is cancelled and the session closes stall
      {st, _} = Destination.sample(new(%{}), s(1, 0, 0.0), 200)
      assert {:send, _} = Destination.before_send(st, 1, 249)
      assert {:cancel, st2, actions} = Destination.before_send(st, 1, 250)
      assert closes(actions) == [:stall] and st2.counts.cancelled_before_send == 1
    end
  end

  test "the acknowledgement deadline runs from the actual send" do
    {st, _} = Destination.sample(new(%{}), s(1, 0, 0.0), 50)
    {:send, st} = Destination.before_send(st, 1, 120)
    # decided at 50, written at 120: the deadline is 320, not 250
    {st1, a} = Destination.tick(st, 319)
    assert closes(a) == [] and st1.in_flight.seq == 1
    {_st, a} = Destination.tick(st, 320)
    assert closes(a) == [:ack_timeout]
    {st3, a} = ack(st, 1, 0.0, 300)
    assert closes(a) == [] and st3.counts.applied == 1 and st3.ref.r == 120
  end

  test "a target the trace refused is withdrawn and counted (the count was lost before)" do
    {st, _} = Destination.sample(new(%{}), s(1, 0, 0.0), 50)
    st = Destination.withdrawn(st, 1)
    assert st.counts.withdrawn == 1 and st.counts.forwarded == 0 and st.in_flight == nil
  end

  describe "share: the sample's eligibility at its hand-over" do
    defp share,
      do:
        Source.new(%{share_id: @share, interval_ms: 50, duration_ms: 1_000, opened_at: 0})
        |> Source.announced()

    defp relayed(st, seq, now, dirty \\ false) do
      hs = %{
        share_id: @share,
        seq: seq,
        frame: 100 + seq,
        native_mono_ms: 10 * seq,
        pos: "c2a77ccf,416b27e8,bfc2d6ba",
        dirty: dirty
      }

      {st, actions} = Source.hero_sample(st, hs, now)
      [fields] = for {:send_peer, "pose.sample", f} <- actions, do: f
      {st, fields}
    end

    test "inside the duration: handed over with the share's bound as the connection's not_after" do
      {st, fields} = relayed(share(), 1, 990)
      assert {:send, ^st, 1_000} = Source.before_send(st, fields, 999)
    end

    test "at the bound: not handed over, no longer relayed; the share closes and ends its stream" do
      {st, fields} = relayed(share(), 1, 990, true)
      assert st.counts.relayed == 1 and st.counts.relayed_unqualified == 1
      assert {:cancel, st, actions} = Source.before_send(st, fields, 1_000)
      assert st.counts.relayed == 0 and st.counts.relayed_unqualified == 0
      assert st.counts.cancelled_before_send == 1
      assert {:send_share_close, :duration} in actions

      assert [%{"reason" => "duration", "sent" => 0}] =
               for({:send_peer, "stream.end", f} <- actions, do: f)
    end
  end
end

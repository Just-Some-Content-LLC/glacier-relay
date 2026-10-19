defmodule GlacierRelay.Motion.DestinationTest do
  @moduledoc """
  M7-B1: the destination session's BEAM-side rules (design section 15.3–15.6), pure, on synthetic
  times: acquisition and pauses bounded against the opening snapshot or the last confirmed apply,
  exact displacement boundaries, supersession and confirmation kept apart, the first uncertainty and
  every control failure ending application, stall, lag growth, area, duration, reports and the four
  close states. No process, socket or native is involved; "native" answers here are hand-written.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.TransformWords
  alias GlacierRelay.Motion.Destination

  @pre "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2b2fae1,416d47ae,bfc2d6ba"
  @sid "6b9c8f0e-3d1a-4c2b-9e7f-0a1b2c3d4e5f"
  @stream "1f2e3d4c-5b6a-4978-8a9b-0c1d2e3f4a5b"
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

  # a sample at the anchor offset by (dx, dy) metres, at source time `src`
  defp s(seq, src, dx \\ 0.0, dy \\ 0.0, opts \\ []) do
    xw = TransformWords.to_word(@ax + dx)
    yw = TransformWords.to_word(@ay + dy)

    %{
      stream_id: Keyword.get(opts, :stream, @stream),
      seq: seq,
      src_mono_ms: src,
      src_frame: nil,
      pos: TransformWords.encode([xw, yw, 0]),
      qualified: Keyword.get(opts, :qualified, true),
      reason: nil
    }
  end

  defp pos2(dx, dy \\ 0.0),
    do:
      TransformWords.encode([TransformWords.to_word(@ax + dx), TransformWords.to_word(@ay + dy)])

  defp sent(actions), do: for({:send_target, t} <- actions, do: t.seq)
  defp closes(actions), do: for({:send_close, r} <- actions, do: r)

  defp applied(st, seq, pos, now),
    do:
      Destination.applied(
        st,
        %{
          seq: seq,
          outcome: "applied",
          reason: nil,
          post: pos,
          exact: true,
          frame: 1,
          native_mono_ms: 1
        },
        now
      )

  defp ack(st, seq, outcome, now, extra \\ %{}),
    do:
      Destination.applied(
        st,
        Map.merge(
          %{
            seq: seq,
            outcome: outcome,
            reason: nil,
            post: nil,
            exact: nil,
            frame: 1,
            native_mono_ms: 1
          },
          extra
        ),
        now
      )

  describe "limits" do
    test "defaults, compiled bounds and unknown keys" do
      assert {:ok, d} = Destination.limits(%{})
      assert d == Destination.defaults()

      assert d == %{
               half_extent_mm: 8_000,
               max_speed_mmps: 2_000,
               credit_ms: 100,
               min_forward_interval_ms: 50,
               stall_ms: 250,
               max_lag_growth_ms: 100,
               duration_ms: 120_000
             }

      assert {:error, {:limit_out_of_range, :max_speed_mmps, 3_001}} =
               Destination.limits(%{max_speed_mmps: 3_001})

      assert {:error, {:limit_out_of_range, :half_extent_mm, 8_001}} =
               Destination.limits(%{half_extent_mm: 8_001})

      assert {:error, {:limit_out_of_range, :duration_ms, 300_001}} =
               Destination.limits(%{duration_ms: 300_001})

      assert {:error, {:limit_out_of_range, :credit_ms, 1.0}} =
               Destination.limits(%{credit_ms: 1.0})

      assert {:error, {:unknown_limits, [:catch_up]}} = Destination.limits(%{catch_up: true})
      assert {:ok, %{stall_ms: 100}} = Destination.limits(%{stall_ms: 100})
    end
  end

  describe "acquisition and displacement" do
    test "the first target is bounded against the opening snapshot; at the anchor it is forwarded" do
      st = new()
      {st, a} = Destination.sample(st, s(1, 0), 60)
      assert sent(a) == [1]
      assert st.in_flight.seq == 1
      assert st.ref.seq == nil
    end

    test "no acquisition exemption: a far first target is refused however long the session waited" do
      st = new(%{stall_ms: 1_000})
      # a 0.25 m first target 900 ms after open: the credit caps the allowance at 0.2 m
      {st, a} = Destination.sample(st, s(1, 0, 0.25), 900)
      assert sent(a) == [] and closes(a) == []
      assert st.counts.refused.refused_displacement == 1
      assert st.pending == nil
      # nothing is clamped, interpolated or held for later: the next sample is judged on its own
      {_st, a} = Destination.sample(st, s(2, 50, 0.19), 950)
      assert sent(a) == [2]
    end

    test "a pause never earns more than the credit (after a confirmed apply)" do
      st = new(%{stall_ms: 1_000})
      {st, [_ | _] = a} = Destination.sample(st, s(1, 0), 60)
      assert sent(a) == [1]
      {st, _} = applied(st, 1, pos2(0.0), 70)
      # 800 ms of silence, then a target 0.21 m away: refused (0.2 m at most)
      {st, a} = Destination.sample(st, s(2, 800, 0.21), 860)
      assert sent(a) == [] and st.counts.refused.refused_displacement == 1
      {_st, a} = Destination.sample(st, s(3, 850, 0.2 - 1.0e-4), 910)
      assert sent(a) == [3]
    end

    test "exact boundary: a distance equal to the allowance passes, one binary32 step more does not" do
      # 1.25 m/s × 100 ms = 0.125 m exactly; anchor x + 0.125 is exactly representable in binary32
      limits = %{max_speed_mmps: 1_250, credit_ms: 100, stall_ms: 1_000}
      dx = TransformWords.to_float(TransformWords.to_word(@ax + 0.125)) - @ax
      assert dx == 0.125

      {_st, a} = Destination.sample(new(limits), s(1, 0, 0.125), 100)
      assert sent(a) == [1]

      # x is negative: one word less is one binary32 step towards zero, i.e. 0.125 m + one ulp away
      xw = TransformWords.to_word(@ax + 0.125) - 1
      beyond = TransformWords.to_float(xw) - @ax
      assert beyond > 0.125
      sample = %{s(1, 0) | pos: TransformWords.encode([xw, TransformWords.to_word(@ay), 0])}
      {st, a} = Destination.sample(new(limits), sample, 100)
      assert sent(a) == [] and st.counts.refused.refused_displacement == 1
    end

    test "the receiver clock bounds speed: a burst arriving early earns only the elapsed time" do
      st = new(%{stall_ms: 1_000})
      {st, a} = Destination.sample(st, s(1, 0), 50)
      assert sent(a) == [1]
      {st, _} = applied(st, 1, pos2(0.0), 55)
      # 0.15 m claimed 75 ms later on the source clock, but only 60 ms of receiver time since the
      # reference was sent: 2 m/s × 60 ms = 0.12 m
      {st, a} = Destination.sample(st, s(2, 75, 0.15), 110)
      assert sent(a) == [] and st.counts.refused.refused_displacement == 1
      {_st, a} = Destination.sample(st, s(3, 100, 0.15), 140)
      assert sent(a) == [3]
    end
  end

  describe "supersession, confirmation and sequence" do
    test "supersession never moves the reference; only a confirmed apply does" do
      st = new()
      # two samples before the first forward slot (opened at 0, interval 50)
      {st, a} = Destination.sample(st, s(1, 0), 10)
      assert sent(a) == []
      {st, a} = Destination.sample(st, s(2, 20, 0.01), 30)
      assert sent(a) == []
      assert st.counts.superseded == 1
      assert st.ref.seq == nil
      {st, a} = Destination.tick(st, 50)
      assert sent(a) == [2]
      # a later sample waits: one target in flight, the reference is still the opening snapshot
      {st, a} = Destination.sample(st, s(3, 70, 0.02), 110)
      assert sent(a) == [] and st.ref.seq == nil and st.pending.seq == 3
      {st, a} = applied(st, 2, pos2(0.01), 115)
      assert st.ref.seq == 2 and st.ref.r == 50
      assert sent(a) == [3]
      assert st.counts.validated == 3 and st.counts.forwarded == 2 and st.counts.applied == 1
    end

    test "a duplicate or older sequence is refused and never re-sent; the last value is not re-applied" do
      st = new()
      {st, a} = Destination.sample(st, s(5, 0), 60)
      assert sent(a) == [5]
      {st, _} = applied(st, 5, pos2(0.0), 65)
      {st, a} = Destination.sample(st, s(5, 50), 120)
      assert sent(a) == []
      {st, a2} = Destination.sample(st, s(4, 60), 125)
      assert sent(a2) == []
      assert st.counts.refused.duplicate == 1 and st.counts.refused.older == 1
      # time passing with nothing new forwards nothing
      {_st, a} = Destination.tick(st, 200)
      assert sent(a) == []
    end

    test "an unqualified sample is withheld and never promoted" do
      st = new()
      {st, a} = Destination.sample(st, s(1, 0, 0.0, 0.0, qualified: false), 60)
      assert sent(a) == [] and closes(a) == []
      assert st.counts.refused.unqualified == 1 and st.pending == nil
    end

    test "a sample of another stream is refused" do
      {st, a} =
        Destination.sample(
          new(),
          s(1, 0, 0.0, 0.0, stream: "00000000-0000-4000-8000-000000000000"),
          60
        )

      assert sent(a) == [] and st.counts.refused.foreign_stream == 1
    end

    test "a source clock that does not increase ends the session" do
      st = new()
      {st, _} = Destination.sample(st, s(1, 100), 60)
      {st, a} = Destination.sample(st, s(2, 100), 110)
      assert closes(a) == [:source_clock_not_increasing]
      assert st.phase == :closing
    end
  end

  describe "freshness: lag growth" do
    test "growth is the receiver interval minus the source interval; above the bound the session closes" do
      st = new(%{stall_ms: 1_000})
      {st, _} = Destination.sample(st, s(1, 1_000), 60)
      {st, _} = Destination.sample(st, s(2, 1_050), 110)
      # received 150 ms later for 50 ms of source time: growth 100 — at the bound, still fresh
      {st, a} = Destination.sample(st, s(3, 1_100), 260)
      assert closes(a) == []
      assert st.counts.max_lag_growth_ms == 100
      {st, a} = Destination.sample(st, s(4, 1_150), 311)
      assert closes(a) == [:late]
      assert st.counts.refused.late == 1
    end

    test "a sample less delayed than the base re-bases (growth never negative)" do
      st = new()
      {st, _} = Destination.sample(st, s(1, 1_000), 100)
      {st, _} = Destination.sample(st, s(2, 1_100), 150)
      assert st.lag_base == {150, 1_100}
    end
  end

  describe "area" do
    test "a sample outside the anchor's area closes the session; the boundary is inclusive" do
      limits = %{half_extent_mm: 1_000, stall_ms: 1_000, max_speed_mmps: 3_000, credit_ms: 200}
      {st, a} = Destination.sample(new(limits), s(1, 0, 0.0, 1.0001), 60)
      assert closes(a) == [:outside_area] and st.counts.refused.outside_area == 1

      # +1.0 m in y rounds to a binary32 word whose offset is within 1 m
      dy = TransformWords.to_float(TransformWords.to_word(@ay + 1.0)) - @ay
      assert abs(dy) <= 1.0
      {st, a} = Destination.sample(new(limits), s(1, 0, 0.0, 1.0), 60)
      assert closes(a) == [] and st.counts.refused.outside_area == 0
    end
  end

  describe "the native's answers end application on the first uncertainty" do
    setup do
      {st, [_ | _]} = Destination.sample(new(), s(1, 0), 60)
      %{st: st}
    end

    test "an uncertain post-call result closes; the target stays unresolved; not restorable", %{
      st: st
    } do
      {st, a} = ack(st, 1, "uncertain", 70, %{reason: "read_back_unavailable"})
      assert closes(a) == [{:uncertain, "read_back_unavailable"}]
      assert st.counts.uncertain == 1 and st.unresolved.seq == 1
      {st, _} = Destination.native_closed(st, closed(true), 80)
      refute Destination.summary(st).restorable
    end

    test "an applied answer whose postimage differs closes (postimage_mismatch)", %{st: st} do
      {st, a} = applied(st, 1, pos2(0.0, 0.001), 70)
      assert closes(a) == [:postimage_mismatch]
      assert st.counts.uncertain == 1
    end

    test "an inexact applied answer closes", %{st: st} do
      {_st, a} =
        Destination.applied(
          st,
          %{
            seq: 1,
            outcome: "applied",
            reason: nil,
            post: pos2(0.0),
            exact: false,
            frame: 1,
            native_mono_ms: 1
          },
          70
        )

      assert closes(a) == [:postimage_mismatch]
    end

    test "any native refusal closes (no invocation)", %{st: st} do
      {st, a} = ack(st, 1, "refused", 70, %{reason: "untouched_field_changed"})
      assert closes(a) == [{:native_refused, "untouched_field_changed"}]
      assert st.counts.refused_native == 1 and st.counts.uncertain == 0
    end

    test "an acknowledgement for another target closes", %{st: st} do
      {st, a} = applied(st, 7, pos2(0.0), 70)
      assert closes(a) == [:ack_mismatch]
      assert st.unresolved != nil
    end

    test "a missing acknowledgement is uncertain after 200 ms and closes", %{st: st} do
      {st, a} = Destination.tick(st, 259)
      assert closes(a) == []
      {st, a} = Destination.tick(st, 260)
      assert closes(a) == [:ack_timeout]
      assert st.counts.uncertain == 1 and st.counts.unacknowledged == 1 and st.unresolved.seq == 1
    end

    test "skipped_identical keeps the position and confirms the sequence", %{st: st} do
      {st, a} = ack(st, 1, "skipped_identical", 70)

      assert closes(a) == [] and st.ref.seq == 1 and st.ref.pos == pos2(0.0) and
               st.counts.skipped == 1
    end
  end

  describe "time: stall and duration" do
    test "no target forwarded for stall_ms closes (no resumption)" do
      st = new()
      {st, a} = Destination.tick(st, 249)
      assert closes(a) == []
      {st, a} = Destination.tick(st, 250)
      assert closes(a) == [:stall]
      # a backlog arriving afterwards is refused, never played out
      {st, a} = Destination.sample(st, s(1, 0), 600)
      {st, a2} = Destination.sample(st, s(2, 50), 601)
      assert sent(a ++ a2) == []
      assert st.counts.refused.not_open == 2
    end

    test "the duration closes" do
      {st, a} = Destination.tick(new(%{duration_ms: 1_000, stall_ms: 1_000}), 999)
      assert closes(a) == []
      {_st, a} = Destination.tick(%{st | last_forward_r: 900}, 1_000)
      assert closes(a) == [:duration]
    end
  end

  describe "reports" do
    setup do
      {st, _} = Destination.sample(new(), s(1, 0), 60)
      {st, _} = applied(st, 1, pos2(0.0), 70)
      %{st: st}
    end

    defp rep(seq, applied, received, extra \\ %{}),
      do:
        Map.merge(
          %{
            report_seq: seq,
            native_mono_ms: 1,
            frame: 1,
            received: received,
            applied: applied,
            skipped: 0,
            refused: 0,
            uncertain: 0,
            superseded: 0,
            last_applied_seq: 1
          },
          extra
        )

    test "a report that agrees changes nothing", %{st: st} do
      {st, a} = Destination.report(st, rep(1, 1, 1), 100)
      assert closes(a) == [] and st.report_seq == 1
    end

    test "a report gap closes", %{st: st} do
      {_st, a} = Destination.report(st, rep(2, 1, 1), 100)
      assert closes(a) == [:report_gap]
    end

    test "a report that disagrees with the acknowledgements closes", %{st: st} do
      {_st, a} = Destination.report(st, rep(1, 2, 1), 100)
      assert closes(a) == [:report_disagrees]
      {_st, a} = Destination.report(st, rep(1, 1, 1, %{superseded: 1}), 100)
      assert closes(a) == [:report_disagrees]
    end
  end

  defp closed(clean),
    do: %{
      reason: "beam:operator",
      native_mono_ms: 1,
      clean: clean,
      final_world: @pre,
      last_applied_seq: 1,
      applied: 1
    }

  describe "close states" do
    test "requested → transmitted → confirmed; a clean confirmed close is restorable" do
      {st, _} = Destination.sample(new(), s(1, 0), 60)
      {st, _} = applied(st, 1, pos2(0.0), 70)
      {st, a} = Destination.close(st, :operator, 100)
      assert closes(a) == [:operator] and st.close.state == :requested
      {st, _} = Destination.close_transmitted(st, 101)
      assert st.close.state == :transmitted
      {_st, a} = Destination.native_closed(st, closed(true), 120)
      assert [{:closed, summary}] = for({:closed, _} = c <- a, do: c)
      assert summary.close.state == :confirmed and summary.restorable
    end

    test "close needs no arming and is idempotent; a second close does nothing" do
      {st, _} = Destination.close(new(), :operator, 10)
      assert {^st, []} = Destination.close(st, :again, 11)
    end

    test "no confirmation within 1,000 ms: unknown, the link is dropped, not restorable" do
      {st, _} = Destination.close(new(), :operator, 100)
      {st, a} = Destination.tick(st, 1_099)
      assert a == []
      {st, a} = Destination.tick(st, 1_100)
      assert {:drop_link, :close_unconfirmed} in a
      assert st.close.state == :unknown and st.phase == :closed
      refute Destination.summary(st).restorable
    end

    test "the motion link lost before confirmation: unknown" do
      {st, _} = Destination.sample(new(), s(1, 0), 60)
      {_st, a} = Destination.link_lost(st, 70)
      assert [{:closed, summary}] = for({:closed, _} = c <- a, do: c)
      assert summary.close.state == :unknown and summary.unresolved_seq == 1
      refute summary.restorable
    end

    test "a native-initiated close is confirmed with the native's reason" do
      {_st, a} =
        Destination.native_closed(new(), %{closed(true) | reason: "target_silence"}, 1_000)

      assert [{:closed, summary}] = for({:closed, _} = c <- a, do: c)
      assert summary.close.by == :native and summary.close.state == :confirmed
      assert summary.close.reason == "native:target_silence"
    end

    test "an unclean native close is not restorable" do
      {st, _} = Destination.close(new(), :operator, 10)
      {st, _} = Destination.native_closed(st, closed(false), 20)
      refute Destination.summary(st).restorable
    end
  end

  test "next_deadline covers pacing, acknowledgement, stall, duration and close confirmation" do
    st = new()
    assert Destination.next_deadline(st) == 250
    {st, _} = Destination.sample(st, s(1, 0), 10)
    assert Destination.next_deadline(st) == 50
    {st, _} = Destination.tick(st, 50)
    assert Destination.next_deadline(st) == 250
    {st, _} = Destination.close(st, :operator, 60)
    assert Destination.next_deadline(st) == 1_060
  end
end

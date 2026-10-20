defmodule GlacierRelay.Motion.AdmissionUnitTest do
  @moduledoc """
  M7-L3 source-sequence admission correction (`docs/design/M7_NETWORK_GHOST.md` section 29), pure:
  the per-stream received progress (`Motion.StreamProgress`), the `stationary_prefix` admission's
  validation and evaluation with its inclusive bounds (`Motion.Admission`), and the destination's
  acquisition — the first-target rule — on synthetic times (`Motion.Destination`). No process,
  socket or native is involved; "native" answers here are hand-written.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.TransformWords
  alias GlacierRelay.Motion.{Admission, Destination, StreamProgress}

  @pre "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2b2fae1,416d47ae,bfc2d6ba"
  @anchor "c2b2fae1,416d47ae"
  @sid "6b9c8f0e-3d1a-4c2b-9e7f-0a1b2c3d4e5f"
  @stream "1f2e3d4c-5b6a-4978-8a9b-0c1d2e3f4a5b"
  @ax TransformWords.to_float(0xC2B2FAE1)
  @ay TransformWords.to_float(0x416D47AE)
  @course "out_and_back test course"
  @limits %{duration_ms: 20_000, half_extent_mm: 1_250, max_speed_mmps: 1_000, credit_ms: 100}

  defp adm(over \\ %{}),
    do:
      Map.merge(
        %{
          kind: "stationary_prefix",
          anchor: @anchor,
          course: @course,
          max_open_seq: 55,
          max_activation_seq: 61,
          first_changing_seq: 82
        },
        over
      )

  # a decoded sample at the anchor offset by dx metres along x
  defp s(seq, src, dx \\ 0.0, opts \\ []) do
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
      qualified: Keyword.get(opts, :qualified, true),
      reason: nil
    }
  end

  defp xy(dx),
    do: TransformWords.encode([TransformWords.to_word(@ax + dx), TransformWords.to_word(@ay)])

  defp stream(samples, over \\ %{}) do
    p =
      Enum.reduce(samples, StreamProgress.new(), fn {smp, t}, p ->
        StreamProgress.observe(p, smp, t)
      end)

    Map.merge(%{source_kind: "synthetic", course: @course, progress: p, reopened: false}, over)
  end

  defp new_dest(acq \\ %{first_changing_seq: 82}) do
    {:ok, l} = Destination.limits(@limits)

    Destination.new(%{
      session_id: @sid,
      stream_id: @stream,
      limits: l,
      opening_world: @pre,
      opened_at: 0,
      acquisition: acq
    })
  end

  defp sent(actions), do: for({:send_target, t} <- actions, do: t.seq)
  defp closes(actions), do: for({:send_close, r} <- actions, do: r)

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

  describe "StreamProgress" do
    test "the highest sequence and a receipt count are kept apart; observed gaps are counted" do
      p =
        Enum.reduce([{1, 0}, {4, 50}, {9, 100}, {30, 150}], StreamProgress.new(), fn {seq, t},
                                                                                     p ->
          StreamProgress.observe(p, s(seq, t), t + 1)
        end)

      assert p.received == 4 and p.advanced == 4 and p.not_advanced == 0
      assert p.first_seq == 1 and p.index_gaps == 2 + 4 + 20

      assert %{seq: 30, xy: @anchor, qualified: true, src_mono_ms: 150, received_mono_ms: 151} =
               p.high
    end

    test "an older or duplicate sample never moves the high-water mark or overwrites its values" do
      p = StreamProgress.observe(StreamProgress.new(), s(60, 10), 11)
      p = StreamProgress.observe(p, s(10, 20, 0.5), 21)
      p = StreamProgress.observe(p, s(60, 30, 0.7, qualified: false), 31)
      assert p.received == 3 and p.advanced == 1 and p.not_advanced == 2

      assert %{seq: 60, xy: @anchor, qualified: true, src_mono_ms: 10, received_mono_ms: 11} =
               p.high
    end

    test "a newer unqualified sample replaces the high-water mark" do
      p = StreamProgress.observe(StreamProgress.new(), s(10, 10), 11)
      p = StreamProgress.observe(p, s(11, 20, 0.0, qualified: false), 21)
      assert %{seq: 11, qualified: false} = p.high
    end

    test "absent progress is nil, not zero" do
      assert StreamProgress.new().high == nil
    end
  end

  describe "Admission.validate" do
    test "M7-L3's values pass; unknown fields, wrong kinds, non-canonical anchors and bad bounds are refused" do
      assert {:ok, _} = Admission.validate(adm())
      assert {:ok, nil} = Admission.validate(nil)

      assert {:error, {:admission_unknown_fields, [:extra]}} =
               Admission.validate(Map.put(adm(), :extra, 1))

      assert {:error, {:admission_kind, "other"}} = Admission.validate(adm(%{kind: "other"}))

      assert {:error, :admission_anchor_invalid} =
               Admission.validate(adm(%{anchor: "C2B2FAE1,416D47AE"}))

      assert {:error, :admission_anchor_invalid} = Admission.validate(adm(%{anchor: "c2b2fae1"}))
      assert {:error, :admission_course_invalid} = Admission.validate(adm(%{course: ""}))
      assert {:error, :admission_course_invalid} = Admission.validate(adm(%{course: "a\nb"}))
      assert {:error, :admission_sequence_bounds} = Admission.validate(adm(%{max_open_seq: 0}))
      assert {:error, :admission_sequence_bounds} = Admission.validate(adm(%{max_open_seq: 62}))

      assert {:error, :admission_sequence_bounds} =
               Admission.validate(adm(%{max_activation_seq: 82}))

      assert {:error, :admission_sequence_bounds} =
               Admission.validate(adm(%{first_changing_seq: 100_001, max_activation_seq: 61}))

      assert {:error, :admission_sequence_bounds} = Admission.validate(adm(%{max_open_seq: "55"}))

      assert {:error, :admission_sequence_bounds} =
               Admission.validate(Map.delete(adm(), :first_changing_seq))

      # inclusive edges: equal open and activation bounds; activation one below the first change
      assert {:ok, _} = Admission.validate(adm(%{max_open_seq: 61, max_activation_seq: 61}))
      assert {:ok, _} = Admission.validate(adm(%{max_activation_seq: 81}))
    end
  end

  describe "Admission.evaluate (inclusive bounds)" do
    test "preparation: 55 passes, 56 does not" do
      assert {:ok, %{"verdict" => "met", "high_seq" => 55}} =
               Admission.evaluate(adm(), stream([{s(55, 0), 1}]), :prepare)

      assert {{:error, {:progress_beyond, 56, 55}}, %{"verdict" => "progress_beyond:56>55"}} =
               Admission.evaluate(adm(), stream([{s(56, 0), 1}]), :prepare)
    end

    test "activation: 61 passes, 62 does not; the anchor must be the opening snapshot's" do
      assert {:ok, _} = Admission.evaluate(adm(), stream([{s(61, 0), 1}]), :activation, @pre)

      assert {{:error, {:progress_beyond, 62, 61}}, _} =
               Admission.evaluate(adm(), stream([{s(62, 0), 1}]), :activation, @pre)

      other = String.replace(@pre, "c2b2fae1,416d47ae", "c2b2fae2,416d47ae")

      assert {{:error, :anchor_not_the_opening}, _} =
               Admission.evaluate(adm(), stream([{s(10, 0), 1}]), :activation, other)
    end

    test "nothing manufactures eligibility: receipt 2 at sequence 83, off-anchor, unqualified, none, older after higher, reopened, course, kind" do
      assert {{:error, {:progress_off_anchor, 83}},
              %{"received" => 2, "high_seq" => 83, "index_gaps" => 81}} =
               Admission.evaluate(
                 adm(),
                 stream([{s(1, 0), 1}, {s(83, 50, -0.025), 51}]),
                 :prepare
               )

      assert {{:error, {:progress_off_anchor, 10}}, _} =
               Admission.evaluate(adm(), stream([{s(10, 0, 0.001), 1}]), :prepare)

      assert {{:error, {:progress_unqualified, 11}}, _} =
               Admission.evaluate(
                 adm(),
                 stream([{s(10, 0), 1}, {s(11, 50, 0.0, qualified: false), 51}]),
                 :prepare
               )

      assert {{:error, :no_progress}, %{"high_seq" => nil}} =
               Admission.evaluate(adm(), stream([]), :prepare)

      assert {{:error, {:progress_beyond, 60, 55}}, %{"not_advanced" => 1}} =
               Admission.evaluate(adm(), stream([{s(60, 0), 1}, {s(10, 50), 51}]), :prepare)

      assert {{:error, :stream_reopened}, _} =
               Admission.evaluate(adm(), stream([{s(1, 0), 1}], %{reopened: true}), :prepare)

      assert {{:error, :course_mismatch}, _} =
               Admission.evaluate(adm(), stream([{s(1, 0), 1}], %{course: "another"}), :prepare)

      assert {{:error, :stream_not_synthetic}, _} =
               Admission.evaluate(adm(), stream([{s(1, 0), 1}], %{source_kind: "game"}), :prepare)

      assert {{:error, :stream_not_open}, %{"received" => nil}} =
               Admission.evaluate(adm(), nil, :prepare)
    end
  end

  describe "Destination acquisition (the first target)" do
    test "an anchor prefix sample is the first target; skipped_identical at the anchor establishes acquisition; then the envelope rules" do
      st = new_dest()
      {st, a} = Destination.sample(st, s(62, 1_000), 60)
      assert sent(a) == [62] and st.acquisition.state == :in_flight
      # a displaced sample while the anchor target is in flight waits in the pending slot
      {st, a} = Destination.sample(st, s(83, 1_050, -0.05), 110)
      assert sent(a) == [] and st.pending.seq == 83
      {st, a} = ack(st, 62, "skipped_identical", 120)

      assert st.acquisition.state == :established and
               Destination.summary(st).acquisition.seq == 62

      # established: the pending displaced sample is judged by the unchanged envelope (0.05 m <= 0.06 m)
      assert sent(a) == [83]

      assert Enum.any?(
               a,
               &match?(
                 {:trace, %{"event" => "destination.acquisition", "state" => "established"}},
                 &1
               )
             )
    end

    test "applied exact at the anchor also establishes acquisition" do
      st = new_dest()
      {st, [_ | _] = a} = Destination.sample(st, s(5, 1_000), 60)
      assert sent(a) == [5]
      {st, _} = ack(st, 5, "applied", 70, %{post: @anchor, exact: true})
      assert st.acquisition.state == :established
    end

    test "a first routed sample past the prefix closes the session and is not forwarded, though it fits the displacement bound" do
      st = new_dest()
      # 0.05 m from P, inside the 0.1 m bound at 100 ms of credit
      {st, a} = Destination.sample(st, s(83, 1_000, -0.05), 150)
      assert sent(a) == []
      assert [{:acquisition_missed, why}] = closes(a)
      assert why == "past_prefix:83"
      assert %{state: :missed, seq: 83} = Destination.summary(st).acquisition
      assert st.counts.forwarded == 0
    end

    test "a prefix sequence off the anchor, and the anchor at a sequence past the prefix, both close" do
      {_st, a} = Destination.sample(new_dest(), s(10, 1_000, -0.001), 150)
      assert [{:acquisition_missed, why}] = closes(a)
      assert sent(a) == []
      assert why == "off_anchor:10"
      {_st, a} = Destination.sample(new_dest(), s(241, 1_000), 150)
      assert [{:acquisition_missed, _}] = closes(a)
      assert sent(a) == []
    end

    test "an anchor sample still pending (pacing) and superseded by a displaced one: the session closes, nothing is forwarded" do
      st = new_dest()
      # 20 ms after the open: inside min_forward_interval, so the anchor sample waits pending
      {st, a} = Destination.sample(st, s(61, 1_000), 20)
      assert sent(a) == [] and st.pending.seq == 61
      {st, a} = Destination.sample(st, s(84, 1_050, -0.075), 40)
      assert sent(a) == []
      assert [{:acquisition_missed, _}] = closes(a)
      assert st.counts.forwarded == 0 and st.counts.dropped_on_close == 1
    end

    test "an unqualified prefix sample is withheld and establishes nothing" do
      st = new_dest()
      {st, a} = Destination.sample(st, s(10, 1_000, 0.0, qualified: false), 60)
      assert sent(a) == [] and closes(a) == [] and st.acquisition.state == :awaiting
    end

    test "a withdrawn acquisition target establishes nothing" do
      st = new_dest()
      {st, a} = Destination.sample(st, s(10, 1_000), 60)
      assert sent(a) == [10]
      st = Destination.withdrawn(st, 10)
      assert st.acquisition.state == :awaiting and st.acquisition.seq == nil
    end

    test "without an admission there is no acquisition state: the unchanged contract forwards a displaced first target inside the bound" do
      st = new_dest(nil)
      {st, a} = Destination.sample(st, s(83, 1_000, -0.05), 150)
      assert sent(a) == [83]
      assert Destination.summary(st).acquisition == nil
    end

    test "an expected horizontal word, never z: a sample differing only in z is at the anchor" do
      st = new_dest()
      smp = %{s(10, 1_000) | pos: TransformWords.encode([0xC2B2FAE1, 0x416D47AE, 0x40000000])}
      {_st, a} = Destination.sample(st, smp, 60)
      assert sent(a) == [10]
      assert xy(0.0) == @anchor
    end
  end
end

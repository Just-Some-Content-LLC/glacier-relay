defmodule GlacierRelay.Motion.SourceCourseTest do
  @moduledoc """
  M7-B1: the share relay's rules (design section 15.4, 15.6) and the deterministic course generator
  (section 15.9), pure. The courses are offline fixtures from section 14's proposed geometry: their
  checks are numeric (area, steps, origin), never clearance.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.TransformWords
  alias GlacierRelay.Motion.{Course, Source}

  @share "2a3b4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d"
  @p {0xC2B2FAE1, 0x416D47AE}

  defp hs(seq, native_ms, opts \\ []),
    do: %{
      share_id: @share,
      seq: seq,
      frame: 100 + seq,
      native_mono_ms: native_ms,
      pos: "c2a77ccf,416b27e8,bfc2d6ba",
      dirty: Keyword.get(opts, :dirty, false)
    }

  defp src,
    do:
      Source.new(%{
        share_id: @share,
        interval_ms: 50,
        duration_ms: 1_000,
        opened_at: 0,
        label: "test"
      })

  defp relayed(actions), do: for({:send_peer, "pose.sample", f} <- actions, do: f)

  describe "share relay" do
    test "relays the native's samples with the native clock as the source clock" do
      {st, a} = Source.hero_sample(src(), hs(1, 5_000), 10)
      assert [f] = relayed(a)

      assert f["stream_id"] == @share and f["seq"] == 1 and f["src_mono_ms"] == 5_000 and
               f["qualified"]

      assert Source.stream_open(st)["source_kind"] == "game"
      assert Source.stream_open(st)["src_clock"] == "native"
    end

    test "a dirty sample is relayed labelled unqualified, never as a valid one" do
      {st, a} = Source.hero_sample(src(), hs(1, 5_000, dirty: true), 10)
      assert [%{"qualified" => false, "reason" => "dirty"}] = relayed(a)
      assert st.counts.relayed_unqualified == 1
    end

    test "duplicates, older samples and a non-increasing native clock" do
      {st, _} = Source.hero_sample(src(), hs(2, 5_000), 10)
      {st, a} = Source.hero_sample(st, hs(2, 5_050), 60)
      assert relayed(a) == [] and st.counts.duplicate == 1
      {st, a} = Source.hero_sample(st, hs(1, 5_100), 110)
      assert relayed(a) == [] and st.counts.older == 1
      {st, a} = Source.hero_sample(st, hs(3, 5_000), 160)
      assert {:send_share_close, :native_clock_not_increasing} in a
      assert st.phase == :closing
    end

    test "the send rate: at least 90 % of the interval between relayed samples" do
      {st, _} = Source.hero_sample(src(), hs(1, 5_000), 100)
      {st, a} = Source.hero_sample(st, hs(2, 5_010), 144)
      assert relayed(a) == [] and st.counts.rate == 1
      {_st, a} = Source.hero_sample(st, hs(3, 5_060), 145)
      assert [_] = relayed(a)
    end

    test "the duration ends the share and the stream" do
      {st, a} = Source.tick(src(), 1_000)
      assert {:send_share_close, :duration} in a

      assert [{"stream.end", %{"reason" => "duration"}}] =
               for({:send_peer, "stream.end", f} <- a, do: {"stream.end", f})

      {st, a} = Source.native_closed(st, %{reason: "beam:duration", last_seq: 0, sent: 0}, 1_010)
      assert st.phase == :closed and st.close.state == :confirmed
      assert [{:closed, _}] = for({:closed, _} = c <- a, do: c)
    end

    test "the link lost: the close is unknown" do
      {st, _} = Source.link_lost(src(), 10)
      assert st.close.state == :unknown
    end
  end

  describe "courses" do
    defp courses do
      [
        Course.out_and_back(@p),
        Course.out_and_back(@p,
          direction: :reverse,
          heading_rad: :math.pi() / 2,
          distance_m: 0.5
        ),
        Course.shuttle(@p, a: {-91.318, 14.833}, b: {-84.044, 14.833}),
        Course.shuttle(@p,
          a: {-91.318, 14.833},
          b: {-84.044, 14.833},
          direction: :reverse,
          laps: 2
        ),
        Course.rectangle(@p, x: {-92.82, -86.17}, y: {10.49, 19.17}),
        Course.rectangle(@p, x: {-92.82, -86.17}, y: {10.49, 19.17}, direction: :reverse),
        Course.figure_eight(@p, c1: {-87.670, 17.672}, c2: {-91.318, 17.672}),
        Course.figure_eight(@p,
          c1: {-87.670, 17.672},
          c2: {-91.318, 17.672},
          direction: :reverse
        ),
        Course.circle(@p, center: {-89.49, 12.0}, radius_m: 1.5),
        Course.circle(@p, center: {-89.49, 12.0}, radius_m: 1.5, direction: :reverse)
      ]
    end

    test "every profile starts stationary at the anchor's exact words and passes the default limits" do
      for c <- courses() do
        assert {:ok, stats} = Course.check(c), "#{c.name} #{inspect(c.params)}"
        [first, second | _] = Course.samples(c)
        assert {first.x_word, first.y_word} == @p
        # the stationary prefix: the second sample is still the anchor
        assert {second.x_word, second.y_word} == @p
        assert stats.max_step_m <= c.speed_mps * c.interval_ms / 1_000 + 0.001
        {x0, x1, y0, y1} = stats.bbox
        {ax, ay} = c.origin

        assert abs(x0 - ax) <= 8.0 and abs(x1 - ax) <= 8.0 and abs(y0 - ay) <= 8.0 and
                 abs(y1 - ay) <= 8.0
      end
    end

    test "every profile returns to the anchor and ends with a hold there" do
      for c <- courses() do
        last = List.last(Course.samples(c))

        assert abs(last.x - elem(c.origin, 0)) < 1.0e-4 and
                 abs(last.y - elem(c.origin, 1)) < 1.0e-4,
               "#{c.name} ends at #{last.x},#{last.y}"
      end
    end

    test "deterministic: the same parameters give the same samples and timestamps" do
      for c <- courses(), do: assert(Course.samples(c) == Course.samples(c))
      [_, b | _] = Course.samples(Course.shuttle(@p, a: {-91.318, 14.833}, b: {-84.044, 14.833}))
      assert b.t_ms == 50 and b.seq == 2
    end

    test "reverse directions really reverse the first move" do
      move = fn c -> Enum.find(Course.samples(c), &({&1.x_word, &1.y_word} != @p)) end
      {ax, ay} = Course.out_and_back(@p).origin

      f = move.(Course.out_and_back(@p))
      r = move.(Course.out_and_back(@p, direction: :reverse))
      assert f.x > ax and r.x < ax

      f = move.(Course.figure_eight(@p, c1: {-87.670, 17.672}, c2: {-91.318, 17.672}))
      assert f.y > ay
      # the crossing is reached by an explicit transition, never acquired by a jump
      c8 = Course.figure_eight(@p, c1: {-87.670, 17.672}, c2: {-91.318, 17.672})
      steps = c8 |> Course.samples() |> Enum.chunk_every(2, 1, :discard)

      assert Enum.all?(steps, fn [a, b] ->
               :math.sqrt(:math.pow(b.x - a.x, 2) + :math.pow(b.y - a.y, 2)) <= 0.051
             end)
    end

    test "the figure-eight's lobes turn in opposite senses through the crossing" do
      c = Course.figure_eight(@p, c1: {-87.670, 17.672}, c2: {-91.318, 17.672})
      assert [{:hold, _}, {:line, {cx, cy}}, {:arc, _, s1}, {:arc, _, s2} | _] = c.segments
      assert_in_delta cx, -89.494, 1.0e-9
      assert_in_delta cy, 17.672, 1.0e-9
      assert s1 * s2 < 0
    end

    test "check/2 finds courses that leave a tighter area or exceed the session's speed" do
      big = Course.shuttle(@p, a: {-91.318, 14.833}, b: {-84.044, 14.833})
      assert {:error, [{:outside_area, _} | _]} = Course.check(big, %{half_extent_mm: 1_000})
      fast = Course.out_and_back(@p, speed_mps: 2.5, distance_m: 1.0)
      assert {:error, [{:step, _, _} | _]} = Course.check(fast, %{max_speed_mmps: 2_000})
    end

    test "the recommended first destination course: a short slow out-and-back along the avenue" do
      c = Course.out_and_back(@p, heading_rad: :math.pi(), distance_m: 1.0, speed_mps: 0.5)
      assert {:ok, stats} = Course.check(c, %{half_extent_mm: 2_000, max_speed_mmps: 500})
      assert stats.length_m > 1.99 and stats.length_m < 2.01
      assert stats.max_step_m <= 0.0251
      assert Course.describe(c) =~ "out_and_back v=0.5"
      assert byte_size(Course.describe(c)) <= 200
    end

    test "positions are binary32 words; the pos text carries x, y and the constant z" do
      [s | _] = Course.samples(Course.out_and_back(@p, z_word: 0xBFC2D6BA))
      assert s.pos == "c2b2fae1,416d47ae,bfc2d6ba"
      assert {:ok, [_, _, _]} = TransformWords.decode(s.pos, 3)
    end
  end
end

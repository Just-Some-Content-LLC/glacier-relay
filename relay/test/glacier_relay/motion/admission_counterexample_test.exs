defmodule GlacierRelay.Motion.AdmissionCounterexampleTest do
  @moduledoc """
  M7-L3 source-sequence admission correction (`docs/design/M7_NETWORK_GHOST.md` section 29;
  `M7L3_LAN_GAME_PREPARATION.md` section 13): the strict counterexample to the sealed M7-L3
  `dest-wait` gate. That gate admitted a session on the hub's count of unrouted samples received
  since its baseline (at most 55 before the open, 61 at activation), never on the stream's source
  sequence. Here the source has omitted samples 2 … 82 — as spacing, producer or stale-queue drops
  can — so the host has received two samples (sequences 1 and 83) while the course is already
  displaced. The former gate's two quantities are computed exactly as `cmd-m7l3.exs` computed them,
  and both pass; the session opens without an admission condition (the contract of sections 15–17,
  unchanged for such callers); and the next sample, sequence 84 of M7-C's real course, 0.075 m from
  P, is forwarded as the FIRST target and applied by the fake native inside the session's
  displacement bound (0.1 m at M7-C's limits). The envelope holds; the stationary-prefix start does
  not. Samples are production-decoded events injected through the hub's handler API on a stream
  opened the same way (as `DeadlineHubTest`); the fake native and the motion socket are real.
  Fake-native evidence only.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command.Schema
  alias GlacierRelay.Motion.{Course, Hub}
  alias GlacierRelay.Peer.Codec
  alias GlacierRelay.Test.{FakeMotionNative, MotionStack}

  @p FakeMotionNative.anchor_words()
  # M7-C's course and session limits (the sealed cmd-m7l3.exs constants)
  @course_opts [
    distance_m: 1.0,
    speed_mps: 0.5,
    heading_rad: 0.0,
    direction: :reverse,
    prefix_ms: 4_000,
    hold_ms: 2_000,
    interval_ms: 50
  ]
  @limits %{duration_ms: 20_000, half_extent_mm: 1_250, max_speed_mmps: 1_000, credit_ms: 100}

  defp wait(fun, attempts \\ 400, sleep \\ 10), do: MotionStack.wait(fun, attempts, sleep)
  defp peer_info, do: :sys.get_state(Hub).peer.info
  defp unrouted, do: Hub.status().counts.unrouted_samples

  defp targets(fake),
    do: for({:target_line, _sid, seq, _t} <- FakeMotionNative.events(fake), do: seq)

  defp decode!(line) do
    {:ok, decoded} = Codec.decode(String.trim_trailing(line, "\n"))
    decoded
  end

  defp open_stream(course) do
    id = Schema.uuid4()

    {:stream_open, f} =
      decode!(
        Codec.encode("stream.open", %{
          "stream_id" => id,
          "source_kind" => "synthetic",
          "interval_ms" => 50,
          "src_clock" => "beam",
          "label" => "M7-L3 synthetic course (Mac headless peer; not a player)",
          "course" => Course.describe(course)
        })
      )

    :ok = Hub.peer_event(Hub, {:stream_open, peer_info(), f}, 1_000)
    id
  end

  defp send_seq(stream, samples, seq) do
    s = Enum.find(samples, &(&1.seq == seq))

    {:pose_sample, f} =
      decode!(
        Codec.encode("pose.sample", %{
          "stream_id" => stream,
          "seq" => seq,
          "src_mono_ms" => GlacierRelay.Motion.Clock.now_ms(),
          "src_frame" => nil,
          "pos" => s.pos,
          "qualified" => true,
          "reason" => nil
        })
      )

    :ok = Hub.peer_event(Hub, {:sample, peer_info(), f}, 1_000)
  end

  test "CE-1: receipt 2 at source sequence 83 passes the former count gate, and a displaced first target is applied" do
    st = MotionStack.start()
    course = Course.out_and_back(@p, @course_opts)
    samples = Course.samples(course)
    assert length(samples) == 241
    assert Enum.find(samples, &({&1.x_word, &1.y_word} != @p)).seq == 82

    stream = open_stream(course)
    # the former gate's baseline: the hub's unrouted counter when the sequence was prepared
    base = unrouted()

    # the source omitted 2 … 82 (unobservable to the host before the stream's end)
    :ok = send_seq(stream, samples, 1)
    :ok = send_seq(stream, samples, 83)
    k_pre = unrouted() - base

    assert k_pre == 2 and k_pre <= 55,
           "the former open gate (<= 55 received) passes at source sequence 83"

    {_sid, _cid} = MotionStack.open_session(st.adapter, stream, limits: @limits)
    k_act = unrouted() - base
    assert k_act == 2 and k_act <= 61, "the former activation gate (<= 61 received) passes"

    # the credit for a 0.075 m first step accrues in 75 ms of receiver time after the open
    Process.sleep(150)
    :ok = send_seq(stream, samples, 84)
    wait(fn -> Hub.status().session.summary.counts.applied == 1 end)

    s = Hub.status().session.summary
    p84 = Enum.find(samples, &(&1.seq == 84))
    assert targets(st.fake) == [84], "the first target bytes the native read are sequence 84's"
    assert s.confirmed_seq == 84
    assert s.confirmed_pos == GlacierRelay.Command.TransformWords.encode([p84.x_word, p84.y_word])
    dx = abs(p84.x - GlacierRelay.Command.TransformWords.to_float(elem(@p, 0)))
    assert_in_delta dx, 0.075, 1.0e-5
    assert dx <= @limits.max_speed_mmps * @limits.credit_ms / 1_000_000

    :ok = GlacierRelay.Motion.close_session(:test_end)
    wait(fn -> match?(%{status: :done}, Hub.status().session) end, 300)
  end
end

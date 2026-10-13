defmodule GlacierRelay.Recording.ReplayPerfTest do
  @moduledoc "M4-B measurements, printed, no thresholds: read, fold and render time and memory on the largest recording the fixtures make."
  use ExUnit.Case, async: false

  alias GlacierRelay.MissionSession
  alias GlacierRelay.Recording.{Reader, Recorder, Replay}
  alias GlacierRelay.Test.RecordingFixtures, as: F

  @fixtures ~w(stage1 stage_a_probe b1_probe b2_probe b3_probe b4_probe b5_probe b5_run1 b6_probe b6_run1)

  test "replay of all ten fixtures recorded into one recording" do
    :ok = MissionSession.subscribe()
    {rec, _, _} = F.start_recorder()
    ids = for name <- @fixtures, do: F.play(name, "perf")
    {:ok, summary} = Recorder.close(rec)

    bytes =
      summary.segments
      |> Enum.map(fn {n, _} -> File.stat!(Path.join(summary.recording_dir, n)).size end)
      |> Enum.sum()

    :erlang.garbage_collect()
    mem0 = :erlang.memory(:total)
    {read_us, {:ok, result}} = :timer.tc(fn -> Reader.read(summary.recording_dir) end)
    {replay_us, replay} = :timer.tc(fn -> Replay.replay_result(result) end)
    mem1 = :erlang.memory(:total)

    # A second run, warm, for the per-stage timings.
    {:ok, warm} = Replay.replay(summary.recording_dir)

    IO.puts("""

    [replay perf] #{length(ids)} instances, #{length(result.records)} records, #{bytes} bytes on disk:
      cold: read+verify #{read_us} us; fold+render #{replay_us} us (fold #{replay.timings_us.fold} us, render #{replay.timings_us.render} us)
      warm: read+verify #{warm.timings_us.read} us; fold #{warm.timings_us.fold} us; render #{warm.timings_us.render} us
      VM total memory during the cold replay: #{mem0} -> #{mem1} bytes (delta #{mem1 - mem0})
    """)

    assert replay.completeness.recorder_authoritative?
    assert Map.keys(replay.instances) |> Enum.sort() == Enum.sort(ids)
  end
end

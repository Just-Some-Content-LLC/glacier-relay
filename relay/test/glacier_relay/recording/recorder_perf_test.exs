defmodule GlacierRelay.Recording.RecorderPerfTest do
  @moduledoc """
  M4-A measurements, printed, no thresholds (design section 12): the B5 45-envelope fixture
  through the real listener with the recorder disabled and enabled; flush and sync latencies;
  mailbox growth; the ingest difference; close time.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.MissionSession
  alias GlacierRelay.Recording.Recorder
  alias GlacierRelay.Test.FixturePlayer

  @runs 3

  setup do
    :ok = MissionSession.subscribe()

    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-recorder-perf-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp ingest(prefix) do
    id = FixturePlayer.unique_id(prefix)
    lines = FixturePlayer.lines("b5_run1") |> FixturePlayer.with_instance(id)
    socket = FixturePlayer.connect()
    t0 = System.monotonic_time(:microsecond)
    FixturePlayer.send_lines(socket, lines)
    FixturePlayer.await(id, 45)
    t1 = System.monotonic_time(:microsecond)
    :gen_tcp.close(socket)
    FixturePlayer.await_closed(id)
    t1 - t0
  end

  test "B5 fixture ingest with the recorder disabled and enabled", %{dir: dir} do
    baseline = for _ <- 1..@runs, do: ingest("perf-off")

    name = :"recorder_perf_#{System.unique_integer([:positive])}"
    start_supervised!({Recorder, name: name, dir: dir, flush_ms: 100})
    recorded = for _ <- 1..@runs, do: ingest("perf-on")
    health = Recorder.flush(name)
    t0 = System.monotonic_time(:microsecond)
    assert {:ok, summary} = Recorder.close(name)
    close_us = System.monotonic_time(:microsecond) - t0

    bytes =
      summary.segments
      |> Enum.map(fn {n, _} -> File.stat!(Path.join(summary.recording_dir, n)).size end)
      |> Enum.sum()

    IO.puts("""

    [recorder perf] B5 45-envelope fixture, #{@runs} runs each (send → last session notification):
      recorder disabled: #{Enum.map_join(baseline, ", ", &"#{div(&1, 1000)}.#{rem(&1, 1000) |> div(100)} ms")}
      recorder enabled:  #{Enum.map_join(recorded, ", ", &"#{div(&1, 1000)}.#{rem(&1, 1000) |> div(100)} ms")}
      flushes #{health.flushes}; write us last/max #{health.write_us.last}/#{health.write_us.max}; sync us last/max/total #{health.sync_us.last}/#{health.sync_us.max}/#{health.sync_us.total}
      mailbox max #{health.mailbox_max}; records received #{health.records_received}; lines written #{health.lines_written}; bytes #{health.bytes_written}
      close (drain, flush, footer, hashes, marker): #{close_us} us; recording bytes on disk #{bytes}
    """)

    assert health.overflow_events == 0 and health.gaps == []
  end
end

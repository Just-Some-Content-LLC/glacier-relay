defmodule GlacierRelay.Dashboard.ProjectionPerfTest do
  @moduledoc """
  M3-B measurements (not thresholds): the largest fixture at full speed, the B1 window at its
  observed publication rate and accelerated, the session read and recompute latencies, the
  number of recomputes and snapshots per burst, the text route's latency under the burst, the
  memory of a 200-row event window, and ingestion time with the dashboard on and off. The
  numbers are printed for the record; the assertions are sanity only.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.{MissionSession, Summary}
  alias GlacierRelay.Dashboard.Projection
  alias GlacierRelay.Test.FixturePlayer, as: Player
  alias GlacierRelay.Wire.Envelope

  setup do
    start_supervised!(GlacierRelayWeb.Supervisor)
    :ok = MissionSession.subscribe()
    :ok = Phoenix.PubSub.subscribe(GlacierRelay.PubSub, Projection.snapshot_topic())
    :ok
  end

  defp entry(s, id), do: Enum.find(s.instances, &(&1.id == id))

  defp drain_snapshots(done?, count \\ 0) do
    receive do
      {:snapshot, s} -> if done?.(s), do: {count + 1, s}, else: drain_snapshots(done?, count + 1)
    after
      5_000 -> raise "no final snapshot"
    end
  end

  defp http_get(path) do
    {:ok, {_, port}} = GlacierRelayWeb.Endpoint.server_info(:http)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      )

    recv(socket, "")
  end

  defp recv(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, b} -> recv(socket, acc <> b)
      {:error, :closed} -> :gen_tcp.close(socket) && acc
    end
  end

  defp burst(name, id, last, opts) do
    before = Projection.stats()
    t0 = System.monotonic_time(:microsecond)
    Player.play(name, id, opts)
    Player.await(id, last)
    ingest_us = System.monotonic_time(:microsecond) - t0

    {snapshots, final} =
      drain_snapshots(fn s ->
        (e = entry(s, id)) && e.last_sequence == last && e.observation == :lost
      end)

    stats = Projection.stats()

    %{
      ingest_us: ingest_us,
      snapshots: snapshots,
      recomputes: stats.recomputes - before.recomputes,
      read_us_max: stats.read_us.max,
      read_us_last: stats.read_us.last,
      compute_us_max: stats.compute_us.max,
      compute_us_last: stats.compute_us.last,
      final: final
    }
  end

  test "measurements: largest fixture, B1 window at observed and accelerated rates, text route under burst, window memory" do
    Process.flag(:trap_exit, true)

    # A warm-up burst first: the first recompute in a fresh VM pays for code loading, which is
    # not what the controlled experiment will see. Cold numbers are recorded separately.
    cold = burst("b6_run1", Player.unique_id("perf-cold"), 16, [])
    id45 = Player.unique_id("perf45")

    # The text route (the M3-A exception) is polled during the 45-envelope burst.
    poller =
      Task.async(fn ->
        for _ <- 1..8 do
          t = System.monotonic_time(:microsecond)
          _ = http_get("/report.txt")
          System.monotonic_time(:microsecond) - t
        end
      end)

    m45 = burst("b5_run1", id45, 45, [])
    route_us = Task.await(poller)
    [r] = Summary.report(%{id45 => MissionSession.state()[id45]})
    assert entry(m45.final, id45).report == r
    assert m45.recomputes <= 46

    idb1 = Player.unique_id("perfb1-observed")
    mb1 = burst("b1_probe", idb1, 18, speed: 1.0)
    idb1f = Player.unique_id("perfb1-fast")
    mb1f = burst("b1_probe", idb1f, 18, [])
    [rb] = Summary.report(%{idb1f => MissionSession.state()[idb1f]})
    assert entry(mb1f.final, idb1f).report == rb
    [attempt] = rb.attempts

    assert Enum.map(attempt.timeline.lines, & &1.sequence) |> Enum.reject(&is_nil/1) |> length() >=
             16

    # Memory of a 200-row event window (the dashboard's bounded pane) built from real envelopes.
    rows =
      "b5_run1"
      |> Player.lines()
      |> Stream.cycle()
      |> Enum.take(200)
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        {:ok, e} = Envelope.decode(line)

        %{
          id: "evt-x-#{i}",
          kind: :event,
          instance_id: e.adapter_instance_id,
          sequence: i,
          at: e.timestamp,
          type: e.event_type,
          detail: JSON.encode!(e.payload),
          tag: :engine
        }
      end)

    window_bytes = :erts_debug.flat_size(rows) * :erlang.system_info(:wordsize)

    # Ingestion with the dashboard off, for comparison.
    :ok = stop_supervised!(GlacierRelayWeb.Supervisor)
    idoff = Player.unique_id("perfoff")
    t0 = System.monotonic_time(:microsecond)
    Player.play("b5_run1", idoff)
    Player.await(idoff, 45)
    ingest_off_us = System.monotonic_time(:microsecond) - t0

    IO.puts("""

    [perf] M3-B projection measurements (#{DateTime.utc_now() |> DateTime.to_iso8601()})
    [perf] cold warm-up, b6_run1 (16 envelopes, full speed, first burst in this VM): ingest #{cold.ingest_us} us; snapshots #{cold.snapshots}; recomputes #{cold.recomputes}; session read max #{cold.read_us_max} us; recompute max #{cold.compute_us_max} us
    [perf] b5_run1 (45 envelopes, full speed): ingest #{m45.ingest_us} us; snapshots #{m45.snapshots}; recomputes #{m45.recomputes}; session read max #{m45.read_us_max} us (last #{m45.read_us_last}); recompute max #{m45.compute_us_max} us (last #{m45.compute_us_last})
    [perf] /report.txt during the burst: #{Enum.count(route_us)} GETs, max #{Enum.max(route_us)} us, min #{Enum.min(route_us)} us
    [perf] b1_probe (18 envelopes) at the observed publication rate: ingest #{mb1.ingest_us} us; snapshots #{mb1.snapshots}; recomputes #{mb1.recomputes}
    [perf] b1_probe (18 envelopes) accelerated (full speed): ingest #{mb1f.ingest_us} us; snapshots #{mb1f.snapshots}; recomputes #{mb1f.recomputes}; recompute max #{mb1f.compute_us_max} us
    [perf] 200-row event window from real envelopes: #{window_bytes} bytes (flat size)
    [perf] b5_run1 ingest with the dashboard disabled: #{ingest_off_us} us (dashboard enabled above: #{m45.ingest_us} us)
    """)

    assert window_bytes > 0
  end
end

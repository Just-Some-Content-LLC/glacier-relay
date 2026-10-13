defmodule GlacierRelay.Recording.RecorderTest do
  @moduledoc """
  The recorder through the real listener (M4-A): records equal the session's evidence in the
  session's order with the session's times; transport identity by connection number; the close
  protocol; process restart; segment roll; overload, write failure and budget behaviour; and
  isolation from the existing subscribers, the headless tree and the dashboard.
  """
  # Not async: shares the application's listener and MissionSession.
  use ExUnit.Case, async: false

  alias GlacierRelay.{Lifecycle, MissionSession}
  alias GlacierRelay.Recording.{Codec, Recorder, Segment}
  alias GlacierRelay.Test.{FixturePlayer, StubWriter}

  setup do
    :ok = MissionSession.subscribe()

    dir =
      Path.join(System.tmp_dir!(), "glacier-relay-recorder-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # -- helpers ---------------------------------------------------------------------------------

  defp start(dir, opts \\ []) do
    name = :"recorder_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, dir: dir, flush_ms: 20], opts)
    pid = start_supervised!({Recorder, opts})
    {name, pid}
  end

  defp recording_dir(name), do: Recorder.health(name).recording_dir

  # A session call first: the records the session just sent are then ahead of the flush request.
  defp flush(name) do
    _ = MissionSession.unidentified()
    Recorder.flush(name)
  end

  defp segments(rdir), do: rdir |> Path.join("segment-*.ndjson") |> Path.wildcard() |> Enum.sort()

  defp lines(rdir) do
    for path <- segments(rdir), line <- File.read!(path) |> String.split("\n", trim: true) do
      {:ok, map} = Codec.decode_line(line)
      map
    end
  end

  defp verified_lines(summary) do
    for {name, _hash} <- summary.segments,
        line <-
          File.read!(Path.join(summary.recording_dir, name)) |> String.split("\n", trim: true) do
      {:ok, map} = Codec.decode_line(line)
      map
    end
  end

  defp records(lines), do: Enum.filter(lines, &Map.has_key?(&1, "r"))
  defp of_instance(lines, id), do: Enum.filter(lines, &(&1["instance"] == id))
  defp kinds(lines), do: Enum.map(lines, & &1["k"])

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # Every number between first and last is either a record line or inside a gap range.
  defp covered?(lines, first, last) do
    recorded = lines |> records() |> MapSet.new(& &1["r"])

    gapped =
      lines
      |> Enum.filter(&(&1["k"] == "recorder.gap" and is_integer(&1["to"])))
      |> Enum.flat_map(&Enum.to_list(&1["from"]..&1["to"]))
      |> MapSet.new()

    Enum.all?(first..last, &(MapSet.member?(recorded, &1) or MapSet.member?(gapped, &1)))
  end

  # -- recording a fixture ---------------------------------------------------------------------

  test "a fixture played through the listener is recorded in session order with the session's times",
       %{dir: dir} do
    {name, _} = start(dir)
    id = FixturePlayer.unique_id("rec-b6")
    fixture = FixturePlayer.lines("b6_run1") |> FixturePlayer.with_instance(id)
    :closed = FixturePlayer.play("b6_run1", id)
    FixturePlayer.await_closed(id)
    health = flush(name)
    assert health.status == :recording

    all = lines(recording_dir(name))
    [header | _] = all
    assert header["k"] == "recording.opened" and header["format"] == 1 and header["segment"] == 1

    assert header["transport"] == "recorded" and header["origin"] == "live" and
             header["resumed"] == false

    assert header["recording_id"] == health.recording_id and
             header["listener"]["ip"] == "127.0.0.1"

    mine =
      all
      |> records()
      |> Enum.filter(
        &(&1["instance"] == id or &1["k"] in ["connection.opened", "connection.closed"])
      )

    # The connection of this fixture: identified for this instance; its number is reused on every record.
    [ident] = Enum.filter(mine, &(&1["k"] == "connection.identified"))
    conn = ident["conn"]
    assert is_integer(conn) and ident["previous_instance"] == nil
    [opened] = Enum.filter(mine, &(&1["k"] == "connection.opened" and &1["conn"] == conn))
    [closed] = Enum.filter(mine, &(&1["k"] == "connection.closed" and &1["conn"] == conn))

    assert opened["r"] < ident["r"] and closed["reason"] == "peer_closed" and
             closed["instance"] == id

    envelopes = of_instance(mine, id) |> Enum.filter(&(&1["k"] == "envelope"))
    assert length(envelopes) == 16
    assert Enum.map(envelopes, & &1["sequence"]) == Enum.to_list(1..16)
    assert Enum.all?(envelopes, &(&1["conn"] == conn))
    # Value-exact against the wire lines.
    assert Enum.map(envelopes, & &1["envelope"]) == Enum.map(fixture, &JSON.decode!/1)
    # Record numbers strictly increase in file order; the recording is contiguous.
    rs = all |> records() |> Enum.map(& &1["r"])
    assert rs == Enum.sort(rs) and rs == Enum.to_list(hd(rs)..List.last(rs))

    # `at` is the session's own receipt time, not the recorder's clock.
    inst = MissionSession.state()[id]
    [attempt] = inst.attempts
    [playing] = Enum.filter(envelopes, &(&1["event_type"] == "mission.playing"))
    assert playing["at"] == iso(attempt.playing.received_at)
    [stopped] = Enum.filter(envelopes, &(&1["event_type"] == "mission.stopped"))
    assert stopped["at"] == iso(attempt.stopped.received_at)
    [%Lifecycle.Connection{} = c] = inst.connections

    assert opened["at"] == iso(c.opened_at) and ident["at"] == iso(c.identified_at) and
             closed["at"] == iso(c.closed_at)

    assert health.durable_boundary == List.last(rs) and health.records_received >= length(rs)
  end

  test "several adapter instances are recorded apart, each with its own connection number", %{
    dir: dir
  } do
    {name, _} = start(dir)
    a = FixturePlayer.unique_id("rec-a")
    b = FixturePlayer.unique_id("rec-b")
    :closed = FixturePlayer.play("stage1", a)
    :closed = FixturePlayer.play("b2_probe", b)
    FixturePlayer.await_closed(a)
    FixturePlayer.await_closed(b)
    flush(name)
    all = lines(recording_dir(name))
    [ia] = all |> of_instance(a) |> Enum.filter(&(&1["k"] == "connection.identified"))
    [ib] = all |> of_instance(b) |> Enum.filter(&(&1["k"] == "connection.identified"))
    assert ia["conn"] != ib["conn"]
    assert Enum.all?(of_instance(all, a), &(&1["conn"] == ia["conn"]))
    assert Enum.all?(of_instance(all, b), &(&1["conn"] == ib["conn"]))
    assert length(Enum.filter(of_instance(all, a), &(&1["k"] == "envelope"))) == 3
    assert length(Enum.filter(of_instance(all, b), &(&1["k"] == "envelope"))) == 9
  end

  # -- transport evidence ------------------------------------------------------------------------

  test "re-attribution, unidentified close, and a close that is never a stop", %{dir: dir} do
    {name, _} = start(dir)
    a = FixturePlayer.unique_id("re-a")
    b = FixturePlayer.unique_id("re-b")
    [l1, l2 | _] = FixturePlayer.lines("b6_run1")

    # One socket names a then b.
    socket = FixturePlayer.connect()
    FixturePlayer.send_lines(socket, FixturePlayer.with_instance([l1, l2], a))
    FixturePlayer.await(a, 2)
    FixturePlayer.send_lines(socket, FixturePlayer.with_instance([l1, l2], b))
    FixturePlayer.await(b, 2)
    :gen_tcp.close(socket)
    FixturePlayer.await_closed(b)

    # Another socket opens and closes without a line.
    silent = FixturePlayer.connect()
    assert_receive {:relay_connection, :opened, _}, 2_000
    :gen_tcp.close(silent)
    assert_receive {:relay_connection, :closed, %{instance_id: nil}}, 2_000

    flush(name)
    all = lines(recording_dir(name))

    idents =
      all
      |> records()
      |> Enum.filter(&(&1["k"] == "connection.identified" and &1["instance"] in [a, b]))

    assert [
             %{"instance" => ^a, "previous_instance" => nil, "conn" => conn},
             %{"instance" => ^b, "previous_instance" => ^a, "conn" => conn}
           ] = idents

    [closed] = Enum.filter(all, &(&1["k"] == "connection.closed" and &1["conn"] == conn))
    assert closed["instance"] == b
    ia = of_instance(all, a) |> kinds()
    assert ia == ["connection.identified", "envelope", "envelope"]

    assert of_instance(all, b) |> kinds() == [
             "connection.identified",
             "envelope",
             "envelope",
             "connection.closed"
           ]

    # The silent connection: opened then closed, never identified, no instance.
    silent_conn =
      all |> Enum.filter(&(&1["k"] == "connection.opened")) |> List.last() |> Map.fetch!("conn")

    assert silent_conn > conn

    assert [
             %{"k" => "connection.opened"},
             %{"k" => "connection.closed", "instance" => nil, "reason" => "peer_closed"}
           ] =
             Enum.filter(all, &(&1["conn"] == silent_conn))

    # The close is transport evidence only: the attempts stay last known playing with observation lost.
    for id <- [a, b] do
      inst = MissionSession.state()[id]
      assert [%Lifecycle.Attempt{mission: :playing}] = inst.attempts
      refute Enum.any?(of_instance(all, id), &(&1["event_type"] == "mission.stopped"))
    end

    assert Lifecycle.observation(MissionSession.state()[b]) == :lost
  end

  test "connections sharing one peer description get distinct session connection numbers", %{
    dir: dir
  } do
    {name, _} = start(dir)
    peer = "127.0.0.1:1"
    at = ~U[2026-10-13 05:00:00Z]
    parent = self()

    # Two processes announce the same peer string; the second delivers an envelope.
    spawn_conn = fn deliver ->
      spawn(fn ->
        MissionSession.connection_opened(peer, at)
        if deliver, do: MissionSession.handle_event(deliver, at)

        receive do
          :close -> MissionSession.connection_closed(:peer_closed, at)
        end

        send(parent, :closed)
      end)
    end

    id = FixturePlayer.unique_id("peer")

    {:ok, envelope} =
      FixturePlayer.lines("stage1")
      |> FixturePlayer.with_instance(id)
      |> hd()
      |> GlacierRelay.Wire.Envelope.decode()

    p1 = spawn_conn.(nil)
    assert_receive {:relay_connection, :opened, %{peer: ^peer}}, 2_000
    p2 = spawn_conn.(envelope)
    assert_receive {:relay_connection, :identified, %{peer: ^peer, instance_id: ^id}}, 2_000
    send(p1, :close)
    send(p2, :close)
    assert_receive :closed, 2_000
    assert_receive :closed, 2_000
    assert_receive {:relay_connection, :closed, %{peer: ^peer, instance_id: nil}}, 2_000
    assert_receive {:relay_connection, :closed, %{peer: ^peer, instance_id: ^id}}, 2_000

    flush(name)
    all = lines(recording_dir(name))
    same_peer = Enum.filter(all, &(&1["peer"] == peer))
    conns = same_peer |> Enum.map(& &1["conn"]) |> Enum.uniq()
    assert length(conns) == 2
    [c1, c2] = conns

    assert Enum.filter(same_peer, &(&1["conn"] == c1)) |> kinds() == [
             "connection.opened",
             "connection.closed"
           ]

    assert Enum.filter(same_peer, &(&1["conn"] == c2)) |> kinds() == [
             "connection.opened",
             "connection.identified",
             "connection.closed"
           ]

    [env] = all |> of_instance(id) |> Enum.filter(&(&1["k"] == "envelope"))
    assert env["conn"] == c2 and env["at"] == iso(at)
  end

  # -- the close protocol ------------------------------------------------------------------------

  test "the close protocol writes the footer, the hashes and the marker, then records nothing more",
       %{dir: dir} do
    {name, _} = start(dir)
    id = FixturePlayer.unique_id("close")
    :closed = FixturePlayer.play("b5_run1", id)
    FixturePlayer.await_closed(id)

    assert {:ok, summary} = Recorder.close(name)
    rdir = summary.recording_dir
    assert File.exists?(Path.join(rdir, "CLOSED"))
    all = lines(rdir)
    footer = List.last(all)
    last_r = all |> records() |> List.last() |> Map.fetch!("r")

    assert footer["k"] == "recording.closed" and footer["boundary"] == last_r and
             footer["reason"] == "close"

    assert summary.boundary == last_r and summary.unverified_segments == []

    # sha256.txt matches the file; the summary carries the same hash.
    [{seg_name, hash}] = summary.segments
    assert File.read!(Path.join(rdir, "sha256.txt")) == "#{hash}  #{seg_name}\n"
    assert sha256(Path.join(rdir, seg_name)) == hash

    # Closed: later evidence is counted, never recorded; the files do not change; close again is an error.
    before = File.read!(Path.join(rdir, seg_name))
    :closed = FixturePlayer.play("stage1", FixturePlayer.unique_id("after"))
    Process.sleep(50)
    health = Recorder.health(name)
    assert health.status == :closed
    assert %{from: from, to: to} = health.unrecorded_after_close
    assert from > last_r and to >= from
    assert File.read!(Path.join(rdir, seg_name)) == before
    assert {:error, {:not_open, :closed}} = Recorder.close(name)
  end

  test "a supervisor shutdown reaches the close protocol", %{dir: dir} do
    {name, pid} = start(dir)
    id = FixturePlayer.unique_id("shutdown")
    :closed = FixturePlayer.play("stage1", id)
    FixturePlayer.await_closed(id)
    rdir = recording_dir(name)
    :ok = stop_supervised(name)
    refute Process.alive?(pid)
    assert File.exists?(Path.join(rdir, "CLOSED"))
    assert List.last(lines(rdir))["reason"] == "shutdown"
  end

  # -- restart ---------------------------------------------------------------------------------

  test "a recorder-process restart resumes the recording from the durable boundary and bounds the hole",
       %{dir: dir} do
    name = :"recorder_restart_#{System.unique_integer([:positive])}"
    opts = [name: name, dir: dir, flush_ms: 20]
    {:ok, pid1} = Recorder.start_link(opts)
    Process.unlink(pid1)

    a = FixturePlayer.unique_id("rs-a")
    :closed = FixturePlayer.play("stage1", a)
    FixturePlayer.await_closed(a)
    h1 = flush(name)
    boundary = h1.durable_boundary
    rdir = h1.recording_dir
    assert boundary > 0

    # Crash. Evidence issued while no recorder runs is lost to the recording.
    ref = Process.monitor(pid1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}
    b = FixturePlayer.unique_id("rs-b")
    :closed = FixturePlayer.play("stage1", b)
    FixturePlayer.await_closed(b)

    {:ok, pid2} = Recorder.start_link(opts)
    Process.unlink(pid2)
    h2 = Recorder.health(name)
    assert h2.resumed and h2.recording_id == h1.recording_id and h2.recording_dir == rdir
    assert h2.unverified_segments == ["segment-000001.ndjson"] and h2.segment == 2

    c = FixturePlayer.unique_id("rs-c")
    :closed = FixturePlayer.play("stage1", c)
    FixturePlayer.await_closed(c)
    assert {:ok, summary} = Recorder.close(name)

    all = lines(rdir)
    [h_1, h_2] = Enum.filter(all, &(&1["k"] == "recording.opened"))
    assert h_1["segment"] == 1 and h_2["segment"] == 2

    assert h_2["previous_segment"] == "segment-000001.ndjson" and
             h_2["previous_unverified"] == true

    assert h_2["resumed"] == true and h_2["durable_boundary"] == boundary

    # Segment 1 has no footer; segment 2 carries the restart gap before the first record it saw.
    seg1 =
      File.read!(Path.join(rdir, "segment-000001.ndjson"))
      |> String.split("\n", trim: true)
      |> Enum.map(&elem(Codec.decode_line(&1), 1))

    refute Enum.any?(seg1, &(&1["k"] == "recording.closed"))

    seg2 =
      File.read!(Path.join(rdir, "segment-000002.ndjson"))
      |> String.split("\n", trim: true)
      |> Enum.map(&elem(Codec.decode_line(&1), 1))

    [_header, gap | rest] = seg2

    assert gap["k"] == "recorder.gap" and gap["cause"] == "restart" and
             gap["from"] == boundary + 1

    first_after = rest |> Enum.find(&Map.has_key?(&1, "r")) |> Map.fetch!("r")
    assert gap["to"] == first_after - 1 and gap["durable_boundary"] == boundary
    # The b records (issued during the outage) are exactly the hole.
    refute Enum.any?(all, &(&1["instance"] == b))
    assert Enum.any?(all, &(&1["instance"] == c))
    assert covered?(all, boundary + 1, summary.boundary)

    # Hashes: segment 1 listed as unverified, segment 2 hashed.
    assert File.read!(Path.join(rdir, "sha256.txt")) =~ "unverified  segment-000001.ndjson"
    [{"segment-000002.ndjson", hash}] = summary.segments
    assert sha256(Path.join(rdir, "segment-000002.ndjson")) == hash
  end

  test "closing after a restart with no record seen writes an open-ended hole, never an invented end",
       %{dir: dir} do
    name = :"recorder_restart2_#{System.unique_integer([:positive])}"
    opts = [name: name, dir: dir, flush_ms: 20]
    {:ok, pid1} = Recorder.start_link(opts)
    Process.unlink(pid1)
    a = FixturePlayer.unique_id("rs2-a")
    :closed = FixturePlayer.play("stage1", a)
    FixturePlayer.await_closed(a)
    h1 = flush(name)
    ref = Process.monitor(pid1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}
    {:ok, pid2} = Recorder.start_link(opts)
    Process.unlink(pid2)
    assert {:ok, _} = Recorder.close(name)
    all = lines(h1.recording_dir)
    [gap] = Enum.filter(all, &(&1["k"] == "recorder.gap"))

    assert gap["from"] == h1.durable_boundary + 1 and gap["to"] == nil and
             gap["cause"] == "restart"

    assert List.last(all)["boundary"] == h1.durable_boundary
  end

  test "a new VM lifetime is a new recording: nothing persists without the persistent term", %{
    dir: dir
  } do
    {name1, _} = start(dir)
    id = FixturePlayer.unique_id("vm")
    :closed = FixturePlayer.play("stage1", id)
    FixturePlayer.await_closed(id)
    h1 = Recorder.flush(name1)
    # Simulate the VM boundary: the process is gone and so is its persistent term.
    :ok = stop_supervised(name1)
    :persistent_term.erase({Recorder, name1})
    {name2, _} = start(dir)
    h2 = Recorder.health(name2)
    assert h2.recording_id != h1.recording_id and h2.resumed == false and h2.durable_boundary == 0
    assert File.exists?(Path.join(h1.recording_dir, "CLOSED"))
    assert File.dir?(h2.recording_dir) and h2.recording_dir != h1.recording_dir
  end

  # -- segments ----------------------------------------------------------------------------------

  test "segments roll at the configured size with chained headers, continuous numbers and hashes",
       %{dir: dir} do
    {name, _} = start(dir, segment_bytes: 3_000)
    id = FixturePlayer.unique_id("roll")
    # Five flushed chunks of the 45-envelope fixture: a roll follows each flush past the size.
    lines = FixturePlayer.lines("b5_run1") |> FixturePlayer.with_instance(id)
    socket = FixturePlayer.connect()

    for {chunk, i} <- Enum.with_index(Enum.chunk_every(lines, 9), 1) do
      FixturePlayer.send_lines(socket, chunk)
      FixturePlayer.await(id, i * 9)
      flush(name)
    end

    :gen_tcp.close(socket)
    FixturePlayer.await_closed(id)
    assert {:ok, summary} = Recorder.close(name)
    rdir = summary.recording_dir
    names = segments(rdir) |> Enum.map(&Path.basename/1)
    assert length(names) >= 3
    headers = lines(rdir) |> Enum.filter(&(&1["k"] == "recording.opened"))
    assert Enum.map(headers, & &1["segment"]) == Enum.to_list(1..length(names))
    assert Enum.map(headers, & &1["previous_segment"]) == [nil | Enum.drop(names, -1)]

    assert Enum.all?(
             headers,
             &(&1["previous_unverified"] == false and &1["recording_id"] == summary.recording_id)
           )

    rs = lines(rdir) |> records() |> Enum.map(& &1["r"])
    assert rs == Enum.to_list(hd(rs)..List.last(rs))

    for {seg_name, hash} <- summary.segments,
        do: assert(sha256(Path.join(rdir, seg_name)) == hash)

    assert length(summary.segments) == length(names)

    assert File.read!(Path.join(rdir, "sha256.txt")) ==
             Enum.map_join(summary.segments, "", fn {n, h} -> "#{h}  #{n}\n" end)
  end

  # -- write pressure ------------------------------------------------------------------------------

  test "a stalled writer: the mailbox grows unmeasured, then the soft policy discards exact ranges",
       %{dir: dir} do
    {:ok, agent} = StubWriter.start()

    {name, _} =
      start(dir, writer: {StubWriter, agent}, mailbox_high: 40, mailbox_low: 5, flush_ms: 5)

    ids = for i <- 1..6, do: FixturePlayer.unique_id("stall#{i}")
    first_line = FixturePlayer.lines("stage1") |> hd()

    # Get one record into the buffer, stall the writer on its flush, then burst while it is stuck.
    StubWriter.mode(agent, :stall)
    :closed = FixturePlayer.play("stage1", hd(ids), lines: [first_line])
    FixturePlayer.await(hd(ids), 1)
    Process.sleep(30)
    for id <- tl(ids), do: :closed = FixturePlayer.play("b4_probe", id)
    for id <- tl(ids), do: FixturePlayer.await_closed(id)
    StubWriter.mode(agent, :ok)

    assert {:ok, summary} = Recorder.close(name)
    all = lines(summary.recording_dir)
    health = Recorder.health(name)
    assert health.overflow_events >= 1 and health.mailbox_max > 40
    gaps = Enum.filter(all, &(&1["k"] == "recorder.gap"))
    assert gaps != [] and Enum.all?(gaps, &(&1["cause"] == "overflow" and is_integer(&1["to"])))
    first = all |> records() |> hd() |> Map.fetch!("r")
    assert covered?(all, first, summary.boundary)
    assert health.records_discarded == Enum.sum(Enum.map(gaps, &(&1["to"] - &1["from"] + 1)))
    assert health.records_discarded > 0
  end

  test "a write failure degrades the recorder, keeps the batch, abandons the segment and recovers into a new one",
       %{dir: dir} do
    {:ok, agent} = StubWriter.start()
    {name, _} = start(dir, writer: {StubWriter, agent}, flush_ms: 20)
    rdir = recording_dir(name)
    StubWriter.mode(agent, {:fail_append, :enospc})
    a = FixturePlayer.unique_id("fail-a")
    :closed = FixturePlayer.play("stage1", a)
    FixturePlayer.await_closed(a)
    h = flush(name)
    assert h.status == :degraded and h.last_error == :enospc and h.write_errors >= 1
    assert h.segment == nil and h.unverified_segments == ["segment-000001.ndjson"]
    assert h.pending_count > 0 and h.durable_boundary < h.last_record_no
    assert %{error: :enospc} = h.degraded

    StubWriter.mode(agent, :ok)
    b = FixturePlayer.unique_id("fail-b")
    :closed = FixturePlayer.play("stage1", b)
    FixturePlayer.await_closed(b)
    h2 = flush(name)
    assert h2.status == :recording and h2.segment == 2 and h2.degraded == nil

    seg2 =
      File.read!(Path.join(rdir, "segment-000002.ndjson"))
      |> String.split("\n", trim: true)
      |> Enum.map(&elem(Codec.decode_line(&1), 1))

    assert hd(seg2)["previous_segment"] == "segment-000001.ndjson" and
             hd(seg2)["previous_unverified"] == true

    assert Enum.any?(seg2, &(&1["k"] == "recorder.recovered" and &1["error"] == ":enospc"))
    # Nothing of a or b is missing: every number from the first record is present (no gap at all).
    rs = seg2 |> records() |> Enum.map(& &1["r"])
    assert rs == Enum.to_list(hd(rs)..List.last(rs))
    assert Enum.any?(seg2, &(&1["instance"] == a)) and Enum.any?(seg2, &(&1["instance"] == b))
    refute Enum.any?(seg2, &(&1["k"] == "recorder.gap"))

    assert {:ok, summary} = Recorder.close(name)
    assert File.read!(Path.join(rdir, "sha256.txt")) =~ "unverified  segment-000001.ndjson"
    assert [{"segment-000002.ndjson", _}] = summary.segments
  end

  test "while degraded with a full buffer, records are discarded with an exact write_failure range",
       %{dir: dir} do
    {:ok, agent} = StubWriter.start()

    {name, _} =
      start(dir, writer: {StubWriter, agent}, flush_ms: 20, mailbox_high: 4, mailbox_low: 1)

    StubWriter.mode(agent, {:fail_sync, :eio})
    a = FixturePlayer.unique_id("full-a")
    :closed = FixturePlayer.play("b2_probe", a)
    FixturePlayer.await_closed(a)
    h = flush(name)
    assert h.status == :degraded and h.last_error == :eio and h.pending_count >= 4

    # Still failing, buffer full: the next evidence is discarded, numbered exactly.
    b = FixturePlayer.unique_id("full-b")
    :closed = FixturePlayer.play("b2_probe", b)
    FixturePlayer.await_closed(b)
    h = flush(name)
    assert h.status == :degraded and (h.discarding != nil or h.records_discarded > 0)

    StubWriter.mode(agent, :ok)
    assert {:ok, summary} = Recorder.close(name)
    # The unverified segments hold the retained buffer written on each failed attempt (the same
    # lines again, unsynced); the account is read from the verified segment only.
    all = verified_lines(summary)
    assert length(summary.unverified_segments) >= 2
    # The burst of b meets both policies: the full buffer (write_failure) and, with a high-water
    # mark this low, the mailbox (overflow). Every discarded number is in exactly one gap.
    gaps = Enum.filter(all, &(&1["k"] == "recorder.gap"))
    assert Enum.any?(gaps, &(&1["cause"] == "write_failure"))

    assert Enum.all?(
             gaps,
             &(&1["cause"] in ["write_failure", "overflow"] and is_integer(&1["to"]))
           )

    first = all |> records() |> hd() |> Map.fetch!("r")
    assert covered?(all, first, summary.boundary)
    assert Enum.any?(all, &(&1["instance"] == a))
    refute Enum.any?(all, &(&1["instance"] == b))
    # Each segment starts with its header, even one reopened after a failure.
    for path <- segments(summary.recording_dir) do
      {:ok, first_line} =
        path |> File.read!() |> String.split("\n", parts: 2) |> hd() |> Codec.decode_line()

      assert first_line["k"] == "recording.opened"
    end

    assert Recorder.health(name).records_discarded ==
             Enum.sum(Enum.map(gaps, &(&1["to"] - &1["from"] + 1)))

    # Order: the gap line precedes every record numbered after it.
    Enum.each(gaps, fn g ->
      idx = Enum.find_index(all, &(&1 == g))
      assert Enum.all?(Enum.drop(all, idx + 1) |> records(), &(&1["r"] > g["to"]))
    end)
  end

  test "the disk budget stops the recorder before it starts, with nothing written", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "old.bin"), String.duplicate("x", 10_000))
    {name, _} = start(dir, budget_bytes: 5_000)
    h = Recorder.health(name)
    assert h.status == :stopped and match?({:budget, 10_000}, h.last_error)
    assert h.recording_dir == nil
    id = FixturePlayer.unique_id("budget")
    :closed = FixturePlayer.play("stage1", id)
    FixturePlayer.await_closed(id)
    assert %{from: _, to: _} = Recorder.health(name).unrecorded_after_close
    assert File.ls!(dir) == ["old.bin"]
    assert {:error, {:not_open, :stopped}} = Recorder.close(name)
  end

  test "the disk budget reached at a roll finalizes the recording with reason budget and deletes nothing",
       %{dir: dir} do
    {name, _} = start(dir, segment_bytes: 2_000, budget_bytes: 3_000)
    id = FixturePlayer.unique_id("budget-roll")
    :closed = FixturePlayer.play("b5_run1", id)
    FixturePlayer.await_closed(id)
    flush(name)
    h = Recorder.health(name)
    assert h.status == :stopped and match?({:budget, _}, h.last_error)
    rdir = h.recording_dir
    assert File.exists?(Path.join(rdir, "CLOSED"))
    assert List.last(lines(rdir))["reason"] == "budget"
    assert segments(rdir) != []
    before = Enum.map(segments(rdir), &sha256/1)

    # Later evidence is counted, not recorded; nothing is deleted or changed.
    later = FixturePlayer.unique_id("budget-later")
    :closed = FixturePlayer.play("stage1", later)
    FixturePlayer.await_closed(later)
    assert %{from: _, to: _} = Recorder.health(name).unrecorded_after_close
    assert Enum.map(segments(rdir), &sha256/1) == before
    assert {:error, {:not_open, :stopped}} = Recorder.close(name)
  end

  test "an invalid (relative) directory stops the recorder without touching the filesystem" do
    {name, _} = start("relative/path")
    h = Recorder.health(name)
    assert h.status == :stopped and h.last_error == {:invalid_dir, "relative/path"}
    refute File.exists?("relative")
  end

  # -- isolation -----------------------------------------------------------------------------------

  test "ordinary subscribers see the unchanged messages and never a record", %{dir: dir} do
    {_name, _} = start(dir)
    id = FixturePlayer.unique_id("iso")
    :closed = FixturePlayer.play("stage1", id)
    FixturePlayer.await_closed(id)
    assert_receive {:relay_connection, :opened, %{peer: _, at: %DateTime{}}}
    assert_receive {:relay_connection, :identified, %{instance_id: ^id}}

    assert_receive {:relay_event,
                    %GlacierRelay.Wire.Envelope{adapter_instance_id: ^id, sequence: 1}}

    refute_received {:relay_record, _}
    # The read API is what it was.
    assert MissionSession.report_text() ==
             GlacierRelay.Summary.render_report(
               MissionSession.state(),
               MissionSession.unidentified()
             )
  end

  test "the recorder's permissions and the recording directory", %{dir: dir} do
    {name, _} = start(dir)
    rdir = recording_dir(name)
    assert String.starts_with?(rdir, dir)

    assert Path.basename(rdir) =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(rdir).mode |> Bitwise.band(0o777) == 0o700
    assert Segment.name(7) == "segment-000007.ndjson"
  end

  test "the dashboard is unchanged with the recorder running", %{dir: dir} do
    Process.flag(:trap_exit, true)
    {name, _} = start(dir)
    start_supervised!(GlacierRelayWeb.Supervisor)
    id = FixturePlayer.unique_id("dash")
    :closed = FixturePlayer.play("b6_run1", id)
    FixturePlayer.await_closed(id)

    FixturePlayer.wait_until(fn ->
      snap = GlacierRelay.Dashboard.Projection.snapshot()
      Enum.any?(snap.instances, &(&1.id == id and &1.observation == :lost))
    end)

    snap = GlacierRelay.Dashboard.Projection.snapshot()
    assert snap.report_text == MissionSession.report_text()
    assert snap.source == :live
    flush(name)
    assert Enum.any?(lines(recording_dir(name)), &(&1["instance"] == id))
  end

  test "the recorder calls only the session's subscription and never the wire or the fold" do
    {:ok, modules} = :application.get_key(:glacier_relay, :modules)

    recording =
      Enum.filter(
        modules,
        &String.starts_with?(Atom.to_string(&1), "Elixir.GlacierRelay.Recording")
      )

    assert GlacierRelay.Recording.Recorder in recording

    for module <- recording do
      {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
      session_calls = for {GlacierRelay.MissionSession, f, a} <- imports, do: {f, a}

      assert session_calls in [[], [{:subscribe, 1}]],
             "#{inspect(module)} calls #{inspect(session_calls)}"

      for {m, f, a} <- imports do
        refute m in [
                 GlacierRelay.Wire.Listener,
                 GlacierRelay.Wire.Connection,
                 GlacierRelay.Wire.Framing,
                 GlacierRelay.Events,
                 :gen_tcp,
                 :inet,
                 :socket
               ],
               "#{inspect(module)} calls #{inspect({m, f, a})}"

        refute m == GlacierRelay.Lifecycle, "#{inspect(module)} calls Lifecycle.#{f}/#{a}"
        refute {m, f} == {GenServer, :cast}, "#{inspect(module)} casts"
      end
    end

    # And the web never reaches the recorder.
    web = Enum.filter(modules, &String.starts_with?(Atom.to_string(&1), "Elixir.GlacierRelayWeb"))

    for module <- web ++ [GlacierRelay.Dashboard.Projection] do
      {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])

      refute Enum.any?(imports, fn {m, _, _} -> m in recording end),
             "#{inspect(module)} references the recorder"
    end
  end
end

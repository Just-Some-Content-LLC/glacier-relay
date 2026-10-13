defmodule GlacierRelay.Recording.ReplayTest do
  @moduledoc """
  Live/replay equivalence (M4-B): every committed fixture recorded through the real listener and
  replayed without the session gives term-equal instances, equal summary and report data and
  byte-identical texts at the recording boundary; the transport scenarios; legacy import.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.{Lifecycle, MissionSession, Summary}
  alias GlacierRelay.Recording.{Recorder, Replay}
  alias GlacierRelay.Test.{FixturePlayer, RecordingFixtures, StubWriter}

  @fixtures ~w(stage1 stage_a_probe b1_probe b2_probe b3_probe b4_probe b5_probe b5_run1 b6_probe b6_run1)

  setup do
    :ok = MissionSession.subscribe()
    :ok
  end

  # Equivalence at the recording boundary: the replay's instances against the live ones with the
  # same ids; the unidentified list against the live list's newest entries (the recording holds
  # only closes after its start); summary and report data and text over that subset.
  defp assert_equivalent(replay, live, ids) do
    assert Map.keys(replay.instances) |> Enum.sort() == Enum.sort(ids)
    assert replay.instances == Map.take(live.instances, ids)
    n = length(replay.unidentified)
    assert replay.unidentified == Enum.take(live.unidentified, n)
    assert replay.summary == live.summary
    assert replay.report == live.report
    assert replay.summary_text == live.summary_text.(n)
    assert replay.report_text == live.report_text.(n)
  end

  for name <- @fixtures do
    test "replay of #{name} equals the live session at the recording boundary" do
      %{dir: dir, id: id, live: live, summary: summary} =
        RecordingFixtures.record_fixture(unquote(name))

      {:ok, replay} = Replay.replay(dir)
      assert replay.boundary == summary.boundary and replay.recording_id == summary.recording_id
      assert_equivalent(replay, live, [id])
      c = replay.completeness

      assert c.finalization == :clean and c.evidence == :authoritative and
               c.recorder_authoritative?

      assert c.transport == :recorded and c.receipt_times == :recorded and
               c.native_drops == :unknown

      assert c.rejected_by_current_validator == [] and c.replay_issues == []
      # Receipt times are the session's, as DateTime values.
      [attempt | _] = replay.instances[id].attempts
      assert %DateTime{microsecond: {_, 6}} = attempt.playing.received_at
    end
  end

  test "several adapter instances in one recording" do
    {rec, _, _} = RecordingFixtures.start_recorder()
    a = RecordingFixtures.play("stage1", "multi-a")
    b = RecordingFixtures.play("b6_run1", "multi-b")
    live = RecordingFixtures.capture([a, b])
    {:ok, summary} = Recorder.close(rec)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    assert_equivalent(replay, live, [a, b])
  end

  test "two connections sharing one peer string, one unidentified, one identified" do
    {rec, _, _} = RecordingFixtures.start_recorder()
    peer = "127.0.0.1:1"
    at = ~U[2026-10-13 07:00:00.000000Z]
    parent = self()
    id = FixturePlayer.unique_id("peer")

    {:ok, envelope} =
      FixturePlayer.lines("stage1")
      |> FixturePlayer.with_instance(id)
      |> hd()
      |> GlacierRelay.Wire.Envelope.decode()

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

    p1 = spawn_conn.(nil)
    assert_receive {:relay_connection, :opened, %{peer: ^peer}}, 2_000
    p2 = spawn_conn.(envelope)
    assert_receive {:relay_connection, :identified, %{instance_id: ^id}}, 2_000
    send(p1, :close)
    assert_receive :closed, 2_000
    assert_receive {:relay_connection, :closed, %{peer: ^peer, instance_id: nil}}, 2_000
    send(p2, :close)
    assert_receive :closed, 2_000
    assert_receive {:relay_connection, :closed, %{instance_id: ^id}}, 2_000

    live = RecordingFixtures.capture([id])
    {:ok, summary} = Recorder.close(rec)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    assert_equivalent(replay, live, [id])
    assert [%{peer: ^peer, close_reason: :peer_closed} | _] = replay.unidentified

    assert [
             %Lifecycle.Connection{
               peer: ^peer,
               opened_at: ^at,
               identified_at: ^at,
               closed_at: ^at
             }
           ] = replay.instances[id].connections
  end

  test "re-attribution replays to the same state, stale open record included" do
    {rec, _, _} = RecordingFixtures.start_recorder()
    a = FixturePlayer.unique_id("re-a")
    b = FixturePlayer.unique_id("re-b")
    [l1, l2 | _] = FixturePlayer.lines("b6_run1")
    socket = FixturePlayer.connect()
    FixturePlayer.send_lines(socket, FixturePlayer.with_instance([l1, l2], a))
    FixturePlayer.await(a, 2)
    FixturePlayer.send_lines(socket, FixturePlayer.with_instance([l1, l2], b))
    FixturePlayer.await(b, 2)
    :gen_tcp.close(socket)
    FixturePlayer.await_closed(b)
    live = RecordingFixtures.capture([a, b])
    {:ok, summary} = Recorder.close(rec)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    assert_equivalent(replay, live, [a, b])
    assert Lifecycle.observation(replay.instances[a]) == :live
    assert Lifecycle.observation(replay.instances[b]) == :lost
    assert replay.completeness.replay_issues == []
  end

  test "connection loss with an open attempt is an interruption, never a stop, live and replayed" do
    {rec, _, _} = RecordingFixtures.start_recorder()
    id = FixturePlayer.unique_id("loss")
    [l1, l2 | _] = FixturePlayer.lines("b6_run1")
    :closed = FixturePlayer.play("b6_run1", id, lines: [l1, l2])
    FixturePlayer.await_closed(id)
    live = RecordingFixtures.capture([id])
    {:ok, summary} = Recorder.close(rec)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    assert_equivalent(replay, live, [id])

    assert [%Lifecycle.Attempt{mission: :playing, stopped: nil, interruptions: [_]}] =
             replay.instances[id].attempts

    assert Lifecycle.observation(replay.instances[id]) == :lost
    assert replay.report_text =~ "last known playing"
  end

  test "missing envelopes are Relay sequence gaps, equal live and replayed, and accounted separately" do
    {rec, _, _} = RecordingFixtures.start_recorder()
    id = FixturePlayer.unique_id("gaps")

    lines =
      FixturePlayer.lines("b5_run1")
      |> Enum.reject(&(JSON.decode!(&1)["sequence"] in [3, 10, 11]))

    :closed = FixturePlayer.play("b5_run1", id, lines: lines)
    FixturePlayer.await_closed(id)
    live = RecordingFixtures.capture([id])
    {:ok, summary} = Recorder.close(rec)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    assert_equivalent(replay, live, [id])
    assert replay.instances[id].gaps == [{10, 12}, {3, 4}]
    c = replay.completeness
    assert c.relay_sequence_gaps == %{id => [{3, 4}, {10, 12}]}
    assert c.recorder_gaps == [] and c.unexplained_missing == [] and c.recorder_authoritative?
    assert Enum.any?(c.limitations, &String.contains?(&1, "Relay sequence gap"))
  end

  test "a recorded envelope the current validator rejects is listed, not folded, not replaced" do
    %{dir: dir, id: id} = RecordingFixtures.record_fixture("stage1")
    copy = RecordingFixtures.copy(dir)
    path = RecordingFixtures.segment(copy, 1)

    RecordingFixtures.edit_lines(path, fn lines ->
      Enum.map(lines, fn line ->
        if String.contains?(line, "\"sequence\":2,\"event_type\":\"mission.playing\""),
          do: String.replace(line, "\"schema_version\":1", "\"schema_version\":9"),
          else: line
      end)
    end)

    RecordingFixtures.rehash(copy)
    {:ok, replay} = Replay.replay(copy)

    assert [
             %{
               sequence: 2,
               event_type: "mission.playing",
               schema_version: 9,
               reason: {:unsupported_schema_version, _, _}
             }
           ] = replay.rejected

    assert replay.completeness.rejected_by_current_validator == replay.rejected
    refute replay.completeness.recorder_authoritative?
    # Without #2 (a rise), #1's attempt is superseded by #3 instead of by #2; a gap 2→3 appears.
    assert [%Lifecycle.Attempt{mission: :superseded, superseded_at: 3}, %Lifecycle.Attempt{}] =
             replay.instances[id].attempts

    assert replay.instances[id].gaps == [{2, 3}]
  end

  test "the session's identification decisions are checked, not trusted" do
    %{dir: dir} = RecordingFixtures.record_fixture("stage1")
    copy = RecordingFixtures.copy(dir)
    path = RecordingFixtures.segment(copy, 1)

    RecordingFixtures.edit_lines(path, fn lines ->
      Enum.map(lines, fn line ->
        if String.contains?(line, "\"k\":\"connection.identified\""),
          do:
            String.replace(line, "\"previous_instance\":null", "\"previous_instance\":\"ghost\""),
          else: line
      end)
    end)

    RecordingFixtures.rehash(copy)
    {:ok, replay} = Replay.replay(copy)

    assert Enum.any?(
             replay.issues,
             &match?({:identification_mismatch, _, _, {_, "ghost"}, {_, nil}}, &1)
           )

    refute replay.completeness.recorder_authoritative?
  end

  test "the stub writer scenarios replay with their accounts: restart gap, overflow, write failure, budget" do
    # Restart with a hole.
    {rec, pid, dir} = RecordingFixtures.start_recorder()
    name = rec
    _a = RecordingFixtures.play("stage1", "rs-a")
    h1 = RecordingFixtures.flush(name)
    RecordingFixtures.kill(pid)
    b = RecordingFixtures.play("stage1", "rs-b")
    {:ok, pid2} = Recorder.start_link(name: name, dir: dir, flush_ms: 20)
    Process.unlink(pid2)
    c = RecordingFixtures.play("stage1", "rs-c")
    live = RecordingFixtures.capture([c])
    {:ok, summary} = Recorder.close(name)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    acc = replay.completeness
    assert [%{cause: "restart", from: from}] = acc.recorder_gaps
    assert from == h1.durable_boundary + 1
    assert acc.evidence == :authoritative and acc.finalization == :clean
    refute acc.recorder_authoritative?
    refute Map.has_key?(replay.instances, b)
    assert replay.instances[c] == live.instances[c]
    assert acc.segments.unverified == ["segment-000001.ndjson"]

    # Open-ended restart gap.
    {rec, pid, dir} = RecordingFixtures.start_recorder()
    _ = RecordingFixtures.play("stage1", "oe")
    RecordingFixtures.flush(rec)
    RecordingFixtures.kill(pid)
    {:ok, pid2} = Recorder.start_link(name: rec, dir: dir, flush_ms: 20)
    Process.unlink(pid2)
    {:ok, summary} = Recorder.close(rec)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    assert [%{cause: "restart"}] = replay.completeness.open_ended_gaps
    refute replay.completeness.recorder_authoritative?

    # Overflow.
    {:ok, agent} = StubWriter.start()

    {rec, _, _} =
      RecordingFixtures.start_recorder(
        writer: {StubWriter, agent},
        mailbox_high: 40,
        mailbox_low: 5,
        flush_ms: 5
      )

    StubWriter.mode(agent, :stall)
    first = FixturePlayer.unique_id("ov")
    :closed = FixturePlayer.play("stage1", first, lines: [hd(FixturePlayer.lines("stage1"))])
    FixturePlayer.await(first, 1)
    Process.sleep(30)
    for i <- 1..5, do: RecordingFixtures.play("b4_probe", "ov#{i}")
    StubWriter.mode(agent, :ok)
    {:ok, summary} = Recorder.close(rec)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    acc = replay.completeness
    assert acc.recorder_gaps != [] and Enum.all?(acc.recorder_gaps, &(&1.cause == "overflow"))
    assert acc.unexplained_missing == [] and acc.evidence == :authoritative
    refute acc.recorder_authoritative?

    # Write failure, recovery, discards; duplicates across the unverified and verified segments.
    {:ok, agent} = StubWriter.start()

    {rec, _, _} =
      RecordingFixtures.start_recorder(
        writer: {StubWriter, agent},
        flush_ms: 20,
        # 12 = one fixture's records: wa's burst stays under the mailbox mark; wb's records meet
        # the full buffer while degraded and are discarded as one write_failure run.
        mailbox_high: 12,
        mailbox_low: 1
      )

    StubWriter.mode(agent, {:fail_sync, :eio})
    wa = RecordingFixtures.play("b2_probe", "wf-a")
    RecordingFixtures.flush(rec)
    wb = RecordingFixtures.play("b2_probe", "wf-b")
    RecordingFixtures.flush(rec)
    StubWriter.mode(agent, :ok)
    live = RecordingFixtures.capture([wa])
    {:ok, summary} = Recorder.close(rec)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    acc = replay.completeness

    assert acc.recorder_gaps != [] and
             Enum.all?(acc.recorder_gaps, &(&1.cause == "write_failure"))

    assert acc.records.duplicates > 0 and acc.records.conflicts == 0 and
             acc.records.ambiguous == []

    assert acc.evidence == :authoritative and acc.segments.unverified != []
    assert replay.instances[wa] == live.instances[wa]
    refute Map.has_key?(replay.instances, wb)
    refute acc.recorder_authoritative?

    # Budget at a roll.
    {rec, _, _} = RecordingFixtures.start_recorder(segment_bytes: 2_000, budget_bytes: 3_000)
    _ = RecordingFixtures.play("b5_run1", "budget")
    RecordingFixtures.flush(rec)
    later = RecordingFixtures.play("stage1", "later")
    h = Recorder.health(rec)
    assert h.status == :stopped
    {:ok, replay} = Replay.replay(h.recording_dir)
    acc = replay.completeness
    assert acc.finalization == :budget and acc.closed_marker
    refute acc.recorder_authoritative?
    refute Map.has_key?(replay.instances, later)
    assert Enum.any?(acc.limitations, &String.contains?(&1, "disk budget"))
  end

  test "a new node lifetime after an unclean recording is a distinct recording that starts past r=1" do
    {rec, pid, _} = RecordingFixtures.start_recorder()
    _ = RecordingFixtures.play("stage1", "nl-a")
    h1 = RecordingFixtures.flush(rec)
    RecordingFixtures.kill(pid)
    :persistent_term.erase({Recorder, rec})
    {rec2, _, _} = RecordingFixtures.start_recorder()
    b = RecordingFixtures.play("stage1", "nl-b")
    live = RecordingFixtures.capture([b])
    {:ok, summary} = Recorder.close(rec2)
    {:ok, old} = Replay.replay(h1.recording_dir)
    {:ok, new} = Replay.replay(summary.recording_dir)
    assert old.completeness.finalization == :unclosed and old.recording_id != new.recording_id

    assert new.first_record_no > 1 and new.completeness.unexplained_missing == [] and
             new.completeness.recorder_authoritative?

    assert new.instances[b] == live.instances[b]
  end

  # -- legacy ------------------------------------------------------------------------------------

  for name <- @fixtures do
    test "legacy import of #{name} equals the direct fold and keeps the summary snapshot" do
      lines = FixturePlayer.lines(unquote(name))
      replay = Replay.from_envelopes(lines, name: unquote(name))

      direct =
        Enum.reduce(lines, %{}, fn line, acc ->
          {:ok, e} = GlacierRelay.Wire.Envelope.decode(line)

          inst =
            Map.get_lazy(acc, e.adapter_instance_id, fn ->
              Lifecycle.new(e.adapter_instance_id)
            end)

          {inst, _} = Lifecycle.apply_event(inst, e, nil)
          Map.put(acc, e.adapter_instance_id, inst)
        end)

      assert replay.instances == direct
      assert replay.unidentified == []

      assert replay.summary_text <> "\n" ==
               File.read!("test/snapshots/#{unquote(name)}.summary.txt")

      assert replay.report_text == Summary.render_report(direct, [])
      c = replay.completeness

      assert c.source == :legacy and c.transport == :not_recorded and
               c.receipt_times == :unavailable

      assert c.native_drops == :unknown and c.finalization == :not_applicable
      refute c.recorder_authoritative?
      assert Enum.all?(Map.values(replay.instances), &(Lifecycle.observation(&1) == :never))
      assert Enum.any?(c.limitations, &String.contains?(&1, "not that no connection existed"))
    end
  end
end

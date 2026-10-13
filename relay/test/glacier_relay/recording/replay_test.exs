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

  # -- close reasons (correction B) --------------------------------------------------------------

  # A process that announces a connection, then closes it with `reason` (or dies with `exit`).
  defp open_connection(peer, at) do
    parent = self()

    pid =
      spawn(fn ->
        MissionSession.connection_opened(peer, at)
        send(parent, :opened)

        receive do
          {:close, reason} -> MissionSession.connection_closed(reason, at)
          {:exit, reason} -> exit(reason)
        end
      end)

    assert_receive :opened, 2_000
    assert_receive {:relay_connection, :opened, %{peer: ^peer}}, 2_000
    # The session's monitor is a signal the idle process must handle before it is killed;
    # killing it first makes the runtime answer the monitor with :noproc (a harness race, not
    # the session's behaviour with a running connection process).
    session = Process.whereis(MissionSession)

    assert FixturePlayer.wait_until(fn ->
             session in elem(Process.info(pid, :monitored_by), 1)
           end)

    pid
  end

  defp close_with(pid, peer, reason) do
    send(pid, {:close, reason})
    assert_receive {:relay_connection, :closed, %{peer: ^peer, reason: ^reason}}, 2_000
  end

  defp strip_reasons(list), do: Enum.map(list, &Map.put(&1, :close_reason, nil))

  test "close reasons the format reconstructs exactly replay term-equal: peer_closed, line_too_long, a TCP error, a process exit" do
    {rec, _, _} = RecordingFixtures.start_recorder()
    at = ~U[2026-10-13 08:00:00.000000Z]

    # peer_closed and line_too_long over the real wire.
    socket = FixturePlayer.connect()
    :gen_tcp.close(socket)
    assert_receive {:relay_connection, :closed, %{instance_id: nil, reason: :peer_closed}}, 2_000
    socket = FixturePlayer.connect()
    :ok = :gen_tcp.send(socket, String.duplicate("a", 5_000) <> "\n")

    assert_receive {:relay_connection, :closed, %{instance_id: nil, reason: :line_too_long}},
                   2_000

    :gen_tcp.close(socket)

    # A TCP error as the connection process reports it; a DOWN as the session observes it.
    p = open_connection("127.0.0.1:1", at)
    close_with(p, "127.0.0.1:1", {:tcp_error, :econnreset})
    p = open_connection("127.0.0.1:2", at)
    Process.exit(p, :kill)

    assert_receive {:relay_connection, :closed, %{peer: "127.0.0.1:2", reason: {:down, :killed}}},
                   2_000

    p = open_connection("127.0.0.1:3", at)
    send(p, {:exit, :shutdown})

    assert_receive {:relay_connection, :closed,
                    %{peer: "127.0.0.1:3", reason: {:down, :shutdown}}},
                   2_000

    live = RecordingFixtures.capture([])
    {:ok, summary} = Recorder.close(rec)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    n = length(replay.unidentified)
    assert n == 5
    assert replay.unidentified == Enum.take(live.unidentified, n)

    assert Enum.map(replay.unidentified, & &1.close_reason) ==
             [
               {:down, :shutdown},
               {:down, :killed},
               {:tcp_error, :econnreset},
               :line_too_long,
               :peer_closed
             ]

    assert replay.summary_text == live.summary_text.(n) and
             replay.report_text == live.report_text.(n)

    c = replay.completeness
    assert c.close_reasons == %{exact: 5, qualified: []} and replay.qualified_reasons == []
    assert c.recorder_authoritative?
    refute Enum.any?(c.limitations, &String.contains?(&1, "close reason"))
  end

  test "close reasons outside the vocabulary replay qualified: the category is kept, the inequality is explicit, nothing is invented" do
    {rec, _, _} = RecordingFixtures.start_recorder()
    at = ~U[2026-10-13 08:00:00.000000Z]
    p = open_connection("127.0.0.1:11", at)
    close_with(p, "127.0.0.1:11", {:tcp_error, {:weird, 1}})
    p = open_connection("127.0.0.1:12", at)
    send(p, {:exit, {:shutdown, %{x: 1}}})

    assert_receive {:relay_connection, :closed,
                    %{peer: "127.0.0.1:12", reason: {:down, {:shutdown, %{x: 1}}}}},
                   2_000

    p = open_connection("127.0.0.1:13", at)
    close_with(p, "127.0.0.1:13", :some_other_atom)
    live = RecordingFixtures.capture([])
    {:ok, summary} = Recorder.close(rec)
    {:ok, replay} = Replay.replay(summary.recording_dir)
    n = 3
    live_unidentified = Enum.take(live.unidentified, n)

    assert Enum.map(live_unidentified, & &1.close_reason) ==
             [:some_other_atom, {:down, {:shutdown, %{x: 1}}}, {:tcp_error, {:weird, 1}}]

    assert Enum.map(replay.unidentified, & &1.close_reason) == [
             {:recorded_text, ":some_other_atom"},
             {:down, {:recorded_text, "{:shutdown, %{x: 1}}"}},
             {:tcp_error, {:recorded_text, "{:weird, 1}"}}
           ]

    # Everything but the reason is equal; the reason is not, and the account says so.
    assert replay.unidentified != live_unidentified
    assert strip_reasons(replay.unidentified) == strip_reasons(live_unidentified)
    assert replay.summary_text != live.summary_text.(n)
    c = replay.completeness
    assert c.close_reasons.exact == 0 and length(c.close_reasons.qualified) == 3
    assert Enum.all?(c.close_reasons.qualified, &(&1.why == :unrepresentable))

    assert Enum.map(c.close_reasons.qualified, & &1.recorded) |> Enum.reverse() == [
             %{"text" => ":some_other_atom"},
             %{"down" => %{"text" => "{:shutdown, %{x: 1}}"}},
             %{"tcp_error" => %{"text" => "{:weird, 1}"}}
           ]

    assert Enum.any?(
             c.limitations,
             &String.contains?(&1, "3 close reason(s) not reconstructed exactly")
           )

    # Type fidelity is reported apart from evidence completeness.
    assert c.evidence == :authoritative and c.recorder_authoritative?
  end

  test "legacy inspected-string and malformed reasons replay as recorded evidence and create no atom" do
    {rec, _, _} = RecordingFixtures.start_recorder()
    at = ~U[2026-10-13 08:00:00.000000Z]

    for i <- 1..5 do
      p = open_connection("127.0.0.1:2#{i}", at)
      close_with(p, "127.0.0.1:2#{i}", {:tcp_error, :econnreset})
    end

    # A session call first: the close records are then ahead of the recorder's close request.
    _ = MissionSession.unidentified()
    {:ok, summary} = Recorder.close(rec)
    dir = RecordingFixtures.copy(summary.recording_dir)
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    typed = ~s("reason":{"tcp_error":{"posix":"econnreset"}})

    replacements = [
      ~s("reason":{"tcp_error":":econnreset"}),
      ~s("reason":"gone"),
      ~s("reason":{"tcp_error":{"posix":"nope_#{suffix}"}}),
      ~s("reason":{"down":{"exit":"os_cmd_#{suffix}"}}),
      ~s("reason":12)
    ]

    RecordingFixtures.edit_lines(RecordingFixtures.segment(dir, 1), fn lines ->
      {edited, _} =
        Enum.map_reduce(lines, replacements, fn line, reps ->
          if String.contains?(line, typed) and reps != [] do
            {String.replace(line, typed, hd(reps)), tl(reps)}
          else
            {line, reps}
          end
        end)

      edited
    end)

    RecordingFixtures.rehash(dir)
    {:ok, replay} = Replay.replay(dir)

    assert Enum.map(replay.unidentified, & &1.close_reason) |> Enum.reverse() == [
             {:tcp_error, {:recorded_text, ":econnreset"}},
             {:recorded_text, "gone"},
             {:tcp_error, {:recorded_text, "nope_#{suffix}"}},
             {:down, {:recorded_text, "os_cmd_#{suffix}"}},
             {:unrecognized_reason, 12}
           ]

    assert Enum.map(replay.qualified_reasons, & &1.why) ==
             [:legacy_text, :legacy_text, :outside_vocabulary, :outside_vocabulary, :unrecognized]

    assert_raise ArgumentError, fn -> String.to_existing_atom("nope_#{suffix}") end
    assert_raise ArgumentError, fn -> String.to_existing_atom("os_cmd_#{suffix}") end
    assert length(replay.completeness.close_reasons.qualified) == 5
    assert replay.completeness.rejected_by_current_validator == []
    # The report renders the recorded evidence, never a reconstructed term.
    assert replay.report_text =~ "recorded_text" and replay.report_text =~ "unrecognized_reason"
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

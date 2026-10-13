defmodule GlacierRelay.Dashboard.ProjectionTest do
  @moduledoc """
  M3-B projection: a pure build equal to the B7 report over every committed fixture; the process
  behaviour over the real listener and the real session (late start, coalescing, revisions, dirty
  recomputation, multiple adapters, connection loss and reconnection, crash and restart); and
  the rule that the projection never mutates session evidence.
  """
  # Not async: the web subtree and the MissionSession are shared singletons.
  use ExUnit.Case, async: false

  alias GlacierRelay.{Lifecycle, MissionSession, Summary}
  alias GlacierRelay.Dashboard.Projection
  alias GlacierRelay.Test.FixturePlayer, as: Player
  alias GlacierRelay.Wire.Envelope

  @fixtures ~w(stage1 stage_a_probe b1_probe b2_probe b3_probe b4_probe b5_probe b5_run1 b6_probe b6_run1)

  setup do
    start_supervised!(GlacierRelayWeb.Supervisor)
    :ok = MissionSession.subscribe()
    :ok = Phoenix.PubSub.subscribe(GlacierRelay.PubSub, Projection.snapshot_topic())
    :ok = Phoenix.PubSub.subscribe(GlacierRelay.PubSub, Projection.events_topic())
    :ok
  end

  defp fixture_instances(name) do
    name
    |> Player.lines()
    |> Enum.reduce(%{}, fn line, acc ->
      {:ok, e} = Envelope.decode(line)

      inst =
        Map.get_lazy(acc, e.adapter_instance_id, fn -> Lifecycle.new(e.adapter_instance_id) end)

      {inst, _} = Lifecycle.apply_event(inst, e, nil)
      Map.put(acc, e.adapter_instance_id, inst)
    end)
  end

  defp entry(snapshot, id), do: Enum.find(snapshot.instances, &(&1.id == id))

  defp session_report(id) do
    [r] = Summary.report(%{id => MissionSession.state()[id]})
    r
  end

  # Collects snapshot broadcasts until one satisfies `done?`; returns {snapshots, final}.
  defp collect_snapshots(done?, acc \\ [], timeout \\ 5_000) do
    receive do
      {:snapshot, s} ->
        if done?.(s),
          do: {Enum.reverse([s | acc]), s},
          else: collect_snapshots(done?, [s | acc], timeout)
    after
      timeout -> raise "no satisfying snapshot within #{timeout} ms (#{length(acc)} seen)"
    end
  end

  # -- pure --------------------------------------------------------------------------------------

  describe "build/4 over every committed fixture" do
    for name <- @fixtures do
      @name name
      test "#{name}: each instance's entry carries the B7 report unchanged, and the text matches" do
        instances = fixture_instances(@name)
        meta = %{revision: 1, source: :replay}
        {snapshot, reports, recomputed} = Projection.build(instances, [], %{}, meta)
        expected = Summary.report(instances)

        assert Enum.sort(recomputed) == Enum.sort(Map.keys(instances))
        assert length(snapshot.instances) == length(expected)

        for e <- expected do
          entry = entry(snapshot, e.adapter_instance_id)
          assert entry.report == e
          assert entry.observation == e.observation
          assert entry.last_sequence == e.last_sequence
          assert entry.gaps == e.gaps
        end

        assert snapshot.report_text == Summary.render_report(instances, [])
        assert snapshot.source == :replay
        assert snapshot.revision == 1
        assert snapshot.focus in Map.keys(instances)

        # The same evidence again: nothing recomputed, the same entries.
        {again, _, recomputed2} = Projection.build(instances, [], reports, %{meta | revision: 2})
        assert recomputed2 == []
        assert Enum.map(again.instances, & &1.report) == Enum.map(snapshot.instances, & &1.report)
        assert again.revision == 2
      end
    end

    test "an empty session is an empty snapshot" do
      {snapshot, reports, []} = Projection.build(%{}, [], %{}, %{revision: 7, source: :live})
      assert snapshot.instances == []
      assert snapshot.focus == nil
      assert snapshot.report_text == "no adapter instance has delivered an event"
      assert reports == %{}
    end

    test "unidentified connection evidence is carried, never attached to an instance" do
      record = %{
        peer: "127.0.0.1:9",
        opened_at: ~U[2026-10-12 21:00:00Z],
        closed_at: ~U[2026-10-12 21:00:01Z],
        close_reason: :peer_closed
      }

      {snapshot, _, _} = Projection.build(%{}, [record], %{}, %{revision: 1, source: :live})
      assert snapshot.unidentified == [record]
      assert snapshot.instances == []
      assert snapshot.report_text =~ "connections that closed before identifying an instance: 1"
    end
  end

  # -- process -----------------------------------------------------------------------------------

  test "the source is :live unless the environment says otherwise, even for fixture-shaped traffic" do
    # Stopping the web subtree stops PubSub, whose Registry is linked to its subscribers.
    Process.flag(:trap_exit, true)
    id = Player.unique_id("src")
    Player.play("stage1", id)
    Player.await(id, 3)
    assert Projection.refresh().source == :live

    :ok = stop_supervised!(GlacierRelayWeb.Supervisor)
    start_supervised!({GlacierRelayWeb.Supervisor, projection: [source: :replay]})
    assert Projection.snapshot().source == :replay
  end

  test "startup reads the session: an instance played before the projection existed is in the first snapshot" do
    Process.flag(:trap_exit, true)
    :ok = stop_supervised!(GlacierRelayWeb.Supervisor)
    id = Player.unique_id("late")
    Player.play("b6_run1", id)
    Player.await(id, 16)
    Player.await_closed(id)

    before = MissionSession.state()
    start_supervised!(GlacierRelayWeb.Supervisor)
    snapshot = Projection.snapshot()

    e = entry(snapshot, id)
    assert e.last_sequence == 16
    assert e.observation == :lost
    assert e.report == session_report(id)
    assert MissionSession.state() == before
  end

  test "a burst is coalesced into few snapshots, every event reaches the authoritative report, revisions increase" do
    id = Player.unique_id("burst")
    before = Projection.stats()
    Player.play("b6_run1", id)

    {snapshots, final} =
      collect_snapshots(fn s ->
        (e = entry(s, id)) && e.last_sequence == 16 && e.observation == :lost
      end)

    revisions = Enum.map(snapshots, & &1.revision)
    assert revisions == Enum.sort(revisions) and length(Enum.uniq(revisions)) == length(revisions)
    assert length(snapshots) < 16, "#{length(snapshots)} snapshots for 16 events"

    e = entry(final, id)
    assert e.report == session_report(id)
    [attempt] = e.report.attempts

    assert Enum.map(attempt.timeline.lines, & &1.sequence) |> Enum.reject(&is_nil/1) ==
             Enum.to_list(1..16)

    after_ = Projection.stats()
    assert after_.events_seen - before.events_seen == 16
    assert after_.recomputes - before.recomputes <= length(snapshots)
    assert after_.last_revision == final.revision
  end

  test "only the instance whose evidence changed is recomputed" do
    id1 = Player.unique_id("dirty-a")
    id2 = Player.unique_id("dirty-b")

    Player.play("b6_run1", id1)

    {_, s1} =
      collect_snapshots(fn s ->
        (e = entry(s, id1)) && e.last_sequence == 16 && e.observation == :lost
      end)

    report1 = entry(s1, id1).report

    Player.play("b1_probe", id2)

    {_, s2} =
      collect_snapshots(fn s ->
        (e = entry(s, id2)) && e.last_sequence == 18 && e.observation == :lost
      end)

    stats = Projection.stats()
    assert id2 in stats.recomputed_instances_last or stats.recomputed_instances_last == []
    refute id1 in stats.recomputed_instances_last
    assert entry(s2, id1).report == report1
  end

  test "a connection close is transport evidence and never a stop; a reconnect continues the instance" do
    id = Player.unique_id("loss")
    lines = Player.lines("b5_run1")
    {first, rest} = Enum.split(lines, 20)

    socket = Player.play("b5_run1", id, lines: first, keep: true)
    Player.await(id, 20)
    s = Projection.refresh()
    e = entry(s, id)
    assert e.observation == :live
    assert e.current_attempt == 1
    [attempt] = e.report.attempts
    assert attempt.overview.mission == :playing

    :gen_tcp.close(socket)
    Player.await_closed(id)
    s = Projection.refresh()
    e = entry(s, id)
    assert e.observation == :lost
    assert e.current_attempt == 1
    [attempt] = e.report.attempts
    assert attempt.overview.mission == :playing

    assert attempt.overview.stop == %{
             status: :not_observed,
             reason: :last_known_playing,
             tag: :not_observed
           }

    assert Enum.any?(attempt.uncertainty, &(&1.kind == :interruption and &1.tag == :transport))
    assert Enum.any?(attempt.timeline.lines, &(&1.family == :transport and is_nil(&1.sequence)))
    assert_received {:transport, ^id, :closed, _}

    socket = Player.play("b5_run1", id, lines: rest, keep: true)
    Player.await(id, 45)
    s = Projection.refresh()
    e = entry(s, id)
    assert e.observation == :live
    assert e.current_attempt == nil
    [attempt] = e.report.attempts
    assert attempt.overview.mission == :stopped
    assert %{sequence: 45} = attempt.overview.stop

    assert Enum.any?(attempt.uncertainty, &(&1.kind == :interruption)),
           "the interruption stays on the record"

    assert e.report == session_report(id)
    :gen_tcp.close(socket)
  end

  test "several adapters are distinct entries; focus follows a live connection, else the most recent envelope" do
    id1 = Player.unique_id("multi-a")
    id2 = Player.unique_id("multi-b")

    Player.play("b6_run1", id1)
    Player.await(id1, 16)
    Player.await_closed(id1)
    socket = Player.play("stage1", id2, keep: true)
    Player.await(id2, 3)

    s = Projection.refresh()
    assert entry(s, id1).observation == :lost
    assert entry(s, id2).observation == :live
    assert s.focus == id2

    :gen_tcp.close(socket)
    Player.await_closed(id2)
    s = Projection.refresh()
    # No connection is live now: focus is an instance whose last envelope is the newest (the
    # session is shared, so another instance may tie with id1's 2026-10-12 envelopes).
    newest = s.instances |> Enum.map(& &1.last_event.timestamp) |> Enum.max()
    assert entry(s, s.focus).last_event.timestamp == newest
    refute s.focus == id2
    assert entry(s, id1).report == session_report(id1)
    assert entry(s, id2).report == session_report(id2)
    assert_received {:event, ^id1, %Envelope{sequence: 1}}
    assert_received {:event, ^id2, %Envelope{sequence: 1}}
  end

  test "the events topic carries envelopes and transport notices distinctly, per instance" do
    id = Player.unique_id("topic")
    Player.play("stage1", id)
    Player.await(id, 3)
    Player.await_closed(id)

    assert_receive {:transport, nil, :opened, %{peer: _}}, 1_000
    assert_receive {:transport, ^id, :identified, %{peer: _}}, 1_000
    assert_receive {:event, ^id, %Envelope{sequence: 1, event_type: "mission.playing"}}, 1_000
    assert_receive {:event, ^id, %Envelope{sequence: 3}}, 1_000
    assert_receive {:transport, ^id, :closed, %{reason: :peer_closed}}, 1_000
  end

  test "a crash restarts the projection from the session with a higher revision; ingestion is untouched" do
    id = Player.unique_id("crash")
    Player.play("b6_run1", id)
    Player.await(id, 16)
    Player.await_closed(id)
    before = Projection.refresh()
    session = Process.whereis(MissionSession)
    listener = Process.whereis(GlacierRelay.Wire.Listener)
    pid = Process.whereis(Projection)

    Process.exit(pid, :kill)
    Player.wait_until(fn -> (p = Process.whereis(Projection)) && p != pid end)
    Player.wait_until(fn -> match?({:ok, _}, GlacierRelayWeb.Endpoint.server_info(:http)) end)

    after_ = Projection.snapshot()
    assert after_.revision > before.revision
    assert entry(after_, id).report == entry(before, id).report
    assert Process.whereis(MissionSession) == session
    assert Process.whereis(GlacierRelay.Wire.Listener) == listener
  end

  test "reading and refreshing never changes session evidence" do
    id = Player.unique_id("ro")
    Player.play("b4_probe", id)
    Player.await_closed(id)
    before = MissionSession.state()
    _ = Projection.snapshot()
    _ = Projection.refresh()
    _ = Projection.stats()
    assert MissionSession.state() == before
  end
end

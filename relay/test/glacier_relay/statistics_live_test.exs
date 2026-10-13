defmodule GlacierRelay.StatisticsLiveTest do
  @moduledoc """
  M4-C statistics over recordings made through the real listener and recorder in this VM
  (M4-B's fixtures): a clean recording against its legacy fixture, a rolled recording with an
  unverified segment, a recording left unclosed by a recorder crash, and one with a segment
  removed — each class of incomplete evidence must reach the statistics unchanged.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.MissionSession
  alias GlacierRelay.Recording.{Reader, Replay}
  alias GlacierRelay.Statistics
  alias GlacierRelay.Statistics.{Comparison, Text}
  alias GlacierRelay.Test.{FixturePlayer, RecordingFixtures}

  setup do
    :ok = MissionSession.subscribe()
    :ok
  end

  defp stats(dir) do
    {:ok, replay} = Replay.replay(dir)
    Statistics.of_replay(replay)
  end

  @observed ~w(attempts envelopes actor_outcomes contracts disguise items objectives player_state anomalies)a

  test "a clean recording of b6_run1 counts what its legacy fixture counts; only the evidence differs" do
    %{dir: dir} = RecordingFixtures.record_fixture("b6_run1")
    rec = stats(dir)

    leg =
      FixturePlayer.lines("b6_run1")
      |> Replay.from_envelopes(name: "b6_run1")
      |> Statistics.of_replay()

    for field <- @observed do
      rec_v = Map.fetch!(rec, field) |> Map.delete(:per_instance)
      leg_v = Map.fetch!(leg, field) |> Map.delete(:per_instance)
      assert rec_v == leg_v, "#{field} differs between the recording and the legacy fixture"
    end

    strip = &Map.drop(&1, [:instance, :start, :stop, :engine_times, :history])
    assert Enum.map(rec.per_attempt, strip) == Enum.map(leg.per_attempt, strip)

    assert rec.evidence.classification == :authoritative and
             leg.evidence.classification == :legacy

    assert rec.transport.status == :recorded and leg.transport.status == :not_recorded
    assert rec.transport.openings == 1 and rec.transport.closes == 1
    assert rec.evidence.receipt_times == :recorded and leg.evidence.receipt_times == :unavailable

    assert Text.render(rec) =~ "evidence: authoritative" and
             Text.render(leg) =~ "evidence: legacy"
  end

  test "a rolled recording with an unverified segment carries that class into every count" do
    %{dir: dir} = RecordingFixtures.rolled_recording()
    {:ok, %Reader.Result{segments: segments}} = Reader.read(dir)
    assert length(segments) > 1
    intact = stats(dir)

    assert intact.evidence.classification == :authoritative and
             intact.evidence.records.unverified_used == 0

    # The last segment: no later continuation header states a boundary that would make its
    # records durable (an unverified middle segment is covered by the next header's boundary).
    last = List.last(segments).name
    damaged = RecordingFixtures.copy(dir) |> RecordingFixtures.mark_unverified(last)
    s = stats(damaged)

    assert s.evidence.classification == :includes_unverified
    refute s.evidence.recorder_authoritative?
    assert s.evidence.records.unverified_used > 0
    assert Enum.any?(s.evidence.observed_only_reasons, &(&1 =~ "come from unverified evidence"))
    # The counts themselves are what the records say; the class says how far to trust them.
    assert s.envelopes.received == intact.envelopes.received
    assert s.actor_outcomes == intact.actor_outcomes
    assert Text.render(s) =~ "evidence: includes_unverified"

    # The damaged copy keeps the recording's identity (its header), so both land in one group,
    # which is marked mixed because one of its rows is not recorder-authoritative.
    c = Comparison.compare([intact, s], group_by: [:recording_id])
    [g] = c.groups
    assert g.mixed_evidence and g.recorder_authoritative == 1 and g.attempts == 2
    assert Enum.any?(c.limitations, &(&1 =~ "1 result(s) not recorder-authoritative"))
  end

  test "a recording left unclosed by a recorder crash is unclosed and not authoritative" do
    {rec, pid, _} = RecordingFixtures.start_recorder()
    _id = RecordingFixtures.play("b5_run1", "crash")
    health = RecordingFixtures.flush(rec)
    RecordingFixtures.kill(pid)
    s = stats(health.recording_dir)

    assert s.evidence.finalization == :unclosed
    refute s.evidence.recorder_authoritative?
    assert s.evidence.classification == :includes_unverified
    assert s.attempts.observed == 1 and s.items.occurrences == 28

    assert Enum.any?(
             s.evidence.observed_only_reasons,
             &(&1 =~ "(unclosed, evidence includes_unverified)")
           )
  end

  test "a recording with a segment removed reports the missing records as missing, not as nothing" do
    %{dir: dir} = RecordingFixtures.rolled_recording()
    {:ok, %Reader.Result{segments: segments}} = Reader.read(dir)
    assert length(segments) >= 3
    intact = stats(dir)

    damaged = RecordingFixtures.copy(dir)
    File.rm!(Path.join(damaged, "segment-000002.ndjson"))
    s = stats(damaged)

    refute s.evidence.recorder_authoritative?
    assert s.evidence.segments.missing == [2]
    assert s.evidence.unexplained_missing != []
    assert s.envelopes.received < intact.envelopes.received
    assert Enum.any?(s.evidence.observed_only_reasons, &(&1 =~ "unexplained missing record(s)"))
    assert Enum.any?(s.evidence.observed_only_reasons, &(&1 =~ "Relay sequence gap"))
    assert s.evidence.relay_sequence_gaps != []
  end
end

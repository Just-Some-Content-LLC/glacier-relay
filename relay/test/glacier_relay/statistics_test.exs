defmodule GlacierRelay.StatisticsTest do
  @moduledoc """
  M4-C statistics over the committed evidence: the ten legacy fixtures, the accepted M4 live
  recording and the M4-A/M4-B standalone recordings under `test/recordings/`, plus synthetic
  envelope streams for attribution boundaries, duplicate display names, engine-clock domains,
  sequence gaps and absent contract fields. Pure: no session, no recorder, no socket.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Recording.Replay
  alias GlacierRelay.Statistics
  alias GlacierRelay.Statistics.{Comparison, Text}

  @fixtures ~w(stage1 stage_a_probe b1_probe b2_probe b3_probe b4_probe b5_probe b5_run1 b6_probe b6_run1)
  @recordings ~w(m4-run1-9fcb9a72 m4a-A m4a-B m4a-C m4b-D)

  defp fixture_lines(name),
    do:
      Path.expand("../#{name}_envelopes.ndjson", __DIR__)
      |> File.read!()
      |> String.split("\n", trim: true)

  defp legacy(name), do: name |> fixture_lines() |> Replay.from_envelopes(name: name)
  defp legacy_stats(name), do: name |> legacy() |> Statistics.of_replay()

  defp recording_dir(name), do: Path.expand("../recordings/#{name}", __DIR__)

  defp recording_stats(name) do
    {:ok, replay} = Replay.replay(recording_dir(name))
    Statistics.of_replay(replay)
  end

  defp decoded(lines), do: Enum.map(lines, &JSON.decode!/1)
  defp count_type(objects, type), do: Enum.count(objects, &(&1["event_type"] == type))

  defp edit(lines, fun), do: lines |> decoded() |> Enum.map(fun) |> Enum.map(&JSON.encode!/1)

  # Every map key in the structured result, recursively.
  defp keys(%_{} = s), do: s |> Map.from_struct() |> keys()
  defp keys(map) when is_map(map), do: Enum.flat_map(map, fn {k, v} -> [k | keys(v)] end)
  defp keys(list) when is_list(list), do: Enum.flat_map(list, &keys/1)
  defp keys(_), do: []

  defp hash_tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(&{&1, :crypto.hash(:sha256, File.read!(&1)), File.stat!(&1).mtime})
  end

  describe "the ten legacy fixtures" do
    for name <- @fixtures do
      test "#{name}: deterministic, every envelope accounted for, counts are the stream's" do
        name = unquote(name)
        lines = fixture_lines(name)
        objects = decoded(lines)
        replay = legacy(name)
        s = Statistics.of_replay(replay)

        # Deterministic structured result, JSON and text.
        assert s == Statistics.of_replay(legacy(name))
        json = Statistics.JSON.encode(s)
        assert json == Statistics.JSON.encode(Statistics.of_replay(legacy(name)))
        assert Text.render(s) == Text.render(Statistics.of_replay(legacy(name)))
        assert is_map(JSON.decode!(json))
        assert s.schema == "glacier-relay.statistics/1"

        # Evidence class inherited from the replay: legacy, no transport, nothing authoritative.
        assert s.evidence.classification == :legacy and s.evidence.source == :legacy
        refute s.evidence.recorder_authoritative?
        assert s.evidence.transport == :not_recorded and s.evidence.receipt_times == :unavailable
        assert s.evidence.native_drops == :unknown
        assert s.transport.status == :not_recorded
        assert Enum.any?(s.evidence.observed_only_reasons, &(&1 =~ "legacy"))
        assert List.last(s.evidence.observed_only_reasons) =~ "native-side drops unknown"
        assert s.evidence.counts_are == :observed_occurrences

        # Every folded envelope is accounted for exactly once, by type, as the stream carried it.
        assert s.envelopes.received == length(lines) - length(replay.rejected)
        assert s.envelopes.reconciled?
        assert s.envelopes.accounted == s.envelopes.received

        for type <- Statistics.event_types() do
          assert s.envelopes.by_event_type[type] == count_type(objects, type),
                 "#{name}: #{type}"
        end

        assert s.attempts.observed == count_type(objects, "mission.playing")
        assert s.attempts.starts_observed == s.attempts.observed
        assert s.attempts.stops_observed == count_type(objects, "mission.stopped")
        assert s.attempts.stopped + s.attempts.stop_not_observed == s.attempts.observed

        assert s.attempts.durations.bounded + s.attempts.durations.unbounded ==
                 s.attempts.observed

        assert s.attempts.durations.bounded == s.attempts.stopped

        assert s.actor_outcomes.died + s.actor_outcomes.unattributed.died ==
                 count_type(objects, "actor.died")

        assert s.actor_outcomes.pacified + s.actor_outcomes.unattributed.pacified ==
                 count_type(objects, "actor.pacified")

        assert s.actor_outcomes.target.died + s.actor_outcomes.non_target.died ==
                 s.actor_outcomes.died

        assert s.contracts.sessions_observed == count_type(objects, "contract.started")

        assert s.contracts.ended + s.contracts.unmatched_ends ==
                 count_type(objects, "contract.ended")

        assert s.disguise.occurrences + s.disguise.unattributed ==
                 count_type(objects, "disguise.equipped") +
                   count_type(objects, "disguise.compromised") +
                   count_type(objects, "disguise.compromise_cleared")

        assert s.items.occurrences + s.items.unattributed ==
                 count_type(objects, "item.picked_up") + count_type(objects, "item.thrown") +
                   count_type(objects, "item.removed_from_inventory")

        assert s.objectives.occurrences + s.objectives.unattributed.total ==
                 count_type(objects, "objective.completed")

        assert s.player_state.occurrences + s.player_state.unattributed ==
                 count_type(objects, "player.trespassing") +
                   count_type(objects, "player.illegal_weapon")

        assert length(s.per_attempt) == s.attempts.observed
        assert s.actor_outcomes.counted == :occurrences

        # The result never carries a distinct-actor, victory, failure, rating, survival or
        # inventory field, and the text never says "complete".
        ks = s |> keys() |> Enum.map(&to_string/1)

        refute Enum.any?(
                 ks,
                 &(&1 =~
                     ~r/distinct_actor|unique_actor|actors|victory|success|failure|rating|surviv|inventory_contents|current_state/)
               )

        refute Text.render(s) =~ ~r/complete/i
        # The replay's own outputs are untouched by the statistics (a pure function of them).
        assert replay.report_text == legacy(name).report_text
        assert replay.summary_text == legacy(name).summary_text
      end
    end

    test "b6_run1: the B6 live run's known counts" do
      s = legacy_stats("b6_run1")
      [a] = s.per_attempt

      assert s.attempts.observed == 1 and s.attempts.stopped == 1
      assert s.actor_outcomes.died == 2 and s.actor_outcomes.pacified == 1
      assert s.actor_outcomes.non_target == %{died: 2, pacified: 1}
      assert s.actor_outcomes.target == %{died: 0, pacified: 0}
      assert s.actor_outcomes.by_actor_type == %{"guard" => 3}
      assert s.actor_outcomes.by_death_type == %{"bloody_kill" => 2, "pacify" => 1}
      assert s.actor_outcomes.by_kill_class == %{"ballistic" => 2, "melee" => 1}
      assert s.actor_outcomes.by_method_broad == %{"pistol" => 2, "unarmed" => 1}
      assert s.actor_outcomes.with_item == 2
      assert a.actor_outcomes.display_groups == 3
      assert s.disguise.occurrences == 5 and s.disguise.changes == 1
      assert s.disguise.compromised == 2 and s.disguise.compromise_cleared == 1
      assert s.disguise.equipped_initial == 1 and s.disguise.equipped_change == 1
      assert a.disguise.definitions_used == 2 and a.disguise.worn_standing == :compromised

      assert s.player_state.trespassing == %{
               occurrences: 2,
               observed_value_changes: 1,
               standing_by_attempt: %{"last_observed" => 1},
               notes: 0
             }

      assert s.player_state.illegal_weapon.occurrences == 2
      assert a.player_state.illegal_weapon.last == %{value: false, sequence: 8}
      assert s.contracts.paired == 1 and s.contracts.ended == 1
      assert s.contracts.by_paired_by == %{"next_rise" => 1}
      assert s.contracts.by_reason_kind == %{"exit_to_menu" => 1}
      assert s.attempts.by_disposition == %{"exited_to_menu" => 1}
      assert a.disposition == %{value: :exited_to_menu, tag: :derived}
      assert a.duration.bounded and div(a.duration.ms, 1000) == 181
      assert a.duration.clock == :relay and a.duration.rule =~ "rise to fall"
      assert a.engine_times.occurrences_outside_domain == 0
      assert a.engine_times.occurrences_in_domain == a.engine_times.occurrences_timed
      assert Float.round(a.engine_times.contract_span_s, 3) == 154.709
      assert Float.round(a.engine_times.observed_span_s, 3) == 154.709
      assert a.history == :intact
      assert s.attempts.history == %{intact: 1, broken: 0}

      assert s.envelopes.by_family == %{
               lifecycle: 2,
               contract: 2,
               actor: 3,
               disguise: 5,
               item: 0,
               objective: 0,
               player_state: 4
             }
    end

    test "stage1: three rises and no fall — unbounded durations, supersession visible, nothing invented" do
      s = legacy_stats("stage1")

      assert s.attempts.observed == 3 and s.attempts.stopped == 0
      assert s.attempts.superseded == 2 and s.attempts.last_known_playing == 1
      assert s.attempts.stop_not_observed == 3
      assert s.attempts.durations.bounded == 0 and s.attempts.durations.unbounded == 3
      assert s.attempts.durations.min_ms == nil and s.attempts.durations.total_ms == 0
      assert s.attempts.history == %{intact: 1, broken: 2}

      assert Enum.map(s.per_attempt, & &1.duration.reason) == [
               :superseded,
               :superseded,
               :stop_not_observed
             ]

      assert Enum.map(s.per_attempt, & &1.stop.observed) == [false, false, false]

      assert Enum.at(s.per_attempt, 0).stop == %{
               observed: false,
               reason: :superseded,
               by: 2,
               tag: :not_observed
             }

      assert %{broken: [%{kind: :superseded, by: 2, at_sequence: 2}]} =
               Enum.at(s.per_attempt, 0).history

      assert Enum.all?(s.per_attempt, &(&1.contract == %{status: :not_observed}))
      assert Enum.all?(s.per_attempt, &(&1.engine_times.domain == :none))

      assert Enum.any?(
               s.evidence.observed_only_reasons,
               &(&1 =~ "3 attempt(s) whose stop was not observed")
             )

      assert Enum.any?(
               s.evidence.observed_only_reasons,
               &(&1 =~ "2 attempt(s) with a broken observation history")
             )
    end

    test "b2_probe: a restart gives two attempts with their own dispositions and sessions" do
      s = legacy_stats("b2_probe")
      assert s.attempts.observed == 2
      assert s.attempts.by_disposition == %{"restarted" => 1, "exited_to_menu" => 1}

      assert s.contracts.sessions_observed == 2 and s.contracts.ended == 2 and
               s.contracts.paired == 2

      assert Enum.map(s.per_attempt, & &1.engine_times.domain) |> Enum.uniq() |> length() == 2
      assert Enum.all?(s.per_attempt, &(&1.engine_times.occurrences_outside_domain == 0))
    end
  end

  describe "synthetic streams" do
    test "no open attempt: every attempt-gated occurrence stays unattributed; nothing is attached by proximity" do
      lines =
        fixture_lines("b6_run1")
        |> Enum.reject(&(JSON.decode!(&1)["event_type"] == "mission.playing"))

      s = Replay.from_envelopes(lines, name: "no-rise") |> Statistics.of_replay()
      [u] = s.unattributed

      assert s.attempts.observed == 0 and s.per_attempt == []
      assert s.attempts.stops_observed == 1 and s.attempts.stops_with_no_open_attempt == 1
      assert s.actor_outcomes.died == 0 and s.actor_outcomes.pacified == 0
      assert s.actor_outcomes.unattributed == %{died: 2, pacified: 1}
      assert s.disguise.occurrences == 0 and s.disguise.unattributed == 5
      assert s.player_state.occurrences == 0 and s.player_state.unattributed == 4
      assert u.total == 2 + 1 + 5 + 4 + 1 and u.stops_with_no_open_attempt == 1
      assert u.unpaired_contract_sessions == 1 and s.contracts.unpaired == 1
      assert u.rule =~ "never attached by proximity"
      # The missing rise is also a Relay sequence gap (2 never arrived) and is reported as such.
      assert [%{gaps: [%{expected: 2, got: 3, missing: 1}]}] = s.evidence.relay_sequence_gaps
      assert Enum.any?(s.evidence.observed_only_reasons, &(&1 =~ "Relay sequence gap"))
      assert s.envelopes.reconciled? and s.envelopes.received == 15
    end

    test "a Relay sequence gap inside the attempt breaks its history and is never filled" do
      lines = fixture_lines("b6_run1") |> Enum.reject(&(JSON.decode!(&1)["sequence"] == 5))
      s = Replay.from_envelopes(lines, name: "gap") |> Statistics.of_replay()
      [a] = s.per_attempt

      assert %{broken: [%{kind: :gap, expected: 5, got: 6}]} = a.history
      assert a.gaps_in_attempt == 1
      assert s.attempts.history == %{intact: 0, broken: 1}
      assert [%{gaps: [%{expected: 5, got: 6, missing: 1}]}] = s.evidence.relay_sequence_gaps
      assert s.player_state.trespassing.occurrences == 1
      assert s.envelopes.received == 15 and s.envelopes.by_event_type["player.trespassing"] == 1

      assert Enum.any?(
               s.evidence.observed_only_reasons,
               &(&1 =~ "1 attempt(s) with a broken observation history")
             )

      # The gap-cut standing is the derived reading, kept as the report makes it.
      assert a.player_state.trespassing.standing in [:last_observed, :unknown]
    end

    test "duplicate display names and a shared repository id are occurrences, not actors" do
      lines =
        edit(fixture_lines("b6_run1"), fn
          %{"event_type" => "actor.died"} = o ->
            put_in(o, ["payload", "actor_name"], "Guard")
            |> put_in(["payload", "repository_id"], "e65cff4c-7023-448d-b875-18e8336e7ec8")

          o ->
            o
        end)

      s = Replay.from_envelopes(lines, name: "dupes") |> Statistics.of_replay()
      [a] = s.per_attempt

      assert s.actor_outcomes.died == 2 and a.actor_outcomes.died == 2
      assert a.actor_outcomes.display_groups == 2
      assert a.actor_outcomes.note =~ "not actors"
      assert s.actor_outcomes.note =~ "never distinct actors"
      refute Map.has_key?(a.actor_outcomes, :distinct_actors)
    end

    test "an occurrence in another contract-session clock domain is counted, never compared" do
      lines =
        edit(fixture_lines("b6_run1"), fn
          %{"sequence" => 12} = o ->
            put_in(o, ["payload", "contract_session_id"], "other-session-clock")

          o ->
            o
        end)

      base = legacy_stats("b6_run1") |> Map.fetch!(:per_attempt) |> hd()
      s = Replay.from_envelopes(lines, name: "clock") |> Statistics.of_replay()
      [a] = s.per_attempt

      assert a.engine_times.occurrences_timed == base.engine_times.occurrences_timed
      assert a.engine_times.occurrences_outside_domain == 1
      assert a.engine_times.occurrences_in_domain == base.engine_times.occurrences_in_domain - 1
      assert a.engine_times.contract_span_s == base.engine_times.contract_span_s
      assert a.engine_times.observed_span_s == base.engine_times.observed_span_s
      assert a.engine_times.rule =~ "one clock domain"
      assert a.actor_outcomes.died == 2
    end

    test "absent contract fields stay explicit and group under not_observed, last" do
      s1 = legacy_stats("b1_probe")
      [a] = s1.per_attempt
      assert a.contract == %{status: :not_observed}
      assert a.disposition == %{value: :not_observed, tag: :not_observed}

      assert s1.contracts.sessions_observed == 0 and
               s1.attempts.by_disposition == %{"not_observed" => 1}

      c =
        Comparison.compare([s1, legacy_stats("b6_run1")],
          group_by: [:contract_id, :difficulty_level]
        )

      assert Enum.map(c.groups, & &1.key) == [
               %{contract_id: "00000000-0000-0000-0000-000000000200", difficulty_level: "2"},
               %{contract_id: "not_observed", difficulty_level: "not_observed"}
             ]
    end
  end

  describe "the committed recordings" do
    test "the accepted M4 live recording (9fcb9a72): authoritative, transport recorded, exact close reason" do
      s = recording_stats("m4-run1-9fcb9a72")
      [a] = s.per_attempt

      assert s.recording.id == "9fcb9a72-74bb-49fa-86c3-7e6e21820381"
      assert s.recording.source == :recording and s.recording.format == 1
      assert s.recording.app_version == "0.1.0" and s.recording.schema_versions == [1]
      assert s.recording.node == "relay@VENGEANCE"
      assert s.evidence.classification == :authoritative and s.evidence.recorder_authoritative?
      assert s.evidence.finalization == :clean

      assert s.evidence.records.verified == 12 and s.evidence.records.first == 1 and
               s.evidence.records.last == 12

      assert s.evidence.records.durable_by_trusted_boundary == 0 and
               s.evidence.records.unverified_used == 0

      assert s.evidence.recorder_gaps == [] and s.evidence.relay_sequence_gaps == []
      assert s.evidence.transport == :recorded and s.evidence.receipt_times == :recorded

      assert s.evidence.observed_only_reasons == [
               "native-side drops unknown: a recording cannot show them to be zero"
             ]

      assert s.transport == %{
               status: :recorded,
               openings: 1,
               identifications: 1,
               closes: 1,
               closed_unidentified: 0,
               still_open_at_boundary: 0,
               by_close_reason: %{"peer_closed" => 1},
               close_reasons: %{exact: 1, qualified: 0}
             }

      assert s.envelopes.received == 9 and s.envelopes.reconciled?

      assert s.envelopes.by_family == %{
               lifecycle: 2,
               contract: 2,
               actor: 0,
               disguise: 1,
               item: 0,
               objective: 0,
               player_state: 4
             }

      assert s.attempts.durations == %{
               s.attempts.durations
               | total_ms: 207_718,
                 min_ms: 207_718,
                 max_ms: 207_718
             }

      assert a.duration == %{bounded: true, ms: 207_718, clock: :relay, rule: a.duration.rule}

      assert a.contract.contract_id == "00000000-0000-0000-0000-000000000200" and
               a.contract.difficulty_level == 2

      assert a.contract.location_id == "LOCATION_PARIS" and a.contract.paired_by == :next_rise
      assert a.disposition.value == :exited_to_menu
      assert Float.round(a.engine_times.contract_span_s, 3) == 205.202

      assert a.engine_times.occurrences_in_domain == 7 and
               a.engine_times.occurrences_outside_domain == 0

      assert s.player_state.trespassing.occurrences == 2 and
               s.player_state.illegal_weapon.occurrences == 2

      assert s.actor_outcomes.occurrences == 0 and s.items.occurrences == 0 and
               s.objectives.occurrences == 0

      assert s.instances.observation == %{"lost" => 1}
      assert Text.render(s) =~ "recorder-authoritative true"
    end

    test "the M4-A SIGKILL recording (B): unclosed, unverified evidence inherited by every count" do
      s = recording_stats("m4a-B")
      assert s.evidence.classification == :includes_unverified
      refute s.evidence.recorder_authoritative?
      assert s.evidence.finalization == :unclosed
      assert s.evidence.records.unverified_used == 19 and s.evidence.records.verified == 0

      assert Enum.any?(
               s.evidence.observed_only_reasons,
               &(&1 =~ "not recorder-authoritative (unclosed, evidence includes_unverified)")
             )

      assert Enum.any?(
               s.evidence.observed_only_reasons,
               &(&1 =~ "19 record(s) come from unverified evidence")
             )

      assert s.attempts.observed == 1 and s.actor_outcomes.died == 2
      assert Text.render(s) =~ "not recorder-authoritative"
    end

    test "the resumed recordings (M4-A C, M4-B D): durable-by-boundary records counted as such" do
      c = recording_stats("m4a-C")
      assert c.evidence.classification == :authoritative and c.evidence.recorder_authoritative?

      assert c.evidence.records == %{
               c.evidence.records
               | verified: 19,
                 durable_by_trusted_boundary: 19,
                 unverified_used: 0
             }

      assert c.evidence.boundaries == %{trusted: 1, untrusted: 0, unstated: 0}
      assert c.instances.observed == 2 and c.attempts.observed == 2
      assert c.transport.openings == 2 and c.transport.closes == 2

      d = recording_stats("m4b-D")

      assert d.evidence.records == %{
               d.evidence.records
               | verified: 50,
                 durable_by_trusted_boundary: 19
             }

      assert d.transport.openings == 3 and d.transport.closes == 3 and
               d.transport.closed_unidentified == 1

      assert d.transport.by_close_reason == %{"peer_closed" => 3}

      assert d.attempts.observed == 2 and
               d.attempts.by_disposition == %{"exited_to_menu" => 1, "not_observed" => 1}
    end

    test "the input files are never modified" do
      before = @recordings |> Enum.map(&recording_dir/1) |> Enum.map(&hash_tree/1)

      for name <- @recordings do
        s = recording_stats(name)
        _ = Statistics.JSON.encode(s)
        _ = Text.render(s)
      end

      _ = Comparison.compare(Enum.map(@recordings, &recording_stats/1), group_by: [:recording_id])
      assert @recordings |> Enum.map(&recording_dir/1) |> Enum.map(&hash_tree/1) == before
    end

    test "deterministic JSON and text for every committed recording" do
      for name <- @recordings do
        a = recording_stats(name)
        b = recording_stats(name)
        assert Map.delete(a, :recording) == Map.delete(b, :recording)
        assert Statistics.JSON.encode(a) == Statistics.JSON.encode(b)
        assert Text.render(a) == Text.render(b)
        refute Text.render(a) =~ ~r/complete/i
        assert JSON.decode!(Statistics.JSON.encode(a))["schema"] == "glacier-relay.statistics/1"
      end
    end
  end

  describe "comparison" do
    defp all_stats,
      do: Enum.map(@fixtures, &legacy_stats/1) ++ Enum.map(@recordings, &recording_stats/1)

    test "groups by scene resource with observed counts, evidence classes and a stated basis" do
      stats = all_stats()
      c = Comparison.compare(stats)

      assert c.schema == "glacier-relay.statistics-comparison/1"
      assert c.basis.group_by == [:scene_resource] and c.basis.unit == :attempt
      assert c.rows == stats |> Enum.map(& &1.attempts.observed) |> Enum.sum()
      assert length(c.recordings) == 15 and c.recordings == Enum.sort_by(c.recordings, & &1.id)

      assert Enum.map(c.groups, & &1.key.scene_resource) == [
               "assembly:/_PRO/Scenes/Missions/CoastalTown/Mission01.entity",
               "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"
             ]

      paris = Enum.at(c.groups, 1)
      assert paris.attempts == 24 and length(paris.recordings) == 15

      assert paris.evidence_classes == %{
               "authoritative" => 6,
               "includes_unverified" => 1,
               "legacy" => 17
             }

      assert paris.history == %{intact: 22, broken: 2}
      assert paris.durations.bounded == 22 and paris.durations.unbounded == 2
      assert paris.actor_outcomes.counted == :occurrences
      assert paris.counts_are == :observed_occurrences and paris.mixed_evidence

      # b6_probe 7, b6_run1 4, the live recording 4, M4-A A and B (b6) 4 each, C (b6 twice) 8, D (b6 + b5) 4.
      assert paris.families.player_state == 7 + 4 + 4 + 4 + 4 + 8 + 4
      assert Enum.any?(c.limitations, &(&1 =~ "10 legacy envelope-only input(s)"))

      assert Enum.any?(
               c.limitations,
               &(&1 =~ "engine build is not part of the recorded evidence")
             )

      assert List.last(c.limitations) =~ "native-side drops are unknown"
    end

    test "the comparison is independent of input order and deterministic as JSON and text" do
      stats = all_stats()
      a = Comparison.compare(stats, group_by: [:contract_id, :difficulty_level])
      b = Comparison.compare(Enum.reverse(stats), group_by: [:contract_id, :difficulty_level])
      assert a == b
      assert Statistics.JSON.encode(a) == Statistics.JSON.encode(b)
      assert Text.render_comparison(a) == Text.render_comparison(b)
      refute Text.render_comparison(a) =~ ~r/complete/i

      assert List.last(a.groups).key == %{
               contract_id: "not_observed",
               difficulty_level: "not_observed"
             }
    end

    test "grouping by recording, instance, attempt and event family" do
      stats = [recording_stats("m4a-C"), legacy_stats("b2_probe")]

      by_instance = Comparison.compare(stats, group_by: [:instance])
      assert length(by_instance.groups) == 3

      by_attempt = Comparison.compare(stats, group_by: [:recording_id, :attempt_number])

      assert Enum.map(
               by_attempt.groups,
               &{&1.key.recording_id, &1.key.attempt_number, &1.attempts}
             ) ==
               [
                 {"b2_probe", 1, 1},
                 {"b2_probe", 2, 1},
                 {"c8385c96-6cb4-4b52-bff7-672f2c757006", 1, 2}
               ]

      by_family = Comparison.compare(stats, group_by: [:event_family])
      assert by_family.rows == 4 * length(Statistics.families())
      assert Enum.map(by_family.groups, & &1.key.event_family) == Enum.sort(Statistics.families())
      actor = Enum.find(by_family.groups, &(&1.key.event_family == :actor))
      # m4a-C holds the B6 run twice (3 outcomes each); b2_probe one death.
      assert actor.families == %{actor: 3 + 3 + 1}
      assert actor.attempts == 4

      assert_raise ArgumentError, ~r/unsupported grouping key/, fn ->
        Comparison.compare(stats, group_by: [:victory])
      end
    end

    test "a group of authoritative, intact rows is not marked mixed" do
      c = Comparison.compare([recording_stats("m4-run1-9fcb9a72"), recording_stats("m4a-A")])
      [g] = c.groups
      refute g.mixed_evidence
      assert g.recorder_authoritative == 2 and g.evidence_classes == %{"authoritative" => 2}
    end
  end

  describe "JSON" do
    test "keys are sorted whatever the map order; atoms, tuples and DateTime values are plain JSON" do
      dt = ~U[2026-10-13 20:00:59.171850Z]
      value = %{"zeta" => [1, 2.5, nil, true], :alpha => %{y: :sym, x: {1, "two"}}, :m => dt}

      assert Statistics.JSON.encode(value) ==
               ~s({"alpha":{"x":[1,"two"],"y":"sym"},"m":"2026-10-13T20:00:59.171850Z","zeta":[1,2.5,null,true]})

      assert JSON.decode!(Statistics.JSON.encode(value))["alpha"]["x"] == [1, "two"]
    end

    test "the statistics JSON decodes, keeps the identity and the evidence classification, and is not the evidence log" do
      s = recording_stats("m4-run1-9fcb9a72")
      json = JSON.decode!(Statistics.JSON.encode(s))
      assert json["recording"]["id"] == "9fcb9a72-74bb-49fa-86c3-7e6e21820381"
      assert json["evidence"]["classification"] == "authoritative"
      assert json["evidence"]["recorder_authoritative?"] == true
      assert json["evidence"]["counts_are"] == "observed_occurrences"
      assert json["transport"]["by_close_reason"] == %{"peer_closed" => 1}
      assert json["rules"]["not_inferred"] =~ "victory, failure, rating, target survival"
      refute Map.has_key?(json, "records")
    end
  end
end

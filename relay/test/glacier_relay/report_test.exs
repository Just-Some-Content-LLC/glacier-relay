defmodule GlacierRelay.ReportTest do
  @moduledoc """
  M2 B7: the mission-oriented report (design section 50 as refined by the implementation
  authorization). Every fixture the project holds is replayed; the report is checked against the
  records it must present (nothing added, nothing dropped, nothing reordered), the named-target
  grouping is display only, the timeline respects contract-session clock domains, transport evidence
  carries no Relay sequence, the uncertainty list is complete, and the legacy summary stays
  byte-identical to the committed snapshots.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.{Lifecycle, Summary}
  alias GlacierRelay.Wire.Envelope

  @id "b7-test-instance"
  @session_a "2516109628137904204-c00b2d17-08b1-4949-9f9d-5f68b691f40f"
  @session_b "2516109618691980006-9666b5ad-6a4f-44bb-b5fb-ff86bb3a8d76"
  @paris "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"
  @novikov "052434e7-f451-462f-a9d7-13657cb047c0"
  @suit "874c4c48-0a8b-49e9-883e-49fc5f1fb051"

  @fixtures ~w(stage1 stage_a_probe b1_probe b2_probe b3_probe b4_probe b5_probe b5_run1 b6_probe b6_run1)

  # -- builders ------------------------------------------------------------------------------

  defp env(type, seq, payload) do
    %Envelope{
      protocol_version: 1,
      adapter_instance_id: @id,
      sequence: seq,
      timestamp:
        "2026-10-12T21:00:#{String.pad_leading(Integer.to_string(rem(seq, 60)), 2, "0")}.000Z",
      event_type: type,
      schema_version: 1,
      payload: payload
    }
  end

  defp playing(seq, session \\ @session_a),
    do:
      env("mission.playing", seq, %{
        scene_resource: @paris,
        scene_type: "mission",
        codename_hint: "Peacock",
        game_session_id: session
      })

  defp stopped(seq),
    do:
      env("mission.stopped", seq, %{
        scene_resource: @paris,
        scene_type: "mission",
        codename_hint: "Peacock",
        game_session_id: @session_a
      })

  defp started(seq, session),
    do:
      env("contract.started", seq, %{
        source: "engine_telemetry",
        engine_event: "ContractStart",
        contract_session_id: session,
        contract_id: "00000000-0000-0000-0000-000000000200",
        location_id: "LOCATION_PARIS",
        contract_type: "mission",
        difficulty_level: 2,
        starting_disguise_repository_id: @suit,
        is_hitman_suit: true,
        engine_timestamp_s: 0
      })

  defp ended(seq, session, kind \\ "exit_to_menu"),
    do:
      env("contract.ended", seq, %{
        source: "engine_telemetry",
        engine_event: "ContractFailed",
        contract_session_id: session,
        contract_id: "00000000-0000-0000-0000-000000000200",
        reason:
          if(kind == "restart",
            do: "Contract ended manually: OnRestartLevel",
            else: "Contract ended manually: User pressed exit to Main menu"
          ),
        reason_kind: kind,
        engine_timestamp_s: 100.5
      })

  defp outcome(seq, kind, opts) do
    env("actor." <> to_string(kind), seq, %{
      source: "engine_telemetry",
      repository_id: Keyword.get(opts, :repo, @novikov),
      actor_name: Keyword.get(opts, :name, "Viktor Novikov"),
      engine_actor_id: Keyword.get(opts, :actor_id, 1_171_052_055),
      actor_type: Keyword.get(opts, :type, "civilian"),
      actor_type_code: nil,
      is_target: Keyword.get(opts, :target, true),
      death_type: if(kind == :died, do: "kill", else: "pacify"),
      death_type_code: nil,
      death_context: Keyword.get(opts, :context, "murder"),
      death_context_code: nil,
      accident: Keyword.get(opts, :accident, false),
      kill_class: Keyword.get(opts, :class, "ballistic"),
      method_broad: Keyword.get(opts, :method, "pistol"),
      method_strict: "",
      damage_events: ["Shoot"],
      item_repository_id: Keyword.get(opts, :item, nil),
      contract_session_id: Keyword.get(opts, :session, @session_a),
      engine_timestamp_s: Keyword.get(opts, :t, 10.0)
    })
  end

  defp trespass(seq, value, opts \\ []),
    do:
      env("player.trespassing", seq, %{
        source: "engine_telemetry",
        engine_event: "Trespassing",
        trespassing: value,
        room_id: 6,
        contract_session_id: Keyword.get(opts, :session, @session_a),
        engine_timestamp_s: Keyword.get(opts, :t, 40.0)
      })

  defp objective(seq, opts \\ []),
    do:
      env("objective.completed", seq, %{
        source: "engine_telemetry",
        engine_event: "ObjectiveCompleted",
        objective_id: "aca8cd5b-e3a3-4a60-b953-c590484f0491",
        objective_type: Keyword.get(opts, :type, "kill"),
        objective_category: "primary",
        exclude_from_scoring: false,
        contract_session_id: Keyword.get(opts, :session, @session_a),
        engine_timestamp_s: Keyword.get(opts, :t, 11.0)
      })

  defp fold(steps, instance \\ Lifecycle.new(@id)) do
    Enum.reduce(steps, instance, fn
      {:close, at}, inst -> Lifecycle.connection_closed(inst, at, :peer_closed)
      {:reopen, at}, inst -> Lifecycle.connection_identified(inst, "127.0.0.1:1", at, at)
      %Envelope{} = e, inst -> elem(Lifecycle.apply_event(inst, e, nil), 0)
    end)
  end

  defp identified(instance),
    do:
      Lifecycle.connection_identified(
        instance,
        "127.0.0.1:1",
        ~U[2026-10-12 21:00:00Z],
        ~U[2026-10-12 21:00:00Z]
      )

  defp fixture_instances(name) do
    File.read!("test/#{name}_envelopes.ndjson")
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn l, acc ->
      {:ok, e} = Envelope.decode(l)

      inst =
        Map.get_lazy(acc, e.adapter_instance_id, fn -> Lifecycle.new(e.adapter_instance_id) end)

      Map.put(acc, e.adapter_instance_id, elem(Lifecycle.apply_event(inst, e, nil), 0))
    end)
  end

  defp report1(instance), do: Summary.report(%{@id => instance}) |> hd()
  defp attempt(instance, n \\ 1), do: Enum.at(report1(instance).attempts, n - 1)
  defp text(instance), do: Summary.render_report(%{@id => instance})

  # Every sequence an attempt's records occupy, from the Lifecycle records themselves.
  defp record_sequences(%Lifecycle.Attempt{} = a, %Lifecycle.Instance{} = inst) do
    paired =
      Enum.find(
        inst.contract_sessions,
        &(&1.attempt_number == a.number and &1.contract_session_id == a.contract_session_id)
      )

    [a.playing.sequence] ++
      if(a.stopped, do: [a.stopped.sequence], else: []) ++
      if(paired,
        do: [paired.started.sequence] ++ if(paired.ended, do: [paired.ended.sequence], else: []),
        else: []
      ) ++
      Enum.map(
        a.outcomes ++
          a.disguise_events ++ a.item_events ++ a.objective_events ++ a.player_state_events,
        & &1.sequence
      )
  end

  @tags [:engine, :derived, :last_observed, :not_observed, :transport]
  # Family reserved words plus the report-level words; checked on every line except the
  # explicitly labelled limitation lines, which state in words what is NOT observable.
  @forbidden ~r/complet|accomplish|all objectives|remaining|clean\b|undetected|\bsafe\b|silent assassin|inventory contents|holding|carried|owns|recovered|throws|surviv|unique|distinct actor|currently|is wearing|is trespassing|\bassassinat/i

  defp non_limitation_lines(t) do
    t
    |> String.split("\n")
    |> Enum.reject(
      &(String.contains?(&1, "is not observable on this stream") or
          String.contains?(&1, "is not established") or String.contains?(&1, "is a name only") or
          String.contains?(&1, "not a continuously verified"))
    )
  end

  describe "fixture replay (every committed envelope fixture, including the real B5 and B6 run envelopes)" do
    for name <- @fixtures do
      @name name
      test "#{name}: every record of every attempt appears exactly once in its timeline, in sequence order, with a tag; nothing is invented" do
        instances = fixture_instances(@name)
        reports = Summary.report(instances)
        assert length(reports) == map_size(instances)

        for r <- reports do
          inst = instances[r.adapter_instance_id]

          for {a, i} <- Enum.with_index(r.attempts) do
            attempt = Enum.at(inst.attempts, i)
            expected = record_sequences(attempt, inst) |> Enum.sort()
            sequenced = a.timeline.lines |> Enum.map(& &1.sequence) |> Enum.reject(&is_nil/1)
            assert sequenced == Enum.sort(sequenced), "timeline not in sequence order"
            assert sequenced == expected
            assert Enum.all?(a.timeline.lines, &(&1.tag in @tags))
            assert Enum.all?(a.timeline.lines, &(&1.sequence != nil or &1.tag == :transport))
            assert Enum.all?(a.uncertainty, &(&1.tag in @tags))
            assert Enum.count(a.uncertainty, &(&1.kind == :limitation)) == 4

            assert a.overview.number == attempt.number and
                     a.overview.start.sequence == attempt.playing.sequence

            assert a.targets.occurrences + a.non_targets.occurrences == length(attempt.outcomes)

            assert Enum.sum(
                     Enum.map(a.targets.groups ++ a.non_targets.groups, &length(&1.occurrences))
                   ) == length(attempt.outcomes)
          end
        end

        # The rendered report presents the same facts: every timeline fact and uncertainty detail is in the text.
        t = Summary.render_report(instances)

        for r <- reports, a <- r.attempts do
          for l <- a.timeline.lines, do: assert(String.contains?(t, l.fact))
          for u <- a.uncertainty, do: assert(String.contains?(t, u.detail))
        end

        for l <- non_limitation_lines(t), do: refute(l =~ @forbidden, l)
      end

      test "#{name}: the legacy summary is byte-identical to its committed snapshot, and the records are untouched by reporting" do
        instances = fixture_instances(@name)

        assert Summary.render(instances) <> "\n" ==
                 File.read!("test/snapshots/#{@name}.summary.txt")

        before = instances
        _ = Summary.report(instances)
        _ = Summary.render_report(instances)
        assert instances == before

        assert Summary.render(instances) <> "\n" ==
                 File.read!("test/snapshots/#{@name}.summary.txt")
      end
    end

    test "the report is a function of the replayed facts: two independent folds and a prefix+rest fold give the same report" do
      for name <- @fixtures do
        a = fixture_instances(name)
        b = fixture_instances(name)
        assert Summary.report(a) == Summary.report(b)
        assert Summary.render_report(a) == Summary.render_report(b)
      end

      lines = File.read!("test/b6_run1_envelopes.ndjson") |> String.split("\n", trim: true)
      {first, rest} = Enum.split(lines, 7)
      whole = fixture_instances("b6_run1")

      staged =
        Enum.reduce(first ++ rest, %{}, fn l, acc ->
          {:ok, e} = Envelope.decode(l)

          inst =
            Map.get_lazy(acc, e.adapter_instance_id, fn ->
              Lifecycle.new(e.adapter_instance_id)
            end)

          Map.put(acc, e.adapter_instance_id, elem(Lifecycle.apply_event(inst, e, nil), 0))
        end)

      assert Summary.report(whole) == Summary.report(staged)
    end
  end

  describe "the real B6 run (section 48) and B5 run (section 44), as a reader sees them" do
    test "B6 run: overview, player state, named non-targets, exit disposition, intact history" do
      instances = fixture_instances("b6_run1")
      [r] = Summary.report(instances)
      [a] = r.attempts
      assert a.overview.contract.status == :paired and a.overview.contract.paired_by == :next_rise

      assert a.overview.disposition.value == :exited_to_menu and
               a.overview.disposition.tag == :derived

      assert a.overview.completeness == :complete
      assert a.targets.groups == [] and length(a.non_targets.groups) == 3

      assert a.activity.player_state.view.trespassing.last.value == false and
               a.activity.player_state.view_tag == :last_observed

      t = Summary.render_report(instances)

      assert t =~
               "target outcomes observed: none in the stream; the full status of all mission targets is not established; an absent outcome is not evidence of survival [not observed]"

      assert t =~
               "disposition: exited to menu [engine reason \"Contract ended manually: User pressed exit to Main menu\"; attached from the paired session's contract.ended #16 (after the stop): BEAM-derived]"

      assert t =~
               "player state: trespassing last observed false at #5 (room_id 6), 2 occurrences, 1 observed value change; illegal weapon last observed false at #8 (last named weapon ICA19 Red Trinity fca954f6… at #6), 2 occurrences, 1 observed value change [last observed, never current state]"

      assert t =~
               "#4 2026-10-12T20:48:53.264Z engine 40.31857681274414s (t+40.319s) player.trespassing: true (room_id 6) [engine-authored]"
    end

    test "B5 run: Novikov and Margolis are reported as engine-classified accident/explosion deaths, with no attribution and no survival claim" do
      instances = fixture_instances("b5_run1")
      [r] = Summary.report(instances)
      [a] = r.attempts
      assert Enum.map(a.targets.groups, & &1.actor_name) == ["Viktor Novikov", "Dalia Margolis"]

      assert [
               %{
                 occurrences: [
                   %{
                     kind: :died,
                     death_type: "kill",
                     death_context: "accident",
                     kill_class: "explosion",
                     accident: true,
                     tag: :engine
                   }
                 ]
               }
               | _
             ] = a.targets.groups

      assert a.overview.disposition.value == :not_observed
      assert Enum.any?(a.uncertainty, &(&1.kind == :contract_end_not_observed))
      t = Summary.render_report(instances)

      assert t =~
               "        Viktor Novikov (052434e7…): 1 occurrence\n          #16 died @217.10797119140625s (civilian; engine actor id 1171052055): kill/accident, explosion, accident/accident_explosion, damage [Shoot], item a8a0c154… [engine classification]"

      assert t =~
               "objectives: 2 occurrences — kill/primary (first observed) aca8cd5b… at #19, kill/primary (first observed) 9da41883… at #42 [engine telemetry; says nothing about how the mission ended]"

      for l <- non_limitation_lines(t), do: refute(l =~ ~r/47 killed|assassinated|surviv/i, l)
    end
  end

  describe "named targets (display grouping only)" do
    test "pacify then death of the same named target are two occurrences in one display group" do
      inst =
        fold([playing(1), outcome(2, :pacified, t: 5.0), outcome(3, :died, t: 6.0), stopped(4)])

      a = attempt(inst)

      assert [
               %{
                 actor_name: "Viktor Novikov",
                 repository_id: @novikov,
                 occurrences: [%{sequence: 2, kind: :pacified}, %{sequence: 3, kind: :died}]
               }
             ] = a.targets.groups

      assert a.targets.occurrences == 2 and a.targets.grouping == :display_only
      assert text(inst) =~ "Viktor Novikov (052434e7…): 2 occurrences"
    end

    test "the B1 fixture: Novikov pacified by the explosion then killed are two occurrences, each with its own classification" do
      [r] = Summary.report(fixture_instances("b1_probe"))
      [a] = r.attempts
      [novikov] = a.targets.groups

      assert Enum.map(novikov.occurrences, &{&1.sequence, &1.kind, &1.kill_class}) == [
               {14, :pacified, "explosion"},
               {15, :died, "ballistic"}
             ]
    end

    test "identical names with distinct definitions are distinct groups; identical name and definition with distinct engine actor ids stay one display group with both ids kept" do
      inst =
        fold([
          playing(1),
          outcome(2, :died, name: "Guard", repo: "aaaa", actor_id: 1, target: false),
          outcome(3, :died, name: "Guard", repo: "bbbb", actor_id: 2, target: false),
          outcome(4, :died, name: "Guard", repo: "aaaa", actor_id: 3, target: false)
        ])

      a = attempt(inst)

      assert Enum.map(
               a.non_targets.groups,
               &{&1.repository_id, Enum.map(&1.occurrences, fn o -> o.engine_actor_id end)}
             ) == [{"aaaa", [1, 3]}, {"bbbb", [2]}]

      t = text(inst)

      assert t =~ "Guard (aaaa): 2 occurrences" and t =~ "engine actor id 1)" and
               t =~ "engine actor id 3)"

      refute t =~ ~r/unique|distinct actor/i
      assert t =~ "occurrence counts, not an actor count"
    end

    test "no target outcome: no target is listed and no survival is claimed; the note stays" do
      inst = fold([playing(1), outcome(2, :died, name: "Guard", repo: "aaaa", target: false)])
      a = attempt(inst)
      assert a.targets.groups == [] and a.targets.note =~ "not evidence of survival"
      t = text(inst)
      assert t =~ "target outcomes observed: none in the stream"
      refute t =~ ~r/surviv(ed|es|ing)\b/i
    end
  end

  describe "timeline and clock domains" do
    test "engine timestamps are compared only within one established contract-session domain; a regression there is marked; nothing is reordered" do
      inst =
        fold([
          started(1, @session_a),
          playing(2),
          trespass(3, true, t: 50.0),
          trespass(4, false, t: 20.0),
          stopped(5)
        ])

      lines = attempt(inst).timeline.lines
      assert Enum.map(lines, & &1.sequence) == [1, 2, 3, 4, 5]
      l4 = Enum.find(lines, &(&1.sequence == 4))
      assert l4.clock == %{domain: @session_a, comparability: :same_domain, regression: true}
      assert l4.engine_t == 20.0 and l4.engine_t_rel == 20.0

      assert text(inst) =~
               "#4 2026-10-12T21:00:04.000Z engine 20.0s (t+20.0s) (engine time earlier than the previous line) player.trespassing: false (room_id 6)"
    end

    test "a contract-session change is a new clock: the reset to 0 is not a regression and relative time restarts from the attempt's own session" do
      inst =
        fold([
          started(1, @session_a),
          playing(2),
          trespass(3, true, t: 300.0),
          stopped(4),
          playing(5, @session_b),
          started(6, @session_b),
          trespass(7, true, session: @session_b, t: 2.0)
        ])

      a2 = attempt(inst, 2)
      l6 = Enum.find(a2.timeline.lines, &(&1.sequence == 6))
      l7 = Enum.find(a2.timeline.lines, &(&1.sequence == 7))
      assert l6.clock.comparability == :first and l6.engine_t_rel == 0

      assert l7.clock == %{domain: @session_b, comparability: :same_domain, regression: false} and
               l7.engine_t_rel == 2.0

      # The same instance: an attempt-2 occurrence still stamped with session A, arriving before ContractStart(B), is a different domain.
      inst =
        fold([
          started(1, @session_a),
          playing(2),
          trespass(3, true, t: 300.0),
          stopped(4),
          playing(5, @session_b),
          trespass(6, true, session: @session_a, t: 301.0),
          started(7, @session_b),
          trespass(8, false, session: @session_b, t: 1.0)
        ])

      a2 = attempt(inst, 2)
      by = Map.new(a2.timeline.lines, &{&1.sequence, &1})
      assert by[6].clock.comparability == :first and by[6].engine_t_rel == nil
      assert by[7].clock.comparability == :new_domain and by[7].clock.regression == false
      assert by[8].clock.comparability == :same_domain and by[8].engine_t_rel == 1.0
      assert text(inst) =~ "(new contract clock)"
    end

    test "an unknown clock domain (no session on the occurrence) makes comparability unknown and no regression is marked" do
      inst =
        fold([
          started(1, @session_a),
          playing(2),
          trespass(3, true, t: 50.0),
          trespass(4, false, session: nil, t: 20.0),
          trespass(5, true, t: 10.0)
        ])

      by = Map.new(attempt(inst).timeline.lines, &{&1.sequence, &1})

      assert by[4].clock == %{domain: :unknown, comparability: :unknown, regression: false} and
               by[4].engine_t_rel == nil

      assert by[5].clock == %{domain: @session_a, comparability: :unknown, regression: false}
      assert text(inst) =~ "(clock comparability unknown)"
    end

    test "lifecycle edges carry Relay time only and take part in no engine-time comparison; an attempt without a paired session shows no relative time" do
      inst = fold([playing(1), trespass(2, true, t: 50.0), stopped(3)])
      lines = attempt(inst).timeline.lines

      assert Enum.map(lines, &{&1.sequence, &1.engine_t, &1.engine_t_rel}) == [
               {1, nil, nil},
               {2, 50.0, nil},
               {3, nil, nil}
             ]

      assert Enum.find(lines, &(&1.sequence == 2)).clock.comparability == :first

      assert text(inst) =~
               "#2 2026-10-12T21:00:02.000Z engine 50.0s player.trespassing: true (room_id 6) [engine-authored]"
    end

    test "a transport interruption appears after the last received sequence with no Relay sequence and implies no stop" do
      at = ~U[2026-10-12 21:05:00Z]
      inst = fold([playing(1), trespass(2, true), {:close, at}], identified(Lifecycle.new(@id)))
      a = attempt(inst)
      [l1, l2, l3] = a.timeline.lines
      assert {l1.sequence, l2.sequence} == {1, 2}

      assert l3.sequence == nil and l3.position == {2, 1} and l3.tag == :transport and
               l3.relay_at == at

      assert l3.fact =~ "no mission.stopped is implied"

      assert a.overview.stop == %{
               status: :not_observed,
               reason: :last_known_playing,
               tag: :not_observed
             }

      assert Enum.any?(a.uncertainty, &(&1.kind == :interruption and &1.tag == :transport))

      assert text(inst) =~
               "-- 2026-10-12T21:05:00Z observation lost: the connection closed (:peer_closed) after #2; no mission.stopped is implied [transport]"
    end
  end

  describe "uncertainty and provenance" do
    test "gaps, supersession and ambiguous correlation are listed with their tags" do
      inst =
        fold([
          started(1, @session_a),
          started(2, @session_b),
          playing(3),
          trespass(4, true),
          trespass(7, false),
          playing(9)
        ])

      a1 = attempt(inst, 1)
      kinds = Enum.map(a1.uncertainty, & &1.kind)
      assert :gap in kinds and :superseded in kinds and :contract_ambiguous in kinds

      assert Enum.find(a1.uncertainty, &(&1.kind == :gap)).detail ==
               "sequence gap 5→7 inside the attempt: 2 envelope(s) never arrived"

      assert a1.overview.contract.status == :ambiguous and
               a1.overview.stop.reason == {:superseded, 2}

      assert Enum.any?(a1.uncertainty, &(&1.kind == :player_state_unknown))
      t = text(inst)

      assert t =~
               "observation coverage: history broken — gap 5→7, gap 8→9, superseded by attempt 2 at #9"

      assert t =~ "stop: not observed; superseded by attempt 2 [not observed]"
    end

    test "every overview field carries its tag; disposition is derived from engine reasons by correlation, the objective label is first observed, and nothing claims the mission ended" do
      inst =
        fold([
          started(1, @session_a),
          playing(2),
          outcome(3, :died, t: 10.0),
          objective(4),
          stopped(5),
          ended(6, @session_a)
        ])

      a = attempt(inst)
      assert a.overview.start.tag == :engine and a.overview.stop.tag == :engine

      assert a.overview.contract.correlation_tag == :derived and
               a.overview.contract.started.tag == :engine

      assert a.overview.disposition == %{
               value: :exited_to_menu,
               reason: "Contract ended manually: User pressed exit to Main menu",
               reason_kind: "exit_to_menu",
               ended_sequence: 6,
               ended_relative: :after_stop,
               tag: :derived
             }

      assert [%{metadata_basis: :first_observed}] = a.activity.objectives.view.by_objective

      assert a.activity.player_state.view_tag == :last_observed and
               a.activity.disguise.view_tag == :derived

      t = text(inst)

      assert t =~
               "kill/primary (first observed) aca8cd5b… at #4 [engine telemetry; says nothing about how the mission ended]"

      for l <- non_limitation_lines(t), do: refute(l =~ @forbidden, l)
      assert Enum.count(a.uncertainty, &(&1.kind == :limitation)) == 4
    end

    test "unattributed occurrences and instance anomalies stay at the instance level, labelled, never attached" do
      inst = fold([outcome(1, :died, []), playing(2), stopped(3), objective(4)])
      r = report1(inst)
      assert length(r.unattributed.outcomes) == 1 and length(r.unattributed.objectives) == 1
      t = text(inst)
      assert t =~ "actor.died #1 Viktor Novikov with no open attempt [engine, unattributed]"
      assert t =~ "objective aca8cd5b… #4 not attached (no_open_attempt) [engine, unattributed]"
    end

    test "an empty state renders" do
      assert Summary.render_report(%{}) == "no adapter instance has delivered an event"
      assert Summary.report(%{}) == []
    end
  end
end

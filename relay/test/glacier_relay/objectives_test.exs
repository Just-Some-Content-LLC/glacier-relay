defmodule GlacierRelay.ObjectivesTest do
  @moduledoc """
  M2 B5: validation of objective.completed v1; attribution fixed at receipt (design section 42.7:
  stream order selects the open attempt, an established contradicting contract session vetoes,
  everything else is kept unattributed with its reason, nothing is ever moved); the display
  grouping and its conflicts (no objective state inferred); history bounded by the shared
  `AttemptHistory`; replay equivalence from the bare facts; and the summary wording.

  Evidence case: the one B0 occurrence (13 ms after the Novikov kill). SYN cases are synthetic and
  pin the model's conservative behaviour, not engine semantics. Every external fact a case depends
  on — pairing, gaps, interruptions, supersession, the stop — is supplied explicitly by the stream.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.{AttemptHistory, Events, Items, Lifecycle, Objectives, Summary}
  alias GlacierRelay.Lifecycle.Attempt
  alias GlacierRelay.Wire.Envelope

  @id "b5-test-instance"
  @session_a "2516109628137904204-c00b2d17-08b1-4949-9f9d-5f68b691f40f"
  @session_b "2516109618691980006-9666b5ad-6a4f-44bb-b5fb-ff86bb3a8d76"
  @paris "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"
  @novikov "aca8cd5b-e3a3-4a60-b953-c590484f0491"
  @other "5f0d2c1e-3b7a-4c9d-8e21-6a4b9c0d1e2f"
  @suit "874c4c48-0a8b-49e9-883e-49fc5f1fb051"

  # -- stream builders -------------------------------------------------------------------------

  defp env(type, seq, payload) do
    %Envelope{
      protocol_version: 1,
      adapter_instance_id: @id,
      sequence: seq,
      timestamp: "2026-10-09T06:00:#{String.pad_leading(Integer.to_string(rem(seq, 60)), 2, "0")}.000Z",
      event_type: type,
      schema_version: 1,
      payload: payload
    }
  end

  defp playing(seq, session \\ @session_a),
    do: env("mission.playing", seq, %{scene_resource: @paris, scene_type: "mission", codename_hint: "Peacock", game_session_id: session})

  defp stopped(seq),
    do: env("mission.stopped", seq, %{scene_resource: @paris, scene_type: "mission", codename_hint: "Peacock", game_session_id: @session_a})

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

  defp objective_payload(id, opts) do
    %{
      source: "engine_telemetry",
      engine_event: "ObjectiveCompleted",
      objective_id: id,
      objective_type: Keyword.get(opts, :type, "kill"),
      objective_category: Keyword.get(opts, :category, "primary"),
      exclude_from_scoring: Keyword.get(opts, :scoring, false),
      contract_session_id: Keyword.get(opts, :session, @session_a),
      engine_timestamp_s: Keyword.get(opts, :t, 759.401611)
    }
  end

  defp objective(seq, id \\ @novikov, opts \\ []), do: env("objective.completed", seq, objective_payload(id, opts))

  defp pickup(seq),
    do:
      env("item.picked_up", seq, %{
        source: "engine_telemetry",
        engine_event: "ItemPickedUp",
        item_repository_id: "6adddf7e-6879-4d51-a7e2-6a25ffdca6ae",
        item_instance_id: nil,
        item_name: "Wrench",
        item_type: "CC_Wrench",
        online_traits: ["melee_nonlethal"],
        contract_session_id: @session_a,
        engine_timestamp_s: 176.078949
      })

  defp died(seq),
    do:
      env("actor.died", seq, %{
        source: "engine_telemetry",
        repository_id: "052434e7-f451-462f-a9d7-13657cb047c0",
        actor_name: "Viktor Novikov",
        engine_actor_id: 1_171_052_055,
        actor_type: "civilian",
        actor_type_code: nil,
        is_target: true,
        death_type: "kill",
        death_type_code: nil,
        death_context: "murder",
        death_context_code: nil,
        accident: false,
        kill_class: "ballistic",
        method_broad: "pistol",
        method_strict: "",
        damage_events: ["Shoot"],
        item_repository_id: "e70adb5b-0646-4f88-bd4a-85bea7a2a654",
        contract_session_id: @session_a,
        engine_timestamp_s: 759.388428
      })

  defp fold(steps, instance \\ Lifecycle.new(@id)) do
    Enum.reduce(steps, {instance, []}, fn
      {:close, at}, {inst, notes} ->
        {Lifecycle.connection_closed(inst, at, :peer_closed), notes}

      {:reopen, at}, {inst, notes} ->
        {Lifecycle.connection_identified(inst, "127.0.0.1:1", at, at), notes}

      %Envelope{} = e, {inst, notes} ->
        {inst, more} = Lifecycle.apply_event(inst, e, nil)
        {inst, notes ++ more}
    end)
  end

  defp identified(instance),
    do: Lifecycle.connection_identified(instance, "127.0.0.1:1", ~U[2026-10-09 06:00:00Z], ~U[2026-10-09 06:00:00Z])

  defp view(instance, number \\ 1) do
    attempt = Enum.at(instance.attempts, number - 1)
    Objectives.derive(attempt, instance)
  end

  # The same view from the bare facts: the occurrences with their recorded attribution, the
  # instance's gaps, the attempt's interruptions and supersession — and nothing about pairing,
  # which the derivation must not consult.
  defp from_facts(instance, number \\ 1) do
    attempt = Enum.at(instance.attempts, number - 1)

    bare = %Attempt{
      number: attempt.number,
      playing: attempt.playing,
      stopped: attempt.stopped,
      mission: attempt.mission,
      superseded_by: attempt.superseded_by,
      superseded_at: attempt.superseded_at,
      interruptions: attempt.interruptions,
      objective_events: attempt.objective_events
    }

    Objectives.derive(bare, %{Lifecycle.new(@id) | gaps: instance.gaps})
  end

  defp text(instance), do: Summary.render(%{@id => instance})

  defp objectives_line(instance, n \\ 0) do
    text(instance) |> String.split("\n") |> Enum.filter(&String.contains?(&1, "objectives (engine telemetry)")) |> Enum.at(n)
  end

  defp attributions(instance, number \\ 1),
    do: Enum.at(instance.attempts, number - 1).objective_events |> Enum.map(&{&1.sequence, &1.attribution})

  defp wire(extra \\ %{}) do
    Map.merge(
      %{
        "source" => "engine_telemetry",
        "engine_event" => "ObjectiveCompleted",
        "objective_id" => @novikov,
        "objective_type" => "kill",
        "objective_category" => "primary",
        "exclude_from_scoring" => false,
        "contract_session_id" => @session_a,
        "engine_timestamp_s" => 759.401611
      },
      extra
    )
  end

  @forbidden ~r/complet|accomplish|all objectives|\bof \d+\b|remaining|clean|undetected|safe|silent assassin|inventory contents|holding|carried|owns|recovered|throws/i

  describe "validation" do
    test "objective.completed v1 with the B0 shape; false is carried as false" do
      assert {:ok, p} = Events.validate("objective.completed", 1, wire())
      assert p.objective_id == @novikov and p.engine_event == "ObjectiveCompleted"
      assert p.objective_type == "kill" and p.objective_category == "primary"
      assert p.exclude_from_scoring == false
      assert p.contract_session_id == @session_a and p.engine_timestamp_s == 759.401611
    end

    test "the id is the subject: required, non-empty, a string" do
      assert {:error, {:missing_field, "objective_id"}} = Events.validate("objective.completed", 1, Map.delete(wire(), "objective_id"))
      assert {:error, {:invalid_field, "objective_id"}} = Events.validate("objective.completed", 1, wire(%{"objective_id" => ""}))
      assert {:error, {:invalid_field, "objective_id"}} = Events.validate("objective.completed", 1, wire(%{"objective_id" => 7}))
    end

    test "the other fields are optional; present must be typed; exclude_from_scoring must be a boolean" do
      bare = Map.drop(wire(), ["objective_type", "objective_category", "exclude_from_scoring", "contract_session_id", "engine_timestamp_s"])
      assert {:ok, p} = Events.validate("objective.completed", 1, bare)
      assert p.objective_type == nil and p.objective_category == nil and p.exclude_from_scoring == nil
      assert p.contract_session_id == nil and p.engine_timestamp_s == nil

      assert {:ok, %{exclude_from_scoring: true}} = Events.validate("objective.completed", 1, wire(%{"exclude_from_scoring" => true}))
      assert {:ok, %{objective_type: ""}} = Events.validate("objective.completed", 1, wire(%{"objective_type" => ""}))

      for {key, bad} <- [
            {"objective_type", 0},
            {"objective_category", ["primary"]},
            {"exclude_from_scoring", "false"},
            {"exclude_from_scoring", 0},
            {"exclude_from_scoring", nil},
            {"contract_session_id", 1},
            {"engine_timestamp_s", "x"}
          ] do
        assert {:error, {:invalid_field, ^key}} = Events.validate("objective.completed", 1, wire(%{key => bad}))
      end

      assert {:error, {:missing_field, "engine_event"}} = Events.validate("objective.completed", 1, Map.delete(wire(), "engine_event"))
    end

    test "unknown versions and names are rejected; classification" do
      assert {:error, {:unsupported_schema_version, "objective.completed", 2}} = Events.validate("objective.completed", 2, wire())

      for name <- ["objective.failed", "objective.updated", "mission.completed", "objective.complete", "objectives.completed"] do
        assert {:error, {:unknown_event_type, ^name}} = Events.validate(name, 1, wire())
      end

      assert Events.objective_event?("objective.completed")
      refute Events.objective_event?("objective.failed")
      refute Events.item_event?("objective.completed")
      refute Events.contract_event?("objective.completed")
      refute Events.actor_outcome?("objective.completed")
      refute Events.disguise_event?("objective.completed")
    end
  end

  # -- evidence: the native envelopes of the B5 standalone wire run ----------------------------

  @b5_lines File.read!("test/b5_probe_envelopes.ndjson") |> String.split("\n", trim: true)
  @b5_id "3894ff3e-8fb7-416a-a3d8-1c734c93a2cd"

  describe "B5 wire fixture (16 native envelopes: the B0 occurrence beside the accepted vocabulary, then the 42.7 placements)" do
    test "every envelope decodes with the payload the native normalizer wrote; the objective after the fall has its payload" do
      decoded = Enum.map(@b5_lines, fn l -> {:ok, e} = Envelope.decode(l); e end)
      assert Enum.map(decoded, & &1.sequence) == Enum.to_list(1..16)
      assert Enum.map(decoded, & &1.event_type) == [
               "contract.started", "mission.playing", "disguise.equipped", "actor.died", "objective.completed", "item.picked_up",
               "contract.ended", "mission.stopped", "objective.completed", "mission.playing", "objective.completed", "contract.started",
               "objective.completed", "objective.completed", "mission.stopped", "contract.ended"
             ]

      for {line, e} <- Enum.zip(@b5_lines, decoded), Events.objective_event?(e.event_type) do
        raw = JSON.decode!(line)["payload"]
        assert e.payload.objective_id == raw["objective_id"]
        assert e.payload.objective_type == raw["objective_type"] and e.payload.objective_category == raw["objective_category"]
        assert e.payload.exclude_from_scoring == raw["exclude_from_scoring"] and raw["exclude_from_scoring"] == false
        assert e.payload.contract_session_id == raw["contract_session_id"]
        assert e.payload.engine_timestamp_s == raw["engine_timestamp_s"]
        assert Map.keys(raw) -- ["source", "engine_event", "objective_id", "objective_type", "objective_category", "exclude_from_scoring", "contract_session_id", "engine_timestamp_s"] == []
      end

      # #9 was presented after the fall-frame drain and published after mission.stopped (#8).
      assert Enum.at(decoded, 8).event_type == "objective.completed" and Enum.at(decoded, 7).event_type == "mission.stopped"
      assert Enum.at(decoded, 8).payload.objective_id == @novikov
    end

    test "folded: the recorded placements attribute as designed, and the facts reproduce the views" do
      decoded = Enum.map(@b5_lines, fn l -> {:ok, e} = Envelope.decode(l); e end)
      {inst, notes} = fold(decoded, Lifecycle.new(@b5_id))
      assert inst.received == 16 and inst.gaps == []
      assert {:unattributed_objective_event, 9, :no_open_attempt} in notes
      assert {:unattributed_objective_event, 13, {:session_contradiction, 2, @session_b, @session_a}} in notes

      assert attributions(inst, 1) == [{5, %{attempt: 1, basis: :order_session_match, attempt_session: @session_a, occurrence_session: @session_a}}]
      assert attributions(inst, 2) == [
               {11, %{attempt: 2, basis: :order, attempt_session: nil, occurrence_session: @session_a}},
               {14, %{attempt: 2, basis: :order_session_match, attempt_session: @session_b, occurrence_session: @session_b}}
             ]
      assert Enum.map(inst.unattributed_objective_events, &{&1.sequence, &1.attribution.basis}) == [{9, :no_open_attempt}, {13, :session_contradiction}]

      for n <- 1..2, do: assert(from_facts(inst, n) == view(inst, n))
      assert view(inst, 1).completed == 1 and view(inst, 2).completed == 2 and view(inst, 2).objective_ids == [@novikov, @other]
      t = Summary.render(%{@b5_id => inst})
      assert t =~ "objectives (engine telemetry): 2 reported done — kill/primary aca8cd5b… #11 @759.401611s, kill/primary 5f0d2c1e… #14 @759.401611s; history intact"
      refute t =~ @forbidden
    end
  end

  describe "B0 (evidence order): the kill and the objective 13 ms later" do
    test "attached by order with the matching session; one row; the facts reproduce it" do
      {inst, notes} = fold([started(1, @session_a), playing(2), died(3), objective(4), stopped(5)])
      refute Enum.any?(notes, &match?({:unattributed_objective_event, _, _}, &1))
      [a] = inst.attempts
      assert a.contract_session_id == @session_a
      assert attributions(inst) == [{4, %{attempt: 1, basis: :order_session_match, attempt_session: @session_a, occurrence_session: @session_a}}]
      assert Enum.map(a.outcomes, & &1.sequence) == [3]

      d = view(inst)
      assert d.completed == 1 and d.occurrences == 1 and d.objective_ids == [@novikov] and d.history == :complete
      assert d.by_objective == [
               %{objective_id: @novikov, occurrences: 1, sequences: [4], objective_type: "kill", objective_category: "primary", exclude_from_scoring: false, conflicts: []}
             ]

      assert from_facts(inst) == d
      assert objectives_line(inst) == "    objectives (engine telemetry): 1 reported done — kill/primary aca8cd5b… #4 @759.401611s; history intact"
      refute objectives_line(inst) =~ @forbidden
    end
  end

  describe "SYN: display grouping (no objective state)" do
    test "counts are independent of distinct ids; every sequence is kept" do
      {inst, _} = fold([playing(1), objective(2), objective(3), objective(4, @other), objective(5)])
      d = view(inst)
      assert d.completed == 4 and d.occurrences == 4 and d.objective_ids == [@novikov, @other]
      assert [%{occurrences: 3, sequences: [2, 3, 5]}, %{occurrences: 1, sequences: [4]}] = d.by_objective
      assert from_facts(inst) == d
    end

    test "exclude_from_scoring: false is preserved as false, distinct from absence" do
      {inst, _} = fold([playing(1), objective(2, @novikov, scoring: false)])
      assert [%{exclude_from_scoring: false}] = view(inst).by_objective
      refute objectives_line(inst) =~ "not scored"

      {inst, _} = fold([playing(1), objective(2, @novikov, scoring: nil)])
      assert [%{exclude_from_scoring: :not_observed}] = view(inst).by_objective
      refute objectives_line(inst) =~ "not scored"

      {inst, _} = fold([playing(1), objective(2, @novikov, scoring: true)])
      assert [%{exclude_from_scoring: true}] = view(inst).by_objective
      assert objectives_line(inst) =~ "aca8cd5b… #2 @759.401611s (not scored)"

      # absent then false: the first observed boolean, false, sticks; no conflict.
      {inst, _} = fold([playing(1), objective(2, @novikov, scoring: nil), objective(3, @novikov, scoring: false)])
      assert [%{exclude_from_scoring: false, conflicts: []}] = view(inst).by_objective

      # false then true: the first stays, the later one is a visible conflict.
      {inst, _} = fold([playing(1), objective(2, @novikov, scoring: false), objective(3, @novikov, scoring: true), objective(4, @novikov, scoring: true)])
      assert [%{exclude_from_scoring: false, conflicts: [%{sequence: 3, field: :exclude_from_scoring, observed: true}, %{sequence: 4, field: :exclude_from_scoring, observed: true}]}] = view(inst).by_objective
      assert objectives_line(inst) =~ "(later observations differ: #3 scoring excluded true, #4 scoring excluded true)"
    end

    test "type and category: first non-empty observed string; empty is no value; later differing strings are conflicts" do
      {inst, _} = fold([playing(1), objective(2, @novikov, type: "", category: nil), objective(3, @novikov, type: "kill", category: "primary")])
      assert [%{objective_type: "kill", objective_category: "primary", conflicts: []}] = view(inst).by_objective

      {inst, _} = fold([playing(1), objective(2, @novikov, type: nil, category: nil)])
      assert [%{objective_type: nil, objective_category: nil}] = view(inst).by_objective
      assert objectives_line(inst) =~ "1 reported done — objective aca8cd5b… #2"

      {inst, _} =
        fold([playing(1), objective(2, @novikov, type: "kill", category: "primary"), objective(3, @novikov, type: "setpiece", category: "primary"), objective(4, @novikov, type: "", category: "secondary"), objective(5, @novikov, type: "kill")])

      [row] = view(inst).by_objective
      assert row.objective_type == "kill" and row.objective_category == "primary" and row.occurrences == 4
      assert row.conflicts == [
               %{sequence: 3, field: :objective_type, observed: "setpiece"},
               %{sequence: 4, field: :objective_category, observed: "secondary"}
             ]

      assert objectives_line(inst) =~ "kill/primary aca8cd5b… #2 @759.401611s #3 @759.401611s #4 @759.401611s #5 @759.401611s (later observations differ: #3 type \"setpiece\", #4 category \"secondary\")"
      assert from_facts(inst) == view(inst)
    end

    test "an attempt with no objective occurrence" do
      {inst, _} = fold([playing(1), died(2)])
      assert view(inst) == %{completed: 0, by_objective: [], objective_ids: [], history: :complete, occurrences: 0}
      assert objectives_line(inst) == "    objectives (engine telemetry): none observed in the attempt"
    end
  end

  describe "SYN: attribution fixed at receipt (session as a veto only)" do
    test "before any rise and after a stop: unattributed with :no_open_attempt, never attached later" do
      {inst, notes} = fold([objective(1), playing(2), objective(3), stopped(4), objective(5)])
      assert {:unattributed_objective_event, 1, :no_open_attempt} in notes
      assert {:unattributed_objective_event, 5, :no_open_attempt} in notes
      assert Enum.map(inst.unattributed_objective_events, &{&1.sequence, &1.attribution.basis}) == [{1, :no_open_attempt}, {5, :no_open_attempt}]
      assert attributions(inst) == [{3, %{attempt: 1, basis: :order, attempt_session: nil, occurrence_session: @session_a}}]
      assert view(inst).completed == 1
      t = text(inst)
      assert t =~ "  objective kill/primary aca8cd5b… #1 @759.401611s with no open attempt"
      assert t =~ "  objective kill/primary aca8cd5b… #5 @759.401611s with no open attempt"
      refute t =~ @forbidden
    end

    test "open attempt without an established session, or an occurrence without a session: attached by order" do
      # Attempt paired later or never; the occurrence's session is not compared with anything.
      {inst, _} = fold([playing(1), objective(2, @novikov, session: @session_b)])
      assert attributions(inst) == [{2, %{attempt: 1, basis: :order, attempt_session: nil, occurrence_session: @session_b}}]

      # Attempt paired; the occurrence carries no session.
      {inst, _} = fold([started(1, @session_a), playing(2), objective(3, @novikov, session: nil)])
      assert attributions(inst) == [{3, %{attempt: 1, basis: :order, attempt_session: @session_a, occurrence_session: nil}}]
      assert view(inst).completed == 1 and inst.unattributed_objective_events == []
    end

    test "ambiguous pairing (two waiting sessions, none paired): the attempt has no established session, so order attaches" do
      {inst, notes} = fold([started(1, @session_a), started(2, @session_b), playing(3), objective(4, @novikov, session: @session_a)])
      assert Enum.any?(notes, &match?({:contract_pairing_ambiguous, 1, _}, &1))
      [a] = inst.attempts
      assert a.contract_session_id == nil and a.contract_candidates == [@session_a, @session_b]
      assert attributions(inst) == [{4, %{attempt: 1, basis: :order, attempt_session: nil, occurrence_session: @session_a}}]
    end

    test "matching session: attached with :order_session_match" do
      {inst, _} = fold([playing(1), started(2, @session_a), objective(3)])
      assert attributions(inst) == [{3, %{attempt: 1, basis: :order_session_match, attempt_session: @session_a, occurrence_session: @session_a}}]
    end

    test "contradicting session: vetoed, unattributed with the reason and an anomaly; neither attempt changed" do
      {inst, notes} =
        fold([started(1, @session_a), playing(2), objective(3), stopped(4), playing(5, @session_b), started(6, @session_b), objective(7, @novikov, session: @session_a), objective(8, @other, session: @session_b)])

      assert {:unattributed_objective_event, 7, {:session_contradiction, 2, @session_b, @session_a}} in notes
      [a1, a2] = inst.attempts
      assert Enum.map(a1.objective_events, & &1.sequence) == [3]
      assert Enum.map(a2.objective_events, & &1.sequence) == [8]

      assert [%{sequence: 7, attribution: %{attempt: nil, basis: :session_contradiction, attempt_session: @session_b, occurrence_session: @session_a}}] =
               inst.unattributed_objective_events

      assert [%{kind: :objective_session_contradiction, sequence: 7, open_attempt: 2, attempt_session: @session_b, occurrence_session: @session_a}] = inst.anomalies
      assert view(inst, 1).completed == 1 and view(inst, 2).completed == 1
      t = text(inst)
      assert t =~ "  objective kill/primary aca8cd5b… #7 @759.401611s with session 25161096… contradicting the open attempt's session 25161096…; not attached"
      assert t =~ "anomaly: objective event #7 named session #{@session_a} while attempt 2 was paired with #{@session_b}; kept unattributed, not attached to any attempt"
      refute t =~ @forbidden
    end

    test "the rise's game_session_id is not consulted: only the paired contract session can veto" do
      # The rise carries session B as its registry value, the attempt is paired with A, the
      # occurrence carries A: a match on the paired session, attached.
      {inst, _} = fold([started(1, @session_a), playing(2, @session_b), objective(3, @novikov, session: @session_a)])
      assert attributions(inst) == [{3, %{attempt: 1, basis: :order_session_match, attempt_session: @session_a, occurrence_session: @session_a}}]
      assert Enum.any?(inst.anomalies, &(&1.kind == :contract_session_id_mismatch))
    end

    test "decision fixed at receipt: an occurrence with session A attached while the attempt was unpaired stays attached after ContractStart pairs the attempt with B" do
      base = [playing(1, @session_b), objective(2, @novikov, session: @session_a)]
      {inst, _} = fold(base)
      assert attributions(inst) == [{2, %{attempt: 1, basis: :order, attempt_session: nil, occurrence_session: @session_a}}]
      before = view(inst)

      {inst, notes} = fold([started(3, @session_b)], inst)
      refute Enum.any?(notes, &match?({:unattributed_objective_event, _, _}, &1))
      [a] = inst.attempts
      assert a.contract_session_id == @session_b and a.contract_paired_by == :open_attempt
      # Not moved, not discarded, its recorded basis unchanged, no anomaly invented after the fact.
      assert attributions(inst) == [{2, %{attempt: 1, basis: :order, attempt_session: nil, occurrence_session: @session_a}}]
      assert inst.unattributed_objective_events == [] and inst.anomalies == []
      assert view(inst) == before

      # A further occurrence with session A is now vetoed; the earlier one still stands.
      {inst, _} = fold([objective(4, @novikov, session: @session_a)], inst)
      assert attributions(inst) == [{2, %{attempt: 1, basis: :order, attempt_session: nil, occurrence_session: @session_a}}]
      assert [%{sequence: 4, attribution: %{basis: :session_contradiction}}] = inst.unattributed_objective_events

      # Full ordered-stream replay reproduces the same decisions.
      {replayed, _} = fold(base ++ [started(3, @session_b), objective(4, @novikov, session: @session_a)])
      assert attributions(replayed) == attributions(inst)
      assert Enum.map(replayed.unattributed_objective_events, & &1.attribution) == Enum.map(inst.unattributed_objective_events, & &1.attribution)
      assert view(replayed) == view(inst) and from_facts(replayed) == view(inst)
    end

    test "a closed attempt's objective view is never changed by what arrives after its stop" do
      {inst, _} = fold([started(1, @session_a), playing(2), objective(3), stopped(4)])
      frozen = view(inst)
      frozen_attr = attributions(inst)

      extensions = [objective(5, @novikov, session: @session_a), playing(6, @session_b), started(7, @session_b), objective(8, @novikov, session: @session_a), objective(9, @other, session: @session_b), stopped(10)]

      Enum.reduce(extensions, inst, fn e, acc ->
        {acc, _} = fold([e], acc)
        assert view(acc, 1) == frozen and attributions(acc, 1) == frozen_attr
        acc
      end)
    end
  end

  describe "SYN: history (gaps, interruptions, supersession) and the shared bounding" do
    test "a gap inside the attempt marks the history incomplete; the count is what arrived" do
      {inst, notes} = fold([playing(1), objective(2), objective(5, @other)])
      assert {:gap, 3, 5} in notes
      d = view(inst)
      assert d.history == {:incomplete, [{:gap, 3, 5}]} and d.completed == 2
      assert objectives_line(inst) =~ "; history broken: gap 3→5"
      assert from_facts(inst) == d
    end

    test "an interruption inside the attempt; occurrences after the reconnect still count" do
      at = ~U[2026-10-09 06:05:00Z]
      inst = identified(Lifecycle.new(@id))
      {inst, _} = fold([playing(1), objective(2), {:close, at}, {:reopen, at}, objective(3, @other)], inst)
      d = view(inst)
      assert d.history == {:incomplete, [{:interruption, at, :peer_closed}]} and d.completed == 2
      assert from_facts(inst) == d
    end

    test "superseded attempts are bounded by the rise that superseded them (63184c4, for objectives)" do
      {inst, _} = fold([playing(1), objective(2), objective(3), playing(5), objective(6, @other), objective(9, @other)])
      assert inst.gaps == [{7, 9}, {4, 5}]
      [a1, _] = inst.attempts
      assert a1.mission == :superseded and a1.superseded_at == 5
      assert view(inst, 1).history == {:incomplete, [{:gap, 4, 5}, {:superseded, 2, 5}]} and view(inst, 1).completed == 2
      assert view(inst, 2).history == {:incomplete, [{:gap, 7, 9}]} and view(inst, 2).completed == 2
      assert AttemptHistory.gaps_in_attempt(inst.gaps, a1) == [{4, 5}]
      for n <- 1..2, do: assert(from_facts(inst, n) == view(inst, n))
      # The item view on the same attempt sees the same history through the shared helper.
      assert Items.derive(a1, inst).history == view(inst, 1).history
    end

    test "objective, item and actor facts interleave in one sequence and stay apart" do
      {inst, _} = fold([playing(1), pickup(2), died(3), objective(4), pickup(5)])
      [a] = inst.attempts
      assert Enum.map(a.objective_events, & &1.sequence) == [4]
      assert Enum.map(a.item_events, & &1.sequence) == [2, 5]
      assert Enum.map(a.outcomes, & &1.sequence) == [3]
    end
  end

  describe "replay equivalence" do
    test "the view is a function of the recorded facts on every stream; every prefix's facts are a prefix" do
      at = ~U[2026-10-09 06:05:00Z]

      streams = [
        [started(1, @session_a), playing(2), died(3), objective(4), stopped(5)],
        [objective(1), playing(2), objective(3), stopped(4), objective(5)],
        [playing(1, @session_b), objective(2, @novikov, session: @session_a), started(3, @session_b), objective(4, @novikov, session: @session_a), objective(5, @other, session: @session_b)],
        [started(1, @session_a), playing(2), objective(3), stopped(4), playing(5, @session_b), started(6, @session_b), objective(7, @novikov, session: @session_a)],
        [playing(1), objective(2), objective(5, @other), {:close, at}, {:reopen, at}, objective(6, @novikov, scoring: true)],
        [playing(1), objective(2), playing(5), objective(6, @other)],
        [playing(1), pickup(2), died(3)]
      ]

      for steps <- streams do
        inst = identified(Lifecycle.new(@id))
        {inst, _} = fold(steps, inst)
        for n <- 1..length(inst.attempts), do: assert(from_facts(inst, n) == view(inst, n))

        final = Enum.map(inst.attempts, & &1.objective_events)
        final_unattributed = inst.unattributed_objective_events

        for n <- 1..length(steps) do
          prefix = identified(Lifecycle.new(@id))
          {prefix, _} = fold(Enum.take(steps, n), prefix)

          for {attempt, i} <- Enum.with_index(prefix.attempts) do
            assert attempt.objective_events == Enum.take(Enum.at(final, i), length(attempt.objective_events))
          end

          assert prefix.unattributed_objective_events == Enum.take(final_unattributed, length(prefix.unattributed_objective_events))
        end
      end
    end
  end

  describe "summary wording" do
    test "the objective lines never say complete, completed, completion, accomplished, all objectives, N of M or remaining" do
      at = ~U[2026-10-09 06:05:00Z]
      inst = identified(Lifecycle.new(@id))

      {inst, _} =
        fold([started(1, @session_a), playing(2), died(3), objective(4), objective(5, @other, scoring: true, type: "setpiece", category: "secondary"), {:close, at}], inst)

      t = text(inst)
      lines = t |> String.split("\n") |> Enum.filter(&String.contains?(&1, "objective"))
      assert length(lines) >= 1
      for l <- lines, do: refute(l =~ @forbidden)
      assert objectives_line(inst) =~ "2 reported done — kill/primary aca8cd5b… #4 @759.401611s, setpiece/secondary 5f0d2c1e… #5 @759.401611s (not scored); history broken: observation lost"
      refute t =~ "objective.completed"
    end
  end
end

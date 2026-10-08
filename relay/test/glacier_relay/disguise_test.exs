defmodule GlacierRelay.DisguiseTest do
  @moduledoc """
  M2 B3: validation of disguise.equipped / disguise.compromised / disguise.compromise_cleared v1;
  the fold contract of design section 30.8 (facts, episodes, wearing intervals, the standing rule
  order, cuts from gap/interruption evidence); the SYN table of section 30.10; replay equivalence
  on ordinary and incomplete-history streams; and the summary wording.

  Evidence cases use the ids and order of the B0 session; SYN cases are synthetic and pin the
  model's conservative behaviour, not engine semantics.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.{Disguise, Events, Lifecycle, Summary}
  alias GlacierRelay.Lifecycle.Attempt
  alias GlacierRelay.Wire.Envelope

  @id "b3-test-instance"
  @suit "874c4c48-0a8b-49e9-883e-49fc5f1fb051"
  @outfit_a "2018db77-aa8a-4bf9-9afb-56bdaa161156"
  @outfit_b "992cc7b6-4ccf-4ae8-a467-e9b2aabaeeb5"
  @session_a "2516109628137904204-c00b2d17-08b1-4949-9f9d-5f68b691f40f"
  @paris "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"

  # -- stream builders -------------------------------------------------------------------------

  defp env(type, seq, payload) do
    %Envelope{
      protocol_version: 1,
      adapter_instance_id: @id,
      sequence: seq,
      timestamp: "2026-10-08T21:00:#{String.pad_leading(Integer.to_string(rem(seq, 60)), 2, "0")}.000Z",
      event_type: type,
      schema_version: 1,
      payload: payload
    }
  end

  defp playing(seq, session \\ @session_a),
    do: env("mission.playing", seq, %{scene_resource: @paris, scene_type: "mission", codename_hint: "Peacock", game_session_id: session})

  defp stopped(seq),
    do: env("mission.stopped", seq, %{scene_resource: @paris, scene_type: "mission", codename_hint: "Peacock", game_session_id: @session_a})

  defp started(seq, session \\ @session_a, suit \\ @suit),
    do:
      env("contract.started", seq, %{
        source: "engine_telemetry",
        engine_event: "ContractStart",
        contract_session_id: session,
        contract_id: "00000000-0000-0000-0000-000000000200",
        location_id: "LOCATION_PARIS",
        contract_type: "mission",
        difficulty_level: 2,
        starting_disguise_repository_id: suit,
        is_hitman_suit: true,
        engine_timestamp_s: 0
      })

  defp disguise_payload(kind, engine_event, id),
    do: %{source: "engine_telemetry", kind: kind, engine_event: engine_event, disguise_repository_id: id, contract_session_id: @session_a, engine_timestamp_s: seq_time(id)}

  defp seq_time(_id), do: 1.0

  defp initial(seq, id \\ @suit), do: env("disguise.equipped", seq, disguise_payload("initial", "StartingSuit", id))
  defp change(seq, id), do: env("disguise.equipped", seq, disguise_payload("change", "Disguise", id))
  defp comp(seq, id), do: env("disguise.compromised", seq, disguise_payload(nil, "DisguiseBlown", id))
  defp clear(seq, id), do: env("disguise.compromise_cleared", seq, disguise_payload(nil, "BrokenDisguiseCleared", id))

  defp died(seq),
    do:
      env("actor.died", seq, %{
        source: "engine_telemetry",
        repository_id: "5dc7ede5-bb9d-4f93-a892-cb7fb2791b19",
        actor_name: "Jacqueline Ducloitre",
        engine_actor_id: 195_054_661,
        actor_type: "civilian",
        actor_type_code: nil,
        is_target: false,
        death_type: "kill",
        death_type_code: nil,
        death_context: "murder",
        death_context_code: nil,
        accident: false,
        kill_class: "melee",
        method_broad: "unarmed",
        method_strict: "",
        damage_events: ["CoupDeGrace"],
        item_repository_id: nil,
        contract_session_id: @session_a,
        engine_timestamp_s: 393.78
      })

  # Steps are envelopes or {:close, at} / {:reopen, at}; the stream is folded in order.
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

  defp identified(instance), do: Lifecycle.connection_identified(instance, "127.0.0.1:1", ~U[2026-10-08 21:00:00Z], ~U[2026-10-08 21:00:00Z])

  defp view(instance, number \\ 1) do
    attempt = Enum.at(instance.attempts, number - 1)
    Disguise.derive(attempt, instance)
  end

  # The same view, rebuilt from the bare facts only: the occurrences, the instance's gaps and
  # the attempt's interruptions, on an otherwise empty attempt.
  defp from_facts(instance, number \\ 1) do
    attempt = Enum.at(instance.attempts, number - 1)

    bare = %Attempt{
      number: attempt.number,
      playing: attempt.playing,
      stopped: attempt.stopped,
      mission: attempt.mission,
      interruptions: attempt.interruptions,
      disguise_events: attempt.disguise_events,
      contract_session_id: attempt.contract_session_id
    }

    Disguise.derive(bare, %{Lifecycle.new(@id) | gaps: instance.gaps, contract_sessions: instance.contract_sessions})
  end

  defp text(instance), do: Summary.render(%{@id => instance})

  defp equipped(kind, id, extra \\ %{}) do
    Map.merge(
      %{
        "source" => "engine_telemetry",
        "kind" => kind,
        "engine_event" => if(kind == "initial", do: "StartingSuit", else: "Disguise"),
        "disguise_repository_id" => id,
        "contract_session_id" => @session_a,
        "engine_timestamp_s" => 202.104156
      },
      extra
    )
  end

  defp compromised(id) do
    %{
      "source" => "engine_telemetry",
      "engine_event" => "DisguiseBlown",
      "disguise_repository_id" => id,
      "contract_session_id" => @session_a,
      "engine_timestamp_s" => 222.863129
    }
  end

  describe "validation" do
    test "disguise.equipped v1 with kind initial and change" do
      assert {:ok, p} = Events.validate("disguise.equipped", 1, equipped("initial", @suit))
      assert p.kind == "initial" and p.engine_event == "StartingSuit"
      assert p.disguise_repository_id == @suit
      assert p.contract_session_id == @session_a
      assert p.engine_timestamp_s == 202.104156

      assert {:ok, p} = Events.validate("disguise.equipped", 1, equipped("change", @outfit_a))
      assert p.kind == "change" and p.engine_event == "Disguise"
    end

    test "kind is required and constrained on disguise.equipped" do
      assert {:error, {:missing_field, "kind"}} =
               Events.validate("disguise.equipped", 1, Map.delete(equipped("change", @outfit_a), "kind"))

      assert {:error, {:invalid_field, "kind"}} =
               Events.validate("disguise.equipped", 1, equipped("changed", @outfit_a))

      assert {:error, {:invalid_field, "kind"}} =
               Events.validate("disguise.equipped", 1, equipped("Disguise", @outfit_a))
    end

    test "disguise.compromised and disguise.compromise_cleared v1 carry no kind" do
      assert {:ok, p} = Events.validate("disguise.compromised", 1, compromised(@outfit_a))
      assert p.kind == nil and p.engine_event == "DisguiseBlown"
      assert p.disguise_repository_id == @outfit_a

      cleared = %{compromised(@outfit_a) | "engine_event" => "BrokenDisguiseCleared"}
      assert {:ok, p} = Events.validate("disguise.compromise_cleared", 1, cleared)
      assert p.kind == nil and p.engine_event == "BrokenDisguiseCleared"

      assert {:error, {:unexpected_field, "kind"}} =
               Events.validate("disguise.compromised", 1, Map.put(compromised(@outfit_a), "kind", "change"))
    end

    test "the id is the subject: required, non-empty, a string" do
      for type <- ["disguise.equipped", "disguise.compromised", "disguise.compromise_cleared"] do
        base = if type == "disguise.equipped", do: equipped("change", @outfit_a), else: compromised(@outfit_a)

        assert {:error, {:missing_field, "disguise_repository_id"}} =
                 Events.validate(type, 1, Map.delete(base, "disguise_repository_id"))

        assert {:error, {:invalid_field, "disguise_repository_id"}} =
                 Events.validate(type, 1, Map.put(base, "disguise_repository_id", ""))

        assert {:error, {:invalid_field, "disguise_repository_id"}} =
                 Events.validate(type, 1, Map.put(base, "disguise_repository_id", 7))
      end
    end

    test "provenance is optional; when present it must be typed" do
      bare = Map.drop(compromised(@outfit_a), ["contract_session_id", "engine_timestamp_s"])
      assert {:ok, p} = Events.validate("disguise.compromised", 1, bare)
      assert p.contract_session_id == nil and p.engine_timestamp_s == nil

      assert {:error, {:invalid_field, "engine_timestamp_s"}} =
               Events.validate("disguise.compromised", 1, Map.put(compromised(@outfit_a), "engine_timestamp_s", "x"))

      assert {:error, {:invalid_field, "contract_session_id"}} =
               Events.validate("disguise.compromised", 1, Map.put(compromised(@outfit_a), "contract_session_id", 1))

      assert {:error, {:missing_field, "engine_event"}} =
               Events.validate("disguise.compromised", 1, Map.delete(compromised(@outfit_a), "engine_event"))
    end

    test "unknown versions and unknown disguise names are rejected" do
      assert {:error, {:unsupported_schema_version, "disguise.equipped", 2}} =
               Events.validate("disguise.equipped", 2, equipped("change", @outfit_a))

      assert {:error, {:unknown_event_type, "disguise.changed"}} =
               Events.validate("disguise.changed", 1, equipped("change", @outfit_a))

      assert {:error, {:unknown_event_type, "disguise.blown"}} =
               Events.validate("disguise.blown", 1, compromised(@outfit_a))
    end

    test "classification helpers" do
      assert Events.disguise_event?("disguise.equipped")
      assert Events.disguise_event?("disguise.compromised")
      assert Events.disguise_event?("disguise.compromise_cleared")
      refute Events.disguise_event?("actor.died")
      refute Events.contract_event?("disguise.equipped")
      refute Events.actor_outcome?("disguise.equipped")
    end
  end

  # -- evidence: the B0 session ----------------------------------------------------------------

  describe "B0 session 1 (evidence order)" do
    # initial S; change A; compromised A; cleared A; change B; compromised B; cleared B — the
    # regression case for rule 3 is the session itself: after the change to B the standing is
    # unknown although A's compromise had been cleared.
    test "facts, episodes, intervals and the standing after each step" do
      steps = [
        started(1), playing(2), initial(3), change(4, @outfit_a), comp(5, @outfit_a), died(6),
        clear(7, @outfit_a), change(8, @outfit_b), comp(9, @outfit_b), clear(10, @outfit_b), stopped(11)
      ]

      standings =
        for n <- 3..10 do
          {inst, _} = fold(Enum.take(steps, n))
          view(inst).worn_standing
        end

      assert standings == [:not_observed, :not_observed, :compromised, :compromised, :cleared, :unknown, :compromised, :cleared]

      {inst, notes} = fold(steps)
      refute Enum.any?(notes, &match?({:unattributed_disguise_event, _}, &1))
      d = view(inst)

      assert d.initial == %{repository_id: @suit, sequence: 3}
      assert d.worn == %{repository_id: @outfit_b, since_sequence: 8, kind: :change}
      assert d.worn_standing == :cleared and d.standing_cut == nil

      assert d.compromise_episodes == [
               %{repository_id: @outfit_a, compromised_sequences: [5], cleared_sequence: 7},
               %{repository_id: @outfit_b, compromised_sequences: [9], cleared_sequence: 10}
             ]

      assert d.used == [@suit, @outfit_a, @outfit_b] and d.changes == 2
      assert d.history == :complete and d.notes == [] and d.anomalies == []
      assert d.occurrences == 7
      assert length(hd(inst.attempts).disguise_events) == 7
      assert Enum.map(hd(inst.attempts).disguise_events, & &1.sequence) == [3, 4, 5, 7, 8, 9, 10]
      assert Enum.map(hd(inst.attempts).outcomes, & &1.sequence) == [6]

      # The step after cleared A, before compromised B: unknown, with the earlier episode visible.
      {inst8, _} = fold(Enum.take(steps, 8))
      assert view(inst8).worn_standing == :unknown
      t = text(inst8)
      assert t =~ "worn 992cc7b6… since #8"
      assert t =~ "worn outfit: unknown (compromise observed earlier in this attempt: 2018db77… #5 cleared #7; not evidenced for this wear)"

      t = text(inst)
      assert t =~ "disguises (engine telemetry): contract.started says 874c4c48… (hitman suit); initial 874c4c48… #3 @1.0s; change → 2018db77… #4 @1.0s; compromised 2018db77… #5 @1.0s; cleared 2018db77… #7 @1.0s; change → 992cc7b6… #8 @1.0s; compromised 992cc7b6… #9 @1.0s; cleared 992cc7b6… #10 @1.0s"
      assert t =~ "disguise state (BEAM-derived): worn 992cc7b6… since #8; worn outfit: cleared; 2 changes, 3 definitions used; history intact"
      assert from_facts(inst) == d
    end

    test "the initial equals the paired session's starting suit; a differing one is an anomaly" do
      {inst, _} = fold([started(1), playing(2), initial(3)])
      assert view(inst).anomalies == []
      assert text(inst) =~ "worn 874c4c48… (equals the starting suit id) since #3"

      {inst, _} = fold([started(1), playing(2), initial(3, @outfit_a)])
      assert view(inst).anomalies == [{:initial_differs_from_contract, 3, @outfit_a, @suit}]
      refute text(inst) =~ "equals the starting suit id"

      # No paired session: nothing to compare against, no anomaly.
      {inst, _} = fold([playing(1), initial(2, @outfit_a)])
      assert view(inst).anomalies == []
    end
  end

  # -- SYN: the conservative decisions of 30.8/30.10 --------------------------------------------

  describe "SYN: change invalidates the previous interval" do
    test "A → compromised A → cleared A → B leaves B unknown (rule 3)" do
      {inst, _} = fold([playing(1), initial(2), change(3, @outfit_a), comp(4, @outfit_a), clear(5, @outfit_a), change(6, @outfit_b)])
      d = view(inst)
      assert d.worn == %{repository_id: @outfit_b, since_sequence: 6, kind: :change}
      assert d.worn_standing == :unknown and d.standing_cut == nil
      assert d.compromise_episodes == [%{repository_id: @outfit_a, compromised_sequences: [4], cleared_sequence: 5}]
      assert text(inst) =~ "worn outfit: unknown (compromise observed earlier in this attempt: 2018db77… #4 cleared #5; not evidenced for this wear)"
      assert from_facts(inst) == d
    end

    test "A → compromised A → B → A: re-equipping says nothing until the engine does" do
      base = [playing(1), initial(2), change(3, @outfit_a), comp(4, @outfit_a), change(5, @outfit_b)]
      {inst, _} = fold(base)
      assert view(inst).worn_standing == :unknown
      assert text(inst) =~ "2018db77… #4 episode open; not evidenced for this wear"

      {inst, _} = fold(base ++ [change(6, @outfit_a)])
      d = view(inst)
      assert d.worn == %{repository_id: @outfit_a, since_sequence: 6, kind: :change}
      assert d.worn_standing == :unknown
      assert d.compromise_episodes == [%{repository_id: @outfit_a, compromised_sequences: [4], cleared_sequence: nil}]

      {inst, _} = fold(base ++ [change(6, @outfit_a), comp(7, @outfit_a)])
      d = view(inst)
      assert d.worn_standing == :compromised
      assert d.compromise_episodes == [%{repository_id: @outfit_a, compromised_sequences: [4, 7], cleared_sequence: nil}]
      assert d.notes == [{:compromised_restated, @outfit_a, 7}]

      {inst, _} = fold(base ++ [change(6, @outfit_a), comp(7, @outfit_a), clear(8, @outfit_a)])
      d = view(inst)
      assert d.worn_standing == :cleared
      assert d.compromise_episodes == [%{repository_id: @outfit_a, compromised_sequences: [4, 7], cleared_sequence: 8}]
      assert d.anomalies == []
      assert from_facts(inst) == d
    end

    test "a clear naming another outfit than the worn one yields unknown (rule 2)" do
      {inst, _} = fold([playing(1), change(2, @outfit_a), comp(3, @outfit_a), change(4, @outfit_b), clear(5, @outfit_a)])
      d = view(inst)
      assert d.worn.repository_id == @outfit_b and d.worn_standing == :unknown
      assert d.compromise_episodes == [%{repository_id: @outfit_a, compromised_sequences: [3], cleared_sequence: 5}]
      assert text(inst) =~ "worn outfit: unknown (the latest statement in this wear names another outfit)"
    end
  end

  describe "SYN: episodes" do
    test "repeated compromises before one clear: one episode, every occurrence kept" do
      {inst, _} = fold([playing(1), change(2, @outfit_a), comp(3, @outfit_a), comp(4, @outfit_a), comp(5, @outfit_a), clear(6, @outfit_a)])
      d = view(inst)
      assert d.compromise_episodes == [%{repository_id: @outfit_a, compromised_sequences: [3, 4, 5], cleared_sequence: 6}]
      assert d.notes == [{:compromised_restated, @outfit_a, 4}, {:compromised_restated, @outfit_a, 5}]
      assert d.worn_standing == :cleared and d.anomalies == []
      assert Enum.map(hd(inst.attempts).disguise_events, &{&1.type, &1.sequence}) ==
               [{:equipped, 2}, {:compromised, 3}, {:compromised, 4}, {:compromised, 5}, {:compromise_cleared, 6}]
    end

    test "repeated compromise/clear cycles: one closed episode per cycle" do
      steps = [playing(1), change(2, @outfit_a), comp(3, @outfit_a), clear(4, @outfit_a), comp(5, @outfit_a), clear(6, @outfit_a)]
      {inst, _} = fold(steps)
      d = view(inst)
      assert d.compromise_episodes == [
               %{repository_id: @outfit_a, compromised_sequences: [3], cleared_sequence: 4},
               %{repository_id: @outfit_a, compromised_sequences: [5], cleared_sequence: 6}
             ]
      assert d.worn_standing == :cleared and d.notes == [] and d.anomalies == []

      {inst, _} = fold(steps ++ [comp(7, @outfit_a)])
      d = view(inst)
      assert d.worn_standing == :compromised
      assert List.last(d.compromise_episodes) == %{repository_id: @outfit_a, compromised_sequences: [7], cleared_sequence: nil}
    end

    test "a clear with no open episode is an anomaly and creates no episode; standing follows the interval rule" do
      {inst, _} = fold([playing(1), change(2, @outfit_a), clear(3, @outfit_a)])
      d = view(inst)
      assert d.compromise_episodes == []
      assert d.anomalies == [{:cleared_without_compromise, @outfit_a, 3}]
      assert d.worn_standing == :cleared
      assert Enum.map(hd(inst.attempts).disguise_events, & &1.type) == [:equipped, :compromise_cleared]

      {inst, _} = fold([playing(1), change(2, @outfit_a), clear(3, @outfit_b)])
      assert view(inst).worn_standing == :unknown
    end

    test "a compromise with no worn outfit: episode kept, standing has no interval to speak of" do
      {inst, _} = fold([playing(1), comp(2, @outfit_a)])
      d = view(inst)
      assert d.worn == :not_observed and d.worn_standing == :not_observed
      assert d.compromise_episodes == [%{repository_id: @outfit_a, compromised_sequences: [2], cleared_sequence: nil}]
      assert d.notes == [{:compromised_not_worn, @outfit_a, 2}]
      assert text(inst) =~ "worn: not observed; worn outfit: not observed"

      {inst, _} = fold([playing(1), comp(2, @outfit_a), change(3, @outfit_a)])
      assert view(inst).worn_standing == :unknown
    end
  end

  describe "SYN: initial assertion" do
    test "a change with no initial" do
      {inst, _} = fold([playing(1), change(2, @outfit_a)])
      d = view(inst)
      assert d.initial == :not_observed and d.worn.repository_id == @outfit_a and d.worn_standing == :not_observed
      assert d.used == [@outfit_a] and d.changes == 1
    end

    test "an initial after a change is an anomaly and does not touch worn" do
      {inst, _} = fold([playing(1), change(2, @outfit_a), initial(3)])
      d = view(inst)
      assert d.initial == :not_observed and d.worn == %{repository_id: @outfit_a, since_sequence: 2, kind: :change}
      assert d.anomalies == [{:initial_after_change, 3, @suit}]
      assert d.used == [@outfit_a, @suit]
    end

    test "a second initial before any change is a restatement; a different id a conflict" do
      {inst, _} = fold([playing(1), initial(2), initial(3)])
      d = view(inst)
      assert d.initial == %{repository_id: @suit, sequence: 2} and d.worn.since_sequence == 2
      assert d.notes == [{:initial_restated, 3}] and d.anomalies == []

      {inst, _} = fold([playing(1), initial(2), initial(3, @outfit_a)])
      d = view(inst)
      assert d.worn.repository_id == @suit
      assert d.anomalies == [{:initial_conflict, 3, @outfit_a, @suit}]
    end

    test "an attempt with no disguise event at all" do
      {inst, _} = fold([started(1), playing(2), died(3)])
      d = view(inst)
      assert d == %{
               initial: :not_observed, worn: :not_observed, compromise_episodes: [], worn_standing: :not_observed,
               standing_reason: nil, standing_cut: nil, used: [], changes: 0, history: :complete, notes: [], anomalies: [], occurrences: 0
             }
      assert text(inst) =~ "disguises (engine telemetry): contract.started says 874c4c48… (hitman suit); none observed in the attempt"
      assert text(inst) =~ "disguise state (BEAM-derived): worn: not observed; worn outfit: not observed; 0 changes, 0 definitions used; history intact"
    end
  end

  describe "SYN: gaps and interruptions (incomplete history)" do
    test "a gap inside the wear makes the standing unknown and shows what it was before" do
      {inst, notes} = fold([playing(1), initial(2), change(3, @outfit_a), comp(4, @outfit_a), died(7)])
      assert {:gap, 5, 7} in notes
      d = view(inst)
      assert d.history == {:incomplete, [{:gap, 5, 7}]}
      assert d.worn == %{repository_id: @outfit_a, since_sequence: 3, kind: :change}
      assert d.worn_standing == :unknown
      assert d.standing_cut == %{cut: {:gap, 5, 7}, standing_before: :compromised}
      t = text(inst)
      assert t =~ "worn outfit: unknown (gap 5→7 inside this wear; before it: compromised)"
      assert t =~ "history broken: gap 5→7"
      assert from_facts(inst) == d
    end

    test "a gap before the wear does not make a fresh equipped unreliable" do
      {inst, _} = fold([playing(1), died(4), change(5, @outfit_a)])
      d = view(inst)
      assert d.history == {:incomplete, [{:gap, 2, 4}]}
      assert d.worn.since_sequence == 5 and d.worn_standing == :not_observed and d.standing_cut == nil
      assert from_facts(inst) == d
    end

    test "a stale worn id cannot be re-established by a later clear or compromise naming it (rule 1)" do
      {inst, _} = fold([playing(1), change(2, @outfit_a), comp(3, @outfit_a), clear(6, @outfit_a)])
      d = view(inst)
      assert d.compromise_episodes == [%{repository_id: @outfit_a, compromised_sequences: [3], cleared_sequence: 6}]
      assert d.worn_standing == :unknown
      assert d.standing_cut == %{cut: {:gap, 4, 6}, standing_before: :compromised}
      assert from_facts(inst) == d

      {inst, _} = fold([playing(1), change(2, @outfit_a), comp(5, @outfit_a)])
      d = view(inst)
      assert d.worn_standing == :unknown
      assert d.standing_cut == %{cut: {:gap, 3, 5}, standing_before: :not_observed}
      assert from_facts(inst) == d
    end

    test "a new equipped after the gap starts a reliable interval; rule 3 then applies" do
      {inst, _} = fold([playing(1), change(2, @outfit_a), comp(3, @outfit_a), change(6, @outfit_a)])
      d = view(inst)
      assert d.worn.since_sequence == 6 and d.standing_cut == nil and d.worn_standing == :unknown
      {inst, _} = fold([playing(1), change(2, @outfit_a), comp(3, @outfit_a), change(6, @outfit_a), comp(7, @outfit_a)])
      assert view(inst).worn_standing == :compromised
    end

    test "an interruption inside the wear is a cut; a clear after the reconnect does not restore standing" do
      at = ~U[2026-10-08 21:05:00Z]
      inst = identified(Lifecycle.new(@id))
      {inst, _} = fold([playing(1), change(2, @outfit_a), comp(3, @outfit_a), {:close, at}, {:reopen, at}, clear(4, @outfit_a)], inst)
      d = view(inst)
      assert d.history == {:incomplete, [{:interruption, at, :peer_closed}]}
      assert hd(inst.attempts).interruptions == [%{at: at, reason: :peer_closed, after_sequence: 3}]
      assert d.compromise_episodes == [%{repository_id: @outfit_a, compromised_sequences: [3], cleared_sequence: 4}]
      assert d.worn_standing == :unknown
      assert d.standing_cut == %{cut: {:interruption, at, :peer_closed}, standing_before: :compromised}
      assert text(inst) =~ "worn outfit: unknown (observation lost 2026-10-08T21:05:00Z (:peer_closed) inside this wear; before it: compromised)"
      assert from_facts(inst) == d

      # A change after the reconnect starts a reliable interval again.
      {inst, _} = fold([change(5, @outfit_b)], inst)
      d = view(inst)
      assert d.worn.since_sequence == 5 and d.standing_cut == nil and d.worn_standing == :unknown
      assert from_facts(inst) == d
    end

    test "an interruption before the wear is attempt-level history only" do
      at = ~U[2026-10-08 21:05:00Z]
      inst = identified(Lifecycle.new(@id))
      {inst, _} = fold([playing(1), {:close, at}, {:reopen, at}, change(2, @outfit_a), comp(3, @outfit_a)], inst)
      d = view(inst)
      assert d.history == {:incomplete, [{:interruption, at, :peer_closed}]}
      assert d.worn_standing == :compromised and d.standing_cut == nil
      assert from_facts(inst) == d
    end

    test "TCP close with no reconnect: facts frozen, standing unknown with the pre-cut standing shown" do
      at = ~U[2026-10-08 21:09:00Z]
      inst = identified(Lifecycle.new(@id))
      {inst, _} = fold([playing(1), initial(2), change(3, @outfit_a), comp(4, @outfit_a), {:close, at}], inst)
      d = view(inst)
      assert Lifecycle.observation(inst) == :lost
      assert d.worn_standing == :unknown
      assert d.standing_cut == %{cut: {:interruption, at, :peer_closed}, standing_before: :compromised}
      assert d.compromise_episodes == [%{repository_id: @outfit_a, compromised_sequences: [4], cleared_sequence: nil}]
      t = text(inst)
      assert t =~ "stop not observed; last known playing"
      assert t =~ "worn 2018db77… since #3; worn outfit: unknown (observation lost 2026-10-08T21:09:00Z (:peer_closed) inside this wear; before it: compromised)"
      assert from_facts(inst) == d
    end

    test "a superseded attempt reports it in its history" do
      {inst, _} = fold([playing(1), change(2, @outfit_a), playing(3)])
      assert view(inst, 1).history == {:incomplete, [:superseded]}
      assert view(inst, 2).history == :complete
    end
  end

  describe "SYN: attempt boundaries" do
    test "disguise events after the stop with no attempt open are unattributed, never attached by adjacency" do
      {inst, notes} = fold([playing(1), change(2, @outfit_a), stopped(3), comp(4, @outfit_a)])
      assert {:unattributed_disguise_event, 4} in notes
      assert Enum.map(inst.unattributed_disguise_events, & &1.sequence) == [4]
      assert Enum.map(hd(inst.attempts).disguise_events, & &1.sequence) == [2]
      assert view(inst).worn_standing == :not_observed and view(inst).anomalies == []
      assert text(inst) =~ "disguise compromised 2018db77… #4 @1.0s with no open attempt"

      {inst, notes} = fold([change(1, @outfit_a)])
      assert notes == [{:unattributed_disguise_event, 1}] and inst.attempts == []
    end

    test "an equipped right before the stop is attached; a restart starts the new attempt from nothing" do
      {inst, _} = fold([playing(1), change(2, @outfit_a), comp(3, @outfit_a), change(4, @outfit_b), stopped(5), playing(6)])
      assert Enum.map(hd(inst.attempts).disguise_events, & &1.sequence) == [2, 3, 4]
      assert view(inst, 1).worn.repository_id == @outfit_b and view(inst, 1).worn_standing == :unknown
      assert view(inst, 2) == %{
               initial: :not_observed, worn: :not_observed, compromise_episodes: [], worn_standing: :not_observed,
               standing_reason: nil, standing_cut: nil, used: [], changes: 0, history: :complete, notes: [], anomalies: [], occurrences: 0
             }
    end
  end

  describe "replay equivalence" do
    test "the view is a function of the facts on every stream, including the incomplete ones" do
      at = ~U[2026-10-08 21:05:00Z]

      streams = [
        [started(1), playing(2), initial(3), change(4, @outfit_a), comp(5, @outfit_a), died(6), clear(7, @outfit_a), change(8, @outfit_b), comp(9, @outfit_b), clear(10, @outfit_b), stopped(11)],
        [playing(1), initial(2), change(3, @outfit_a), comp(4, @outfit_a), died(7)],
        [playing(1), change(2, @outfit_a), comp(3, @outfit_a), {:close, at}, {:reopen, at}, clear(4, @outfit_a), change(5, @outfit_b)],
        [playing(1), comp(2, @outfit_a), change(3, @outfit_a), comp(4, @outfit_a), comp(5, @outfit_a), clear(6, @outfit_a), {:close, at}],
        [playing(1), initial(2), initial(3, @outfit_a), change(4, @outfit_b), initial(5), clear(6, @outfit_b)],
        [started(1), playing(2), initial(3, @outfit_a), stopped(4), comp(5, @outfit_a)]
      ]

      for steps <- streams do
        inst = identified(Lifecycle.new(@id))
        {inst, _} = fold(steps, inst)
        assert from_facts(inst) == view(inst)

        # Every prefix: the facts folded so far are a prefix of the final facts, and the view of
        # the final stream never contradicts the occurrences a prefix already holds.
        final = hd(inst.attempts).disguise_events

        for n <- 1..length(steps) do
          prefix = identified(Lifecycle.new(@id))
          {prefix, _} = fold(Enum.take(steps, n), prefix)

          case prefix.attempts do
            [] -> :ok
            [attempt | _] -> assert attempt.disguise_events == Enum.take(final, length(attempt.disguise_events))
          end
        end
      end
    end
  end

  describe "summary wording" do
    test "never clean, undetected, safe or Silent Assassin; suit only as the labelled id equality" do
      at = ~U[2026-10-08 21:05:00Z]
      inst = identified(Lifecycle.new(@id))

      {inst, _} =
        fold([started(1), playing(2), initial(3), change(4, @outfit_a), comp(5, @outfit_a), clear(6, @outfit_a), change(7, @outfit_b), {:close, at}], inst)

      t = text(inst)
      refute t =~ ~r/clean|undetected|safe|silent assassin|complet/i
      assert t =~ "worn 874c4c48… (equals the starting suit id) since #3" == false
      assert t =~ "worn 992cc7b6… since #7"
      refute t =~ "992cc7b6… (equals"
      assert t =~ "worn outfit: unknown (observation lost"
    end
  end
end

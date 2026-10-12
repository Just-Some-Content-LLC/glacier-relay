defmodule GlacierRelay.PlayerStateTest do
  @moduledoc """
  M2 B6: validation of player.trespassing v1 and player.illegal_weapon v1; attachment by stream
  order; the pure per-subject fold (design section 46.6: last observed with its position, the
  occurrence and observed-value-change counts, a standing that is `:not_observed` with no
  occurrence — never `false` — and `:unknown` after a cut that follows the last occurrence);
  history bounded by the shared `AttemptHistory`; replay equivalence from the bare facts; the
  summary wording; and the accepted vocabulary's lines unchanged beside the new one.

  Evidence case: the six B0 occurrences (two Trespassing, four HoldingIllegalWeapon). SYN cases are
  synthetic and pin the model's conservative behaviour, not engine semantics. Every external fact a
  case depends on — gaps, interruptions, supersession, the stop — is supplied explicitly by the
  stream. Fixture tests exercise BEAM's validation and derivation only: they establish nothing
  about the Glacier runtime's field types or the native intake.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.{AttemptHistory, Events, Items, Lifecycle, Objectives, PlayerState, Summary}
  alias GlacierRelay.Lifecycle.Attempt
  alias GlacierRelay.Wire.Envelope

  @id "b6-test-instance"
  @session_a "2516109628137904204-c00b2d17-08b1-4949-9f9d-5f68b691f40f"
  @session_b "2516109618691980006-9666b5ad-6a4f-44bb-b5fb-ff86bb3a8d76"
  @paris "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"
  @pistol "e70adb5b-0646-4f88-bd4a-85bea7a2a654"
  @pistol_instance "9a3f1dbb-a8b9-407a-8a7f-cdce8ddf1955"
  @suit "874c4c48-0a8b-49e9-883e-49fc5f1fb051"

  # -- stream builders -------------------------------------------------------------------------

  defp env(type, seq, payload) do
    %Envelope{
      protocol_version: 1,
      adapter_instance_id: @id,
      sequence: seq,
      timestamp: "2026-10-12T20:00:#{String.pad_leading(Integer.to_string(rem(seq, 60)), 2, "0")}.000Z",
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

  # The B0 weapon object as the native normalizer publishes it.
  defp pistol do
    %{
      item_repository_id: @pistol,
      item_instance_id: @pistol_instance,
      item_name: "ICA19 Silverballer",
      item_type: "Gun_HardBaller_01",
      online_traits: ["pistol"],
      perceived_as_weapon: true
    }
  end

  defp trespass(seq, value, opts \\ []),
    do:
      env("player.trespassing", seq, %{
        source: "engine_telemetry",
        engine_event: "Trespassing",
        trespassing: value,
        room_id: Keyword.get(opts, :room, 6),
        contract_session_id: Keyword.get(opts, :session, @session_a),
        engine_timestamp_s: Keyword.get(opts, :t, 166.198425)
      })

  defp weapon(seq, value, opts \\ []),
    do:
      env("player.illegal_weapon", seq, %{
        source: "engine_telemetry",
        engine_event: "HoldingIllegalWeapon",
        holding: value,
        weapon: Keyword.get(opts, :weapon, if(value, do: pistol(), else: nil)),
        contract_session_id: Keyword.get(opts, :session, @session_a),
        engine_timestamp_s: Keyword.get(opts, :t, 476.573425)
      })

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

  defp objective(seq),
    do:
      env("objective.completed", seq, %{
        source: "engine_telemetry",
        engine_event: "ObjectiveCompleted",
        objective_id: "aca8cd5b-e3a3-4a60-b953-c590484f0491",
        objective_type: "kill",
        objective_category: "primary",
        exclude_from_scoring: false,
        contract_session_id: @session_a,
        engine_timestamp_s: 759.401611
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
        item_repository_id: @pistol,
        contract_session_id: @session_a,
        engine_timestamp_s: 759.388428
      })

  defp equipped(seq, id, kind),
    do:
      env("disguise.equipped", seq, %{
        source: "engine_telemetry",
        kind: kind,
        engine_event: if(kind == "initial", do: "StartingSuit", else: "Disguise"),
        disguise_repository_id: id,
        contract_session_id: @session_a,
        engine_timestamp_s: 13.011781
      })

  # The six B0 occurrences in emission order, with the recorded values and timestamps.
  defp b0(seqs) do
    [a, b, c, d, e, f] = seqs

    [
      trespass(a, true, room: 6, t: 166.198425),
      trespass(b, false, room: 3, t: 202.179184),
      weapon(c, true, t: 476.573425),
      weapon(d, false, t: 477.59137),
      weapon(e, true, t: 485.492706),
      weapon(f, false, t: 491.880981)
    ]
  end

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
    do: Lifecycle.connection_identified(instance, "127.0.0.1:1", ~U[2026-10-12 20:00:00Z], ~U[2026-10-12 20:00:00Z])

  defp view(instance, number \\ 1) do
    attempt = Enum.at(instance.attempts, number - 1)
    PlayerState.derive(attempt, instance)
  end

  # The same view from the bare facts: the occurrences, the instance's gaps, the attempt's
  # interruptions and supersession — nothing else (no pairing, no other family).
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
      player_state_events: attempt.player_state_events
    }

    PlayerState.derive(bare, %{Lifecycle.new(@id) | gaps: instance.gaps})
  end

  defp text(instance), do: Summary.render(%{@id => instance})

  defp line(instance, marker, n \\ 0) do
    text(instance) |> String.split("\n") |> Enum.filter(&String.contains?(&1, marker)) |> Enum.at(n)
  end

  defp player_line(instance, n \\ 0), do: line(instance, "player state (engine telemetry)", n)

  defp wire_trespass(extra \\ %{}) do
    Map.merge(
      %{"source" => "engine_telemetry", "engine_event" => "Trespassing", "trespassing" => true, "room_id" => 6, "contract_session_id" => @session_a, "engine_timestamp_s" => 166.198425},
      extra
    )
  end

  defp wire_weapon_object do
    %{
      "item_repository_id" => @pistol,
      "item_instance_id" => @pistol_instance,
      "item_name" => "ICA19 Silverballer",
      "item_type" => "Gun_HardBaller_01",
      "online_traits" => ["pistol"],
      "perceived_as_weapon" => true
    }
  end

  defp wire_weapon(extra \\ %{}) do
    Map.merge(
      %{"source" => "engine_telemetry", "engine_event" => "HoldingIllegalWeapon", "holding" => true, "weapon" => wire_weapon_object(), "contract_session_id" => @session_a, "engine_timestamp_s" => 476.573425},
      extra
    )
  end

  # Every family's reserved words, checked over the whole summary (the actor lines legitimately
  # say "died" about an actor, so the player-only words are checked on the player-state lines).
  @forbidden ~r/complet|accomplish|all objectives|\bof \d+\b|remaining|clean|undetected|safe|silent assassin|inventory contents|holding|carried|owns|recovered|throws/i
  # No present-tense or outcome claim about the player on its own lines.
  @player_claims ~r/\bis trespassing|\barmed|unarmed|\bdead\b|\balive\b|\bdied\b|currently|\bnow\b|\bsafe\b|detected/i

  defp player_lines(instance),
    do: text(instance) |> String.split("\n") |> Enum.filter(&String.contains?(&1, "player state"))

  defp assert_conservative(instance) do
    refute text(instance) =~ @forbidden
    for l <- player_lines(instance), do: refute(l =~ @player_claims)
    assert player_lines(instance) != []
  end

  describe "validation" do
    test "player.trespassing v1 with the B0 shape; false is a value" do
      assert {:ok, p} = Events.validate("player.trespassing", 1, wire_trespass())
      assert p.trespassing == true and p.room_id == 6 and p.engine_event == "Trespassing"
      assert p.contract_session_id == @session_a and p.engine_timestamp_s == 166.198425

      assert {:ok, %{trespassing: false, room_id: 3}} = Events.validate("player.trespassing", 1, wire_trespass(%{"trespassing" => false, "room_id" => 3}))
      assert {:ok, %{room_id: 6.5}} = Events.validate("player.trespassing", 1, wire_trespass(%{"room_id" => 6.5}))
      assert {:ok, %{room_id: nil, contract_session_id: nil, engine_timestamp_s: nil}} =
               Events.validate("player.trespassing", 1, Map.drop(wire_trespass(), ["room_id", "contract_session_id", "engine_timestamp_s"]))
    end

    test "the trespassing boolean is the subject: required and a boolean; room_id present must be a number" do
      assert {:error, {:missing_field, "trespassing"}} = Events.validate("player.trespassing", 1, Map.delete(wire_trespass(), "trespassing"))

      for bad <- ["true", 1, nil, %{}] do
        assert {:error, {:invalid_field, "trespassing"}} = Events.validate("player.trespassing", 1, wire_trespass(%{"trespassing" => bad}))
      end

      for bad <- ["6", nil, true, %{"id" => 6}, [6]] do
        assert {:error, {:invalid_field, "room_id"}} = Events.validate("player.trespassing", 1, wire_trespass(%{"room_id" => bad}))
      end

      assert {:error, {:invalid_field, "engine_timestamp_s"}} = Events.validate("player.trespassing", 1, wire_trespass(%{"engine_timestamp_s" => "x"}))
      assert {:error, {:missing_field, "engine_event"}} = Events.validate("player.trespassing", 1, Map.delete(wire_trespass(), "engine_event"))
    end

    test "player.illegal_weapon v1 with the B0 true form (weapon object) and false form (no weapon)" do
      assert {:ok, p} = Events.validate("player.illegal_weapon", 1, wire_weapon())
      assert p.holding == true and p.engine_event == "HoldingIllegalWeapon"
      assert p.weapon == pistol()
      assert p.contract_session_id == @session_a and p.engine_timestamp_s == 476.573425

      assert {:ok, %{holding: false, weapon: nil}} = Events.validate("player.illegal_weapon", 1, wire_weapon(%{"holding" => false}) |> Map.delete("weapon"))
    end

    test "a true without a weapon and a false with a well-typed weapon are both valid, carried as sent" do
      assert {:ok, %{holding: true, weapon: nil}} = Events.validate("player.illegal_weapon", 1, Map.delete(wire_weapon(), "weapon"))
      assert {:ok, %{holding: false, weapon: w}} = Events.validate("player.illegal_weapon", 1, wire_weapon(%{"holding" => false}))
      assert w == pistol()
    end

    test "the weapon object follows the item rules: definition id required; instance id present must be non-empty; typed optionals" do
      minimal = wire_weapon(%{"weapon" => %{"item_repository_id" => "x"}})
      assert {:ok, %{weapon: %{item_repository_id: "x", item_instance_id: nil, item_name: nil, item_type: nil, online_traits: nil, perceived_as_weapon: nil}}} =
               Events.validate("player.illegal_weapon", 1, minimal)

      assert {:ok, %{weapon: %{perceived_as_weapon: false}}} =
               Events.validate("player.illegal_weapon", 1, wire_weapon(%{"weapon" => Map.put(wire_weapon_object(), "perceived_as_weapon", false)}))

      assert {:ok, %{weapon: %{item_name: ""}}} =
               Events.validate("player.illegal_weapon", 1, wire_weapon(%{"weapon" => Map.put(wire_weapon_object(), "item_name", "")}))

      assert {:error, {:missing_field, "weapon.item_repository_id"}} =
               Events.validate("player.illegal_weapon", 1, wire_weapon(%{"weapon" => Map.delete(wire_weapon_object(), "item_repository_id")}))

      for {key, bad} <- [
            {"item_repository_id", ""},
            {"item_repository_id", 7},
            {"item_instance_id", ""},
            {"item_instance_id", nil},
            {"item_name", 1},
            {"item_type", ["Gun"]},
            {"online_traits", "pistol"},
            {"online_traits", ["pistol", 7]},
            {"perceived_as_weapon", "true"},
            {"perceived_as_weapon", 1}
          ] do
        nested = "weapon." <> key
        assert {:error, {:invalid_field, ^nested}} = Events.validate("player.illegal_weapon", 1, wire_weapon(%{"weapon" => Map.put(wire_weapon_object(), key, bad)}))
      end

      for bad <- ["e70adb5b", ["x"], 7, nil, true] do
        assert {:error, {:invalid_field, "weapon"}} = Events.validate("player.illegal_weapon", 1, wire_weapon(%{"weapon" => bad}))
      end
    end

    test "the holding boolean is the subject: required and a boolean" do
      assert {:error, {:missing_field, "holding"}} = Events.validate("player.illegal_weapon", 1, Map.delete(wire_weapon(), "holding"))

      for bad <- ["true", 1, nil, %{}] do
        assert {:error, {:invalid_field, "holding"}} = Events.validate("player.illegal_weapon", 1, wire_weapon(%{"holding" => bad}))
      end
    end

    test "unknown versions and names are rejected; classification" do
      assert {:error, {:unsupported_schema_version, "player.trespassing", 2}} = Events.validate("player.trespassing", 2, wire_trespass())
      assert {:error, {:unsupported_schema_version, "player.illegal_weapon", 2}} = Events.validate("player.illegal_weapon", 2, wire_weapon())

      for name <- ["player.health", "player.died", "player.dead", "player.state", "player.trespass", "player.weapon", "hero.health"] do
        assert {:error, {:unknown_event_type, ^name}} = Events.validate(name, 1, wire_trespass())
      end

      assert Events.player_state_event?("player.trespassing") and Events.player_state_event?("player.illegal_weapon")
      refute Events.player_state_event?("player.health")

      for other <- [&Events.item_event?/1, &Events.contract_event?/1, &Events.actor_outcome?/1, &Events.disguise_event?/1, &Events.objective_event?/1] do
        refute other.("player.trespassing") or other.("player.illegal_weapon")
      end
    end
  end

  # -- evidence: the native envelopes of the B6 standalone wire run ----------------------------

  @b6_lines File.read!("test/b6_probe_envelopes.ndjson") |> String.split("\n", trim: true)
  @b6_id "18b902b3-f84d-4b73-9ef8-9c009357cc1b"

  describe "B6 wire fixture (22 native envelopes: the six B0 occurrences beside the accepted vocabulary, two attempts)" do
    test "every envelope decodes with the payload the native normalizer wrote, the weapon object field for field" do
      decoded = Enum.map(@b6_lines, fn l -> {:ok, e} = Envelope.decode(l); e end)
      assert Enum.map(decoded, & &1.sequence) == Enum.to_list(1..22)
      assert Enum.map(decoded, & &1.event_type) == [
               "contract.started", "mission.playing", "disguise.equipped", "player.trespassing", "item.picked_up", "disguise.equipped",
               "player.trespassing", "actor.pacified", "player.illegal_weapon", "player.illegal_weapon", "player.illegal_weapon",
               "player.illegal_weapon", "actor.died", "objective.completed", "contract.ended", "mission.stopped", "mission.playing",
               "contract.started", "disguise.equipped", "player.illegal_weapon", "mission.stopped", "contract.ended"
             ]

      for {line, e} <- Enum.zip(@b6_lines, decoded), Events.player_state_event?(e.event_type) do
        raw = JSON.decode!(line)["payload"]

        case e.event_type do
          "player.trespassing" ->
            assert e.payload.trespassing == raw["trespassing"] and e.payload.room_id == raw["room_id"]
            assert Map.keys(raw) -- ["source", "engine_event", "trespassing", "room_id", "contract_session_id", "engine_timestamp_s"] == []

          "player.illegal_weapon" ->
            assert e.payload.holding == raw["holding"]
            assert Map.keys(raw) -- ["source", "engine_event", "holding", "weapon", "contract_session_id", "engine_timestamp_s"] == []

            case raw["weapon"] do
              nil -> assert e.payload.weapon == nil
              w -> assert e.payload.weapon == pistol() and w == wire_weapon_object()
            end
        end

        assert e.payload.contract_session_id == raw["contract_session_id"] and e.payload.engine_timestamp_s == raw["engine_timestamp_s"]
      end

      # The two true forms carry the object, the two false forms do not; room ids as the engine's numbers.
      assert Enum.map([3, 6], &Enum.at(decoded, &1).payload.room_id) == [6, 3]
      assert Enum.map([8, 9, 10, 11], &(Enum.at(decoded, &1).payload.weapon != nil)) == [true, false, true, false]
    end

    test "folded: attached by order to two attempts; the views equal the ones derived from the bare facts; the exact lines" do
      decoded = Enum.map(@b6_lines, fn l -> {:ok, e} = Envelope.decode(l); e end)
      {inst, notes} = fold(decoded, Lifecycle.new(@b6_id))
      assert inst.received == 22 and inst.gaps == [] and inst.unattributed_player_state_events == []
      refute Enum.any?(notes, &match?({:unattributed_player_state_event, _}, &1))

      [a1, a2] = inst.attempts
      assert Enum.map(a1.player_state_events, &{&1.subject, &1.sequence}) == [{:trespassing, 4}, {:trespassing, 7}, {:illegal_weapon, 9}, {:illegal_weapon, 10}, {:illegal_weapon, 11}, {:illegal_weapon, 12}]
      assert Enum.map(a2.player_state_events, &{&1.subject, &1.sequence}) == [{:illegal_weapon, 20}]

      for n <- 1..2, do: assert(from_facts(inst, n) == view(inst, n))
      assert view(inst, 1).trespassing.last.value == false and view(inst, 1).illegal_weapon.observed_value_changes == 3
      assert view(inst, 2).trespassing.last == :not_observed and view(inst, 2).illegal_weapon.last.value == true

      t = Summary.render(%{@b6_id => inst})
      assert t =~ "player state (engine telemetry): trespassing last observed false at #7 @202.179184s (room_id 3), 2 occurrences, 1 observed value change; illegal weapon last observed false at #12 @491.880981s (last named weapon ICA19 Silverballer e70adb5b… at #11), 4 occurrences, 3 observed value changes; history intact"
      assert t =~ "player state (engine telemetry): trespassing not observed; illegal weapon last observed true at #20 @476.573425s (ICA19 Silverballer e70adb5b…), 1 occurrence, 0 observed value changes; history intact"
      assert_conservative(inst)
    end
  end

  describe "B0 (evidence order): the six occurrences inside one attempt" do
    test "attached by order; last observed per subject with the recorded metadata; counts; the facts reproduce the view" do
      {inst, notes} = fold([started(1, @session_a), playing(2)] ++ b0([3, 4, 5, 6, 7, 8]) ++ [stopped(9)])
      refute Enum.any?(notes, &match?({:unattributed_player_state_event, _}, &1))
      [a] = inst.attempts
      assert Enum.map(a.player_state_events, &{&1.subject, &1.sequence}) == [{:trespassing, 3}, {:trespassing, 4}, {:illegal_weapon, 5}, {:illegal_weapon, 6}, {:illegal_weapon, 7}, {:illegal_weapon, 8}]

      d = view(inst)
      assert d.occurrences == 6 and d.history == :complete

      assert d.trespassing == %{
               last: %{value: false, sequence: 4, engine_timestamp_s: 202.179184, room_id: 3},
               occurrences: 2,
               observed_value_changes: 1,
               standing: :last_observed,
               standing_cut: nil,
               notes: []
             }

      assert d.illegal_weapon == %{
               last: %{value: false, sequence: 8, engine_timestamp_s: 491.880981, weapon: nil},
               last_weapon: %{sequence: 7, weapon: pistol()},
               occurrences: 4,
               observed_value_changes: 3,
               standing: :last_observed,
               standing_cut: nil,
               notes: []
             }

      assert from_facts(inst) == d

      assert player_line(inst) ==
               "    player state (engine telemetry): trespassing last observed false at #4 @202.179184s (room_id 3), 2 occurrences, 1 observed value change; " <>
                 "illegal weapon last observed false at #8 @491.880981s (last named weapon ICA19 Silverballer e70adb5b… at #7), 4 occurrences, 3 observed value changes; history intact"

      assert_conservative(inst)
    end
  end

  describe "SYN: unknown initial state" do
    test "an attempt with no occurrence of a subject is :not_observed, not false; with no occurrence at all the line says none" do
      {inst, _} = fold([playing(1), died(2)])
      d = view(inst)
      assert d.trespassing.last == :not_observed and d.trespassing.standing == :not_observed
      assert d.illegal_weapon.last == :not_observed and d.illegal_weapon.standing == :not_observed
      assert d.trespassing.occurrences == 0 and d.illegal_weapon.occurrences == 0 and d.occurrences == 0
      assert player_line(inst) == "    player state (engine telemetry): none observed in the attempt"

      # One subject observed, the other not: the other stays :not_observed, never false.
      {inst, _} = fold([playing(1), weapon(2, true)])
      d = view(inst)
      assert d.trespassing == %{last: :not_observed, occurrences: 0, observed_value_changes: 0, standing: :not_observed, standing_cut: nil, notes: []}
      assert d.illegal_weapon.last.value == true

      assert player_line(inst) ==
               "    player state (engine telemetry): trespassing not observed; illegal weapon last observed true at #2 @476.573425s (ICA19 Silverballer e70adb5b…), 1 occurrence, 0 observed value changes; history intact"

      refute player_line(inst) =~ "false"
    end

    test "unknown is distinct from false: a false occurrence is a last-observed value, an absent one is not" do
      {inst_false, _} = fold([playing(1), trespass(2, false, room: 3)])
      {inst_none, _} = fold([playing(1)])
      assert view(inst_false).trespassing.last.value == false and view(inst_false).trespassing.standing == :last_observed
      assert view(inst_none).trespassing.last == :not_observed
      assert player_line(inst_false) =~ "trespassing last observed false at #2"
      assert player_line(inst_none) =~ "none observed"
    end
  end

  describe "SYN: occurrences and observed value changes" do
    test "a repeated value is an occurrence, not a change; a differing value is one observed change" do
      {inst, _} = fold([playing(1), trespass(2, true), trespass(3, true), trespass(4, true)])
      assert %{occurrences: 3, observed_value_changes: 0, last: %{value: true, sequence: 4}} = view(inst).trespassing

      {inst, _} = fold([playing(1), trespass(2, true), trespass(3, false)])
      assert %{occurrences: 2, observed_value_changes: 1} = view(inst).trespassing

      {inst, _} = fold([playing(1), weapon(2, true), weapon(3, true), weapon(4, false), weapon(5, false), weapon(6, true)])
      assert %{occurrences: 5, observed_value_changes: 2, last: %{value: true, sequence: 6}} = view(inst).illegal_weapon
      assert player_line(inst) =~ "5 occurrences, 2 observed value changes"
    end

    test "the counter counts differences between consecutive received values only: a gap between two equal values adds none, two differing values across a gap add one" do
      {inst, _} = fold([playing(1), trespass(2, true), trespass(5, true)])
      assert %{occurrences: 2, observed_value_changes: 0, standing: :last_observed} = view(inst).trespassing
      assert view(inst).history == {:incomplete, [{:gap, 3, 5}]}

      {inst, _} = fold([playing(1), trespass(2, true), trespass(5, false)])
      assert %{occurrences: 2, observed_value_changes: 1} = view(inst).trespassing
    end

    test "the two subjects are counted independently and never read into each other" do
      {inst, _} = fold([playing(1), trespass(2, true), weapon(3, true), trespass(4, false), weapon(5, false), weapon(6, true)])
      assert %{occurrences: 2, observed_value_changes: 1} = view(inst).trespassing
      assert %{occurrences: 3, observed_value_changes: 2} = view(inst).illegal_weapon
    end
  end

  describe "SYN: weapon metadata" do
    test "a true without a weapon object: last observed true, no weapon named, recorded as a note" do
      {inst, _} = fold([playing(1), weapon(2, true, weapon: nil)])
      d = view(inst).illegal_weapon
      assert d.last.weapon == nil and d.last_weapon == nil and d.notes == [{:no_weapon_named_on_true, 2}]
      assert player_line(inst) =~ "illegal weapon last observed true at #2 @476.573425s (no weapon named), 1 occurrence, 0 observed value changes; history intact; notes: #2 true without a weapon object"
    end

    test "a false with a weapon object: the object is preserved on the occurrence and shown, recorded as a note; no possession is derived" do
      {inst, _} = fold([playing(1), weapon(2, false, weapon: pistol())])
      d = view(inst).illegal_weapon
      assert d.last.value == false and d.last.weapon == pistol() and d.last_weapon == %{sequence: 2, weapon: pistol()}
      assert d.notes == [{:weapon_named_on_false, 2}]
      assert player_line(inst) =~ "illegal weapon last observed false at #2 @476.573425s (ICA19 Silverballer e70adb5b…), 1 occurrence, 0 observed value changes; history intact; notes: #2 false with a weapon object"
      assert_conservative(inst)
    end

    test "last named weapon: the most recent occurrence that carried an object, shown beside a later false" do
      other = %{pistol() | item_repository_id: "11111111-2222-4333-8444-555555555555", item_name: "Other", item_instance_id: nil}
      {inst, _} = fold([playing(1), weapon(2, true), weapon(3, false), weapon(4, true, weapon: other), weapon(5, false)])
      d = view(inst).illegal_weapon
      assert d.last_weapon == %{sequence: 4, weapon: other}
      assert player_line(inst) =~ "illegal weapon last observed false at #5 @476.573425s (last named weapon Other 11111111… at #4), 4 occurrences, 3 observed value changes"

      # A weapon without a display name is shown by its short id.
      nameless = %{other | item_name: nil}
      {inst, _} = fold([playing(1), weapon(2, true, weapon: nameless)])
      assert player_line(inst) =~ "illegal weapon last observed true at #2 @476.573425s (11111111…)"
    end
  end

  describe "SYN: gaps, interruptions and the per-subject cut" do
    test "a gap after the last occurrence: standing unknown, the last value preserved; a gap before it: last observed, history broken" do
      {inst, notes} = fold([playing(1), trespass(2, true), weapon(5, true)])
      assert {:gap, 3, 5} in notes
      d = view(inst)
      assert d.trespassing.standing == :unknown and d.trespassing.standing_cut == {:gap, 3, 5}
      assert d.trespassing.last == %{value: true, sequence: 2, engine_timestamp_s: 166.198425, room_id: 6}
      # The other subject's occurrence after the gap does not repair the first subject's standing.
      assert d.illegal_weapon.standing == :last_observed and d.illegal_weapon.standing_cut == nil
      assert d.history == {:incomplete, [{:gap, 3, 5}]}

      assert player_line(inst) ==
               "    player state (engine telemetry): trespassing last observed true at #2 @166.198425s (room_id 6), standing unknown after gap 3→5, 1 occurrence, 0 observed value changes; " <>
                 "illegal weapon last observed true at #5 @476.573425s (ICA19 Silverballer e70adb5b…), 1 occurrence, 0 observed value changes; history broken: gap 3→5"

      assert_conservative(inst)
      assert from_facts(inst) == d

      {inst, _} = fold([playing(1), trespass(2, true), trespass(5, false)])
      d = view(inst)
      assert d.trespassing.standing == :last_observed and d.trespassing.last.value == false and d.trespassing.standing_cut == nil
      assert d.history == {:incomplete, [{:gap, 3, 5}]}
      assert player_line(inst) =~ "trespassing last observed false at #5 @166.198425s (room_id 6), 2 occurrences, 1 observed value change; illegal weapon not observed; history broken: gap 3→5"
    end

    test "a fresh occurrence after a cut establishes a fresh last-observed value but the missing interval stays reported" do
      {inst, _} = fold([playing(1), trespass(2, true), trespass(5, true)])
      d = view(inst).trespassing
      assert d.standing == :last_observed and d.last.sequence == 5 and d.observed_value_changes == 0
      assert view(inst).history == {:incomplete, [{:gap, 3, 5}]}
    end

    test "the earliest cut after the last occurrence is named when several follow" do
      {inst, _} = fold([playing(1), trespass(2, true), weapon(4, true), weapon(7, false)])
      assert view(inst).trespassing.standing_cut == {:gap, 3, 4}
      assert view(inst).illegal_weapon.standing == :last_observed
      assert view(inst).history == {:incomplete, [{:gap, 3, 4}, {:gap, 5, 7}]}
    end

    test "an interruption after the last occurrence: standing unknown; after reconnection a new occurrence is last observed again" do
      at = ~U[2026-10-12 20:05:00Z]
      inst = identified(Lifecycle.new(@id))
      {inst, _} = fold([playing(1), trespass(2, true), weapon(3, true), {:close, at}], inst)
      d = view(inst)
      assert d.trespassing.standing == :unknown and d.trespassing.standing_cut == {:interruption, at, :peer_closed}
      assert d.illegal_weapon.standing == :unknown and d.illegal_weapon.standing_cut == {:interruption, at, :peer_closed}
      assert d.history == {:incomplete, [{:interruption, at, :peer_closed}]}
      assert player_line(inst) =~ "trespassing last observed true at #2 @166.198425s (room_id 6), standing unknown after observation lost 2026-10-12T20:05:00Z (:peer_closed)"
      assert player_line(inst) =~ "illegal weapon last observed true at #3 @476.573425s (ICA19 Silverballer e70adb5b…), standing unknown after observation lost 2026-10-12T20:05:00Z (:peer_closed)"

      {inst, _} = fold([{:reopen, at}, weapon(4, false)], inst)
      d = view(inst)
      assert d.illegal_weapon.standing == :last_observed and d.illegal_weapon.last.sequence == 4 and d.illegal_weapon.observed_value_changes == 1
      # The trespassing subject is not repaired by the illegal-weapon occurrence.
      assert d.trespassing.standing == :unknown and d.trespassing.last.sequence == 2
      assert d.history == {:incomplete, [{:interruption, at, :peer_closed}]}
      assert from_facts(inst) == d
    end

    test "different uncertainty per subject: the one whose last occurrence precedes the cut is unknown, the other is last observed" do
      {inst, _} = fold([playing(1), weapon(2, true), trespass(3, true), trespass(6, false)])
      d = view(inst)
      assert d.illegal_weapon.standing == :unknown and d.illegal_weapon.standing_cut == {:gap, 4, 6}
      assert d.trespassing.standing == :last_observed and d.trespassing.last.value == false
    end
  end

  describe "SYN: attempt boundaries" do
    test "no cross-attempt inheritance: the second attempt starts :not_observed whatever the first ended with" do
      {inst, _} = fold([playing(1), trespass(2, true), weapon(3, true), stopped(4), playing(5, @session_b), weapon(6, false)])
      [a1, a2] = inst.attempts
      assert Enum.map(a1.player_state_events, & &1.sequence) == [2, 3]
      assert Enum.map(a2.player_state_events, & &1.sequence) == [6]
      assert view(inst, 1).trespassing.last.value == true and view(inst, 1).illegal_weapon.last.value == true
      assert view(inst, 2).trespassing.last == :not_observed
      assert %{last: %{value: false, sequence: 6, weapon: nil}, last_weapon: nil, occurrences: 1, observed_value_changes: 0} = view(inst, 2).illegal_weapon
      assert player_line(inst, 1) =~ "trespassing not observed; illegal weapon last observed false at #6"
    end

    test "before any rise and after a stop: unattributed, kept visible, never attached" do
      {inst, notes} = fold([trespass(1, true), playing(2), trespass(3, false), stopped(4), weapon(5, true)])
      assert {:unattributed_player_state_event, 1} in notes
      assert {:unattributed_player_state_event, 5} in notes
      assert Enum.map(inst.unattributed_player_state_events, &{&1.subject, &1.sequence}) == [{:trespassing, 1}, {:illegal_weapon, 5}]
      assert [a] = inst.attempts
      assert Enum.map(a.player_state_events, & &1.sequence) == [3]
      t = text(inst)
      assert t =~ "  player state trespassing true (room_id 6) #1 @166.198425s with no open attempt"
      assert t =~ "  player state illegal weapon true (ICA19 Silverballer e70adb5b…) #5 @476.573425s with no open attempt"
      assert_conservative(inst)
    end

    test "a closed attempt's view is never changed by what arrives after its stop" do
      {inst, _} = fold([playing(1), trespass(2, true), weapon(3, true), stopped(4)])
      frozen = view(inst)

      extensions = [trespass(5, false), playing(6, @session_b), weapon(7, false), trespass(9, false), stopped(10)]

      Enum.reduce(extensions, inst, fn e, acc ->
        {acc, _} = fold([e], acc)
        assert view(acc, 1) == frozen
        acc
      end)
    end

    test "superseded attempts are bounded by the rise that superseded them; later gaps never reach them" do
      {inst, _} = fold([playing(1), trespass(2, true), weapon(3, true), playing(5), trespass(6, false), weapon(9, false)])
      assert inst.gaps == [{7, 9}, {4, 5}]
      [a1, _] = inst.attempts
      assert a1.mission == :superseded and a1.superseded_at == 5
      d1 = view(inst, 1)
      assert d1.history == {:incomplete, [{:gap, 4, 5}, {:superseded, 2, 5}]}
      assert d1.trespassing.standing == :unknown and d1.trespassing.standing_cut == {:gap, 4, 5}
      assert d1.illegal_weapon.standing == :unknown and d1.illegal_weapon.standing_cut == {:gap, 4, 5}
      d2 = view(inst, 2)
      assert d2.history == {:incomplete, [{:gap, 7, 9}]}
      assert d2.trespassing.standing == :unknown and d2.trespassing.standing_cut == {:gap, 7, 9}
      assert d2.illegal_weapon.standing == :last_observed and d2.illegal_weapon.last.sequence == 9
      assert AttemptHistory.gaps_in_attempt(inst.gaps, a1) == [{4, 5}]
      for n <- 1..2, do: assert(from_facts(inst, n) == view(inst, n))
      # The item and objective views on the same attempt see the same history through the shared helper.
      assert Items.derive(a1, inst).history == d1.history and Objectives.derive(a1, inst).history == d1.history
      assert player_line(inst, 0) =~ "history broken: gap 4→5, superseded by attempt 2 at #5"
    end

    test "player-state, item, objective, disguise and actor facts interleave in one sequence and stay apart" do
      {inst, _} = fold([started(1, @session_a), playing(2), equipped(3, @suit, "initial"), trespass(4, true), pickup(5), died(6), objective(7), weapon(8, true), weapon(9, false), stopped(10)])
      [a] = inst.attempts
      assert Enum.map(a.player_state_events, & &1.sequence) == [4, 8, 9]
      assert Enum.map(a.item_events, & &1.sequence) == [5]
      assert Enum.map(a.outcomes, & &1.sequence) == [6]
      assert Enum.map(a.objective_events, & &1.sequence) == [7]
      assert Enum.map(a.disguise_events, & &1.sequence) == [3]
    end
  end

  describe "replay equivalence" do
    test "the view is a function of the recorded facts on every stream; every prefix's facts are a prefix" do
      at = ~U[2026-10-12 20:05:00Z]

      streams = [
        [started(1, @session_a), playing(2)] ++ b0([3, 4, 5, 6, 7, 8]) ++ [stopped(9)],
        [trespass(1, true), playing(2), trespass(3, false), stopped(4), weapon(5, true)],
        [playing(1), trespass(2, true), weapon(5, true)],
        [playing(1), trespass(2, true), weapon(3, true), {:close, at}, {:reopen, at}, weapon(4, false)],
        [playing(1), trespass(2, true), weapon(3, true), playing(5), trespass(6, false), weapon(9, false)],
        [playing(1), weapon(2, true, weapon: nil), weapon(3, false, weapon: pistol())],
        [playing(1), pickup(2), died(3)]
      ]

      for steps <- streams do
        inst = identified(Lifecycle.new(@id))
        {inst, _} = fold(steps, inst)
        for n <- 1..length(inst.attempts), do: assert(from_facts(inst, n) == view(inst, n))

        final = Enum.map(inst.attempts, & &1.player_state_events)
        final_unattributed = inst.unattributed_player_state_events

        for n <- 1..length(steps) do
          prefix = identified(Lifecycle.new(@id))
          {prefix, _} = fold(Enum.take(steps, n), prefix)

          for {attempt, i} <- Enum.with_index(prefix.attempts) do
            assert attempt.player_state_events == Enum.take(Enum.at(final, i), length(attempt.player_state_events))
          end

          assert prefix.unattributed_player_state_events == Enum.take(final_unattributed, length(prefix.unattributed_player_state_events))
        end
      end
    end
  end

  describe "summary wording and the accepted vocabulary beside the new line" do
    test "the player-state line never makes a present-tense claim and never uses another family's reserved words" do
      at = ~U[2026-10-12 20:05:00Z]
      inst = identified(Lifecycle.new(@id))

      {inst, _} =
        fold([started(1, @session_a), playing(2)] ++ b0([3, 4, 5, 6, 7, 8]) ++ [weapon(9, true, weapon: nil), weapon(10, false, weapon: pistol()), trespass(12, true), {:close, at}], inst)

      t = text(inst)
      lines = t |> String.split("\n") |> Enum.filter(&String.contains?(&1, "player state"))
      assert length(lines) == 1
      assert_conservative(inst)
      assert hd(lines) =~ "trespassing last observed true at #12 @166.198425s (room_id 6), standing unknown after observation lost 2026-10-12T20:05:00Z (:peer_closed), 3 occurrences, 2 observed value changes"
      assert hd(lines) =~ "illegal weapon last observed false at #10 @476.573425s (ICA19 Silverballer e70adb5b…), standing unknown after gap 11→12, 6 occurrences, 5 observed value changes"
      assert hd(lines) =~ "history broken: gap 11→12, observation lost 2026-10-12T20:05:00Z (:peer_closed); notes: #9 true without a weapon object, #10 false with a weapon object"
      refute t =~ "player.trespassing" and refute(t =~ "player.illegal_weapon")
    end

    test "the B1–B5 lines are unchanged beside the B6 line (regression)" do
      {inst, _} = fold([started(1, @session_a), playing(2), equipped(3, @suit, "initial"), trespass(4, true), pickup(5), died(6), objective(7), weapon(8, true), weapon(9, false), stopped(10)])
      t = text(inst)
      assert line(inst, "actor outcomes (engine telemetry)") == "    actor outcomes (engine telemetry): 1 died (1 target, 0 non-target; 1 civilian; context murder 1); 0 pacified"
      assert line(inst, "disguises (engine telemetry)") == "    disguises (engine telemetry): contract.started says 874c4c48… (hitman suit); initial 874c4c48… #3 @13.011781s"
      assert line(inst, "disguise state (BEAM-derived)") == "    disguise state (BEAM-derived): worn 874c4c48… (equals the starting suit id) since #3; worn outfit: no compromise observed; 0 changes, 1 definition used; history intact"
      assert line(inst, "items (engine telemetry)") == "    items (engine telemetry): picked up 1 — Wrench; thrown 0; removed from inventory 0; 1 definition; history intact"
      assert line(inst, "objectives (engine telemetry)") == "    objectives (engine telemetry): 1 reported done — kill/primary aca8cd5b… #7 @759.401611s; history intact"
      assert line(inst, "disposition (BEAM-derived") == "    disposition (BEAM-derived, session paired by next_rise): not observed; contract end not seen"

      assert player_line(inst) ==
               "    player state (engine telemetry): trespassing last observed true at #4 @166.198425s (room_id 6), 1 occurrence, 0 observed value changes; " <>
                 "illegal weapon last observed false at #9 @476.573425s (last named weapon ICA19 Silverballer e70adb5b… at #8), 2 occurrences, 1 observed value change; history intact"

      # The player-state line follows the objective line, last in the attempt block.
      block = t |> String.split("\n") |> Enum.drop_while(&(not String.contains?(&1, "attempt 1:")))
      assert Enum.at(block, 8) =~ "objectives (engine telemetry)" and Enum.at(block, 9) =~ "player state (engine telemetry)"
    end
  end
end

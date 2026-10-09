defmodule GlacierRelay.ItemsTest do
  @moduledoc """
  M2 B4: validation of item.picked_up / item.thrown / item.removed_from_inventory v1; the direct
  counting of design section 38.6 (per type, per definition, nothing paired); attempt attachment by
  order; history bounded to the attempt (the `63184c4` guarantees, repeated for items through the
  shared `AttemptHistory`); replay equivalence from the bare facts; and the summary wording.

  Evidence cases use the 24 occurrences of the B0 session in their recorded order (the Relay
  payloads the native normalizer produces from Tests/Fixtures/B0Items.h); SYN cases are synthetic
  and pin the model's conservative behaviour, not engine semantics. Every external fact a case
  depends on — gaps, interruptions, supersession, the stop — is supplied explicitly by the stream.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.{AttemptHistory, Disguise, Events, Items, Lifecycle, Summary}
  alias GlacierRelay.Lifecycle.Attempt
  alias GlacierRelay.Wire.Envelope

  @id "b4-test-instance"
  @session_a "2516109628137904204-c00b2d17-08b1-4949-9f9d-5f68b691f40f"
  @paris "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"

  @wrench "6adddf7e-6879-4d51-a7e2-6a25ffdca6ae"
  @crowbar "01ed6d15-e26e-4362-b1a6-363684a7d0fd"
  @rat_poison "8b37a3a8-8a20-4262-81c5-0fcd15f4bba9"
  @lead_pipe "7aeb740f-3d60-4e49-8d27-15a98067ce9f"
  @knife "e17172cc-bf70-4df6-9828-d9856b1a24fd"
  @cleaver "1bbf0ed5-0515-4599-a4c9-454ce59cff44"
  @propane "a8a0c154-c36f-413e-8f29-b83a1b7a22f0"

  # The 24 B0 item occurrences (B0Items.h order): {type, id, name, engine type, traits, timestamp}.
  @melee_nl ["melee_nonlethal", "throw_nonlethal_deprecated"]
  @melee_l ["melee_lethal", "throw_lethal_deprecated"]
  @b0 [
    {:picked_up, @wrench, "Wrench", "CC_Wrench", @melee_nl, 176.078949},
    {:removed_from_inventory, @wrench, "Wrench", "CC_Wrench", @melee_nl, 209.153168},
    {:thrown, @wrench, "Wrench", "CC_Wrench", @melee_nl, 209.153168},
    {:picked_up, @wrench, "Wrench", "CC_Wrench", @melee_nl, 211.12352},
    {:removed_from_inventory, @wrench, "Wrench", "CC_Wrench", @melee_nl, 227.275742},
    {:thrown, @wrench, "Wrench", "CC_Wrench", @melee_nl, 227.275742},
    {:picked_up, @wrench, "Wrench", "CC_Wrench", @melee_nl, 234.305466},
    {:picked_up, @crowbar, "Crowbar", "Unrecognized Item type", @melee_nl, 304.081787},
    {:removed_from_inventory, @crowbar, "Crowbar", "Unrecognized Item type", @melee_nl, 470.11792},
    {:thrown, @crowbar, "Crowbar", "Unrecognized Item type", @melee_nl, 470.11792},
    {:picked_up, @crowbar, "Crowbar", "Unrecognized Item type", @melee_nl, 472.209076},
    {:picked_up, @crowbar, "Crowbar", "Unrecognized Item type", @melee_nl, 547.729797},
    {:picked_up, @rat_poison, "Emetic Rat Poison", "CC_Bottle", ["poison", "consumable_poison"], 553.148804},
    {:picked_up, @lead_pipe, "Lead Pipe", "CC_MetalPipe", @melee_nl, 556.528687},
    {:picked_up, @knife, "Kitchen Knife", "CC_Knife", @melee_l, 646.376404},
    {:picked_up, @cleaver, "Cleaver", "CC_Cleaver", @melee_l, 648.96875},
    {:removed_from_inventory, @lead_pipe, "Lead Pipe", "CC_MetalPipe", @melee_nl, 658.737732},
    {:thrown, @lead_pipe, "Lead Pipe", "CC_MetalPipe", @melee_nl, 658.737732},
    {:removed_from_inventory, @knife, "Kitchen Knife", "CC_Knife", @melee_l, 662.366211},
    {:thrown, @knife, "Kitchen Knife", "CC_Knife", @melee_l, 662.366211},
    {:picked_up, @knife, "Kitchen Knife", "CC_Knife", @melee_l, 666.88208},
    {:picked_up, @propane, "Propane Flask", "CC_FireExtinguisher_01", ["melee_nonlethal", "explosive", "accident_explosion", "throw_nonlethal_deprecated"], 682.982056},
    {:removed_from_inventory, @propane, "Propane Flask", "CC_FireExtinguisher_01", ["melee_nonlethal", "explosive", "accident_explosion", "throw_nonlethal_deprecated"], 721.859741},
    {:thrown, @propane, "Propane Flask", "CC_FireExtinguisher_01", ["melee_nonlethal", "explosive", "accident_explosion", "throw_nonlethal_deprecated"], 721.859741}
  ]

  # -- stream builders -------------------------------------------------------------------------

  defp env(type, seq, payload) do
    %Envelope{
      protocol_version: 1,
      adapter_instance_id: @id,
      sequence: seq,
      timestamp: "2026-10-09T03:00:#{String.pad_leading(Integer.to_string(rem(seq, 60)), 2, "0")}.000Z",
      event_type: type,
      schema_version: 1,
      payload: payload
    }
  end

  defp playing(seq, session \\ @session_a),
    do: env("mission.playing", seq, %{scene_resource: @paris, scene_type: "mission", codename_hint: "Peacock", game_session_id: session})

  defp stopped(seq),
    do: env("mission.stopped", seq, %{scene_resource: @paris, scene_type: "mission", codename_hint: "Peacock", game_session_id: @session_a})

  defp type_name(:picked_up), do: {"item.picked_up", "ItemPickedUp"}
  defp type_name(:thrown), do: {"item.thrown", "ItemThrown"}
  defp type_name(:removed_from_inventory), do: {"item.removed_from_inventory", "ItemRemovedFromInventory"}

  defp item_payload(type, id, opts) do
    {_, engine_event} = type_name(type)

    %{
      source: "engine_telemetry",
      engine_event: engine_event,
      item_repository_id: id,
      item_instance_id: Keyword.get(opts, :instance),
      item_name: Keyword.get(opts, :name),
      item_type: Keyword.get(opts, :type),
      online_traits: Keyword.get(opts, :traits),
      contract_session_id: Keyword.get(opts, :session, @session_a),
      engine_timestamp_s: Keyword.get(opts, :t, 1.0)
    }
  end

  defp item(type, seq, id, opts) do
    {event_type, _} = type_name(type)
    env(event_type, seq, item_payload(type, id, opts))
  end

  defp pickup(seq, id, opts \\ []), do: item(:picked_up, seq, id, opts)
  defp thrown(seq, id, opts \\ []), do: item(:thrown, seq, id, opts)
  defp removed(seq, id, opts \\ []), do: item(:removed_from_inventory, seq, id, opts)

  # The 24 B0 occurrences as the envelopes the native normalizer would publish, from `first_seq`.
  defp b0_stream(first_seq) do
    @b0
    |> Enum.with_index(first_seq)
    |> Enum.map(fn {{type, id, name, engine_type, traits, t}, seq} ->
      item(type, seq, id, name: name, type: engine_type, traits: traits, t: t)
    end)
  end

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

  defp change(seq, id),
    do:
      env("disguise.equipped", seq, %{
        source: "engine_telemetry",
        kind: "change",
        engine_event: "Disguise",
        disguise_repository_id: id,
        contract_session_id: @session_a,
        engine_timestamp_s: 1.0
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

  defp identified(instance),
    do: Lifecycle.connection_identified(instance, "127.0.0.1:1", ~U[2026-10-09 03:00:00Z], ~U[2026-10-09 03:00:00Z])

  defp view(instance, number \\ 1) do
    attempt = Enum.at(instance.attempts, number - 1)
    Items.derive(attempt, instance)
  end

  # The same view, rebuilt from the bare facts only: the occurrences, the instance's gaps and the
  # attempt's interruptions and supersession, on an otherwise empty attempt and instance.
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
      item_events: attempt.item_events
    }

    Items.derive(bare, %{Lifecycle.new(@id) | gaps: instance.gaps})
  end

  defp text(instance), do: Summary.render(%{@id => instance})

  defp items_line(instance) do
    text(instance)
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, "items (engine telemetry)"))
  end

  defp wire(type, id, extra \\ %{}) do
    {_, engine_event} = type_name(type)

    Map.merge(
      %{
        "source" => "engine_telemetry",
        "engine_event" => engine_event,
        "item_repository_id" => id,
        "item_name" => "Wrench",
        "item_type" => "CC_Wrench",
        "online_traits" => @melee_nl,
        "contract_session_id" => @session_a,
        "engine_timestamp_s" => 176.078949
      },
      extra
    )
  end

  @forbidden ~r/inventory contents|holding|carried|owns|recovered|throws|clean|undetected|safe|silent assassin|complet/i

  describe "validation" do
    test "the three types v1 with the full B0 shape" do
      for type <- [:picked_up, :thrown, :removed_from_inventory] do
        {event_type, engine_event} = type_name(type)
        assert {:ok, p} = Events.validate(event_type, 1, wire(type, @wrench))
        assert p.source == "engine_telemetry" and p.engine_event == engine_event
        assert p.item_repository_id == @wrench
        assert p.item_instance_id == nil
        assert p.item_name == "Wrench" and p.item_type == "CC_Wrench"
        assert p.online_traits == @melee_nl
        assert p.contract_session_id == @session_a and p.engine_timestamp_s == 176.078949
      end
    end

    test "the definition id is the subject: required, non-empty, a string" do
      for type <- [:picked_up, :thrown, :removed_from_inventory] do
        {event_type, _} = type_name(type)

        assert {:error, {:missing_field, "item_repository_id"}} =
                 Events.validate(event_type, 1, Map.delete(wire(type, @wrench), "item_repository_id"))

        assert {:error, {:invalid_field, "item_repository_id"}} =
                 Events.validate(event_type, 1, wire(type, ""))

        assert {:error, {:invalid_field, "item_repository_id"}} =
                 Events.validate(event_type, 1, wire(type, 7))
      end
    end

    test "every other item field is optional; absent is valid, present must be typed" do
      bare = Map.drop(wire(:thrown, @wrench), ["item_name", "item_type", "online_traits", "contract_session_id", "engine_timestamp_s"])
      assert {:ok, p} = Events.validate("item.thrown", 1, bare)
      assert p.item_instance_id == nil and p.item_name == nil and p.item_type == nil and p.online_traits == nil
      assert p.contract_session_id == nil and p.engine_timestamp_s == nil

      assert {:ok, %{item_instance_id: "9a3f1dbb-6f6e-4d7b-9a51-2f0c1a7b4e21"}} =
               Events.validate("item.picked_up", 1, wire(:picked_up, @wrench, %{"item_instance_id" => "9a3f1dbb-6f6e-4d7b-9a51-2f0c1a7b4e21"}))

      assert {:ok, %{online_traits: []}} = Events.validate("item.picked_up", 1, wire(:picked_up, @wrench, %{"online_traits" => []}))

      for {key, bad} <- [
            {"item_name", true},
            {"item_type", ["CC_Wrench"]},
            {"online_traits", "melee_nonlethal"},
            {"online_traits", ["melee_nonlethal", 7]},
            {"contract_session_id", 1},
            {"engine_timestamp_s", "x"}
          ] do
        assert {:error, {:invalid_field, ^key}} = Events.validate("item.picked_up", 1, wire(:picked_up, @wrench, %{key => bad}))
      end

      assert {:error, {:missing_field, "engine_event"}} =
               Events.validate("item.picked_up", 1, Map.delete(wire(:picked_up, @wrench), "engine_event"))

      assert {:error, {:missing_field, "source"}} =
               Events.validate("item.picked_up", 1, Map.delete(wire(:picked_up, @wrench), "source"))
    end

    test "item_instance_id: absent is valid; present must be a non-empty string, never read as absent" do
      for type <- [:picked_up, :thrown, :removed_from_inventory] do
        {event_type, _} = type_name(type)
        assert {:ok, %{item_instance_id: nil}} = Events.validate(event_type, 1, wire(type, @wrench))

        assert {:ok, %{item_instance_id: "9a3f1dbb-6f6e-4d7b-9a51-2f0c1a7b4e21"}} =
                 Events.validate(event_type, 1, wire(type, @wrench, %{"item_instance_id" => "9a3f1dbb-6f6e-4d7b-9a51-2f0c1a7b4e21"}))

        for bad <- ["", nil, 1, 1.5, true, ["x"], %{"a" => 1}] do
          assert {:error, {:invalid_field, "item_instance_id"}} =
                   Events.validate(event_type, 1, wire(type, @wrench, %{"item_instance_id" => bad}))
        end
      end

      # The rule is specific to the instance id: empty display strings and an empty trait list
      # stay valid, as before.
      assert {:ok, %{item_name: "", item_type: "", online_traits: []}} =
               Events.validate("item.picked_up", 1, wire(:picked_up, @wrench, %{"item_name" => "", "item_type" => "", "online_traits" => []}))
    end

    test "unknown versions and the names that are not vocabulary are rejected" do
      assert {:error, {:unsupported_schema_version, "item.picked_up", 2}} = Events.validate("item.picked_up", 2, wire(:picked_up, @wrench))
      assert {:error, {:unsupported_schema_version, "item.thrown", 0}} = Events.validate("item.thrown", 0, wire(:thrown, @wrench))

      for name <- ["item.removed", "item.dropped", "item.destroyed", "item.pickedup", "item.stashed", "items.picked_up"] do
        assert {:error, {:unknown_event_type, ^name}} = Events.validate(name, 1, wire(:picked_up, @wrench))
      end
    end

    test "classification helpers" do
      assert Events.item_event?("item.picked_up")
      assert Events.item_event?("item.thrown")
      assert Events.item_event?("item.removed_from_inventory")
      refute Events.item_event?("item.removed")
      refute Events.item_event?("item.dropped")
      refute Events.item_event?("disguise.equipped")
      refute Events.item_event?("actor.died")
      refute Events.disguise_event?("item.thrown")
      refute Events.actor_outcome?("item.thrown")
      refute Events.contract_event?("item.thrown")
    end
  end

  # -- evidence: the native envelopes of the B4 standalone wire run ----------------------------

  @b4_lines File.read!("test/b4_probe_envelopes.ndjson") |> String.split("\n", trim: true)
  @b4_id "31c81c1e-071d-4ff4-8dd2-462b9b97900c"

  describe "B4 wire fixture (45 native envelopes, B0 session 1 order through the production sequencing)" do
    test "every envelope decodes with the payload the native normalizer wrote" do
      decoded = Enum.map(@b4_lines, fn l -> {:ok, e} = Envelope.decode(l); e end)
      assert Enum.map(decoded, & &1.sequence) == Enum.to_list(1..45)
      assert Enum.frequencies_by(decoded, & &1.event_type) == %{
               "contract.started" => 2, "contract.ended" => 2, "mission.playing" => 2, "mission.stopped" => 2,
               "disguise.equipped" => 4, "disguise.compromised" => 2, "disguise.compromise_cleared" => 2,
               "actor.died" => 2, "actor.pacified" => 3,
               "item.picked_up" => 12, "item.thrown" => 6, "item.removed_from_inventory" => 6
             }

      # The validated payload equals the native JSON field for field (nil for absent optionals);
      # item_instance_id is absent on all 24 (empty in the engine's payload, omitted by the native
      # side) and nothing else is on the wire.
      for {line, e} <- Enum.zip(@b4_lines, decoded), Events.item_event?(e.event_type) do
        raw = JSON.decode!(line)["payload"]
        assert e.payload.source == raw["source"]
        assert e.payload.engine_event == raw["engine_event"]
        assert e.payload.item_repository_id == raw["item_repository_id"]
        assert e.payload.item_instance_id == nil and not Map.has_key?(raw, "item_instance_id")
        assert e.payload.item_name == raw["item_name"]
        assert e.payload.item_type == raw["item_type"]
        assert e.payload.online_traits == raw["online_traits"]
        assert e.payload.contract_session_id == raw["contract_session_id"]
        assert e.payload.engine_timestamp_s == raw["engine_timestamp_s"]
        assert Map.keys(raw) -- ["source", "engine_event", "item_repository_id", "item_name", "item_type", "online_traits", "contract_session_id", "engine_timestamp_s"] == []
      end

      # The 24 item payloads on the wire equal, in order, the B0 occurrences this file lists.
      wire_items = decoded |> Enum.filter(&Events.item_event?(&1.event_type)) |> Enum.map(&{type_of(&1.event_type), &1.payload.item_repository_id, &1.payload.item_name, &1.payload.item_type, &1.payload.online_traits, &1.payload.engine_timestamp_s})
      assert wire_items == @b0
    end

    test "folded: the recorded session's counts, and the facts reproduce them" do
      decoded = Enum.map(@b4_lines, fn l -> {:ok, e} = Envelope.decode(l); e end)
      {inst, notes} = fold(decoded, Lifecycle.new(@b4_id))
      refute Enum.any?(notes, &match?({:unattributed_item_event, _}, &1))
      assert inst.received == 45 and inst.gaps == []

      d = view(inst, 1)
      assert d.picked_up == 12 and d.thrown == 6 and d.removed_from_inventory == 6
      assert d.definitions_used == [@wrench, @crowbar, @rat_poison, @lead_pipe, @knife, @cleaver, @propane]
      assert d.history == :complete and from_facts(inst, 1) == d
      assert view(inst, 2).occurrences == 0 and from_facts(inst, 2) == view(inst, 2)

      # Removal/throw neighbours in the stream: consecutive sequences, identical engine timestamp
      # and definition, as the engine emitted them — recorded as two facts, not read as one.
      pairs_by_adjacency =
        hd(inst.attempts).item_events
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(fn [a, b] -> a.type == :removed_from_inventory and b.type == :thrown end)

      assert length(pairs_by_adjacency) == 6
      for [a, b] <- pairs_by_adjacency do
        assert b.sequence == a.sequence + 1
        assert a.payload.engine_timestamp_s == b.payload.engine_timestamp_s
        assert a.payload.item_repository_id == b.payload.item_repository_id
      end
      refute Map.has_key?(d, :pairs)

      # Item, disguise and actor facts interleave in one sequence and stay apart.
      assert Enum.map(hd(inst.attempts).disguise_events, & &1.sequence) == [3, 5, 9, 17, 21, 25, 26]
      assert Enum.map(hd(inst.attempts).outcomes, & &1.sequence) == [10, 13, 16, 31, 34]
    end
  end

  defp type_of("item.picked_up"), do: :picked_up
  defp type_of("item.thrown"), do: :thrown
  defp type_of("item.removed_from_inventory"), do: :removed_from_inventory

  describe "B0 session (evidence order): the 24 occurrences inside one attempt" do
    test "direct counts, per-definition table, seven definitions, history intact; the facts reproduce it" do
      {inst, notes} = fold([playing(1)] ++ b0_stream(2) ++ [stopped(26)])
      refute Enum.any?(notes, &match?({:unattributed_item_event, _}, &1))
      assert inst.gaps == []
      [attempt] = inst.attempts
      assert length(attempt.item_events) == 24
      assert Enum.map(attempt.item_events, & &1.sequence) == Enum.to_list(2..25)

      d = view(inst)
      assert d.picked_up == 12 and d.thrown == 6 and d.removed_from_inventory == 6 and d.occurrences == 24
      assert d.definitions_used == [@wrench, @crowbar, @rat_poison, @lead_pipe, @knife, @cleaver, @propane]
      assert d.history == :complete

      assert d.by_definition == [
               %{item_repository_id: @wrench, picked_up: 3, thrown: 2, removed_from_inventory: 2, item_name: "Wrench", item_type: "CC_Wrench"},
               %{item_repository_id: @crowbar, picked_up: 3, thrown: 1, removed_from_inventory: 1, item_name: "Crowbar", item_type: "Unrecognized Item type"},
               %{item_repository_id: @rat_poison, picked_up: 1, thrown: 0, removed_from_inventory: 0, item_name: "Emetic Rat Poison", item_type: "CC_Bottle"},
               %{item_repository_id: @lead_pipe, picked_up: 1, thrown: 1, removed_from_inventory: 1, item_name: "Lead Pipe", item_type: "CC_MetalPipe"},
               %{item_repository_id: @knife, picked_up: 2, thrown: 1, removed_from_inventory: 1, item_name: "Kitchen Knife", item_type: "CC_Knife"},
               %{item_repository_id: @cleaver, picked_up: 1, thrown: 0, removed_from_inventory: 0, item_name: "Cleaver", item_type: "CC_Cleaver"},
               %{item_repository_id: @propane, picked_up: 1, thrown: 1, removed_from_inventory: 1, item_name: "Propane Flask", item_type: "CC_FireExtinguisher_01"}
             ]

      # The per-definition counts sum to the direct counts: nothing is dropped or merged.
      assert Enum.sum(Enum.map(d.by_definition, & &1.picked_up)) == 12
      assert Enum.sum(Enum.map(d.by_definition, & &1.thrown)) == 6
      assert Enum.sum(Enum.map(d.by_definition, & &1.removed_from_inventory)) == 6

      # The view carries no pairing of any kind and no held/inventory state.
      refute Map.has_key?(d, :pairs) or Map.has_key?(d, :throws) or Map.has_key?(d, :held) or Map.has_key?(d, :inventory)
      assert from_facts(inst) == d

      line = items_line(inst)
      assert line ==
               "    items (engine telemetry): picked up 12 — Wrench ×3, Crowbar ×3, Emetic Rat Poison, Lead Pipe, Kitchen Knife ×2, Cleaver, Propane Flask; " <>
                 "thrown 6 — Wrench ×2, Crowbar, Lead Pipe, Kitchen Knife, Propane Flask; " <>
                 "removed from inventory 6 — Wrench ×2, Crowbar, Lead Pipe, Kitchen Knife, Propane Flask; 7 definitions; history intact"

      refute line =~ @forbidden
      refute line =~ ~r/dropped|destroyed|none observed/
    end

    test "the occurrences are kept whole as facts on the attempt" do
      {inst, _} = fold([playing(1)] ++ b0_stream(2))
      [first, second, third | _] = hd(inst.attempts).item_events
      assert first.type == :picked_up and first.payload.item_repository_id == @wrench and first.payload.engine_timestamp_s == 176.078949
      assert second.type == :removed_from_inventory and third.type == :thrown
      assert second.payload.engine_timestamp_s == third.payload.engine_timestamp_s
      assert second.payload.item_repository_id == third.payload.item_repository_id
      # Two distinct facts with their own sequences; nothing links them.
      assert second.sequence + 1 == third.sequence
      assert Map.keys(second) == Map.keys(third)
      refute Map.has_key?(second, :paired_with)
    end
  end

  describe "SYN: counting" do
    test "a throw with no removal and a removal with no throw each count on their own" do
      {inst, _} = fold([playing(1), thrown(2, @wrench, name: "Wrench"), removed(3, @crowbar, name: "Crowbar")])
      d = view(inst)
      assert d.picked_up == 0 and d.thrown == 1 and d.removed_from_inventory == 1
      assert d.by_definition == [
               %{item_repository_id: @wrench, picked_up: 0, thrown: 1, removed_from_inventory: 0, item_name: "Wrench", item_type: nil},
               %{item_repository_id: @crowbar, picked_up: 0, thrown: 0, removed_from_inventory: 1, item_name: "Crowbar", item_type: nil}
             ]
      assert items_line(inst) == "    items (engine telemetry): picked up 0; thrown 1 — Wrench; removed from inventory 1 — Crowbar; 2 definitions; history intact"
      assert from_facts(inst) == d
    end

    test "two removals and two throws of one definition are four occurrences, counted, never matched" do
      {inst, _} = fold([playing(1), removed(2, @wrench, t: 5.0), thrown(3, @wrench, t: 5.0), removed(4, @wrench, t: 5.0), thrown(5, @wrench, t: 5.0)])
      d = view(inst)
      assert d.thrown == 2 and d.removed_from_inventory == 2 and d.occurrences == 4
      assert [%{thrown: 2, removed_from_inventory: 2}] = d.by_definition
      assert from_facts(inst) == d
    end

    test "repeated pickups of one definition are distinct occurrences; the first non-empty name and type stick" do
      {inst, _} = fold([playing(1), pickup(2, @wrench), pickup(3, @wrench, name: "Wrench"), pickup(4, @wrench, name: "Spanner", type: "CC_Wrench")])
      d = view(inst)
      assert d.picked_up == 3 and d.occurrences == 3 and d.definitions_used == [@wrench]
      assert [%{picked_up: 3, item_name: "Wrench", item_type: "CC_Wrench"}] = d.by_definition
      assert from_facts(inst) == d
    end

    test "a definition the engine never named is shown by its short id; an empty name does not count as a name" do
      {inst, _} = fold([playing(1), pickup(2, @cleaver), thrown(3, @cleaver, name: "")])
      d = view(inst)
      assert [%{item_name: nil, item_type: nil}] = d.by_definition
      assert items_line(inst) == "    items (engine telemetry): picked up 1 — 1bbf0ed5…; thrown 1 — 1bbf0ed5…; removed from inventory 0; 1 definition; history intact"
    end

    test "an instance id the engine named is kept on the fact and changes no count" do
      {inst, _} = fold([playing(1), pickup(2, @wrench, instance: "9a3f1dbb-6f6e-4d7b-9a51-2f0c1a7b4e21"), pickup(3, @wrench)])
      [a, b] = hd(inst.attempts).item_events
      assert a.payload.item_instance_id == "9a3f1dbb-6f6e-4d7b-9a51-2f0c1a7b4e21" and b.payload.item_instance_id == nil
      assert view(inst).picked_up == 2 and length(view(inst).by_definition) == 1
    end

    test "an attempt with no item event at all" do
      {inst, _} = fold([playing(1), died(2)])
      assert view(inst) == %{picked_up: 0, thrown: 0, removed_from_inventory: 0, by_definition: [], definitions_used: [], history: :complete, occurrences: 0}
      assert items_line(inst) == "    items (engine telemetry): none observed in the attempt"
    end

    test "item occurrences, disguise occurrences and actor outcomes interleave in one sequence and stay apart" do
      {inst, _} = fold([playing(1), pickup(2, @wrench), change(3, "2018db77-aa8a-4bf9-9afb-56bdaa161156"), removed(4, @wrench), thrown(5, @wrench), died(6), pickup(7, @wrench)])
      [a] = inst.attempts
      assert Enum.map(a.item_events, & &1.sequence) == [2, 4, 5, 7]
      assert Enum.map(a.disguise_events, & &1.sequence) == [3]
      assert Enum.map(a.outcomes, & &1.sequence) == [6]
      assert view(inst).picked_up == 2 and view(inst).thrown == 1 and view(inst).removed_from_inventory == 1
      assert Disguise.derive(a, inst).changes == 1
    end
  end

  describe "SYN: gaps and interruptions (incomplete history; counts never infer)" do
    test "a gap inside the attempt marks the history incomplete; the counts are what arrived" do
      {inst, notes} = fold([playing(1), pickup(2, @wrench), removed(3, @wrench), thrown(6, @wrench)])
      assert {:gap, 4, 6} in notes
      d = view(inst)
      assert d.history == {:incomplete, [{:gap, 4, 6}]}
      assert d.picked_up == 1 and d.removed_from_inventory == 1 and d.thrown == 1
      assert items_line(inst) =~ "; 1 definition; history broken: gap 4→6"
      assert from_facts(inst) == d
    end

    test "an interruption inside the attempt marks it incomplete; occurrences after the reconnect still count" do
      at = ~U[2026-10-09 03:05:00Z]
      inst = identified(Lifecycle.new(@id))
      {inst, _} = fold([playing(1), pickup(2, @wrench), {:close, at}, {:reopen, at}, thrown(3, @wrench)], inst)
      d = view(inst)
      assert hd(inst.attempts).interruptions == [%{at: at, reason: :peer_closed, after_sequence: 2}]
      assert d.history == {:incomplete, [{:interruption, at, :peer_closed}]}
      assert d.picked_up == 1 and d.thrown == 1
      assert items_line(inst) =~ "history broken: observation lost 2026-10-09T03:05:00Z (:peer_closed)"
      assert from_facts(inst) == d
    end

    test "TCP close with no reconnect: facts frozen, history incomplete, counts unchanged" do
      at = ~U[2026-10-09 03:09:00Z]
      inst = identified(Lifecycle.new(@id))
      {inst, _} = fold([playing(1), pickup(2, @wrench), pickup(3, @crowbar), {:close, at}], inst)
      assert Lifecycle.observation(inst) == :lost
      d = view(inst)
      assert d.picked_up == 2 and d.history == {:incomplete, [{:interruption, at, :peer_closed}]}
      assert text(inst) =~ "stop not observed; last known playing"
      assert from_facts(inst) == d
    end

    test "a superseded attempt reports it in its history" do
      {inst, _} = fold([playing(1), pickup(2, @wrench), playing(3)])
      assert view(inst, 1).history == {:incomplete, [{:superseded, 2, 3}]} and view(inst, 1).picked_up == 1
      assert hd(inst.attempts).superseded_at == 3 and hd(inst.attempts).stopped == nil
      assert view(inst, 2).history == :complete and view(inst, 2).occurrences == 0
      assert text(inst) =~ "history broken: superseded by attempt 2 at #3"
    end
  end

  describe "SYN: attempt boundaries" do
    test "item events after the stop with no attempt open are unattributed, never attached by adjacency" do
      {inst, notes} = fold([playing(1), pickup(2, @wrench), stopped(3), thrown(4, @wrench), removed(5, @wrench)])
      assert {:unattributed_item_event, 4} in notes and {:unattributed_item_event, 5} in notes
      assert Enum.map(inst.unattributed_item_events, & &1.sequence) == [4, 5]
      assert Enum.map(hd(inst.attempts).item_events, & &1.sequence) == [2]
      assert view(inst).picked_up == 1 and view(inst).thrown == 0 and view(inst).removed_from_inventory == 0
      t = text(inst)
      assert t =~ "  item thrown 6adddf7e… #4 @1.0s with no open attempt"
      assert t =~ "  item removed from inventory 6adddf7e… #5 @1.0s with no open attempt"

      {inst, notes} = fold([pickup(1, @wrench)])
      assert notes == [{:unattributed_item_event, 1}] and inst.attempts == []
    end

    test "an occurrence right before the stop is attached; a restart starts the new attempt from nothing" do
      {inst, _} = fold([playing(1), pickup(2, @wrench), removed(3, @wrench), thrown(4, @wrench), stopped(5), playing(6), pickup(7, @crowbar)])
      assert Enum.map(hd(inst.attempts).item_events, & &1.sequence) == [2, 3, 4]
      assert view(inst, 1).thrown == 1 and view(inst, 1).definitions_used == [@wrench]
      assert view(inst, 2).picked_up == 1 and view(inst, 2).thrown == 0 and view(inst, 2).definitions_used == [@crowbar]
      assert view(inst, 2).history == :complete
    end
  end

  describe "regression: a superseded attempt is bounded by the rise that superseded it (63184c4, for items)" do
    test "the boundary gap stays with the superseded attempt; a later gap does not arrive" do
      {inst, _} = fold([playing(1), pickup(2, @wrench), thrown(3, @wrench), playing(5), pickup(6, @crowbar), thrown(9, @crowbar)])
      assert inst.gaps == [{7, 9}, {4, 5}]
      [a1, _a2] = inst.attempts
      assert a1.mission == :superseded and a1.stopped == nil and a1.superseded_by == 2 and a1.superseded_at == 5

      d1 = view(inst, 1)
      assert d1.history == {:incomplete, [{:gap, 4, 5}, {:superseded, 2, 5}]}
      assert d1.picked_up == 1 and d1.thrown == 1 and d1.definitions_used == [@wrench]
      assert from_facts(inst, 1) == d1

      d2 = view(inst, 2)
      assert d2.history == {:incomplete, [{:gap, 7, 9}]}
      assert d2.picked_up == 1 and d2.thrown == 1 and d2.definitions_used == [@crowbar]
      assert from_facts(inst, 2) == d2

      # Both views bound the same way: the shared helper gives the disguise view the same history.
      assert Disguise.derive(a1, inst).history == d1.history
      assert AttemptHistory.gaps_in_attempt(inst.gaps, a1) == [{4, 5}]
    end

    test "supersession without a boundary gap: evidence up to the rise is intact" do
      {inst, _} = fold([playing(1), pickup(2, @wrench), playing(3), pickup(4, @crowbar), thrown(7, @crowbar)])
      d1 = view(inst, 1)
      assert d1.history == {:incomplete, [{:superseded, 2, 3}]} and d1.picked_up == 1
      assert view(inst, 2).history == {:incomplete, [{:gap, 5, 7}]}
      assert from_facts(inst, 1) == d1
    end

    test "chained supersessions: each attempt keeps only the gaps up to its own boundary" do
      {inst, _} = fold([playing(1), pickup(2, @wrench), playing(3), pickup(4, @crowbar), playing(6), pickup(7, @knife), thrown(10, @knife)])
      assert inst.gaps == [{8, 10}, {5, 6}]
      assert view(inst, 1).history == {:incomplete, [{:superseded, 2, 3}]}
      assert view(inst, 2).history == {:incomplete, [{:gap, 5, 6}, {:superseded, 3, 6}]}
      assert view(inst, 3).history == {:incomplete, [{:gap, 8, 10}]}
      assert Enum.map(1..3, &view(inst, &1).definitions_used) == [[@wrench], [@crowbar], [@knife]]
      for n <- 1..3, do: assert(from_facts(inst, n) == view(inst, n))
    end

    test "ordinary stopped attempts are bounded by their stop; a gap between attempts belongs to neither" do
      {inst, _} = fold([playing(1), pickup(2, @wrench), stopped(3), playing(4), pickup(5, @crowbar), thrown(8, @crowbar)])
      assert view(inst, 1).history == :complete
      assert view(inst, 2).history == {:incomplete, [{:gap, 6, 8}]}

      {inst, _} = fold([playing(1), pickup(2, @wrench), stopped(4), playing(6)])
      assert view(inst, 1).history == {:incomplete, [{:gap, 3, 4}]}
      assert view(inst, 2).history == :complete
      assert inst.gaps == [{5, 6}, {3, 4}]
    end

    test "extending later attempts leaves earlier derived views unchanged" do
      base = [playing(1), pickup(2, @wrench), thrown(3, @wrench), playing(5)]
      {inst, _} = fold(base)
      frozen = view(inst, 1)

      extensions = [pickup(6, @crowbar), removed(9, @crowbar), thrown(10, @crowbar), stopped(12), playing(14), pickup(15, @wrench), thrown(18, @wrench)]

      Enum.reduce(extensions, inst, fn e, acc ->
        {acc, _} = fold([e], acc)
        assert view(acc, 1) == frozen
        acc
      end)
    end
  end

  describe "replay equivalence" do
    test "the view is a function of the facts on every stream, including the incomplete ones" do
      at = ~U[2026-10-09 03:05:00Z]

      streams = [
        [playing(1)] ++ b0_stream(2) ++ [stopped(26)],
        [playing(1), pickup(2, @wrench), removed(3, @wrench), thrown(6, @wrench)],
        [playing(1), pickup(2, @wrench), {:close, at}, {:reopen, at}, thrown(3, @wrench), pickup(4, @crowbar)],
        [playing(1), thrown(2, @wrench), removed(3, @crowbar), pickup(4, @wrench), {:close, at}],
        [playing(1), pickup(2, @wrench), playing(3), pickup(4, @crowbar), thrown(7, @crowbar)],
        [playing(1), pickup(2, @wrench), stopped(3), thrown(4, @wrench)],
        [playing(1), died(2), change(3, "2018db77-aa8a-4bf9-9afb-56bdaa161156")]
      ]

      for steps <- streams do
        inst = identified(Lifecycle.new(@id))
        {inst, _} = fold(steps, inst)
        for n <- 1..length(inst.attempts), do: assert(from_facts(inst, n) == view(inst, n))

        # Every prefix: the facts folded so far are a prefix of the final facts, and the view of
        # the final stream never contradicts the occurrences a prefix already holds.
        final = hd(inst.attempts).item_events

        for n <- 1..length(steps) do
          prefix = identified(Lifecycle.new(@id))
          {prefix, _} = fold(Enum.take(steps, n), prefix)

          case prefix.attempts do
            [] -> :ok
            [attempt | _] -> assert attempt.item_events == Enum.take(final, length(attempt.item_events))
          end
        end
      end
    end
  end

  describe "summary wording" do
    test "the item line never says inventory contents, holding, carried, owns, recovered, lost or throws; drops and destroys are not shown" do
      at = ~U[2026-10-09 03:05:00Z]
      inst = identified(Lifecycle.new(@id))
      {inst, _} = fold([playing(1)] ++ b0_stream(2) ++ [{:close, at}], inst)
      line = items_line(inst)
      [facts, history] = String.split(line, "; history ")
      refute facts =~ @forbidden
      refute facts =~ ~r/\blost\b/
      refute line =~ ~r/dropped|destroyed|none observed|pair/i
      assert history =~ "broken: observation lost"
      assert facts =~ "removed from inventory 6"

      {inst, _} = fold([playing(1)])
      refute items_line(inst) =~ @forbidden
    end
  end
end

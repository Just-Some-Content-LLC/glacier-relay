defmodule GlacierRelay.Command.CandidateInspectionTest do
  @moduledoc """
  M6-D1a: `relay.inspect.candidate` v1 through the real command subtree against the fake native
  peer: the schema entry (inert, identified trust, no reversal, the same two optional ids as the
  entity inspection and nothing else — no spawn id, no address), the welcome's allowlist, the
  operator facade, the refusal while disarmed and the acceptance after inert arming, the result's
  field objects decoded strictly and reported as a native read-back (never an independent
  observation), the packed-group grammar decoded by `Command.CandidateReadback` (and refused when
  malformed), missing components kept as unavailable (never absent by assumption), the spawn-to-
  hero reference preserved, registry membership by identity represented exactly as the native
  side classified it, the reduction markers tolerated, link loss handled by the existing status
  ladder, and the journal correlation. The fake peer is never evidence of native game execution;
  nothing here is a second Hitman, placed, visible, simulated or controlled.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{CandidateReadback, Journal, Listener, Schema}
  alias GlacierRelay.Test.{FakeNative, FixturePlayer}

  @suit "874c4c48-0a8b-49e9-883e-49fc5f1fb051"
  @gen1 "2516103582917844185-a105ec5f-3a75-46a3-8ecd-e72fd15b176c"
  @hitmen_brick "007c57a6ea581f8c"
  @agent48 "feede715906f747f"
  @agent48_spawn "feed755acdd56780"
  @hero_id "feed9a0d70d546f4"
  @parent "0000000000000001"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-candidate-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)

    start_supervised!(
      {Command.Supervisor,
       [
         port: 0,
         journal_dir: dir,
         ack_timeout_ms: 300,
         grace_ms: 200,
         default_ttl_ms: 500,
         min_ttl_ms: 50,
         hello_timeout_ms: 400
       ]}
    )

    %{port: Listener.port(), dir: dir}
  end

  defp wait(fun), do: FixturePlayer.wait_until(fun, 100, 10)

  defp field(status, value \\ nil, reason \\ nil) do
    %{"status" => status}
    |> then(&if(value != nil, do: Map.put(&1, "value", value), else: &1))
    |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))
  end

  # A hero's state as the native encoder writes it (the grammar of CandidateObservation.h).
  defp hero_fields(prefix, world, opts \\ []) do
    members =
      Keyword.get(
        opts,
        :members,
        "character=2,animator=1,morpheme=1,ragdoll=2,health=1,kit=2,camera=2,input=1"
      )

    %{
      "#{prefix}_world" => field("observed", world),
      "#{prefix}_local" => field("observed", "0,0,0|0,0,0,1"),
      "#{prefix}_parent" => field("observed", @parent),
      "#{prefix}_spatial_flags" =>
        field(
          "observed",
          Keyword.get(
            opts,
            :flags,
            "visible=1,parent_hidden=0,force_visible=0,dynamic=1,scene_child=0,dirty=0,room=1,tparent=1,tchildren=1"
          )
        ),
      "#{prefix}_members" => field("observed", members),
      "#{prefix}_controllers" =>
        field("observed", "guide=2,ik=2,cheat=2,interaction=2,actor_tag=2"),
      "#{prefix}_outfit" => field("observed", "#{@suit},0,0"),
      "#{prefix}_active" => field("observed", Keyword.get(opts, :active, true))
    }
  end

  # The 47-entry read-back of a stable Paris frame with the candidate present and resolved, as
  # the native scheduler orders it (FAKE values; never an observation).
  defp candidate_observed do
    %{
      "mission_playing" => field("observed", true),
      "scene_type" => field("observed", "mission"),
      "receipt_to_frame_ms" => field("observed", 3),
      "generation_fresh" => field("observed", @gen1),
      "hero_entity_id" => field("observed", @hero_id),
      "hero_flags" => field("observed", 3),
      "brick_count" => field("observed", 24),
      "bricks_scanned" => field("observed", 24),
      "targets" => field("observed", "#{@hitmen_brick},#{@agent48},#{@agent48_spawn}"),
      "cand_brick_present" => field("observed", true),
      "cand_subentity_count" => field("observed", 3),
      "cand_index" => field("observed", 1),
      "cand_index_check" => field("observed", "in_range"),
      "cand_resolved" => field("observed", true),
      "cand_hitman5" => field("observed", true),
      "cand_flags" => field("observed", 3),
      "cand_id_match" => field("observed", true),
      "cand_distinct" => field("observed", true),
      "cand_brick_owner" => field("observed", @hitmen_brick),
      "registry_slots" => field("observed", "0:local,1:empty,2:empty,3:empty"),
      "spawn_index" => field("observed", 2),
      "spawn_index_check" => field("observed", "in_range"),
      "spawn_resolved" => field("observed", true),
      "spawn_class" => field("observed", "ZHeroSpawn"),
      "spawn_world" => field("observed", "-40.99882,-24.29366,0.4925565"),
      "spawn_dirty" => field("observed", false),
      "spawn_player_id" => field("observed", 2),
      "spawn_select" => field("observed", "default=0,preferred=0"),
      "spawn_hitman_ref" => field("observed", @agent48),
      "spawn_ref_is_cand" => field("observed", true),
      "reads_on_frame" => field("observed", true)
    }
    |> Map.merge(hero_fields("cand", "0,0,-1.539356"))
    |> Map.merge(hero_fields("hero", "-109.5881,-89.883,-0.536"))
  end

  defp journal_entries do
    %{path: path} = Journal.status()
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  test "the schema carries the entry as inert, identified, read-only, with exactly the two content ids and no spawn id" do
    entry = Schema.entry("relay.inspect.candidate", 1)
    assert entry.issuable and entry.effect == :none and entry.trust == :identified
    assert entry.reversal == :none and entry.preconditions == []
    assert {:ok, %{}} = Schema.validate_params(entry, %{})

    assert {:ok, %{"brick" => @hitmen_brick, "entity_id" => @agent48}} =
             Schema.validate_params(entry, %{"brick" => @hitmen_brick, "entity_id" => @agent48})

    assert {:error, {:unknown_params, ["spawn_id"]}} =
             Schema.validate_params(entry, %{"spawn_id" => @agent48_spawn})

    assert {:error, {:unknown_params, ["address"]}} =
             Schema.validate_params(entry, %{"address" => "0x14313dac0"})

    assert {:error, {:unknown_params, ["method"]}} =
             Schema.validate_params(entry, %{"method" => "GetObjectToWorldMatrix"})

    assert {:error, {:invalid_param, "entity_id", :not_16_lowercase_hex_digits}} =
             Schema.validate_params(entry, %{"entity_id" => "FEEDE715906F747F"})

    assert Enum.map(Schema.issuable(), & &1["name"]) == [
             "relay.inspect.candidate",
             "relay.inspect.entity",
             "relay.inspect.outfit",
             "relay.inspect.players",
             "relay.probe"
           ]

    assert Schema.issuable_for(1, ["relay.inspect.candidate/1"], true) == Schema.issuable()
    refute Enum.any?(Schema.issuable(), &(&1["name"] == "player.outfit.set"))
  end

  test "the read-back grammar decodes strictly and refuses what does not match it" do
    assert {:ok, {0.0, 0.0, -1.539356}} =
             CandidateReadback.field(field("observed", "0,0,-1.539356"), :vec3)

    assert {:ok, {-40.99882, -24.29366, 0.4925565}} =
             CandidateReadback.field(field("observed", "-40.99882,-24.29366,0.4925565"), :vec3)

    assert {:ok, {1.0e10, 0.0, -1.0}} =
             CandidateReadback.field(field("observed", "1e+10,0,-1"), :vec3)

    assert {:invalid, "0,0"} = CandidateReadback.field(field("observed", "0,0"), :vec3)
    assert {:invalid, "a,b,c"} = CandidateReadback.field(field("observed", "a,b,c"), :vec3)

    assert {:ok, %{translation: {0.0, 0.0, 0.0}, rotation: {0.0, 0.0, 0.0, 1.0}}} =
             CandidateReadback.field(field("observed", "0,0,0|0,0,0,1"), :local)

    assert {:invalid, _} = CandidateReadback.field(field("observed", "0,0,0|0,0,0"), :local)
    assert {:ok, :none} = CandidateReadback.field(field("observed", "none"), :parent)
    assert {:ok, @parent} = CandidateReadback.field(field("observed", @parent), :parent)
    assert {:invalid, "0x12"} = CandidateReadback.field(field("observed", "0x12"), :parent)

    assert {:ok, flags} =
             CandidateReadback.field(
               field(
                 "observed",
                 "visible=1,parent_hidden=0,force_visible=0,dynamic=1,scene_child=0,dirty=1,room=2,tparent=1,tchildren=0"
               ),
               :spatial_flags
             )

    assert flags == %{
             visible: true,
             parent_hidden: false,
             force_visible: false,
             dynamic: true,
             scene_child: false,
             dirty: true,
             room: 2,
             tparent: true,
             tchildren: false
           }

    # a reordered, renamed or truncated group is not the grammar
    assert {:invalid, _} =
             CandidateReadback.field(
               field(
                 "observed",
                 "dirty=1,visible=1,parent_hidden=0,force_visible=0,dynamic=1,scene_child=0,room=2,tparent=1,tchildren=0"
               ),
               :spatial_flags
             )

    assert {:invalid, _} = CandidateReadback.field(field("observed", "visible=1"), :spatial_flags)

    assert {:ok, members} =
             CandidateReadback.field(
               field(
                 "observed",
                 "character=2,animator=1,morpheme=0,ragdoll=2,health=1,kit=2,camera=0,input=1"
               ),
               :members
             )

    assert members == %{
             character: :valid,
             animator: :present,
             morpheme: :null,
             ragdoll: :valid,
             health: :present,
             kit: :valid,
             camera: :null,
             input: :present
           }

    assert {:invalid, _} =
             CandidateReadback.field(
               field(
                 "observed",
                 "character=3,animator=1,morpheme=0,ragdoll=2,health=1,kit=2,camera=0,input=1"
               ),
               :members
             )

    assert {:ok,
            %{guide: :valid, ik: :valid, cheat: :null, interaction: :present, actor_tag: :valid}} =
             CandidateReadback.field(
               field("observed", "guide=2,ik=2,cheat=0,interaction=1,actor_tag=2"),
               :controllers
             )

    assert {:ok, %{kit_id: @suit, charset: 0, variation: 3}} =
             CandidateReadback.field(field("observed", "#{@suit},0,3"), :outfit)

    assert {:ok, %{kit_id: :none, charset: 1, variation: 0}} =
             CandidateReadback.field(field("observed", "none,1,0"), :outfit)

    assert {:invalid, _} = CandidateReadback.field(field("observed", "suit,0,0"), :outfit)

    assert {:ok, %{default: false, preferred: true}} =
             CandidateReadback.field(field("observed", "default=0,preferred=1"), :select)

    assert {:ok, slots} =
             CandidateReadback.field(
               field("observed", "0:local,1:candidate-nohero,2:other,3:empty"),
               :slots
             )

    # (the first expectation here read the empty slot as hero: true — the decoder defect of the
    # M6-D1a review, correction A; an empty slot has no reference and no hero)
    assert slots == [
             %{slot: 0, match: :local, hero: true},
             %{slot: 1, match: :candidate, hero: false},
             %{slot: 2, match: :other, hero: true},
             %{slot: 3, match: :empty, hero: false}
           ]

    assert {:ok, [_, %{match: :inconclusive}, _, _]} =
             CandidateReadback.field(
               field("observed", "0:local,1:inconclusive,2:empty,3:empty"),
               :slots
             )

    assert {:invalid, _} =
             CandidateReadback.field(field("observed", "0:local,1:empty,2:empty"), :slots)

    assert {:invalid, _} =
             CandidateReadback.field(
               field("observed", "0:local,1:agent48,2:empty,3:empty"),
               :slots
             )

    assert {:invalid, _} =
             CandidateReadback.field(field("observed", "1:local,0:empty,2:empty,3:empty"), :slots)

    assert {:ok, %{brick: @hitmen_brick, entity: @agent48, spawn: @agent48_spawn}} =
             CandidateReadback.field(
               field("observed", "#{@hitmen_brick},#{@agent48},#{@agent48_spawn}"),
               :targets
             )

    # statuses other than observed decode to the status, never to a default
    assert {:unobserved, "unavailable"} =
             CandidateReadback.field(field("unavailable", nil, "brick not loaded"), :members)

    assert {:unobserved, "unsupported"} =
             CandidateReadback.field(
               field("unsupported", nil, "property has an engine getter"),
               :bool
             )

    assert :missing = CandidateReadback.field(nil, :vec3)
    assert nil == CandidateReadback.value(field("unavailable"), :vec3)
    assert {0.0, 0.0, 0.0} == CandidateReadback.value(field("observed", "0,0,0"), :vec3)

    assert CandidateReadback.entity_flags(3) == %{
             initialized: true,
             postinitialized: true,
             activated: false,
             predeleted: false,
             editmode: false,
             readonly_flag_set: false,
             readonly: false
           }

    assert CandidateReadback.entity_flags(12).activated and
             CandidateReadback.entity_flags(12).predeleted

    assert CandidateReadback.entity_flags("3") == :invalid
  end

  test "registry slots decode with the hero boolean meaning a resolved hero interface on a nonempty reference: empty slots carry none (M6-D1a review, correction A)" do
    decode = fn text -> CandidateReadback.field(field("observed", text), :slots) end
    e = fn i -> %{slot: i, match: :empty, hero: false} end

    # all four slots empty: no reference anywhere, no hero anywhere
    assert decode.("0:empty,1:empty,2:empty,3:empty") == {:ok, [e.(0), e.(1), e.(2), e.(3)]}

    # the M6-C3 shape: the local hero in slot 0, the other three empty
    assert decode.("0:local,1:empty,2:empty,3:empty") ==
             {:ok, [%{slot: 0, match: :local, hero: true}, e.(1), e.(2), e.(3)]}

    # the candidate in an additional slot, with and without a resolved hero interface
    assert decode.("0:local,1:candidate,2:empty,3:empty") ==
             {:ok,
              [
                %{slot: 0, match: :local, hero: true},
                %{slot: 1, match: :candidate, hero: true},
                e.(2),
                e.(3)
              ]}

    assert decode.("0:local,1:candidate-nohero,2:empty,3:empty") ==
             {:ok,
              [
                %{slot: 0, match: :local, hero: true},
                %{slot: 1, match: :candidate, hero: false},
                e.(2),
                e.(3)
              ]}

    # nonempty references whose hero interface did not resolve, in every identity class
    assert decode.("0:local-nohero,1:other-nohero,2:inconclusive-nohero,3:candidate-nohero") ==
             {:ok,
              [
                %{slot: 0, match: :local, hero: false},
                %{slot: 1, match: :other, hero: false},
                %{slot: 2, match: :inconclusive, hero: false},
                %{slot: 3, match: :candidate, hero: false}
              ]}

    # the candidate's identity unknown on that frame: inconclusive stays its own classification
    assert decode.("0:local,1:inconclusive,2:other,3:empty") ==
             {:ok,
              [
                %{slot: 0, match: :local, hero: true},
                %{slot: 1, match: :inconclusive, hero: true},
                %{slot: 2, match: :other, hero: true},
                e.(3)
              ]}

    # the whole group unavailable or absent: nothing is synthesized
    assert {:unobserved, "unavailable"} =
             CandidateReadback.field(
               field("unavailable", nil, "player registry global null"),
               :slots
             )

    assert :missing = CandidateReadback.field(nil, :slots)
    assert CandidateReadback.decode_readback(%{}).registry_slots == :missing

    # malformed suffixes and shapes are refused whole, never partially decoded
    for bad <- [
          "0:local,1:empty-nohero,2:empty,3:empty",
          "0:local,1:candidate-nohero-nohero,2:empty,3:empty",
          "0:local,1:-nohero,2:empty,3:empty",
          "0:local,1:candidate-nohero-,2:empty,3:empty",
          "0:local,1:candidatenohero,2:empty,3:empty",
          "0:local,1:candidate-NOHERO,2:empty,3:empty",
          "1:local,0:empty,2:empty,3:empty",
          "0:local,1:empty,2:empty,3:empty,4:empty",
          "0:local,1:empty,2:empty",
          "0:local,1:agent48,2:empty,3:empty",
          "0:Local,1:empty,2:empty,3:empty",
          ""
        ] do
      assert {:invalid, ^bad} = decode.(bad)
    end
  end

  test "a candidate inspection is refused while disarmed, travels with its ids after inert arming, and comes back as a native read-back decoded by the grammar",
       %{port: port} do
    {socket, adapter, welcome} =
      FakeNative.handshake(port, Schema.uuid4(),
        capabilities: [
          "relay.probe/1",
          "relay.inspect.outfit/1",
          "relay.inspect.players/1",
          "relay.inspect.entity/1",
          "relay.inspect.candidate/1"
        ],
        mission_generation: @gen1
      )

    assert Enum.map(welcome["allowlist"], & &1["name"]) == [
             "relay.inspect.candidate",
             "relay.inspect.entity",
             "relay.inspect.outfit",
             "relay.inspect.players",
             "relay.probe"
           ]

    refute Enum.any?(welcome["allowlist"], &(&1["name"] == "player.outfit.set"))
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert {:error, :disarmed} = Command.inspect_candidate()
    assert {:error, :timeout} = FakeNative.recv(socket, 150)
    assert :ok = Command.arm()
    s = Command.status()
    assert s.trust.armed and not s.trust.effectful_armed and s.effectful.enabled == false

    assert {:ok, id} =
             Command.inspect_candidate(%{"brick" => @hitmen_brick, "entity_id" => @agent48},
               ttl_ms: 400
             )

    assert {:ok, cmd} = FakeNative.recv(socket)

    assert cmd["name"] == "relay.inspect.candidate" and cmd["version"] == 1 and
             cmd["command_id"] == id and cmd["preconditions"] == %{} and
             cmd["params"] == %{"brick" => @hitmen_brick, "entity_id" => @agent48}

    observed = candidate_observed()
    assert map_size(observed) == 47

    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" => observed,
      "frame" => 33742,
      "mission_generation" => @gen1
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    c = Command.command(id)
    assert c.observed == :native and c.independent_observation == :not_available
    assert c.result.mission_generation == @gen1 and c.result.frame == 33742
    assert map_size(c.result.observed) == 47
    assert Enum.map(c.stages, &elem(&1, 0)) == [:accepted, :transmitted, :received, :applied]

    d = CandidateReadback.decode_readback(c.result.observed)
    assert d.hero_entity_id == {:ok, @hero_id} and d.hero_flags == {:ok, 3}
    assert d.targets == {:ok, %{brick: @hitmen_brick, entity: @agent48, spawn: @agent48_spawn}}
    assert d.cand_brick_present == {:ok, true} and d.cand_index == {:ok, 1}
    assert d.cand_index_check == {:ok, "in_range"} and d.cand_resolved == {:ok, true}
    assert d.cand_hitman5 == {:ok, true} and d.cand_id_match == {:ok, true}
    assert d.cand_distinct == {:ok, true} and d.cand_brick_owner == {:ok, @hitmen_brick}

    assert {:ok,
            [
              %{slot: 0, match: :local, hero: true},
              %{slot: 1, match: :empty, hero: false},
              %{slot: 2, match: :empty, hero: false},
              %{slot: 3, match: :empty, hero: false}
            ]} = d.registry_slots

    assert d.candidate.world == {:ok, {0.0, 0.0, -1.539356}}
    assert d.hero.world == {:ok, {-109.5881, -89.883, -0.536}}
    assert {:ok, %{character: :valid, input: :present}} = d.candidate.members
    assert d.candidate.active == {:ok, true} and d.hero.active == {:ok, true}
    assert d.spawn.class == {:ok, "ZHeroSpawn"} and d.spawn.player_id == {:ok, 2}
    assert d.spawn.select == {:ok, %{default: false, preferred: false}}
    assert d.spawn.hitman_ref == {:ok, @agent48} and d.spawn.ref_is_cand == {:ok, true}
    assert d.spawn.world == {:ok, {-40.99882, -24.29366, 0.4925565}}
    assert d.reads_on_frame == {:ok, true} and d.reduced == false

    # the journal correlates the request and its terminal result, labelled native
    entries = journal_entries()
    accepted = Enum.find(entries, &(&1["event"] == "command.accepted" and &1["command_id"] == id))
    assert accepted["name"] == "relay.inspect.candidate" and accepted["version"] == 1
    terminal = Enum.find(entries, &(&1["event"] == "command.terminal" and &1["command_id"] == id))

    assert terminal["status"] == "applied" and terminal["observed_label"] == "native" and
             terminal["observed"]["registry_slots"]["value"] == "0:local,1:empty,2:empty,3:empty" and
             terminal["mission_generation"] == @gen1 and terminal["frame"] == 33742

    assert Command.status().counters.issued == 1 and Command.status().counters.refused == 1
    assert :ok = Command.disarm()
    FakeNative.close(socket)
  end

  test "missing components stay unavailable, the spawn-to-hero reference and the slot identity come back verbatim, and the reduction markers are tolerated",
       %{port: port} do
    {socket, adapter, _welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert :ok = Command.arm()

    # the candidate resolved without a ZHitman5 interface: the members, controllers, outfit and
    # property are unavailable — not "character=0"; its spawn references another entity; slot 1
    # holds the candidate without a resolved hero; the native side dropped the reasons to fit
    observed =
      candidate_observed()
      |> Map.merge(%{
        "cand_hitman5" => field("observed", false),
        "cand_members" => field("unavailable"),
        "cand_controllers" => field("unavailable"),
        "cand_outfit" => field("unavailable"),
        "cand_active" => field("unavailable"),
        "spawn_hitman_ref" => field("observed", "feed000000000bad"),
        "spawn_ref_is_cand" => field("observed", false),
        "registry_slots" => field("observed", "0:local,1:candidate-nohero,2:empty,3:empty"),
        "reasons_dropped" => true
      })

    assert map_size(observed) == 48
    assert {:ok, id} = Command.inspect_candidate()
    assert {:ok, cmd} = FakeNative.recv(socket)
    assert cmd["params"] == %{}

    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" => observed,
      "frame" => 37838,
      "mission_generation" => @gen1,
      "reason" => "field reasons dropped to fit the result line bound"
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    c = Command.command(id)
    assert c.result.observed["reasons_dropped"] == true
    assert c.result.reason == "field reasons dropped to fit the result line bound"
    d = CandidateReadback.decode_readback(c.result.observed)
    assert d.reduced == true
    assert d.cand_hitman5 == {:ok, false}
    assert d.candidate.members == {:unobserved, "unavailable"}
    assert d.candidate.active == {:unobserved, "unavailable"}
    assert d.candidate.world == {:ok, {0.0, 0.0, -1.539356}}
    assert d.spawn.hitman_ref == {:ok, "feed000000000bad"} and d.spawn.ref_is_cand == {:ok, false}

    assert {:ok,
            [
              %{slot: 0, match: :local, hero: true},
              %{slot: 1, match: :candidate, hero: false},
              %{slot: 2, match: :empty, hero: false},
              %{slot: 3, match: :empty, hero: false}
            ]} = d.registry_slots

    # the player id 2 on the spawn is not a registry classification
    assert d.spawn.player_id == {:ok, 2}
    FakeNative.close(socket)
  end

  test "a malformed packed group from the peer is accepted by the link as text and refused by the decoder, never partially decoded",
       %{port: port} do
    {socket, adapter, _welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert :ok = Command.arm()
    assert {:ok, id} = Command.inspect_candidate()
    assert {:ok, cmd} = FakeNative.recv(socket)

    observed =
      candidate_observed()
      |> Map.merge(%{
        "cand_members" => field("observed", "character=2,animator=1"),
        "registry_slots" => field("observed", "0:local,1:agent48,2:empty,3:empty"),
        "cand_world" => field("observed", "0,0")
      })

    FakeNative.respond(socket, cmd, adapter, "applied", %{"observed" => observed, "frame" => 7})
    assert wait(fn -> Command.command(id).status == :applied end)
    d = CandidateReadback.decode_readback(Command.command(id).result.observed)
    assert d.candidate.members == {:invalid, "character=2,animator=1"}
    assert d.registry_slots == {:invalid, "0:local,1:agent48,2:empty,3:empty"}
    assert d.candidate.world == {:invalid, "0,0"}
    assert d.hero.world == {:ok, {-109.5881, -89.883, -0.536}}
    FakeNative.close(socket)
  end

  test "link loss while the inspection is in flight goes through the existing status ladder", %{
    port: port
  } do
    {socket, _adapter, _welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert :ok = Command.arm()
    assert {:ok, id} = Command.inspect_candidate(%{}, ttl_ms: 400)
    assert {:ok, _cmd} = FakeNative.recv(socket)
    FakeNative.close(socket)
    assert wait(fn -> Command.command(id).status == :unknown end)
    assert Command.command(id).unknown_reason in [:link_lost, :ack_timeout]
    assert wait(fn -> Command.status().link == nil end)
    assert "link.closed" in Enum.map(journal_entries(), & &1["event"])
    refute Command.status().trust.armed
  end

  test "invalid ids and unknown parameters are refused before anything is transmitted, and the effectful authority is untouched",
       %{port: port} do
    {socket, _adapter, _welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert :ok = Command.arm()

    assert {:error, {:invalid_param, "brick", :not_16_lowercase_hex_digits}} =
             Command.inspect_candidate(%{"brick" => "0x14313dac0"})

    assert {:error, {:unknown_params, ["spawn_id"]}} =
             Command.inspect_candidate(%{"spawn_id" => @agent48_spawn})

    assert {:error, {:unknown_params, ["offset"]}} =
             Command.inspect_candidate(%{"offset" => 1816})

    assert {:error, _} =
             Command.set_outfit(%{
               "disguise_repository_id" => @suit,
               "charset" => 0,
               "variation" => 0,
               "expect_current" => %{
                 "disguise_repository_id" => "4fc9396e-2619-4e66-a51e-2bd366230da7",
                 "charset" => 0,
                 "variation" => 0
               }
             })

    assert {:error, _} = Command.arm_effectful(ownership: %{})
    assert {:error, :timeout} = FakeNative.recv(socket, 200)
    assert Command.status().counters.issued == 0
    s = Command.status()
    assert s.effectful.enabled == false and s.trust.effectful_armed == false
    FakeNative.close(socket)
  end
end

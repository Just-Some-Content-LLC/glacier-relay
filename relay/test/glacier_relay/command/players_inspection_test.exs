defmodule GlacierRelay.Command.PlayersInspectionTest do
  @moduledoc """
  M6-B1: `relay.inspect.players` v1 and `relay.inspect.entity` v1 through the real command subtree
  against the fake native peer: the schema entries (inert, identified trust, no reversal), the
  entity entry's two optional 16-hex-digit parameters and the players entry's none, the welcome's
  allowlist, the operator facade, the results' field objects decoded strictly and reported as a
  native read-back (never an independent observation), menu-time absence of a mission generation
  represented as nil, the candidate-absent negative control kept verbatim, the journal
  correlation, and the refusals while disarmed or with invalid parameters. The fake peer is never
  evidence of native game execution; nothing here is a second Hitman.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Journal, Listener, Schema}
  alias GlacierRelay.Test.{FakeNative, FixturePlayer}

  @suit "874c4c48-0a8b-49e9-883e-49fc5f1fb051"
  @zeros "00000000-0000-0000-0000-000000000000"
  @gen1 "2516103582917844185-a105ec5f-3a75-46a3-8ecd-e72fd15b176c"
  @hitmen_brick "007c57a6ea581f8c"
  @agent48 "feede715906f747f"
  @hero_brick "0012e5a7b1c9d3ee"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-players-#{System.pid()}-#{System.unique_integer([:positive])}"
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

  defp slot(index, overrides) do
    base = %{
      "player_id" => field("observed", -1),
      "local_flag" => field("observed", true),
      "connected" => field("observed", false),
      "net_player" => field("observed", false),
      "replica" => field("observed", false),
      "entity" => field("observed", false),
      "hero" => field("unavailable", nil, "entity reference null"),
      "flags_a0" => field("observed", -1),
      "session" => field("unavailable", nil, "session id empty")
    }

    base
    |> Map.merge(overrides)
    |> Map.new(fn {k, v} -> {"slot#{index}_#{k}", v} end)
  end

  defp players_observed(in_mission) do
    local =
      if in_mission,
        do: %{
          "player_id" => field("observed", 0),
          "entity" => field("observed", true),
          "hero" => field("observed", true),
          "flags_a0" => field("observed", 0),
          "session" => field("observed", @gen1)
        },
        else: %{
          "player_id" => field("observed", 0),
          "entity" => field("observed", true),
          "hero" => field("observed", true),
          "flags_a0" => field("observed", 0)
        }

    %{
      "mission_playing" => field("observed", in_mission),
      "scene_type" => field("observed", if(in_mission, do: "mission", else: "")),
      "receipt_to_frame_ms" => field("observed", 4),
      "registry_available" => field("observed", true),
      "registry_words" => field("observed", "slot0,0,0x4000000000000101"),
      "slot0_outfit_id" => field("observed", if(in_mission, do: @suit, else: @zeros)),
      "slot0_character_id" => field("observed", @zeros),
      "slot0_hero_kit_id" => field("observed", @suit),
      "slot0_matches_m5" => field("observed", in_mission),
      "reads_on_frame" => field("observed", true)
    }
    |> Map.merge(slot(0, local))
    |> Map.merge(slot(1, %{}))
    |> Map.merge(slot(2, %{}))
    |> Map.merge(slot(3, %{}))
  end

  defp entity_observed do
    %{
      "mission_playing" => field("observed", true),
      "scene_type" => field("observed", "mission"),
      "receipt_to_frame_ms" => field("observed", 3),
      "brick_count" => field("observed", 23),
      "brick_ids_1" =>
        field(
          "observed",
          Enum.map_join(1..7, ",", &String.pad_leading(Integer.to_string(&1, 16), 16, "0"))
        ),
      "brick_ids_2" =>
        field(
          "observed",
          Enum.map_join(8..14, ",", &String.pad_leading(Integer.to_string(&1, 16), 16, "0"))
        ),
      "brick_ids_3" =>
        field(
          "observed",
          Enum.map_join(15..21, ",", &String.pad_leading(Integer.to_string(&1, 16), 16, "0"))
        ),
      "bricks_truncated" => field("observed", true),
      "hero_resolved" => field("observed", true),
      "hero_entity_id" => field("observed", "feed9a0d70d546f4"),
      "hero_entity_flags" => field("observed", 7),
      "hero_activated" => field("observed", true),
      "hero_predeleted" => field("observed", false),
      "hero_owning_brick" => field("observed", @hero_brick),
      "hero_character_id" => field("observed", "787c1ff2-467c-421d-98f4-6bbb92e5fc99"),
      "hero_initial_outfit_id" => field("observed", @suit),
      "hero_invincible" => field("observed", false),
      "hero_x" => field("observed", -0.035),
      "hero_y" => field("observed", -3.832),
      "hero_z" => field("observed", -0.413),
      "hero_transform_dirty" => field("observed", false),
      "hero_room_behaviour" => field("observed", 1),
      "rt_outcome" => field("observed", "same_entity"),
      "rt_owner_found" => field("observed", true),
      "rt_factory_template" => field("observed", true),
      "rt_subentity_count" => field("observed", 2),
      "rt_index" => field("observed", 1),
      "rt_resolved" => field("observed", true),
      "rt_same_entity" => field("observed", true),
      "cand_brick" => field("observed", @hitmen_brick),
      "cand_entity_id" => field("observed", @agent48),
      "cand_brick_present" => field("observed", false),
      "reads_on_frame" => field("observed", true)
    }
  end

  defp journal_entries do
    %{path: path} = Journal.status()
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  test "the schema carries both entries as inert, identified, read-only, with the entity ids validated" do
    players = Schema.entry("relay.inspect.players", 1)
    assert players.issuable and players.effect == :none and players.trust == :identified
    assert players.reversal == :none and players.preconditions == []
    assert {:ok, %{}} = Schema.validate_params(players, %{})
    assert {:error, {:unknown_params, ["slot"]}} = Schema.validate_params(players, %{"slot" => 0})

    entity = Schema.entry("relay.inspect.entity", 1)
    assert entity.issuable and entity.effect == :none and entity.trust == :identified
    assert {:ok, %{}} = Schema.validate_params(entity, %{})

    assert {:ok, %{"brick" => @hitmen_brick, "entity_id" => @agent48}} =
             Schema.validate_params(entity, %{"brick" => @hitmen_brick, "entity_id" => @agent48})

    assert {:ok, %{"entity_id" => @agent48}} =
             Schema.validate_params(entity, %{"entity_id" => @agent48})

    assert {:error, {:invalid_param, "entity_id", :not_16_lowercase_hex_digits}} =
             Schema.validate_params(entity, %{"entity_id" => "FEEDE715906F747F"})

    assert {:error, {:invalid_param, "brick", :not_16_lowercase_hex_digits}} =
             Schema.validate_params(entity, %{"brick" => "0x14313dac0"})

    assert {:error, {:unknown_params, ["address"]}} =
             Schema.validate_params(entity, %{"address" => "0x14313dac0"})

    assert Schema.hex16?(@agent48) and not Schema.hex16?("feede715906f747") and
             not Schema.hex16?(nil)

    assert Enum.map(Schema.issuable(), & &1["name"]) == [
             "relay.inspect.candidate",
             "relay.inspect.candidate_transform",
             "relay.inspect.entity",
             "relay.inspect.outfit",
             "relay.inspect.players",
             "relay.probe"
           ]

    # the effectful configuration does not change the inert list, and a version-1 peer sees it
    assert Schema.issuable_for(1, ["relay.inspect.players/1"], true) == Schema.issuable()
    refute Enum.any?(Schema.issuable(), &(&1["name"] == "player.outfit.set"))
  end

  test "a players inspection in a mission comes back as a native read-back with every slot's statuses and the generation",
       %{port: port} do
    {socket, adapter, welcome} =
      FakeNative.handshake(port, Schema.uuid4(),
        capabilities: [
          "relay.probe/1",
          "relay.inspect.outfit/1",
          "relay.inspect.players/1",
          "relay.inspect.entity/1"
        ],
        mission_generation: @gen1
      )

    assert Enum.map(welcome["allowlist"], & &1["name"]) == [
             "relay.inspect.candidate",
             "relay.inspect.candidate_transform",
             "relay.inspect.entity",
             "relay.inspect.outfit",
             "relay.inspect.players",
             "relay.probe"
           ]

    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert {:error, :disarmed} = Command.inspect_players()
    assert :ok = Command.arm()
    assert {:ok, id} = Command.inspect_players(ttl_ms: 400)
    assert {:ok, cmd} = FakeNative.recv(socket)

    assert cmd["name"] == "relay.inspect.players" and cmd["version"] == 1 and
             cmd["command_id"] == id and cmd["params"] == %{} and cmd["preconditions"] == %{}

    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" => players_observed(true),
      "frame" => 27252,
      "mission_generation" => @gen1
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    c = Command.command(id)
    assert c.observed == :native and c.independent_observation == :not_available
    assert c.result.mission_generation == @gen1 and c.result.frame == 27252
    assert c.result.observed["registry_available"] == %{"status" => "observed", "value" => true}
    assert c.result.observed["registry_words"]["value"] == "slot0,0,0x4000000000000101"
    assert c.result.observed["slot0_player_id"]["value"] == 0
    assert c.result.observed["slot0_hero"]["value"] == true
    assert c.result.observed["slot0_session"]["value"] == @gen1
    assert c.result.observed["slot0_matches_m5"]["value"] == true
    assert c.result.observed["slot1_player_id"]["value"] == -1
    assert c.result.observed["slot1_local_flag"]["value"] == true

    assert c.result.observed["slot3_hero"] == %{
             "status" => "unavailable",
             "reason" => "entity reference null"
           }

    assert map_size(c.result.observed) == 46 and map_size(c.result.observed) <= 48
    assert Enum.map(c.stages, &elem(&1, 0)) == [:accepted, :transmitted, :received, :applied]

    # the journal correlates the request and its terminal result, labelled native
    entries = journal_entries()
    accepted = Enum.find(entries, &(&1["event"] == "command.accepted" and &1["command_id"] == id))
    assert accepted["name"] == "relay.inspect.players" and accepted["version"] == 1
    terminal = Enum.find(entries, &(&1["event"] == "command.terminal" and &1["command_id"] == id))

    assert terminal["status"] == "applied" and terminal["observed_label"] == "native" and
             terminal["observed"]["slot0_session"]["value"] == @gen1 and
             terminal["mission_generation"] == @gen1

    assert :ok = Command.disarm()
    FakeNative.close(socket)
  end

  test "at the main menu the generation is nil and the empty session is kept as unavailable, not defaulted",
       %{port: port} do
    {socket, adapter, _welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert :ok = Command.arm()
    assert {:ok, id} = Command.inspect_players()
    assert {:ok, cmd} = FakeNative.recv(socket)

    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" => players_observed(false),
      "frame" => 10355
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    c = Command.command(id)
    assert c.result.mission_generation == nil
    assert c.result.observed["mission_playing"]["value"] == false

    assert c.result.observed["slot0_session"] == %{
             "status" => "unavailable",
             "reason" => "session id empty"
           }

    assert c.result.observed["slot0_hero"]["value"] == true
    assert c.result.observed["slot0_outfit_id"]["value"] == @zeros
    assert c.result.observed["slot0_matches_m5"]["value"] == false
    FakeNative.close(socket)
  end

  test "an entity inspection travels with its two ids, and the candidate-absent control and the numbers come back verbatim",
       %{port: port} do
    {socket, adapter, _welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert {:error, :disarmed} = Command.inspect_entity()
    assert :ok = Command.arm()

    assert {:ok, id} =
             Command.inspect_entity(%{"brick" => @hitmen_brick, "entity_id" => @agent48},
               ttl_ms: 400
             )

    assert {:ok, cmd} = FakeNative.recv(socket)

    assert cmd["name"] == "relay.inspect.entity" and cmd["version"] == 1 and
             cmd["params"] == %{"brick" => @hitmen_brick, "entity_id" => @agent48}

    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" => entity_observed(),
      "frame" => 30154,
      "mission_generation" => @gen1
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    c = Command.command(id)
    assert c.observed == :native
    assert c.result.observed["cand_brick_present"] == %{"status" => "observed", "value" => false}
    assert c.result.observed["cand_brick"]["value"] == @hitmen_brick
    refute Map.has_key?(c.result.observed, "cand_index")
    assert c.result.observed["rt_outcome"]["value"] == "same_entity"

    assert c.result.observed["hero_x"]["value"] == -0.035 and
             c.result.observed["hero_z"]["value"] == -0.413

    assert c.result.observed["hero_transform_dirty"]["value"] == false
    assert c.result.observed["hero_owning_brick"]["value"] == @hero_brick
    assert String.length(c.result.observed["brick_ids_1"]["value"]) == 7 * 16 + 6
    assert map_size(c.result.observed) == 33

    # a second inspection without parameters sends none: the defaults are the native reader's
    assert {:ok, id2} = Command.inspect_entity()
    assert {:ok, cmd2} = FakeNative.recv(socket)
    assert cmd2["params"] == %{} and cmd2["command_id"] == id2

    observed =
      entity_observed()
      |> Map.merge(%{
        "cand_brick_present" => field("observed", true),
        "cand_factory_template" => field("observed", true),
        "cand_subentity_count" => field("observed", 3),
        "cand_index" => field("observed", 0),
        "cand_resolved" => field("observed", true),
        "cand_hitman5" => field("observed", true),
        "cand_spatial" => field("observed", true),
        "cand_distinct_from_local" => field("observed", true),
        "cand_entity_id" => field("observed", @agent48),
        "cand_entity_flags" => field("observed", 7),
        "cand_character_id" => field("observed", "787c1ff2-467c-421d-98f4-6bbb92e5fc99"),
        "cand_x" => field("observed", -40.99882),
        "cand_y" => field("observed", -24.293657),
        "cand_z" => field("observed", 0.4925565),
        "cand_transform_dirty" => field("observed", false)
      })

    assert map_size(observed) == 46

    FakeNative.respond(socket, cmd2, adapter, "applied", %{
      "observed" => observed,
      "frame" => 30498,
      "mission_generation" => @gen1
    })

    assert wait(fn -> Command.command(id2).status == :applied end)
    c2 = Command.command(id2)
    assert c2.result.observed["cand_distinct_from_local"]["value"] == true
    assert c2.result.observed["cand_x"]["value"] == -40.99882
    assert map_size(c2.result.observed) == 46
    assert Command.status().counters.issued == 2
    FakeNative.close(socket)
  end

  test "invalid ids and unknown parameters are refused before anything is transmitted", %{
    port: port
  } do
    {socket, _adapter, _welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert :ok = Command.arm()

    assert {:error, {:invalid_param, "entity_id", :not_16_lowercase_hex_digits}} =
             Command.inspect_entity(%{"entity_id" => "FEEDE715906F747F"})

    assert {:error, {:invalid_param, "brick", :not_16_lowercase_hex_digits}} =
             Command.inspect_entity(%{"brick" => "0x14313dac0"})

    assert {:error, {:unknown_params, ["offset"]}} =
             Command.inspect_entity(%{"offset" => "0x390"})

    assert {:error, :timeout} = FakeNative.recv(socket, 200)
    assert Command.status().counters.issued == 0
    FakeNative.close(socket)
  end

  test "the effectful entry and authority are untouched beside the new inert entries", %{
    port: port
  } do
    {socket, _adapter, welcome} = FakeNative.handshake(port)
    refute Enum.any?(welcome["allowlist"], &(&1["name"] == "player.outfit.set"))
    assert wait(fn -> Command.status().trust.peer == :identified end)
    s = Command.status()
    assert s.effectful.enabled == false and s.trust.effectful_armed == false
    assert :ok = Command.arm()

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

    assert {:error, :timeout} = FakeNative.recv(socket, 200)
    FakeNative.close(socket)
  end
end

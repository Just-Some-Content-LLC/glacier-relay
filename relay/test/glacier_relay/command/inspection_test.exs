defmodule GlacierRelay.Command.InspectionTest do
  @moduledoc """
  M5 C-1: `relay.inspect.outfit` v1 through the real command subtree against the fake native peer:
  the schema entry and its one optional parameter, the welcome's allowlist, the operator facade
  with its expected-generation precondition, the result's field objects with their statuses
  (observed / unavailable / unsupported / inconsistent / precondition_failed) decoded strictly
  and reported as a native read-back, never as an independent observation, the raised read-back
  bound, and the reserved entry staying non-issuable. The fake peer is never evidence of native
  game execution.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Journal, Listener, Schema}
  alias GlacierRelay.Test.{FakeNative, FixturePlayer}

  @suit "874c4c48-0a8b-49e9-883e-49fc5f1fb051"
  @gen1 "2516103582917844185-a105ec5f-3a75-46a3-8ecd-e72fd15b176c"
  @gen2 "2516103582027577704-30ccebb9-8138-4c72-9eb9-1a289b4fba33"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-inspect-#{System.pid()}-#{System.unique_integer([:positive])}"
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

  defp inspection_observed do
    %{
      "scene_available" => field("observed", true),
      "scene_loaded" => field("observed", true),
      "loading_stage" => field("observed", 8),
      "scene_type" => field("observed", "mission"),
      "mission_playing" => field("observed", true),
      "prev_frame_playing" => field("observed", true),
      "frame" => field("observed", 23055),
      "receipt_to_frame_ms" => field("observed", 1),
      "rise_age_ms" => field("observed", 31_000),
      "rise_age_frames" => field("observed", 2_900),
      "scene_same_as_rise" => field("observed", true),
      "generation_expected" => field("observed", @gen1),
      "generation_at_receipt" => field("observed", @gen1),
      "generation_cached" => field("observed", @gen1),
      "generation_fresh" => field("observed", @gen1),
      "relay_transition_epoch" => field("observed", 3),
      "epoch_at_receipt" => field("observed", 3),
      "contract_started_seen" => field("observed", @gen1),
      "contract_ended_seen" => field("unavailable", nil, "none observed"),
      "hero_outfit_id" => field("observed", @suit),
      "hero_charset" => field("observed", 0),
      "hero_variation" => field("observed", 0),
      "hero_charset_count" => field("observed", 1),
      "hero_heroa_vars" => field("observed", 1),
      "hero_heroa_valid" => field("observed", true),
      "hero_suit" => field("observed", true),
      "candidate_id" => field("observed", @suit),
      "candidate_found" => field("observed", true),
      "candidate_charsets" => field("observed", 1),
      "candidate_heroa_vars" => field("observed", 1),
      "candidate_heroa_usable" => field("observed", true),
      "candidate_suit" => field("observed", true),
      "kits_scanned" => field("observed", 412),
      "set_outfit_available" => field("observed", true),
      "kit_map" => field("observed", true),
      "reads_on_frame" => field("observed", true),
      "precondition_ok" => field("observed", true),
      "precondition_reasons" => field("observed")
    }
  end

  test "the schema carries the entry, its optional parameter and the raised read-back bound" do
    entry = Schema.entry("relay.inspect.outfit", 1)
    assert entry.issuable and entry.effect == :none and entry.trust == :identified
    assert {:ok, %{}} = Schema.validate_params(entry, %{})

    assert {:ok, %{"disguise_repository_id" => @suit}} =
             Schema.validate_params(entry, %{"disguise_repository_id" => @suit})

    assert {:error, {:invalid_param, "disguise_repository_id", :not_a_uuid}} =
             Schema.validate_params(entry, %{"disguise_repository_id" => "not-an-id"})

    assert {:error, {:unknown_params, ["outfit_pointer"]}} =
             Schema.validate_params(entry, %{"outfit_pointer" => "0x1"})

    assert Schema.max_observed_entries() == 48

    assert Enum.sort(Enum.map(Schema.issuable(), & &1["name"])) == [
             "relay.inspect.candidate",
             "relay.inspect.candidate_transform",
             "relay.inspect.entity",
             "relay.inspect.outfit",
             "relay.inspect.players",
             "relay.probe"
           ]

    refute Schema.entry("player.outfit.set", 1).issuable

    # 48 field objects decode; 49 do not; a field object is a bounded scalar map
    observed = Map.new(1..48, fn i -> {"f#{i}", field("observed", i)} end)

    line =
      JSON.encode!(
        FakeNative.result(
          %{"command_id" => Schema.uuid4(), "link_generation" => 1},
          Schema.uuid4(),
          "applied",
          %{"observed" => observed}
        )
      )

    assert {:ok, {:result, %{observed: ^observed}}} = Schema.decode_line(line)
    too_many = Map.put(observed, "f49", field("observed", 49))

    line =
      JSON.encode!(
        FakeNative.result(
          %{"command_id" => Schema.uuid4(), "link_generation" => 1},
          Schema.uuid4(),
          "applied",
          %{"observed" => too_many}
        )
      )

    assert {:error, {:invalid_field, "observed", :not_a_bounded_observation}} =
             Schema.decode_line(line)
  end

  test "the welcome lists the executable entries and the peer's hello may claim them", %{
    port: port
  } do
    {socket, _adapter, welcome} =
      FakeNative.handshake(port, Schema.uuid4(),
        capabilities: ["relay.probe/1", "relay.inspect.outfit/1"]
      )

    assert Enum.sort(Enum.map(welcome["allowlist"], & &1["name"])) == [
             "relay.inspect.candidate",
             "relay.inspect.candidate_transform",
             "relay.inspect.entity",
             "relay.inspect.outfit",
             "relay.inspect.players",
             "relay.probe"
           ]

    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert Command.status().link.capabilities == ["relay.probe/1", "relay.inspect.outfit/1"]
    FakeNative.close(socket)
  end

  test "an inspection travels with its candidate and expected generation and comes back as a native read-back with per-field statuses",
       %{port: port} do
    {socket, adapter, welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert {:error, :disarmed} = Command.inspect_outfit(%{"disguise_repository_id" => @suit})
    assert :ok = Command.arm()

    assert {:ok, id} =
             Command.inspect_outfit(%{"disguise_repository_id" => @suit},
               expected_generation: @gen1
             )

    assert {:ok, cmd} = FakeNative.recv(socket)

    assert cmd["name"] == "relay.inspect.outfit" and cmd["version"] == 1 and
             cmd["command_id"] == id

    assert cmd["params"] == %{"disguise_repository_id" => @suit}
    assert cmd["preconditions"] == %{"mission_generation" => @gen1}
    assert cmd["link_generation"] == welcome["link_generation"]

    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" => inspection_observed(),
      "frame" => 23055,
      "mission_generation" => @gen1
    })

    assert wait(fn -> Command.command(id).status == :applied end)

    c = Command.command(id)
    assert c.observed == :native
    assert c.independent_observation == :not_available
    assert c.result.observed["hero_outfit_id"] == %{"status" => "observed", "value" => @suit}

    assert c.result.observed["contract_ended_seen"] == %{
             "status" => "unavailable",
             "reason" => "none observed"
           }

    assert c.result.observed["precondition_ok"]["value"] == true
    assert c.result.mission_generation == @gen1
    assert Enum.map(c.stages, &elem(&1, 0)) == [:accepted, :transmitted, :received, :applied]

    # the journal carries the read-back labelled native, with the preconditions that were sent
    %{path: path} = Journal.status()
    entries = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    accepted = Enum.find(entries, &(&1["event"] == "command.accepted" and &1["command_id"] == id))

    assert accepted["name"] == "relay.inspect.outfit" and
             accepted["preconditions"] == %{"mission_generation" => @gen1}

    terminal = Enum.find(entries, &(&1["event"] == "command.terminal" and &1["command_id"] == id))

    assert terminal["status"] == "applied" and
             terminal["observed"]["generation_fresh"]["value"] == @gen1

    assert terminal["observed_label"] == "native" and
             terminal["independent_observation"] == "not_available"

    assert :ok = Command.disarm()
    FakeNative.close(socket)
  end

  test "a failing hypothetical precondition is still an applied inspection: the statuses and reasons are kept verbatim",
       %{port: port} do
    {socket, adapter, _welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert :ok = Command.arm()
    assert {:ok, id} = Command.inspect_outfit(%{}, expected_generation: @gen1)
    assert {:ok, cmd} = FakeNative.recv(socket)
    assert cmd["params"] == %{}

    observed =
      inspection_observed()
      |> Map.drop([
        "candidate_id",
        "candidate_found",
        "candidate_charsets",
        "candidate_heroa_vars",
        "candidate_heroa_usable",
        "candidate_suit",
        "kits_scanned"
      ])
      |> Map.merge(%{
        "generation_fresh" => field("observed", @gen2),
        "generation_cached" => field("observed", @gen1),
        "contract_ended_seen" => field("observed", @gen1),
        "relay_transition_epoch" => field("observed", 4),
        "epoch_at_receipt" => field("observed", 3),
        "hero_outfit_id" => field("inconsistent", nil, "two reads differ"),
        "set_outfit_available" => field("unsupported", nil, "no inspector on this frame source"),
        "precondition_ok" => field("observed", false),
        "precondition_reasons" =>
          field(
            "observed",
            "generation_mismatch_fresh,contract_end_observed,epoch_changed,outfit_unreadable,candidate_missing,setter_unavailable"
          )
      })

    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" => observed,
      "frame" => 30771,
      "mission_generation" => @gen1
    })

    assert wait(fn -> Command.command(id).status == :applied end)
    c = Command.command(id)
    assert c.result.observed["precondition_ok"]["value"] == false

    assert c.result.observed["generation_fresh"]["value"] == @gen2 and
             c.result.observed["generation_cached"]["value"] == @gen1

    assert c.result.observed["hero_outfit_id"] == %{
             "status" => "inconsistent",
             "reason" => "two reads differ"
           }

    assert c.result.observed["set_outfit_available"]["status"] == "unsupported"
    assert c.result.observed["precondition_reasons"]["value"] =~ "epoch_changed"
    assert c.observed == :native
    FakeNative.close(socket)
  end

  test "an invalid expected generation or candidate is refused before anything is transmitted", %{
    port: port
  } do
    {socket, _adapter, _welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert :ok = Command.arm()

    assert {:error, {:invalid_preconditions, _}} =
             Command.inspect_outfit(%{}, expected_generation: String.duplicate("g", 65))

    assert {:error, {:invalid_param, "disguise_repository_id", :not_a_uuid}} =
             Command.inspect_outfit(%{"disguise_repository_id" => "0xdeadbeef"})

    assert {:error, {:unknown_params, ["expect_current"]}} =
             Command.inspect_outfit(%{"expect_current" => @suit})

    assert {:error, :timeout} = FakeNative.recv(socket, 200)
    assert Command.status().counters.issued == 0
    FakeNative.close(socket)
  end

  test "the reserved effectful entry stays non-issuable beside the inspection", %{port: port} do
    {socket, _adapter, _welcome} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert :ok = Command.arm()

    assert {:error, {:not_issuable, "player.outfit.set", 1}} =
             GlacierRelay.Command.Authority.issue("player.outfit.set", 1, %{
               "disguise_repository_id" => @suit
             })

    assert {:error, :timeout} = FakeNative.recv(socket, 200)
    FakeNative.close(socket)
  end
end

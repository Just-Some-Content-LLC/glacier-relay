defmodule GlacierRelay.Wire.EnvelopeTest do
  use ExUnit.Case, async: true

  alias GlacierRelay.Wire.Envelope

  @stage1 File.read!("test/stage1_envelopes.ndjson") |> String.split("\n", trim: true)

  test "decodes the three envelopes the native adapter produced in the stage 1 run" do
    decoded = Enum.map(@stage1, &Envelope.decode/1)
    assert Enum.all?(decoded, &match?({:ok, _}, &1))

    envelopes = Enum.map(decoded, fn {:ok, e} -> e end)
    assert Enum.map(envelopes, & &1.sequence) == [1, 2, 3]

    assert Enum.uniq(Enum.map(envelopes, & &1.adapter_instance_id)) == [
             "9c8f3a75-7054-457c-919d-ee87e77f57d9"
           ]

    assert Enum.all?(envelopes, &(&1.event_type == "mission.playing" and &1.schema_version == 1))

    [paris, restart, sapienza] = envelopes

    assert paris.payload.scene_resource ==
             "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"

    assert paris.payload.codename_hint == "Peacock"

    assert sapienza.payload.scene_resource ==
             "assembly:/_PRO/Scenes/Missions/CoastalTown/Mission01.entity"

    assert sapienza.payload.codename_hint == "Octopus"
    assert restart.payload.game_session_id != paris.payload.game_session_id
    assert paris.timestamp == "2026-10-06T22:01:05.881Z"
  end

  defp valid_map do
    %{
      "protocol_version" => 1,
      "adapter_instance_id" => "00000000-0000-4000-8000-000000000001",
      "sequence" => 1,
      "timestamp" => "2026-10-06T22:01:05.881Z",
      "event_type" => "mission.playing",
      "schema_version" => 1,
      "payload" => %{
        "scene_resource" => "assembly:/x.entity",
        "scene_type" => "mission",
        "codename_hint" => "X"
      }
    }
  end

  defp decode(map), do: map |> JSON.encode!() |> Envelope.decode()

  test "session id is optional and must be a string when present" do
    assert {:ok, %{payload: %{game_session_id: nil}}} = decode(valid_map())
    with_id = put_in(valid_map(), ["payload", "game_session_id"], "abc")
    assert {:ok, %{payload: %{game_session_id: "abc"}}} = decode(with_id)
    bad_id = put_in(valid_map(), ["payload", "game_session_id"], 5)
    assert {:error, {:invalid_field, "game_session_id"}} = decode(bad_id)
  end

  test "rejects malformed JSON, non-objects and arrays" do
    assert {:error, {:invalid_json, _}} = Envelope.decode("{not json")
    assert {:error, :not_an_object} = Envelope.decode("[1,2]")
    assert {:error, :not_an_object} = Envelope.decode("42")
  end

  test "rejects missing and mistyped envelope fields" do
    for key <-
          ~w(protocol_version adapter_instance_id sequence timestamp event_type schema_version payload) do
      assert {:error, {:missing_field, ^key}} = decode(Map.delete(valid_map(), key))
    end

    assert {:error, {:invalid_field, "sequence"}} = decode(Map.put(valid_map(), "sequence", 0))
    assert {:error, {:invalid_field, "sequence"}} = decode(Map.put(valid_map(), "sequence", "1"))

    assert {:error, {:invalid_field, "adapter_instance_id"}} =
             decode(Map.put(valid_map(), "adapter_instance_id", ""))

    assert {:error, {:invalid_field, "payload"}} = decode(Map.put(valid_map(), "payload", "x"))
  end

  test "rejects other protocol versions, unknown events and unknown schema versions" do
    assert {:error, {:unsupported_protocol_version, 2}} =
             decode(Map.put(valid_map(), "protocol_version", 2))

    assert {:error, {:unknown_event_type, "mission.ended"}} =
             decode(Map.put(valid_map(), "event_type", "mission.ended"))

    assert {:error, {:unsupported_schema_version, "mission.playing", 2}} =
             decode(Map.put(valid_map(), "schema_version", 2))
  end

  test "rejects a mission.playing payload without its required fields" do
    assert {:error, {:missing_field, "scene_resource"}} =
             decode(update_in(valid_map(), ["payload"], &Map.delete(&1, "scene_resource")))

    assert {:error, {:invalid_field, "scene_resource"}} =
             decode(put_in(valid_map(), ["payload", "scene_resource"], ""))

    assert {:error, {:missing_field, "scene_type"}} =
             decode(update_in(valid_map(), ["payload"], &Map.delete(&1, "scene_type")))
  end

  test "payload keys the backend does not know are ignored, not errors" do
    assert {:ok, _} = decode(put_in(valid_map(), ["payload", "future_field"], true))
  end
end

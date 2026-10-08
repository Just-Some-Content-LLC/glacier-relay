defmodule GlacierRelay.DisguiseTest do
  @moduledoc """
  M2 B3: validation of disguise.equipped / disguise.compromised / disguise.compromise_cleared v1.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Events

  @suit "874c4c48-0a8b-49e9-883e-49fc5f1fb051"
  @outfit_a "2018db77-aa8a-4bf9-9afb-56bdaa161156"
  @session_a "2516109628137904204-c00b2d17-08b1-4949-9f9d-5f68b691f40f"

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
end

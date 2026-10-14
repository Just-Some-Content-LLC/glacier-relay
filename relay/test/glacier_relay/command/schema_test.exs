defmodule GlacierRelay.Command.SchemaTest do
  @moduledoc "The command protocol (M5-A): strict decoding, bounded fields, the compiled allowlist, deterministic encoding."
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.Schema

  @uuid "9c8f3a75-7054-457c-919d-ee87e77f57d9"

  defp hello(overrides \\ %{}),
    do:
      Map.merge(
        %{"command_protocol_version" => 1, "kind" => "hello", "adapter_instance_id" => @uuid},
        overrides
      )

  defp result(overrides \\ %{}),
    do:
      Map.merge(
        %{
          "command_protocol_version" => 1,
          "kind" => "command.result",
          "command_id" => @uuid,
          "link_generation" => 3,
          "status" => "applied"
        },
        overrides
      )

  defp decode(map), do: map |> JSON.encode!() |> Schema.decode_line()

  test "the protocol version is 1 and the line limit is 4 KiB" do
    assert Schema.protocol_version() == 1 and Schema.max_line_bytes() == 4_096
  end

  test "uuid4 generation is well formed and unique" do
    ids = for _ <- 1..200, do: Schema.uuid4()
    assert Enum.all?(ids, &Schema.uuid?/1) and length(Enum.uniq(ids)) == 200
    refute Schema.uuid?("not-a-uuid")
    refute Schema.uuid?(@uuid |> String.upcase())
  end

  describe "hello" do
    test "decodes with its optional fields" do
      assert {:ok, {:hello, h}} =
               decode(
                 hello(%{
                   "native_at" => "t",
                   "mission_generation" => "g1",
                   "capabilities" => ["relay.probe/1"]
                 })
               )

      assert h == %{
               adapter_instance_id: @uuid,
               native_at: "t",
               mission_generation: "g1",
               capabilities: ["relay.probe/1"]
             }

      assert {:ok, {:hello, %{capabilities: [], mission_generation: nil}}} = decode(hello())
    end

    test "rejects unknown fields, a missing or malformed id, and oversized values" do
      assert {:error, {:unknown_fields, ["extra"]}} = decode(hello(%{"extra" => 1}))

      assert {:error, {:missing_field, "adapter_instance_id"}} =
               decode(Map.delete(hello(), "adapter_instance_id"))

      assert {:error, {:invalid_field, "adapter_instance_id", :not_a_uuid}} =
               decode(hello(%{"adapter_instance_id" => "x"}))

      assert {:error, {:invalid_field, "mission_generation", _}} =
               decode(hello(%{"mission_generation" => String.duplicate("g", 65)}))

      assert {:error, {:invalid_field, "capabilities", _}} =
               decode(hello(%{"capabilities" => [1]}))

      assert {:error, {:invalid_field, "capabilities", _}} =
               decode(hello(%{"capabilities" => List.duplicate("c", 17)}))
    end
  end

  describe "result" do
    test "decodes every status and the bounded observation" do
      for status <- Schema.statuses() do
        assert {:ok, {:result, %{status: ^status}}} = decode(result(%{"status" => status}))
      end

      observed = %{
        "scene_loaded" => true,
        "previous" => %{"disguise_repository_id" => @uuid},
        "current" => %{"x" => 1.5}
      }

      assert {:ok, {:result, r}} =
               decode(
                 result(%{
                   "observed" => observed,
                   "frame" => 42,
                   "reason" => "ok",
                   "mission_generation" => "g"
                 })
               )

      assert r.observed == observed and r.frame == 42 and r.reason == "ok" and
               r.mission_generation == "g"

      assert r.adapter_instance_id == nil
      assert Schema.terminal?("applied") and not Schema.terminal?("received")
      assert Schema.terminal_statuses() == Schema.statuses() -- ["received"]
    end

    test "rejects an unknown status, a bad generation, unknown fields and unbounded observations" do
      assert {:error, {:invalid_field, "status", _}} = decode(result(%{"status" => "done"}))

      assert {:error, {:invalid_field, "link_generation", _}} =
               decode(result(%{"link_generation" => 0}))

      assert {:error, {:invalid_field, "link_generation", _}} =
               decode(result(%{"link_generation" => "1"}))

      assert {:error, {:missing_field, "command_id"}} = decode(Map.delete(result(), "command_id"))
      assert {:error, {:unknown_fields, ["pointer"]}} = decode(result(%{"pointer" => "0x1"}))
      assert {:error, {:invalid_field, "frame", _}} = decode(result(%{"frame" => -1}))

      assert {:error, {:invalid_field, "reason", _}} =
               decode(result(%{"reason" => String.duplicate("r", 201)}))

      too_many = for i <- 1..17, into: %{}, do: {"k#{i}", i}
      assert {:error, {:invalid_field, "observed", _}} = decode(result(%{"observed" => too_many}))

      assert {:error, {:invalid_field, "observed", _}} =
               decode(result(%{"observed" => %{"nested" => %{"deep" => %{"x" => 1}}}}))

      assert {:error, {:invalid_field, "observed", _}} =
               decode(result(%{"observed" => %{"list" => [1, 2]}}))
    end
  end

  describe "lines" do
    test "wrong or missing protocol version, unknown kind, non-objects, invalid JSON and UTF-8, oversize" do
      assert {:error, {:unsupported_protocol_version, 2}} =
               decode(hello(%{"command_protocol_version" => 2}))

      assert {:error, :missing_protocol_version} =
               decode(Map.delete(hello(), "command_protocol_version"))

      assert {:error, {:unknown_kind, "command"}} = decode(hello(%{"kind" => "command"}))
      assert {:error, :missing_kind} = decode(Map.delete(hello(), "kind"))
      assert {:error, :not_an_object} = Schema.decode_line("[1,2]")
      assert {:error, {:invalid_json, _}} = Schema.decode_line("{not json")
      assert {:error, :invalid_utf8} = Schema.decode_line(<<0xFF, 0xFE>> <> "{}")
      assert {:error, :line_too_long} = Schema.decode_line(String.duplicate("x", 4_097))
    end
  end

  describe "allowlist and parameters" do
    test "relay.probe is the only issuable entry; player.outfit.set is reserved and requires an authenticated peer" do
      assert Schema.issuable() == [%{"name" => "relay.probe", "version" => 1}]
      probe = Schema.entry("relay.probe", 1)

      assert probe.issuable and probe.effect == :none and probe.trust == :identified and
               probe.reversal == :none

      outfit = Schema.entry("player.outfit.set", 1)
      refute outfit.issuable

      assert outfit.trust == :authenticated and outfit.preconditions == [:mission_generation] and
               outfit.effect == :outfit

      assert Schema.entry("relay.probe", 2) == nil and
               Schema.entry("game.time_scale.set", 1) == nil
    end

    test "parameters are validated exactly against the entry" do
      probe = Schema.entry("relay.probe", 1)
      assert {:ok, %{}} = Schema.validate_params(probe, %{})
      assert {:error, {:unknown_params, ["x"]}} = Schema.validate_params(probe, %{"x" => 1})
      assert {:error, :params_not_an_object} = Schema.validate_params(probe, [])

      outfit = Schema.entry("player.outfit.set", 1)

      assert {:ok, %{"disguise_repository_id" => @uuid}} =
               Schema.validate_params(outfit, %{"disguise_repository_id" => @uuid})

      assert {:ok, %{"expect_current" => @uuid}} =
               Schema.validate_params(outfit, %{
                 "disguise_repository_id" => @uuid,
                 "expect_current" => @uuid
               })

      assert {:error, {:invalid_param, "disguise_repository_id", :missing}} =
               Schema.validate_params(outfit, %{})

      assert {:error, {:invalid_param, "disguise_repository_id", :not_a_uuid}} =
               Schema.validate_params(outfit, %{"disguise_repository_id" => "suit"})

      assert {:error, {:invalid_param, "expect_current", :not_a_uuid}} =
               Schema.validate_params(outfit, %{
                 "disguise_repository_id" => @uuid,
                 "expect_current" => 1
               })

      assert {:error, {:unknown_params, ["kit_pointer"]}} =
               Schema.validate_params(outfit, %{
                 "disguise_repository_id" => @uuid,
                 "kit_pointer" => "0x0"
               })
    end
  end

  describe "encoding" do
    test "welcome, command and refusal lines are complete, versioned and newline-terminated" do
      welcome = Schema.encode_welcome(7, :relay@test)
      assert String.ends_with?(welcome, "\n")

      assert JSON.decode!(welcome) == %{
               "command_protocol_version" => 1,
               "kind" => "welcome",
               "link_generation" => 7,
               "node" => "relay@test",
               "allowlist" => [%{"name" => "relay.probe", "version" => 1}]
             }

      cmd = %{
        command_id: @uuid,
        link_generation: 7,
        issued_at: "2026-10-13T20:00:00Z",
        ttl_ms: 500,
        name: "relay.probe",
        version: 1,
        params: %{},
        preconditions: %{}
      }

      line = Schema.encode_command(cmd)
      assert line == Schema.encode_command(cmd)

      assert JSON.decode!(line) == %{
               "command_protocol_version" => 1,
               "kind" => "command",
               "command_id" => @uuid,
               "link_generation" => 7,
               "issued_at" => "2026-10-13T20:00:00Z",
               "ttl_ms" => 500,
               "name" => "relay.probe",
               "version" => 1,
               "params" => %{},
               "preconditions" => %{}
             }

      assert JSON.decode!(Schema.encode_refusal(:busy)) == %{
               "command_protocol_version" => 1,
               "kind" => "refused",
               "reason" => "busy"
             }

      refute line =~ ~r/pointer|address|vtable|0x/
    end
  end
end

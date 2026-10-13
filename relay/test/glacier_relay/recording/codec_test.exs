defmodule GlacierRelay.Recording.CodecTest do
  @moduledoc """
  The recording line format (M4-A): every committed fixture envelope round-trips value-exact
  through a record line, the encoding is deterministic, and an envelope built in code (no wire
  object) is marked as such.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Recording.{Codec, Record}
  alias GlacierRelay.Wire.Envelope

  @fixtures ~w(stage1 stage_a_probe b1_probe b2_probe b3_probe b4_probe b5_probe b5_run1 b6_probe b6_run1)

  defp lines(name),
    do: File.read!("test/#{name}_envelopes.ndjson") |> String.split("\n", trim: true)

  defp at, do: ~U[2026-10-13 05:00:00.123456Z]

  test "every fixture envelope round-trips value-exact and re-validates to the same struct" do
    for name <- @fixtures, line <- lines(name) do
      {:ok, envelope} = Envelope.decode(line)
      assert is_map(envelope.raw)

      record = %Record{
        no: 7,
        kind: :envelope,
        at: at(),
        conn: 3,
        instance: envelope.adapter_instance_id,
        envelope: envelope
      }

      encoded = record |> Codec.encode_record() |> IO.iodata_to_binary()
      assert String.ends_with?(encoded, "\n")

      {:ok, decoded} = Codec.decode_line(encoded)
      assert decoded["r"] == 7 and decoded["k"] == "envelope" and decoded["conn"] == 3
      assert decoded["at"] == "2026-10-13T05:00:00.123456Z"

      assert decoded["sequence"] == envelope.sequence and
               decoded["event_type"] == envelope.event_type

      refute Map.has_key?(decoded, "wire")

      # Value-exact against the wire's own JSON, and the same validated struct when re-decoded.
      assert decoded["envelope"] == JSON.decode!(line)
      {:ok, again} = Envelope.decode(JSON.encode!(decoded["envelope"]))
      assert again == envelope
    end
  end

  test "the nested player-state weapon object and its floats survive" do
    line = Enum.find(lines("b6_run1"), &String.contains?(&1, "\"holding\":true"))
    {:ok, envelope} = Envelope.decode(line)

    {:ok, decoded} =
      %Record{no: 1, kind: :envelope, at: at(), envelope: envelope}
      |> Codec.encode_record()
      |> IO.iodata_to_binary()
      |> Codec.decode_line()

    weapon = decoded["envelope"]["payload"]["weapon"]
    assert is_map(weapon) and weapon == JSON.decode!(line)["payload"]["weapon"]

    assert decoded["envelope"]["payload"]["engine_timestamp_s"] ==
             JSON.decode!(line)["payload"]["engine_timestamp_s"]
  end

  test "encoding is deterministic: the same record gives the same bytes, nested keys sorted" do
    {:ok, envelope} = Envelope.decode(hd(lines("b5_run1")))

    record = %Record{
      no: 1,
      kind: :envelope,
      at: at(),
      conn: 1,
      instance: envelope.adapter_instance_id,
      envelope: envelope
    }

    a = record |> Codec.encode_record() |> IO.iodata_to_binary()
    b = record |> Codec.encode_record() |> IO.iodata_to_binary()
    assert a == b
    assert String.starts_with?(a, "{\"r\":1,\"k\":\"envelope\",\"at\":")
    # Nested object keys appear sorted.
    [_, payload] = String.split(a, "\"payload\":{", parts: 2)
    keys = Regex.scan(~r/"([a-z_]+)":/, payload) |> Enum.map(&Enum.at(&1, 1)) |> Enum.take(3)
    assert keys == Enum.sort(keys)
  end

  test "an envelope built in code is written from its validated fields and marked wire:false" do
    envelope = %Envelope{
      protocol_version: 1,
      adapter_instance_id: "built",
      sequence: 1,
      timestamp: "2026-10-13T05:00:00.000Z",
      event_type: "mission.playing",
      schema_version: 1,
      payload: %{
        scene_resource: "assembly:/x.entity",
        scene_type: "mission",
        codename_hint: "T",
        game_session_id: nil
      }
    }

    {:ok, decoded} =
      %Record{no: 2, kind: :envelope, at: nil, envelope: envelope}
      |> Codec.encode_record()
      |> IO.iodata_to_binary()
      |> Codec.decode_line()

    assert decoded["wire"] == false and decoded["at"] == nil

    assert decoded["envelope"]["payload"] == %{
             "scene_resource" => "assembly:/x.entity",
             "scene_type" => "mission",
             "codename_hint" => "T"
           }
  end

  test "transport records and reasons" do
    opened = %Record{no: 1, kind: :connection_opened, at: at(), conn: 4, peer: "127.0.0.1:5"}
    {:ok, o} = opened |> Codec.encode_record() |> IO.iodata_to_binary() |> Codec.decode_line()

    assert o == %{
             "r" => 1,
             "k" => "connection.opened",
             "at" => "2026-10-13T05:00:00.123456Z",
             "conn" => 4,
             "peer" => "127.0.0.1:5"
           }

    ident = %Record{
      no: 2,
      kind: :connection_identified,
      at: at(),
      conn: 4,
      peer: "127.0.0.1:5",
      instance: "b",
      previous_instance: "a"
    }

    {:ok, i} = ident |> Codec.encode_record() |> IO.iodata_to_binary() |> Codec.decode_line()
    assert i["instance"] == "b" and i["previous_instance"] == "a"

    for {reason, expected} <- [
          {:peer_closed, "peer_closed"},
          {:line_too_long, "line_too_long"},
          {{:tcp_error, :econnreset}, %{"tcp_error" => ":econnreset"}},
          {{:down, :killed}, %{"down" => ":killed"}}
        ] do
      closed = %Record{
        no: 3,
        kind: :connection_closed,
        at: at(),
        conn: 4,
        peer: "p",
        instance: nil,
        reason: reason
      }

      {:ok, c} = closed |> Codec.encode_record() |> IO.iodata_to_binary() |> Codec.decode_line()
      assert c["reason"] == expected and c["instance"] == nil
    end
  end

  test "diagnostic lines carry the recorder clock under recorder_at and no r" do
    {:ok, d} =
      Codec.encode_diagnostic("recorder.gap", at(), [
        {"from", 5},
        {"to", nil},
        {"cause", "restart"}
      ])
      |> IO.iodata_to_binary()
      |> Codec.decode_line()

    assert d == %{
             "k" => "recorder.gap",
             "recorder_at" => "2026-10-13T05:00:00.123456Z",
             "from" => 5,
             "to" => nil,
             "cause" => "restart"
           }
  end

  test "a partial line is detectable" do
    {:ok, envelope} = Envelope.decode(hd(lines("stage1")))

    full =
      %Record{no: 1, kind: :envelope, at: at(), envelope: envelope}
      |> Codec.encode_record()
      |> IO.iodata_to_binary()

    assert {:ok, _} = Codec.decode_line(full)
    assert {:error, _} = Codec.decode_line(binary_part(full, 0, byte_size(full) - 20))
  end
end

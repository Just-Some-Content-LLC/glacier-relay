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
          {{:tcp_error, :econnreset}, %{"tcp_error" => %{"posix" => "econnreset"}}},
          {{:down, :killed}, %{"down" => %{"exit" => "killed"}}},
          {{:tcp_error, {:weird, 1}}, %{"tcp_error" => %{"text" => "{:weird, 1}"}}},
          {{:down, {:shutdown, %{x: 1}}}, %{"down" => %{"text" => "{:shutdown, %{x: 1}}"}}},
          {:some_other_atom, %{"text" => ":some_other_atom"}},
          {{:custom, 2}, %{"text" => "{:custom, 2}"}}
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

  # -- close reasons (correction B) --------------------------------------------------------------

  defp round_trip(reason) do
    {:ok, c} =
      %Record{no: 1, kind: :connection_closed, at: at(), conn: 1, peer: "p", reason: reason}
      |> Codec.encode_record()
      |> IO.iodata_to_binary()
      |> Codec.decode_line()

    Codec.decode_reason(c["reason"])
  end

  test "every reason in the exact vocabulary round-trips to the identical term through a line" do
    assert round_trip(:peer_closed) == {:exact, :peer_closed}
    assert round_trip(:line_too_long) == {:exact, :line_too_long}
    %{tcp_error: posix, down: exits} = Codec.exact_reason_vocabulary()
    assert :econnreset in posix and :etimedout in posix and :killed in exits
    for p <- posix, do: assert(round_trip({:tcp_error, p}) == {:exact, {:tcp_error, p}})
    for e <- exits, do: assert(round_trip({:down, e}) == {:exact, {:down, e}})
  end

  test "a reason outside the vocabulary comes back qualified, its category kept, never equal to the original" do
    assert round_trip({:tcp_error, {:weird, 1}}) ==
             {:qualified, {:tcp_error, {:recorded_text, "{:weird, 1}"}}, :unrepresentable}

    assert round_trip({:down, {:shutdown, %{x: 1}}}) ==
             {:qualified, {:down, {:recorded_text, "{:shutdown, %{x: 1}}"}}, :unrepresentable}

    assert round_trip(:some_other_atom) ==
             {:qualified, {:recorded_text, ":some_other_atom"}, :unrepresentable}

    assert round_trip({:custom, 2}) ==
             {:qualified, {:recorded_text, "{:custom, 2}"}, :unrepresentable}

    # A DOWN reason carrying an exception and a stacktrace is text, bounded, never a term.
    {:qualified, {:down, {:recorded_text, text}}, :unrepresentable} =
      round_trip({:down, {%RuntimeError{message: "boom"}, [{__MODULE__, :f, 1, []}]}})

    assert text =~ "RuntimeError" and byte_size(text) < 4_096
  end

  test "legacy format-1 inspected strings are qualified evidence, not reconstructed" do
    assert Codec.decode_reason(%{"tcp_error" => ":econnreset"}) ==
             {:qualified, {:tcp_error, {:recorded_text, ":econnreset"}}, :legacy_text}

    assert Codec.decode_reason(%{"down" => ":killed"}) ==
             {:qualified, {:down, {:recorded_text, ":killed"}}, :legacy_text}

    assert Codec.decode_reason("gone") == {:qualified, {:recorded_text, "gone"}, :legacy_text}
  end

  test "malformed or malicious reason content is returned as recorded and creates no atom" do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    posix_name = "nope_#{suffix}"
    exit_name = "os_cmd_#{suffix}"

    assert Codec.decode_reason(%{"tcp_error" => %{"posix" => posix_name}}) ==
             {:qualified, {:tcp_error, {:recorded_text, posix_name}}, :outside_vocabulary}

    assert Codec.decode_reason(%{"down" => %{"exit" => exit_name}}) ==
             {:qualified, {:down, {:recorded_text, exit_name}}, :outside_vocabulary}

    assert_raise ArgumentError, fn -> String.to_existing_atom(posix_name) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(exit_name) end

    for bad <- [
          12,
          nil,
          ["a"],
          %{},
          %{"tcp_error" => %{"posix" => 1}},
          %{"tcp_error" => %{"posix" => "econnreset", "x" => 1}},
          %{"tcp_error" => %{"posix" => "econnreset"}, "down" => %{"exit" => "killed"}},
          %{"down" => %{"text" => 5}},
          %{"text" => %{"nested" => true}},
          %{"eval" => "System.cmd(\"rm\", [])"}
        ] do
      assert Codec.decode_reason(bad) == {:qualified, {:unrecognized_reason, bad}, :unrecognized}
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

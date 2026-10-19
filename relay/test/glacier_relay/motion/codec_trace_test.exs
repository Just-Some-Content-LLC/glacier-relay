defmodule GlacierRelay.Motion.CodecTraceTest do
  @moduledoc """
  M7-B1: the strict codecs of the motion link and the peer link (design sections 15.5–15.6) and the
  bounded motion trace (section 15.8).
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.Schema
  alias GlacierRelay.Motion.{Codec, Trace}
  alias GlacierRelay.Peer
  alias GlacierRelay.Wire.Framing

  @sid "6b9c8f0e-3d1a-4c2b-9e7f-0a1b2c3d4e5f"

  defp line(map), do: JSON.encode!(map)

  describe "motion link codec" do
    test "round trips every kind in both directions" do
      for {kind, fields} <- [
            {"motion.hello", %{"adapter_instance_id" => Schema.uuid4(), "command_link_generation" => 1}},
            {"hero.sample",
             %{"share_id" => @sid, "seq" => 1, "frame" => 2, "native_mono_ms" => 3, "pos" => "c2a77ccf,416b27e8,bfc2d6ba", "dirty" => false}},
            {"ghost.applied",
             %{"session_id" => @sid, "seq" => 1, "frame" => 2, "native_mono_ms" => 3, "outcome" => "applied", "reason" => nil, "post" => "c2b2fae1,416d47ae", "exact" => true}},
            {"ghost.closed",
             %{"session_id" => @sid, "reason" => "duration", "native_mono_ms" => 3, "clean" => true, "final_world" => nil, "last_applied_seq" => nil, "applied" => 0}}
          ] do
        assert {:ok, {_atom, decoded}} = Codec.decode_from_native(String.trim(Codec.encode_from_native(kind, fields)))
        assert decoded.version == 1
      end

      assert {:ok, {:ghost_target, %{seq: 3, pos: "c2b2fae1,416d47ae"}}} =
               Codec.decode_from_beam(String.trim(Codec.target(@sid, 3, "c2b2fae1,416d47ae")))
    end

    test "refuses unknown kinds, fields, versions, oversize, bad UTF-8, non-finite and miscounted words" do
      base = %{"motion_protocol_version" => 1, "kind" => "ghost.applied", "session_id" => @sid, "seq" => 1, "frame" => 1, "native_mono_ms" => 1, "outcome" => "applied"}
      assert {:ok, _} = Codec.decode_from_native(line(base))
      assert {:error, {:unknown_kind, "ghost.teleport"}} = Codec.decode_from_native(line(%{base | "kind" => "ghost.teleport"}))
      assert {:error, {:unknown_fields, ["speed"]}} = Codec.decode_from_native(line(Map.put(base, "speed", 9)))
      assert {:error, {:unsupported_version, 2}} = Codec.decode_from_native(line(%{base | "motion_protocol_version" => 2}))
      assert {:error, {:invalid_field, "outcome", _}} = Codec.decode_from_native(line(%{base | "outcome" => "maybe"}))
      assert {:error, {:invalid_field, "seq", _}} = Codec.decode_from_native(line(%{base | "seq" => 0}))
      assert {:error, :line_too_long} = Codec.decode_from_native(line(Map.put(base, "reason", String.duplicate("x", 1_100))))
      assert {:error, :invalid_utf8} = Codec.decode_from_native(<<"{\"kind\":\"", 0xFF, "\"}">>)
      # a NaN word and a miscounted group never decode
      assert {:error, {:invalid_field, "post", {:not_finite_words, 2, _}}} =
               Codec.decode_from_native(line(Map.put(base, "post", "7fc00000,416d47ae")))

      assert {:error, {:invalid_field, "post", {:not_finite_words, 2, _}}} =
               Codec.decode_from_native(line(Map.put(base, "post", "c2b2fae1")))

      assert {:error, {:invalid_field, "session_id", :missing}} = Codec.decode_from_native(line(Map.delete(base, "session_id")))
      assert {:error, :missing_kind} = Codec.decode_from_native(line(Map.delete(base, "kind")))
      assert {:error, :not_an_object} = Codec.decode_from_native("[1,2]")
    end

    test "a reason is bounded valid UTF-8 text" do
      assert Codec.to_text(String.duplicate("é", 40)) |> byte_size() <= 64
      assert String.valid?(Codec.to_text(String.duplicate("é", 40)))
      assert Codec.to_text({:native, "x"}) == "{:native, \"x\"}"
    end
  end

  describe "peer codec" do
    test "round trips and strictness" do
      hello = Peer.Codec.hello("host", "game", Schema.uuid4())
      assert {:ok, {:hello, %{client_kind: "game", capabilities: ["pose/1"]}}} = Peer.Codec.decode(String.trim(hello))

      sample = %{
        "peer_protocol_version" => 1,
        "kind" => "pose.sample",
        "stream_id" => @sid,
        "seq" => 1,
        "src_mono_ms" => 0,
        "pos" => "c2b2fae1,416d47ae,00000000",
        "qualified" => true
      }

      assert {:ok, {:pose_sample, %{src_frame: nil, reason: nil}}} = Peer.Codec.decode(line(sample))
      assert {:error, {:unknown_fields, ["session_id"]}} = Peer.Codec.decode(line(Map.put(sample, "session_id", @sid)))
      assert {:error, {:unknown_fields, ["adapter_instance_id"]}} = Peer.Codec.decode(line(Map.put(sample, "adapter_instance_id", @sid)))
      assert {:error, {:invalid_field, "pos", _}} = Peer.Codec.decode(line(%{sample | "pos" => "c2b2fae1,416d47ae"}))
      assert {:error, {:invalid_field, "src_mono_ms", _}} = Peer.Codec.decode(line(%{sample | "src_mono_ms" => -1}))

      open = %{"peer_protocol_version" => 1, "kind" => "stream.open", "stream_id" => @sid, "source_kind" => "replay", "interval_ms" => 50, "src_clock" => "beam"}
      assert {:error, {:invalid_field, "source_kind", _}} = Peer.Codec.decode(line(open))
      assert {:error, {:invalid_field, "interval_ms", _}} = Peer.Codec.decode(line(%{open | "source_kind" => "synthetic", "interval_ms" => 10}))
      assert {:error, {:unknown_kind, "session.open"}} = Peer.Codec.decode(line(%{open | "kind" => "session.open"}))
    end

    test "a line fragmented over many reads decodes once complete; an oversized partial is refused" do
      l = String.trim(Peer.Codec.hello("host", "game", Schema.uuid4())) <> "\n"
      chunks = for <<b::binary-size(1) <- l>>, do: b
      fr = Framing.new(Peer.Codec.max_line_bytes())

      {lines, _} =
        Enum.reduce(chunks, {[], fr}, fn c, {acc, f} ->
          {:ok, ls, f} = Framing.push(f, c)
          {acc ++ ls, f}
        end)

      assert [one] = lines
      assert {:ok, {:hello, _}} = Peer.Codec.decode(one)
      assert {:error, :line_too_long} = Framing.push(fr, String.duplicate("a", 1_025))
    end
  end

  describe "motion trace" do
    setup do
      dir = Path.join(System.tmp_dir!(), "glacier-relay-trace-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "a separate, versioned, 0600 file with sequence, footer and health", %{dir: dir} do
      {:ok, t} = Trace.start_link(dir: dir, role: "test")
      assert :ok = Trace.append(t, [%{"event" => "a"}, %{"event" => "b"}])
      %{path: path, health: :ok, format: "glacier-relay.motion-trace/1"} = Trace.status(t)
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      GenServer.stop(t)
      recs = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      assert Enum.map(recs, & &1["event"]) == ["trace.opened", "a", "b", "trace.closed"]
      assert Enum.map(recs, & &1["trace_seq"]) == [1, 2, 3, 4]
      assert hd(recs)["format"] == "glacier-relay.motion-trace/1"
    end

    test "the bound writes one truncation marker; later appends are refused and counted", %{dir: dir} do
      {:ok, t} = Trace.start_link(dir: dir, role: "test", max_records: 4)
      assert :ok = Trace.append(t, [%{"event" => "a"}, %{"event" => "b"}])
      assert {:error, :full} = Trace.append(t, [%{"event" => "c"}, %{"event" => "d"}])
      assert {:error, :full} = Trace.append(t, [%{"event" => "e"}])
      %{path: path, health: :full, dropped: dropped} = Trace.status(t)
      assert dropped >= 2
      GenServer.stop(t)
      events = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!(&1)["event"])
      assert "trace.truncated" in events and List.last(events) == "trace.closed"
      refute "e" in events
    end

    test "a trace killed without its footer is recognizably incomplete", %{dir: dir} do
      {:ok, t} = Trace.start_link(dir: dir, role: "test", flush_ms: 10)
      Process.unlink(t)
      :ok = Trace.append(t, [%{"event" => "a"}])
      :ok = Trace.flush(t)
      %{path: path} = Trace.status(t)
      Process.exit(t, :kill)
      events = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!(&1)["event"])
      assert events == ["trace.opened", "a"]
    end
  end
end

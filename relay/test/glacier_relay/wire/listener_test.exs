defmodule GlacierRelay.Wire.ListenerTest do
  # Not async: these tests share the application's listener and MissionSession.
  use ExUnit.Case, async: false

  alias GlacierRelay.MissionSession
  alias GlacierRelay.Wire.Listener

  @stage1 File.read!("test/stage1_envelopes.ndjson") |> String.split("\n", trim: true)

  setup do
    :ok = MissionSession.subscribe()
    :ok
  end

  defp connect do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, Listener.port(), [:binary, active: false])
    socket
  end

  defp envelope(instance, sequence, resource \\ "assembly:/x.entity") do
    JSON.encode!(%{
      "protocol_version" => 1,
      "adapter_instance_id" => instance,
      "sequence" => sequence,
      "timestamp" => "2026-10-06T22:00:00.000Z",
      "event_type" => "mission.playing",
      "schema_version" => 1,
      "payload" => %{
        "scene_resource" => resource,
        "scene_type" => "mission",
        "codename_hint" => "T"
      }
    })
  end

  test "listens on loopback only" do
    assert {{127, 0, 0, 1}, port} = Listener.address()
    assert port > 0
  end

  test "delivers the stage 1 envelopes in order to the mission session" do
    socket = connect()
    :ok = :gen_tcp.send(socket, Enum.join(@stage1, "\n") <> "\n")

    for expected <- [1, 2, 3] do
      assert_receive {:relay_event, %{sequence: ^expected, event_type: "mission.playing"}}, 1_000
    end

    instance = MissionSession.state()["9c8f3a75-7054-457c-919d-ee87e77f57d9"]
    assert instance.last_sequence == 3
    assert instance.received >= 3
    assert instance.playing?
    assert instance.gaps == []
    :gen_tcp.close(socket)
  end

  test "bytes arriving in arbitrary chunks are reassembled" do
    socket = connect()
    line = envelope("chunked", 1) <> "\n"

    for chunk <- for(<<c <- line>>, do: <<c>>) |> Enum.chunk_every(7) |> Enum.map(&Enum.join/1) do
      :ok = :gen_tcp.send(socket, chunk)
    end

    assert_receive {:relay_event, %{adapter_instance_id: "chunked", sequence: 1}}, 1_000
    :gen_tcp.close(socket)
  end

  test "a malformed line is dropped and later lines still arrive" do
    socket = connect()

    :ok =
      :gen_tcp.send(
        socket,
        envelope("malformed", 1) <>
          "\n{oops\n" <>
          JSON.encode!(%{"protocol_version" => 9}) <> "\n" <> envelope("malformed", 2) <> "\n"
      )

    assert_receive {:relay_event, %{adapter_instance_id: "malformed", sequence: 1}}, 1_000
    assert_receive {:relay_event, %{adapter_instance_id: "malformed", sequence: 2}}, 1_000
    assert MissionSession.state()["malformed"].gaps == []
    :gen_tcp.close(socket)
  end

  test "a line over the limit closes the connection and nothing after it is delivered" do
    socket = connect()
    huge = String.duplicate("x", 5_000)
    :ok = :gen_tcp.send(socket, huge <> "\n" <> envelope("toolong", 1) <> "\n")
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    refute_receive {:relay_event, %{adapter_instance_id: "toolong"}}, 200
  end

  test "sequence gaps are recorded, not fatal" do
    socket = connect()
    :ok = :gen_tcp.send(socket, envelope("gappy", 1) <> "\n" <> envelope("gappy", 4) <> "\n")
    assert_receive {:relay_event, %{adapter_instance_id: "gappy", sequence: 4}}, 1_000
    assert MissionSession.state()["gappy"].gaps == [{2, 4}]
    :gen_tcp.close(socket)
  end

  test "a reconnecting client is accepted and a new instance id starts a new sequence" do
    first = connect()
    :ok = :gen_tcp.send(first, envelope("run-a", 1) <> "\n")
    assert_receive {:relay_event, %{adapter_instance_id: "run-a", sequence: 1}}, 1_000
    :gen_tcp.close(first)

    second = connect()
    :ok = :gen_tcp.send(second, envelope("run-b", 1) <> "\n")
    assert_receive {:relay_event, %{adapter_instance_id: "run-b", sequence: 1}}, 1_000
    assert MissionSession.state()["run-b"].gaps == []
    :gen_tcp.close(second)
  end

  test "the listener never sends anything to the client" do
    socket = connect()
    :ok = :gen_tcp.send(socket, envelope("silent", 1) <> "\n")
    assert_receive {:relay_event, %{adapter_instance_id: "silent"}}, 1_000
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 300)
    :gen_tcp.close(socket)
  end

  test "the listener rebinds after a crash while an accepted connection keeps working" do
    socket = connect()
    # Make sure the connection has been accepted (a connection still in the backlog dies with the
    # listen socket; the native client handles that by reconnecting).
    :ok = :gen_tcp.send(socket, envelope("survivor", 1) <> "\n")
    assert_receive {:relay_event, %{adapter_instance_id: "survivor", sequence: 1}}, 1_000

    old = Process.whereis(Listener)
    Process.exit(old, :kill)
    wait_until(fn -> Process.whereis(Listener) not in [nil, old] end)

    :ok = :gen_tcp.send(socket, envelope("survivor", 2) <> "\n")
    assert_receive {:relay_event, %{adapter_instance_id: "survivor", sequence: 2}}, 1_000
    assert MissionSession.state()["survivor"].gaps == []

    {:ok, fresh} = :gen_tcp.connect({127, 0, 0, 1}, Listener.port(), [:binary, active: false])
    :gen_tcp.close(fresh)
    :gen_tcp.close(socket)
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end

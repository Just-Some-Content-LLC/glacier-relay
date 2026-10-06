defmodule GlacierRelay.Wire.ListenerTest do
  # Not async: these tests share the application's listener and MissionSession.
  use ExUnit.Case, async: false

  alias GlacierRelay.{Lifecycle, MissionSession}
  alias GlacierRelay.Lifecycle.Attempt
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

  defp envelope(instance, sequence, resource \\ "assembly:/x.entity", opts \\ []) do
    JSON.encode!(%{
      "protocol_version" => 1,
      "adapter_instance_id" => instance,
      "sequence" => sequence,
      "timestamp" => Keyword.get(opts, :timestamp, "2026-10-06T22:00:00.000Z"),
      "event_type" => Keyword.get(opts, :type, "mission.playing"),
      "schema_version" => 1,
      "payload" => %{
        "scene_resource" => resource,
        "scene_type" => "mission",
        "codename_hint" => "T"
      }
    })
  end

  defp playing(instance, seq, ts, resource \\ "assembly:/x.entity"),
    do: envelope(instance, seq, resource, timestamp: ts) <> "\n"

  defp stopped(instance, seq, ts, resource \\ "assembly:/x.entity"),
    do: envelope(instance, seq, resource, timestamp: ts, type: "mission.stopped") <> "\n"

  # Waits for the session to see this test's connection close (the `tcp_closed` arrives
  # asynchronously after the client closes).
  defp await_closed(instance) do
    assert_receive {:relay_connection, :closed, %{instance_id: ^instance}}, 1_000
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
    assert instance.gaps == []
    # Three mission.playing with no falls (the M1 stream): attempts 1 and 2 were superseded, 3 is
    # last known playing. Nothing is marked stopped.
    assert Enum.map(instance.attempts, & &1.mission) == [:superseded, :superseded, :playing]
    assert Lifecycle.observation(instance) == :live
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

  # -- Stage A: connection evidence versus mission evidence ----------------------------------

  test "connection opened and closed with no event stays an unidentified connection" do
    socket = connect()
    assert_receive {:relay_connection, :opened, %{peer: peer}}, 1_000
    :gen_tcp.close(socket)

    assert_receive {:relay_connection, :closed,
                    %{peer: ^peer, instance_id: nil, reason: :peer_closed}},
                   1_000

    assert MissionSession.summary_text() =~
             "connections that closed before identifying an instance"
  end

  test "normal playing then stopped over the wire is one bounded attempt" do
    socket = connect()

    :ok =
      :gen_tcp.send(
        socket,
        playing("bounded", 1, "2026-10-06T22:44:38.230Z") <>
          stopped("bounded", 2, "2026-10-06T22:45:44.243Z")
      )

    assert_receive {:relay_event,
                    %{adapter_instance_id: "bounded", sequence: 2, event_type: "mission.stopped"}},
                   1_000

    instance = MissionSession.state()["bounded"]
    assert [%Attempt{mission: :stopped} = attempt] = instance.attempts
    assert Lifecycle.duration_ms(attempt) == 66_013
    assert %DateTime{} = attempt.playing.received_at
    assert Lifecycle.observation(instance) == :live
    :gen_tcp.close(socket)
    await_closed("bounded")
    assert Lifecycle.observation(MissionSession.state()["bounded"]) == :lost
  end

  test "connection closes with no open attempt: observation lost, attempt untouched" do
    socket = connect()

    :ok =
      :gen_tcp.send(
        socket,
        playing("closed-idle", 1, "2026-10-06T22:44:38.230Z") <>
          stopped("closed-idle", 2, "2026-10-06T22:45:44.243Z")
      )

    assert_receive {:relay_event, %{adapter_instance_id: "closed-idle", sequence: 2}}, 1_000
    :gen_tcp.close(socket)
    await_closed("closed-idle")

    instance = MissionSession.state()["closed-idle"]
    assert Lifecycle.observation(instance) == :lost
    assert [%Attempt{mission: :stopped, interruptions: []}] = instance.attempts
    assert [%{close_reason: :peer_closed}] = instance.connections
  end

  test "connection closes while an attempt is open: last known playing, no stop invented" do
    socket = connect()
    :ok = :gen_tcp.send(socket, playing("closed-open", 1, "2026-10-06T22:47:20.571Z"))
    assert_receive {:relay_event, %{adapter_instance_id: "closed-open", sequence: 1}}, 1_000
    :gen_tcp.close(socket)
    await_closed("closed-open")

    instance = MissionSession.state()["closed-open"]
    assert Lifecycle.observation(instance) == :lost

    assert %Attempt{mission: :playing, stopped: nil, interruptions: [%{reason: :peer_closed}]} =
             Lifecycle.current_attempt(instance)

    assert MissionSession.summary_text() =~
             "stop not observed; last known playing; observation lost"
  end

  test "semantic stop followed by connection close: stopped by evidence, then observation lost" do
    socket = connect()
    :ok = :gen_tcp.send(socket, playing("stop-then-close", 1, "2026-10-06T22:44:38.230Z"))
    assert_receive {:relay_event, %{adapter_instance_id: "stop-then-close", sequence: 1}}, 1_000
    :ok = :gen_tcp.send(socket, stopped("stop-then-close", 2, "2026-10-06T22:45:44.243Z"))
    assert_receive {:relay_event, %{adapter_instance_id: "stop-then-close", sequence: 2}}, 1_000
    :gen_tcp.close(socket)
    await_closed("stop-then-close")

    [summary] =
      Enum.filter(MissionSession.summary(), &(&1.adapter_instance_id == "stop-then-close"))

    assert [%{mission: :stopped, interrupted?: false, duration_ms: 66_013}] = summary.attempts
    assert summary.observation == :lost
  end

  test "reconnect with the same instance id resumes observation and can close the open attempt" do
    first = connect()
    :ok = :gen_tcp.send(first, playing("resume", 1, "2026-10-06T22:44:38.230Z"))
    assert_receive {:relay_event, %{adapter_instance_id: "resume", sequence: 1}}, 1_000
    :gen_tcp.close(first)
    await_closed("resume")
    assert Lifecycle.observation(MissionSession.state()["resume"]) == :lost

    second = connect()
    :ok = :gen_tcp.send(second, stopped("resume", 2, "2026-10-06T22:45:44.243Z"))
    assert_receive {:relay_event, %{adapter_instance_id: "resume", sequence: 2}}, 1_000

    instance = MissionSession.state()["resume"]
    assert Lifecycle.observation(instance) == :live

    assert [%Attempt{mission: :stopped, interruptions: [%{reason: :peer_closed}]}] =
             instance.attempts

    assert length(instance.connections) == 2
    :gen_tcp.close(second)
  end

  test "a replacement connection with a new instance id invents nothing for the old one" do
    first = connect()
    :ok = :gen_tcp.send(first, playing("old-process", 1, "2026-10-06T22:44:38.230Z"))
    assert_receive {:relay_event, %{adapter_instance_id: "old-process", sequence: 1}}, 1_000
    :gen_tcp.close(first)
    await_closed("old-process")

    second = connect()
    :ok = :gen_tcp.send(second, playing("new-process", 1, "2026-10-06T22:50:00.000Z"))
    assert_receive {:relay_event, %{adapter_instance_id: "new-process", sequence: 1}}, 1_000

    old = MissionSession.state()["old-process"]
    assert %Attempt{mission: :playing} = Lifecycle.current_attempt(old)
    assert Lifecycle.observation(old) == :lost
    assert Lifecycle.observation(MissionSession.state()["new-process"]) == :live
    :gen_tcp.close(second)
  end

  test "a malformed mission.stopped is rejected and the attempt stays open" do
    socket = connect()

    bad =
      JSON.encode!(%{
        "protocol_version" => 1,
        "adapter_instance_id" => "bad-stop",
        "sequence" => 2,
        "timestamp" => "t",
        "event_type" => "mission.stopped",
        "schema_version" => 1,
        "payload" => %{"scene_resource" => 1}
      })

    :ok =
      :gen_tcp.send(
        socket,
        playing("bad-stop", 1, "2026-10-06T22:44:38.230Z") <>
          bad <> "\n" <> playing("bad-stop", 3, "2026-10-06T22:45:55.143Z")
      )

    assert_receive {:relay_event, %{adapter_instance_id: "bad-stop", sequence: 3}}, 1_000
    refute_received {:relay_event, %{adapter_instance_id: "bad-stop", sequence: 2}}

    instance = MissionSession.state()["bad-stop"]
    assert instance.gaps == [{2, 3}]
    assert Enum.map(instance.attempts, & &1.mission) == [:superseded, :playing]
    :gen_tcp.close(socket)
  end

  test "sequence gaps across both event types are recorded as before" do
    socket = connect()

    :ok =
      :gen_tcp.send(
        socket,
        playing("gap-mixed", 1, "2026-10-06T22:44:38.230Z") <>
          stopped("gap-mixed", 5, "2026-10-06T22:45:44.243Z")
      )

    assert_receive {:relay_event, %{adapter_instance_id: "gap-mixed", sequence: 5}}, 1_000
    instance = MissionSession.state()["gap-mixed"]
    assert instance.gaps == [{2, 5}]
    assert [%Attempt{mission: :stopped}] = instance.attempts
    :gen_tcp.close(socket)
  end

  test "the summary is generated from the delivered events" do
    socket = connect()

    :ok =
      :gen_tcp.send(
        socket,
        playing("summary", 1, "2026-10-06T22:44:38.230Z", "assembly:/paris.entity") <>
          stopped("summary", 2, "2026-10-06T22:45:44.243Z", "assembly:/paris.entity") <>
          playing("summary", 3, "2026-10-06T22:47:20.571Z", "assembly:/sapienza.entity")
      )

    assert_receive {:relay_event, %{adapter_instance_id: "summary", sequence: 3}}, 1_000
    :gen_tcp.close(socket)
    await_closed("summary")

    text = MissionSession.summary_text()
    assert text =~ "adapter summary: 3 event(s), last sequence 3, gaps [], observation lost"

    assert text =~
             "attempt 1: T (assembly:/paris.entity): playing 2026-10-06T22:44:38.230Z (#1), stopped 2026-10-06T22:45:44.243Z (#2), duration 66.0 s"

    assert text =~
             "attempt 2: T (assembly:/sapienza.entity): playing 2026-10-06T22:47:20.571Z (#3), stop not observed; last known playing; observation lost"
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end

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

  # -- B1: actor outcomes over the wire ----------------------------------------------------

  @b1 File.read!("test/b1_probe_envelopes.ndjson") |> String.split("\n", trim: true)

  test "the B1 native envelopes arrive in order and the outcomes land on the attempt" do
    socket = connect()
    :ok = :gen_tcp.send(socket, Enum.join(@b1, "\n") <> "\n")
    assert_receive {:relay_event, %{sequence: 18, event_type: "mission.stopped"}}, 1_000

    instance = MissionSession.state()["bf3be44e-a36d-4ac6-9508-d94330fb855e"]
    assert instance.gaps == []
    assert [%Attempt{mission: :stopped, outcomes: outcomes}] = instance.attempts
    assert length(outcomes) == 16
    assert Enum.count(outcomes, &(&1.kind == :died)) == 10
    assert %DateTime{} = hd(outcomes).received_at
    assert MissionSession.summary_text() =~ "10 died (1 target, 9 non-target"
    :gen_tcp.close(socket)
  end

  test "an actor outcome sent with no open attempt is unattributed" do
    [_playing | rest] = @b1

    first_outcome =
      hd(rest) |> String.replace("bf3be44e-a36d-4ac6-9508-d94330fb855e", "orphan-outcome")

    socket = connect()
    :ok = :gen_tcp.send(socket, first_outcome <> "\n")

    assert_receive {:relay_event,
                    %{adapter_instance_id: "orphan-outcome", event_type: "actor.pacified"}},
                   1_000

    instance = MissionSession.state()["orphan-outcome"]
    assert instance.attempts == []
    assert [%{kind: :pacified}] = instance.unattributed_outcomes
    assert MissionSession.summary_text() =~ "with no open attempt"
    :gen_tcp.close(socket)
  end

  # -- B2: contract lifecycle over the wire --------------------------------------------------

  @b2 File.read!("test/b2_probe_envelopes.ndjson") |> String.split("\n", trim: true)

  test "the B2 native envelopes arrive in order; contract sessions pair by order and dispositions derive from contract evidence" do
    socket = connect()
    :ok = :gen_tcp.send(socket, Enum.join(@b2, "\n") <> "\n")
    assert_receive {:relay_event, %{sequence: 9, event_type: "contract.ended"}}, 1_000

    instance = MissionSession.state()["a5092b81-2103-4ec1-81a3-8103db3db375"]
    assert instance.gaps == []

    assert [
             %Attempt{mission: :stopped, contract_paired_by: :next_rise, disposition: :restarted},
             %Attempt{mission: :stopped, contract_paired_by: :open_attempt, disposition: :exited_to_menu}
           ] = instance.attempts

    assert length(instance.contract_sessions) == 2
    assert instance.anomalies == [] and instance.unmatched_contract_ends == []
    text = MissionSession.summary_text()
    assert text =~ "disposition (BEAM-derived, session paired by next_rise): restarted"
    assert text =~ "disposition (BEAM-derived, session paired by open_attempt): exited to menu"
    :gen_tcp.close(socket)
  end

  test "a contract.ended for an unknown session over the wire stays unmatched" do
    orphan = List.last(@b2) |> String.replace("a5092b81-2103-4ec1-81a3-8103db3db375", "orphan-contract")
    socket = connect()
    :ok = :gen_tcp.send(socket, orphan <> "\n")
    assert_receive {:relay_event, %{adapter_instance_id: "orphan-contract", event_type: "contract.ended"}}, 1_000

    instance = MissionSession.state()["orphan-contract"]
    assert instance.attempts == [] and instance.contract_sessions == []
    assert [%{payload: %{reason_kind: "exit_to_menu"}}] = instance.unmatched_contract_ends
    assert MissionSession.summary_text() =~ "with no open contract session"
    :gen_tcp.close(socket)
  end

  # -- B3: disguise over the wire ------------------------------------------------------------

  @b3 File.read!("test/b3_probe_envelopes.ndjson") |> String.split("\n", trim: true)
  @b3_id "2f06fed8-6542-47fd-b383-68580798c96b"

  test "the B3 native envelopes arrive in order; disguise occurrences attach by order and the derived view reads them conservatively" do
    socket = connect()
    :ok = :gen_tcp.send(socket, Enum.join(@b3, "\n") <> "\n")
    assert_receive {:relay_event, %{sequence: 22, event_type: "contract.ended"}}, 1_000

    instance = MissionSession.state()[@b3_id]
    assert instance.gaps == [] and instance.unattributed_disguise_events == []
    assert [%Attempt{disguise_events: first}, %Attempt{disguise_events: second}] = instance.attempts
    assert Enum.map(first, &{&1.type, &1.kind, &1.sequence}) == [
             {:equipped, :initial, 3}, {:equipped, :change, 4}, {:compromised, nil, 5}, {:compromise_cleared, nil, 10},
             {:equipped, :change, 11}, {:compromised, nil, 12}, {:compromise_cleared, nil, 15}
           ]
    assert Enum.map(second, &{&1.type, &1.kind, &1.sequence}) == [{:equipped, :initial, 20}]

    [a1, a2] = instance.attempts
    assert %{worn_standing: :cleared, changes: 2, history: :complete, anomalies: []} = GlacierRelay.Disguise.derive(a1, instance)
    assert %{worn_standing: :not_observed, changes: 0, used: ["874c4c48-0a8b-49e9-883e-49fc5f1fb051"]} = GlacierRelay.Disguise.derive(a2, instance)

    text = MissionSession.summary_text()
    assert text =~ "disguise state (BEAM-derived): worn 992cc7b6… since #11; worn outfit: cleared; 2 changes, 3 definitions used; history intact"
    assert text =~ "worn 874c4c48… (equals the starting suit id) since #20; worn outfit: no compromise observed"
    refute text =~ ~r/clean|undetected|safe|silent assassin|complet/i
    :gen_tcp.close(socket)
  end

  test "a disguise event with no open attempt over the wire stays unattributed" do
    orphan = Enum.at(@b3, 4) |> String.replace(@b3_id, "orphan-disguise")
    socket = connect()
    :ok = :gen_tcp.send(socket, orphan <> "\n")
    assert_receive {:relay_event, %{adapter_instance_id: "orphan-disguise", event_type: "disguise.compromised"}}, 1_000

    instance = MissionSession.state()["orphan-disguise"]
    assert instance.attempts == []
    assert [%{type: :compromised, sequence: 5}] = instance.unattributed_disguise_events
    assert MissionSession.summary_text() =~ "disguise compromised 2018db77… #5 @222.863129s with no open attempt"
    :gen_tcp.close(socket)
  end

  # -- B4: items over the wire ---------------------------------------------------------------

  @b4 File.read!("test/b4_probe_envelopes.ndjson") |> String.split("\n", trim: true)
  @b4_id "31c81c1e-071d-4ff4-8dd2-462b9b97900c"

  test "the B4 native envelopes arrive in order; item occurrences attach by order and are counted directly, beside the accepted vocabulary" do
    socket = connect()
    :ok = :gen_tcp.send(socket, Enum.join(@b4, "\n") <> "\n")
    assert_receive {:relay_event, %{sequence: 45, event_type: "contract.ended"}}, 1_000

    instance = MissionSession.state()[@b4_id]
    assert instance.gaps == [] and instance.unattributed_item_events == [] and instance.unattributed_disguise_events == []
    assert [%Attempt{item_events: first} = a1, %Attempt{item_events: []} = a2] = instance.attempts
    assert length(first) == 24
    assert Enum.map(first, & &1.type) |> Enum.frequencies() == %{picked_up: 12, thrown: 6, removed_from_inventory: 6}
    assert Enum.map(first, & &1.sequence) == [4, 6, 7, 8, 11, 12, 14, 15, 18, 19, 20, 22, 23, 24, 27, 28, 29, 30, 32, 33, 35, 36, 37, 38]

    items = GlacierRelay.Items.derive(a1, instance)
    assert %{picked_up: 12, thrown: 6, removed_from_inventory: 6, history: :complete} = items
    assert length(items.definitions_used) == 7
    assert GlacierRelay.Items.derive(a2, instance).occurrences == 0

    # The accepted vocabulary in the same stream is unchanged by the new rows.
    assert Enum.map(a1.disguise_events, & &1.sequence) == [3, 5, 9, 17, 21, 25, 26]
    assert Enum.map(a1.outcomes, & &1.sequence) == [10, 13, 16, 31, 34]
    assert %{worn_standing: :cleared, changes: 2, history: :complete} = GlacierRelay.Disguise.derive(a1, instance)
    assert a1.disposition == :restarted and a2.disposition == :exited_to_menu

    text = MissionSession.summary_text()
    assert text =~ "items (engine telemetry): picked up 12 — Wrench ×3, Crowbar ×3, Emetic Rat Poison, Lead Pipe, Kitchen Knife ×2, Cleaver, Propane Flask; thrown 6 — Wrench ×2, Crowbar, Lead Pipe, Kitchen Knife, Propane Flask; removed from inventory 6 — Wrench ×2, Crowbar, Lead Pipe, Kitchen Knife, Propane Flask; 7 definitions; history intact"
    assert text =~ "items (engine telemetry): none observed in the attempt"
    refute text =~ ~r/inventory contents|holding|carried|owns|recovered|throws|clean|undetected|safe|silent assassin|complet/i
    :gen_tcp.close(socket)
  end

  test "an item event with no open attempt over the wire stays unattributed" do
    orphan = Enum.at(@b4, 6) |> String.replace(@b4_id, "orphan-item")
    socket = connect()
    :ok = :gen_tcp.send(socket, orphan <> "\n")
    assert_receive {:relay_event, %{adapter_instance_id: "orphan-item", event_type: "item.thrown"}}, 1_000

    instance = MissionSession.state()["orphan-item"]
    assert instance.attempts == []
    assert [%{type: :thrown, sequence: 7}] = instance.unattributed_item_events
    assert MissionSession.summary_text() =~ "item thrown 6adddf7e… #7 @209.153168s with no open attempt"
    :gen_tcp.close(socket)
  end

  test "an item envelope with an empty instance id is rejected on the wire and the next valid envelope still arrives" do
    id = "empty-instance-id"
    [playing_line, pickup_line, removed_line] = [Enum.at(@b4, 1), Enum.at(@b4, 3), Enum.at(@b4, 5)] |> Enum.map(&String.replace(&1, @b4_id, id))
    bad = String.replace(pickup_line, ~s("item_repository_id":"), ~s("item_instance_id":"","item_repository_id":"))
    assert bad =~ ~s("item_instance_id":"")

    socket = connect()
    :ok = :gen_tcp.send(socket, playing_line <> "\n" <> bad <> "\n" <> removed_line <> "\n")
    assert_receive {:relay_event, %{adapter_instance_id: ^id, sequence: 2, event_type: "mission.playing"}}, 1_000
    assert_receive {:relay_event, %{adapter_instance_id: ^id, sequence: 6, event_type: "item.removed_from_inventory"}}, 1_000
    refute_received {:relay_event, %{adapter_instance_id: ^id, sequence: 4}}

    instance = MissionSession.state()[id]
    # The rejected line never reached the model: it is not an item fact, not an absence, and the
    # only trace is the sequence gap 3→6 (the rejected #4 plus the #5 this test did not send).
    assert [%Attempt{item_events: [%{type: :removed_from_inventory, sequence: 6}]}] = instance.attempts
    assert instance.gaps == [{3, 6}]
    assert GlacierRelay.Items.derive(hd(instance.attempts), instance).removed_from_inventory == 1
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

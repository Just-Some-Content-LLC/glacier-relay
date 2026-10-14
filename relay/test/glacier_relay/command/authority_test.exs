defmodule GlacierRelay.Command.AuthorityTest do
  @moduledoc """
  The command subtree against a fake native peer (M5-A): listener and link, the handshake and
  its trust states, arming, issuance rules, the full probe ladder, result correlation by command
  id and link generation, stale and foreign results, native statuses, unknown outcomes, two peers,
  protocol violations, the journal, shutdown, and the observer's indifference to all of it.
  The fake peer is never evidence of native game execution.
  """
  # Not async: the subtree's processes are named singletons and the telemetry check uses the
  # shared MissionSession.
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Authority, Journal, Listener, Schema}
  alias GlacierRelay.MissionSession
  alias GlacierRelay.Test.{FakeNative, FixturePlayer, StubWriter}

  @ack 300
  @grace 200
  @ttl 500

  setup context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-cmd-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)

    writer =
      if context[:stub_writer], do: [writer: {StubWriter, elem(StubWriter.start(), 1)}], else: []

    start_supervised!(
      {Command.Supervisor,
       [
         port: 0,
         journal_dir: dir,
         ack_timeout_ms: @ack,
         grace_ms: @grace,
         default_ttl_ms: @ttl,
         min_ttl_ms: 50,
         hello_timeout_ms: 400
       ] ++
         writer}
    )

    %{port: Listener.port(), dir: dir, agent: writer[:writer] && elem(writer[:writer], 1)}
  end

  defp journal_events do
    %{path: path} = Journal.status()

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
    |> Enum.map(& &1["event"])
  end

  defp journal_entries do
    %{path: path} = Journal.status()
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp wait(fun), do: FixturePlayer.wait_until(fun, 100, 10)

  defp armed_peer(port) do
    {socket, adapter, welcome} = FakeNative.handshake(port)
    assert :ok = Command.arm()
    {socket, adapter, welcome["link_generation"]}
  end

  defp probe_and_receive(socket) do
    assert {:ok, id} = Command.probe()
    assert {:ok, cmd} = FakeNative.recv(socket)
    assert cmd["command_id"] == id
    {id, cmd}
  end

  # -- listener and handshake ----------------------------------------------------------------------

  test "the listener binds loopback only, on its own port, and refuses non-loopback at start", %{
    port: port
  } do
    assert {{127, 0, 0, 1}, ^port} = Listener.address()
    assert port > 0 and port != GlacierRelay.Wire.Listener.port()
    Process.flag(:trap_exit, true)

    assert {:error, {:not_loopback, {0, 0, 0, 0}}} =
             GenServer.start(Listener, ip: {0, 0, 0, 0}, port: 0)
  end

  test "trust states are distinct: connected, negotiated, identified (never authenticated), armed, ready",
       %{port: port} do
    assert Command.enabled?()

    assert %{
             trust: %{
               transport: :none,
               protocol: :none,
               peer: :none,
               authenticated: false,
               armed: false,
               ready: false
             }
           } = Command.status()

    socket = FakeNative.connect(port)
    assert wait(fn -> Command.status().trust.transport == :connected end)

    assert %{trust: %{protocol: :not_negotiated, peer: :unidentified, armed: false, ready: false}} =
             Command.status()

    assert {:error, :no_identified_link} = Command.arm()
    assert {:error, :disarmed} = Command.probe()

    adapter = Schema.uuid4()
    FakeNative.send_json(socket, FakeNative.hello(adapter, mission_generation: "gen-a"))
    assert {:ok, welcome} = FakeNative.recv(socket)

    assert welcome["kind"] == "welcome" and welcome["link_generation"] == 1 and
             welcome["command_protocol_version"] == 1

    assert welcome["allowlist"] == [%{"name" => "relay.probe", "version" => 1}]

    assert wait(fn -> Command.status().trust.peer == :identified end)
    s = Command.status()

    assert s.trust == %{
             transport: :connected,
             protocol: :negotiated,
             peer: :identified,
             authenticated: false,
             armed: false,
             ready: false
           }

    assert s.link.adapter_instance_id == adapter and s.link.mission_generation == "gen-a" and
             s.link.generation == 1

    assert :ok = Command.arm()
    assert {:error, :already_armed} = Command.arm()
    assert %{trust: %{armed: true, ready: true, authenticated: false}} = Command.status()
    assert :ok = Command.disarm()
    assert %{trust: %{armed: false, ready: false}} = Command.status()
    assert {:error, :disarmed} = Command.probe()

    entry = Enum.find(journal_entries(), &(&1["event"] == "peer.identified"))

    assert entry["trust"] == "identified (claimed; not authenticated)" and
             entry["adapter_instance_id"] == adapter

    FakeNative.close(socket)
  end

  # -- the ladder ------------------------------------------------------------------------------------

  test "the full probe ladder: accepted, transmitted, received, applied with a native read-back, never independently observed",
       %{port: port} do
    {socket, adapter, gen} = armed_peer(port)
    {id, cmd} = probe_and_receive(socket)

    assert cmd["kind"] == "command" and cmd["name"] == "relay.probe" and cmd["version"] == 1

    assert cmd["link_generation"] == gen and cmd["params"] == %{} and cmd["preconditions"] == %{} and
             cmd["ttl_ms"] == @ttl

    assert is_binary(cmd["issued_at"]) and cmd["command_protocol_version"] == 1

    assert %{in_flight: %{id: ^id, status: :transmitted}, trust: %{ready: false}} =
             Command.status()

    FakeNative.send_json(socket, FakeNative.result(cmd, adapter, "received"))
    assert wait(fn -> Command.command(id).status == :received end)

    observed = %{"scene_loaded" => true, "mission_playing" => false, "frame" => 1234}

    FakeNative.send_json(
      socket,
      FakeNative.result(cmd, adapter, "applied", %{
        "observed" => observed,
        "frame" => 1234,
        "mission_generation" => "gen-a"
      })
    )

    assert wait(fn -> Command.command(id).status == :applied end)

    c = Command.command(id)
    assert Enum.map(c.stages, &elem(&1, 0)) == [:accepted, :transmitted, :received, :applied]
    assert Enum.all?(c.stages, fn {_, ms} -> is_integer(ms) and ms >= 0 end)
    assert c.observed == :native and c.independent_observation == :not_available
    assert c.result.observed == observed and c.result.mission_generation == "gen-a"
    assert %{in_flight: nil, trust: %{ready: true}} = Command.status()

    events = journal_events()

    assert events |> Enum.filter(&String.starts_with?(&1, "command.")) ==
             ~w(command.accepted command.transmitted command.received command.terminal)

    terminal = Enum.find(journal_entries(), &(&1["event"] == "command.terminal"))

    assert terminal["observed_label"] == "native" and
             terminal["independent_observation"] == "not_available"

    assert terminal["command_id"] == id and terminal["link_generation"] == gen
    FakeNative.close(socket)
  end

  test "issuance rules: unknown, reserved, duplicate, one in flight, ttl bounds, parameters", %{
    port: port
  } do
    {socket, adapter, _gen} = armed_peer(port)

    assert {:error, {:unknown_command, "relay.nope", 1}} = Authority.issue("relay.nope", 1)
    assert {:error, {:unknown_command, "relay.probe", 2}} = Authority.issue("relay.probe", 2)

    assert {:error, {:not_issuable, "player.outfit.set", 1}} =
             Authority.issue("player.outfit.set", 1, %{"disguise_repository_id" => Schema.uuid4()})

    assert {:error, {:ttl_out_of_range, 10}} = Command.probe(ttl_ms: 10)
    assert {:error, {:ttl_out_of_range, 20_000}} = Command.probe(ttl_ms: 20_000)
    assert {:error, {:invalid_command_id, "x"}} = Command.probe(command_id: "x")
    assert {:error, {:unknown_params, ["x"]}} = Authority.issue("relay.probe", 1, %{"x" => 1})

    fixed = Schema.uuid4()
    {^fixed, cmd} = probe_and_receive_with(socket, command_id: fixed)
    assert {:error, {:in_flight, ^fixed}} = Command.probe()
    FakeNative.respond(socket, cmd, adapter, "applied")
    assert wait(fn -> Command.command(fixed).status == :applied end)
    assert {:error, {:duplicate_command_id, ^fixed}} = Command.probe(command_id: fixed)
    assert Command.status().counters.refused >= 7
    refute Enum.any?(drain_lines(socket), &(&1["name"] == "player.outfit.set"))
    FakeNative.close(socket)
  end

  defp probe_and_receive_with(socket, opts) do
    assert {:ok, id} = Command.probe(opts)
    assert {:ok, cmd} = FakeNative.recv(socket)
    {id, cmd}
  end

  # Drains whatever the authority sent without a reply (nothing is expected here).
  defp drain_lines(socket) do
    case FakeNative.recv(socket, 50) do
      {:ok, line} -> [line | drain_lines(socket)]
      {:error, _} -> []
    end
  end

  test "every native terminal status is recorded as the native said it; a read-back is native observation only",
       %{port: port} do
    {socket, adapter, _} = armed_peer(port)

    for status <- ~w(rejected busy duplicate expired precondition_failed unavailable failed) do
      {id, cmd} = probe_and_receive(socket)
      FakeNative.respond(socket, cmd, adapter, status, %{"reason" => "native said #{status}"})
      assert wait(fn -> Command.command(id).status == String.to_atom(status) end)
      c = Command.command(id)
      assert c.observed == :none and c.result.reason == "native said #{status}"
    end

    # "applied" echoing a requested value is a native read-back, never an independent observation.
    {id, cmd} = probe_and_receive(socket)
    FakeNative.respond(socket, cmd, adapter, "applied", %{"observed" => %{"echo" => "requested"}})
    assert wait(fn -> Command.command(id).status == :applied end)
    assert %{observed: :native, independent_observation: :not_available} = Command.command(id)
    FakeNative.close(socket)
  end

  # -- unknown outcomes ---------------------------------------------------------------------------------

  test "a missed acknowledgement, a lost terminal result and a link lost after transmission each end unknown",
       %{port: port} do
    {socket, adapter, gen} = armed_peer(port)

    {id, _cmd} = probe_and_receive(socket)
    assert wait(fn -> Command.command(id).status == :unknown end)
    assert Command.command(id).unknown_reason == :ack_timeout
    assert %{in_flight: nil, trust: %{armed: true}} = Command.status()

    {id2, cmd2} = probe_and_receive(socket)
    FakeNative.send_json(socket, FakeNative.result(cmd2, adapter, "received"))
    assert wait(fn -> Command.command(id2).status == :received end)
    assert wait(fn -> Command.command(id2).status == :unknown end)
    assert Command.command(id2).unknown_reason == :terminal_timeout

    {id3, _} = probe_and_receive(socket)
    FakeNative.close(socket)
    assert wait(fn -> Command.command(id3).status == :unknown end)
    assert Command.command(id3).unknown_reason == :link_lost
    assert %{trust: %{transport: :none, armed: false, ready: false}, link: nil} = Command.status()
    assert Command.status().counters.unknown == 3

    events = journal_events()
    assert Enum.count(events, &(&1 == "command.unknown")) == 3
    assert "link.closed" in events

    disarm =
      Enum.find(
        journal_entries(),
        &(&1["event"] == "authority.disarmed" and &1["by"] == "link_loss")
      )

    assert disarm["link_generation"] == gen
    # No automatic retry: three commands issued, nothing re-sent.
    assert Command.status().counters.issued == 3
  end

  test "a reconnect gets a new generation and needs new arming; results from the old link are stale; foreign and unmatched results are anomalies",
       %{port: port} do
    {socket1, adapter1, 1} = armed_peer(port)
    {id, cmd} = probe_and_receive(socket1)
    FakeNative.close(socket1)
    assert wait(fn -> Command.command(id).status == :unknown end)

    {socket2, adapter2, welcome} = FakeNative.handshake(port)
    assert welcome["link_generation"] == 2
    assert {:error, :disarmed} = Command.probe()
    assert :ok = Command.arm()

    # The old link's result for the old command: stale (generation 1 on link 2).
    FakeNative.send_json(socket2, FakeNative.result(cmd, adapter1, "applied"))

    # A result carrying the new generation for a command not in flight and unknown here: unmatched.
    FakeNative.send_json(
      socket2,
      FakeNative.result(
        Map.put(cmd, "link_generation", 2) |> Map.put("command_id", Schema.uuid4()),
        adapter2,
        "applied"
      )
    )

    # A result from another adapter identity on this link: foreign.
    FakeNative.send_json(
      socket2,
      FakeNative.result(Map.put(cmd, "link_generation", 2), Schema.uuid4(), "applied")
    )

    assert wait(fn -> Command.status().counters.anomalies == 3 end)
    assert Command.command(id).status == :unknown

    events = journal_events()

    assert "anomaly.stale_result" in events and "anomaly.unmatched_result" in events and
             "anomaly.foreign_result" in events

    # A late acknowledgement or a second terminal result after the end is an anomaly too; and the
    # old command's own id, now on the new generation, is a late result, not a new outcome.
    FakeNative.send_json(
      socket2,
      FakeNative.result(Map.put(cmd, "link_generation", 2), adapter2, "applied")
    )

    assert wait(fn -> Command.status().counters.anomalies == 4 end)
    assert Command.command(id).status == :unknown
    {id2, cmd2} = probe_and_receive(socket2)
    FakeNative.respond(socket2, cmd2, adapter2, "applied")
    assert wait(fn -> Command.command(id2).status == :applied end)
    FakeNative.send_json(socket2, FakeNative.result(cmd2, adapter2, "received"))
    assert wait(fn -> Command.status().counters.anomalies == 5 end)
    assert Command.command(id2).status == :applied
    assert Enum.count(journal_events(), &(&1 == "anomaly.late_result")) == 2
    FakeNative.close(socket2)
  end

  test "a second peer is refused while a link is up; a disarm during an in-flight command still records its result",
       %{port: port} do
    {socket, adapter, _} = armed_peer(port)
    second = FakeNative.connect(port)
    assert {:ok, %{"kind" => "refused", "reason" => "busy"}} = FakeNative.recv(second)
    assert {:error, :closed} = FakeNative.recv(second, 500)
    assert "link.refused" in journal_events()

    {id, cmd} = probe_and_receive(socket)
    assert :ok = Command.disarm()
    assert {:error, :disarmed} = Command.probe()
    FakeNative.respond(socket, cmd, adapter, "applied")
    assert wait(fn -> Command.command(id).status == :applied end)
    assert %{trust: %{armed: false}, in_flight: nil} = Command.status()
    FakeNative.close(socket)
  end

  # -- protocol violations -------------------------------------------------------------------------------

  test "protocol violations close the link: oversize, malformed, wrong version, unknown kind, hello twice, result before hello, hello timeout",
       %{port: port} do
    violations = [
      {"oversize", String.duplicate("x", 4_097) <> "\n"},
      {"malformed json", "{nope\n"},
      {"invalid utf-8", <<0xFF, 0xFE, ?{, ?}>> <> "\n"},
      {"wrong version",
       JSON.encode!(Map.put(FakeNative.hello(), "command_protocol_version", 2)) <> "\n"},
      {"unknown kind", JSON.encode!(Map.put(FakeNative.hello(), "kind", "exec")) <> "\n"},
      {"unknown field",
       JSON.encode!(Map.put(FakeNative.hello(), "function_pointer", "0x1")) <> "\n"},
      {"result before hello",
       JSON.encode!(
         FakeNative.result(
           %{"command_id" => Schema.uuid4(), "link_generation" => 1},
           Schema.uuid4(),
           "applied"
         )
       ) <> "\n"}
    ]

    for {label, bytes} <- violations do
      socket = FakeNative.connect(port)
      assert wait(fn -> Command.status().trust.transport == :connected end), label
      FakeNative.send_raw(socket, bytes)
      assert {:error, :closed} = FakeNative.recv(socket, 1_000), label
      assert wait(fn -> Command.status().link == nil end), label
    end

    {socket, _adapter, _} = FakeNative.handshake(port)
    FakeNative.send_json(socket, FakeNative.hello())
    assert {:error, :closed} = FakeNative.recv(socket, 1_000)
    assert wait(fn -> Command.status().link == nil end)

    silent = FakeNative.connect(port)
    assert {:error, :closed} = FakeNative.recv(silent, 1_500)

    closes = Enum.filter(journal_entries(), &(&1["event"] == "link.closed"))
    assert length(closes) == length(violations) + 2
    assert Enum.all?(closes, &(&1["reason"] =~ "protocol_violation"))
    assert Enum.any?(closes, &(&1["reason"] =~ "hello_timeout"))
    assert Enum.any?(closes, &(&1["reason"] =~ "line_too_long"))
    assert Enum.any?(closes, &(&1["reason"] =~ "hello_after_handshake"))
    assert Enum.any?(closes, &(&1["reason"] =~ "result_before_handshake"))
  end

  # -- journal ------------------------------------------------------------------------------------------

  @tag :stub_writer
  test "when the journal cannot persist the audit entry, arming and issuance are refused", %{
    port: port,
    agent: agent
  } do
    {socket, adapter, _} = armed_peer(port)
    {id, cmd} = probe_and_receive(socket)
    FakeNative.respond(socket, cmd, adapter, "applied")
    assert wait(fn -> Command.command(id).status == :applied end)

    StubWriter.mode(agent, {:fail_sync, :eio})
    assert {:error, {:journal_unavailable, :eio}} = Command.probe()
    assert %{journal: :degraded, trust: %{ready: false}} = Command.status()
    # The failed acceptance entry degraded the audit trail: the authority disarmed itself and
    # refuses to arm again for its life (M5-B hardening); the journal stays degraded too.
    assert %{degraded: true, failed_event: "command.accepted", reason: :eio} =
             Command.status().audit

    refute Command.status().trust.armed
    assert {:error, {:audit_degraded, "command.accepted"}} = Command.arm()
    FakeNative.close(socket)
  end

  test "the journal records arming, links, handshake, decisions and anomalies; arming is not persisted across a restart",
       %{port: port, dir: dir} do
    {socket, adapter, _} = armed_peer(port)
    {id, cmd} = probe_and_receive(socket)
    FakeNative.respond(socket, cmd, adapter, "applied", %{"observed" => %{"ok" => true}})
    assert wait(fn -> Command.command(id).status == :applied end)
    FakeNative.close(socket)
    assert wait(fn -> Command.status().link == nil end)

    assert journal_events() ==
             ~w(journal.opened link.connected peer.identified authority.armed command.accepted command.transmitted command.received command.terminal link.closed authority.disarmed)

    [path] = Path.wildcard(Path.join(dir, "commands-*.ndjson"))
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    stop_supervised!(Command.Supervisor)

    assert List.last(
             path
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&JSON.decode!/1)
           )["event"] == "journal.closed"

    start_supervised!({Command.Supervisor, port: 0, journal_dir: dir})
    assert %{trust: %{armed: false, transport: :none}} = Command.status()
    assert length(Path.wildcard(Path.join(dir, "commands-*.ndjson"))) == 2
  end

  # -- shutdown and the observer -------------------------------------------------------------------------

  test "stopping the subtree closes the link and frees the port", %{port: port} do
    {socket, _, _} = armed_peer(port)
    stop_supervised!(Command.Supervisor)
    assert {:error, :closed} = FakeNative.recv(socket, 1_000)
    assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary], 500)
    refute Command.enabled?()
    assert {:error, :command_disabled} = Command.status()
  end

  test "telemetry ingestion and the legacy report are unaffected by a command exchange", %{
    port: port
  } do
    :ok = MissionSession.subscribe()
    before_state = MissionSession.state()
    {socket, adapter, _} = armed_peer(port)
    {id, cmd} = probe_and_receive(socket)

    instance = FixturePlayer.unique_id("cmd-iso")
    :closed = FixturePlayer.play("stage1", instance)
    FixturePlayer.await_closed(instance)
    FakeNative.respond(socket, cmd, adapter, "applied")
    assert wait(fn -> Command.command(id).status == :applied end)

    # The session gained exactly this instance and nothing else changed; no command appears in
    # its state or its text.
    state = MissionSession.state()
    assert state[instance].received == 3 and state[instance].gaps == []

    assert Enum.map(state[instance].attempts, & &1.mission) == [
             :superseded,
             :superseded,
             :playing
           ]

    assert Map.delete(state, instance) == before_state
    # Only this instance's own section is inspected: other tests' instance ids may carry words
    # such as "probe" (the fixture names), which has nothing to do with the command path.
    for text <- [MissionSession.summary_text(), MissionSession.report_text()] do
      [_, section | _] = String.split(text, "adapter #{instance}: ")
      section = section |> String.split("\nadapter ") |> hd()
      refute section =~ ~r/command|probe|armed/
    end

    FakeNative.close(socket)
  end
end

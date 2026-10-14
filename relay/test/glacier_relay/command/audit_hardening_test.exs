defmodule GlacierRelay.Command.AuditHardeningTest do
  @moduledoc """
  Journal failure hardening (M5-B checkpoint 1): a journal failure at every transition — before
  acceptance, on acceptance (before any transmission), after transmission, on the native
  acknowledgement, on the terminal result, on a disarm, on a link loss — fails the authority closed
  (degraded, disarmed, no further arming or issuance for its life, a reconnect does not restore it)
  without falsifying the state of a command that was already transmitted, and without touching the
  observer.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Journal, Listener}
  alias GlacierRelay.MissionSession
  alias GlacierRelay.Test.{CountingWriter, FakeNative, FixturePlayer}

  @ack 300
  @grace 200
  @ttl 500

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-audit-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, agent} = CountingWriter.start()

    start_supervised!(
      {Command.Supervisor,
       port: 0,
       journal_dir: dir,
       writer: {CountingWriter, agent},
       ack_timeout_ms: @ack,
       grace_ms: @grace,
       default_ttl_ms: @ttl,
       min_ttl_ms: 50,
       hello_timeout_ms: 400}
    )

    %{port: Listener.port(), dir: dir, agent: agent}
  end

  defp wait(fun), do: FixturePlayer.wait_until(fun, 100, 10)

  defp events do
    %{path: path} = Journal.status()
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!(&1)["event"])
  end

  defp armed_peer(port) do
    {socket, adapter, welcome} = FakeNative.handshake(port)
    assert :ok = Command.arm()
    {socket, adapter, welcome["link_generation"]}
  end

  defp probe_and_receive(socket) do
    assert {:ok, id} = Command.probe()
    assert {:ok, cmd} = FakeNative.recv(socket)
    {id, cmd}
  end

  # The authority after any audit failure: degraded, disarmed, never ready, refusing to arm or
  # issue, and a reconnect does not restore it.
  defp assert_failed_closed(port, failed_event) do
    s = Command.status()
    assert %{degraded: true, failed_event: ^failed_event} = s.audit
    refute s.trust.armed
    refute s.trust.ready
    assert s.journal == :degraded
    assert {:error, {:audit_degraded, ^failed_event}} = Command.arm()
    assert {:error, {:audit_degraded, ^failed_event}} = Command.probe()

    # A fresh link reconnects and identifies, and still nothing is ready or armable.
    {socket, _, _} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert {:error, {:audit_degraded, ^failed_event}} = Command.arm()
    refute Command.status().trust.ready
    FakeNative.close(socket)
  end

  test "journal failure before acceptance: arming is refused and nothing is armed", %{
    port: port,
    agent: agent
  } do
    {socket, _, _} = FakeNative.handshake(port)
    CountingWriter.fail_after(agent, 0, :eio)
    assert {:error, {:journal_unavailable, :eio}} = Command.arm()
    refute Command.status().trust.armed
    assert Command.status().counters.issued == 0
    assert_failed_closed(port, "authority.armed")
    FakeNative.close(socket)
  end

  test "journal failure on acceptance (before any transmission): refused, nothing sent", %{
    port: port,
    agent: agent
  } do
    {socket, _, _} = armed_peer(port)
    CountingWriter.fail_after(agent, 0, :eio)
    assert {:error, {:journal_unavailable, :eio}} = Command.probe()
    assert {:error, :timeout} = FakeNative.recv(socket, 300)
    assert Command.status().counters.issued == 0 and Command.status().in_flight == nil
    assert_failed_closed(port, "command.accepted")
    FakeNative.close(socket)
  end

  test "journal failure after transmission: the command stays in flight and uncertain, its gap is recorded, the result still correlates",
       %{port: port, agent: agent} do
    {socket, adapter, _} = armed_peer(port)
    # accepted succeeds, transmitted fails.
    CountingWriter.fail_after(agent, 1, :enospc)
    assert {:ok, id} = Command.probe()
    assert {:ok, cmd} = FakeNative.recv(socket)
    c = Command.command(id)
    assert c.status == :transmitted and c.audit == {:gap, [:transmitted]}
    assert %{in_flight: %{id: ^id, status: :transmitted}} = Command.status()

    assert %{degraded: true, failed_event: "command.transmitted", reason: :enospc} =
             Command.status().audit

    refute Command.status().trust.armed
    # Never reported as unapplied: the peer's result is still evidence and still correlates.
    FakeNative.respond(socket, cmd, adapter, "applied", %{"observed" => %{"ok" => true}})
    assert wait(fn -> Command.command(id).status == :applied end)
    c = Command.command(id)
    assert c.observed == :native
    assert c.audit == {:gap, [:transmitted, :received, :applied]}
    assert Command.status().in_flight == nil
    assert_failed_closed(port, "command.transmitted")
    # The failed entry's bytes may sit in the file (the append succeeded, the sync did not): the
    # journal's degraded status, not the file's tail, is the truth about durability; nothing after
    # the failure is written at all.
    command_events = events() |> Enum.filter(&String.starts_with?(&1, "command."))

    assert command_events in [
             ["command.accepted"],
             ["command.accepted", "command.transmitted"]
           ]

    FakeNative.close(socket)
  end

  test "journal failure on the native acknowledgement", %{port: port, agent: agent} do
    {socket, adapter, _} = armed_peer(port)
    {id, cmd} = probe_and_receive(socket)
    CountingWriter.fail_after(agent, 0, :eio)
    FakeNative.send_json(socket, FakeNative.result(cmd, adapter, "received"))
    assert wait(fn -> Command.command(id).status == :received end)
    assert Command.command(id).audit == {:gap, [:received]}
    FakeNative.send_json(socket, FakeNative.result(cmd, adapter, "applied"))
    assert wait(fn -> Command.command(id).status == :applied end)
    assert Command.command(id).audit == {:gap, [:received, :applied]}
    assert_failed_closed(port, "command.received")
    FakeNative.close(socket)
  end

  test "journal failure on the terminal result", %{port: port, agent: agent} do
    {socket, adapter, _} = armed_peer(port)
    {id, cmd} = probe_and_receive(socket)
    FakeNative.send_json(socket, FakeNative.result(cmd, adapter, "received"))
    assert wait(fn -> Command.command(id).status == :received end)
    CountingWriter.fail_after(agent, 0, :eio)
    FakeNative.send_json(socket, FakeNative.result(cmd, adapter, "failed", %{"reason" => "x"}))
    assert wait(fn -> Command.command(id).status == :failed end)
    assert Command.command(id).audit == {:gap, [:failed]}
    assert Command.command(id).result.reason == "x"
    assert_failed_closed(port, "command.terminal")
    FakeNative.close(socket)
  end

  test "journal failure during a disarm: disarmed anyway, degraded", %{port: port, agent: agent} do
    {socket, _, _} = armed_peer(port)
    CountingWriter.fail_after(agent, 0, :eio)
    assert :ok = Command.disarm()
    refute Command.status().trust.armed
    assert_failed_closed(port, "authority.disarmed")
    FakeNative.close(socket)
  end

  test "journal failure during a link loss with a command in flight: unknown, disarmed, degraded",
       %{port: port, agent: agent} do
    {socket, _, _} = armed_peer(port)
    {id, _cmd} = probe_and_receive(socket)
    CountingWriter.fail_after(agent, 0, :eio)
    FakeNative.close(socket)
    assert wait(fn -> Command.command(id).status == :unknown end)
    c = Command.command(id)
    assert c.unknown_reason == :link_lost and c.audit == {:gap, [:unknown]}
    assert Command.status().link == nil
    assert_failed_closed(port, "command.unknown")
  end

  test "a journal process that is down is a failed append, not a crash: the authority fails closed",
       %{port: port} do
    {socket, _, _} = armed_peer(port)
    journal = Process.whereis(Journal)
    # Stop the journal under its supervisor's notice: rest_for_one restarts the authority too, so
    # the new authority starts disarmed with an intact audit state and a NEW journal.
    old_authority = Process.whereis(Command.Authority)
    Process.exit(journal, :kill)
    assert wait(fn -> Process.whereis(Command.Authority) not in [nil, old_authority] end)
    assert wait(fn -> Process.whereis(Journal) != nil end)
    s = Command.status()
    assert s.audit == :intact and s.trust.armed == false and s.link == nil
    assert {:error, :closed} = FakeNative.recv(socket, 1_000)
  end

  test "the observer is unaffected by a degraded command audit", %{port: port, agent: agent} do
    :ok = MissionSession.subscribe()
    before = MissionSession.state()
    {socket, _, _} = armed_peer(port)
    CountingWriter.fail_after(agent, 1, :eio)
    {_id, _cmd} = probe_and_receive(socket)
    assert %{degraded: true} = Command.status().audit

    instance = FixturePlayer.unique_id("audit-iso")
    :closed = FixturePlayer.play("stage1", instance)
    FixturePlayer.await_closed(instance)
    state = MissionSession.state()
    assert state[instance].received == 3 and Map.delete(state, instance) == before
    FakeNative.close(socket)
  end
end

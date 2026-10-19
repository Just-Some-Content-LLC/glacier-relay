defmodule GlacierRelayWeb.HeadlessTest do
  @moduledoc """
  M3-A headless invariance: with the dashboard disabled (the default, and the test configuration)
  the application's supervision tree is exactly the three children validated through M2, no web
  process is registered, and no HTTP port is bound.
  """
  # Not async: inspects the application's own supervisor, shared with the web-enabled tests.
  use ExUnit.Case, async: false

  @core_children [
    GlacierRelay.MissionSession,
    GlacierRelay.Wire.ConnectionSupervisor,
    GlacierRelay.Wire.Listener
  ]

  test "the dashboard is disabled by default" do
    refute GlacierRelay.Application.dashboard_enabled?()
    assert Application.get_env(:glacier_relay, :dashboard)[:enabled] == false
  end

  test "the recorder is disabled by default and not running (M4-A headless invariance)" do
    refute GlacierRelay.Application.recording_enabled?()
    assert Application.get_env(:glacier_relay, :recording)[:enabled] == false
    assert Process.whereis(GlacierRelay.Recording.Recorder) == nil
  end

  test "the command subtree is disabled by default and nothing of it runs (M5-A invariance)" do
    refute GlacierRelay.Application.command_enabled?()
    assert Application.get_env(:glacier_relay, :command)[:enabled] == false
    refute GlacierRelay.Command.enabled?()
    assert {:error, :command_disabled} = GlacierRelay.Command.status()
    assert {:error, :command_disabled} = GlacierRelay.Command.arm()
    assert {:error, :command_disabled} = GlacierRelay.Command.probe()

    for name <- [
          GlacierRelay.Command.Supervisor,
          GlacierRelay.Command.Authority,
          GlacierRelay.Command.Journal,
          GlacierRelay.Command.Listener,
          GlacierRelay.Command.LinkSupervisor
        ] do
      assert Process.whereis(name) == nil,
             "#{inspect(name)} is running with command mode disabled"
    end

    port = Application.get_env(:glacier_relay, :command)[:port]
    assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary], 500)
  end

  test "the motion subtree is disabled by default and nothing of it runs (M7-B1 invariance)" do
    assert Application.get_env(:glacier_relay, :motion)[:enabled] == false
    assert Application.get_env(:glacier_relay, :motion)[:peer] == nil
    refute GlacierRelay.Motion.enabled?()
    assert {:error, :motion_disabled} = GlacierRelay.Motion.status()
    assert {:error, :motion_disabled} = GlacierRelay.Motion.close_session()

    for name <- [
          GlacierRelay.Motion.Supervisor,
          GlacierRelay.Motion.Hub,
          GlacierRelay.Motion.Trace,
          GlacierRelay.Motion.Listener,
          GlacierRelay.Motion.LinkSupervisor,
          GlacierRelay.Motion.PeerEndpoint,
          GlacierRelay.HeadlessPeer,
          GlacierRelay.HeadlessPeer.Driver,
          GlacierRelay.HeadlessPeer.Endpoint
        ] do
      assert Process.whereis(name) == nil, "#{inspect(name)} is running with motion disabled"
    end

    for port <- [Application.get_env(:glacier_relay, :motion)[:port], 4750, 4760] do
      assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary], 500)
    end
  end

  test "the supervision tree holds exactly the three M2 children, in the M2 order" do
    ids =
      GlacierRelay.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.reverse()

    assert ids == @core_children
    assert %{active: 3, specs: 3} = Supervisor.count_children(GlacierRelay.Supervisor)
  end

  test "no web process is registered" do
    for name <- [GlacierRelayWeb.Supervisor, GlacierRelayWeb.Endpoint, GlacierRelay.PubSub] do
      assert Process.whereis(name) == nil, "#{inspect(name)} is running in headless mode"
    end
  end

  test "no HTTP listener is bound on the configured dashboard port" do
    port = Application.get_env(:glacier_relay, GlacierRelayWeb.Endpoint)[:http][:port]
    dev_port = 4748

    for p <- Enum.uniq([port, dev_port]), p > 0 do
      assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, p, [:binary], 500)
    end
  end

  test "the wire listener is unchanged: loopback, bound, answering" do
    assert {{127, 0, 0, 1}, port} = GlacierRelay.Wire.Listener.address()
    assert port > 0
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)
    :gen_tcp.close(socket)
  end
end

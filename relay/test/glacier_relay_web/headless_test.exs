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

defmodule GlacierRelay.Application do
  @moduledoc """
  Supervision for M1: the mission session (where events land), a dynamic supervisor for accepted
  connections, and the listener. One-for-one: a listener crash rebinds the port without touching
  live connections or the session; a connection crash affects only that connection.

  M3-A (ADR 0007): an optional web subtree, `GlacierRelayWeb.Supervisor`, is appended last and
  only when `config :glacier_relay, :dashboard, enabled: true`. Under one-for-one, nothing in it
  can restart the three ingestion children; when disabled, the tree is exactly the M2 tree.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        GlacierRelay.MissionSession,
        {DynamicSupervisor, name: GlacierRelay.Wire.ConnectionSupervisor, strategy: :one_for_one},
        GlacierRelay.Wire.Listener
      ] ++ web_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: GlacierRelay.Supervisor)
  end

  @doc "Whether the optional web subtree is configured to start with the application."
  def dashboard_enabled? do
    :glacier_relay
    |> Application.get_env(:dashboard, [])
    |> Keyword.get(:enabled, false) == true
  end

  defp web_children do
    if dashboard_enabled?(), do: [GlacierRelayWeb.Supervisor], else: []
  end
end

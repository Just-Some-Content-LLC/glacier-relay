defmodule GlacierRelay.Application do
  @moduledoc """
  Supervision for M1: the mission session (where events land), a dynamic supervisor for accepted
  connections, and the listener. One-for-one: a listener crash rebinds the port without touching
  live connections or the session; a connection crash affects only that connection.

  M3-A (ADR 0007): an optional web subtree, `GlacierRelayWeb.Supervisor`, is appended last and
  only when `config :glacier_relay, :dashboard, enabled: true`. Under one-for-one, nothing in it
  can restart the three ingestion children; when disabled, the tree is exactly the M2 tree.

  M4-A (ADR 0008): an optional recorder, `GlacierRelay.Recording.Recorder`, is appended after the
  three ingestion children and before the web subtree, only when
  `config :glacier_relay, :recording, enabled: true`. It stops before the wire on shutdown, so
  connection closes caused by the shutdown itself fall after its close boundary (recorded as such
  in its footer). When disabled nothing of it starts.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        GlacierRelay.MissionSession,
        {DynamicSupervisor, name: GlacierRelay.Wire.ConnectionSupervisor, strategy: :one_for_one},
        GlacierRelay.Wire.Listener
      ] ++ recording_children() ++ web_children() ++ command_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: GlacierRelay.Supervisor)
  end

  @doc "Whether the optional command subtree (M5-A, ADR 0009) is configured to start with the application."
  def command_enabled? do
    :glacier_relay
    |> Application.get_env(:command, [])
    |> Keyword.get(:enabled, false) == true
  end

  # M5-A (ADR 0009): the optional command subtree, last, only when enabled; nothing of it starts
  # otherwise and the tree stays exactly M4's.
  defp command_children do
    if command_enabled?(), do: [GlacierRelay.Command.Supervisor], else: []
  end

  @doc "Whether the optional web subtree is configured to start with the application."
  def dashboard_enabled? do
    :glacier_relay
    |> Application.get_env(:dashboard, [])
    |> Keyword.get(:enabled, false) == true
  end

  @doc "Whether the optional recorder is configured to start with the application."
  def recording_enabled? do
    :glacier_relay
    |> Application.get_env(:recording, [])
    |> Keyword.get(:enabled, false) == true
  end

  defp web_children do
    if dashboard_enabled?(), do: [GlacierRelayWeb.Supervisor], else: []
  end

  defp recording_children do
    if recording_enabled?(), do: [GlacierRelay.Recording.Recorder], else: []
  end
end

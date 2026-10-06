defmodule GlacierRelay.Application do
  @moduledoc """
  Supervision for M1: the mission session (where events land), a dynamic supervisor for accepted
  connections, and the listener. One-for-one: a listener crash rebinds the port without touching
  live connections or the session; a connection crash affects only that connection.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GlacierRelay.MissionSession,
      {DynamicSupervisor, name: GlacierRelay.Wire.ConnectionSupervisor, strategy: :one_for_one},
      GlacierRelay.Wire.Listener
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GlacierRelay.Supervisor)
  end
end

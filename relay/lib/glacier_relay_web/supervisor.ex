defmodule GlacierRelayWeb.Supervisor do
  @moduledoc """
  The optional web subtree (M3-A/M3-B, ADR 0007): `Phoenix.PubSub`, the read-only projection and
  the loopback HTTP endpoint.

  One failure boundary, placed last under `GlacierRelay.Supervisor`. Rest-for-one inside: a PubSub
  crash restarts the projection and the endpoint that depend on it; a projection crash restarts
  the endpoint after it (its LiveViews remount from the recovered snapshot); an endpoint crash
  restarts nothing else. Nothing here touches the ingestion children, and nothing here starts
  unless the application is configured with `:dashboard, enabled: true` (or a test starts it).
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children = [
      {Phoenix.PubSub, name: GlacierRelay.PubSub},
      {GlacierRelay.Dashboard.Projection, Keyword.get(opts, :projection, [])},
      GlacierRelayWeb.Endpoint
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule GlacierRelayWeb.Supervisor do
  @moduledoc """
  The optional web subtree (M3-A, ADR 0007): `Phoenix.PubSub` and the loopback HTTP endpoint.

  One failure boundary, placed last under `GlacierRelay.Supervisor`. Rest-for-one inside: a PubSub
  crash restarts the endpoint that depends on it; an endpoint crash restarts nothing else. Nothing
  here touches the ingestion children, and nothing here starts unless the application is
  configured with `:dashboard, enabled: true` (or a test starts it directly).

  The M3-B projection (`GlacierRelay.Dashboard.Projection`) will be a child between PubSub and the
  endpoint; it is not implemented in M3-A.
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Phoenix.PubSub, name: GlacierRelay.PubSub},
      GlacierRelayWeb.Endpoint
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

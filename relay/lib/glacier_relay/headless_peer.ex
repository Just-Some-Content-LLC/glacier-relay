defmodule GlacierRelay.HeadlessPeer do
  @moduledoc """
  M7-B1: the reusable headless protocol peer (`docs/design/M7_NETWORK_GHOST.md` sections 9 and
  15.2): a BEAM application part with **no game** — no command authority, no token, no native
  adapter, no motion link and no engine-writing path. It is started explicitly by its caller (it is
  not a child of `GlacierRelay.Application`) and consists of a motion trace, the driver and one peer
  endpoint that **listens** for the one allowlisted game host (loopback only in B1).

  As a **source** it emits only labelled synthetic courses (`Motion.Course`; `source_kind:
  synthetic`), one stream per course run. As a **sink** it records every stream it receives in
  its trace and checks sequence, labels and the declared sampling bounds; it has no path that
  sends a received sample anywhere. A result obtained with it is never equivalent to two real game
  instances and never satisfies the M7 exit.

  Options: `:ip`, `:port` (4760; 0 picks one), `:credentials` (`Peer.TLS.credentials/1`),
  `:label` (this peer's label), `:expected` (`%{label, client_kind}` of the game host),
  `:trace_dir`, `:sink_bounds` (`%{center: {x, y}, half_extent_m, min_interval_ms}`; checks only).
  """

  use Supervisor

  alias GlacierRelay.HeadlessPeer.Driver
  alias GlacierRelay.Motion.Trace
  alias GlacierRelay.Peer.Endpoint

  @trace GlacierRelay.HeadlessPeer.Trace
  @endpoint GlacierRelay.HeadlessPeer.Endpoint

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def endpoint, do: @endpoint
  def trace, do: @trace

  @impl true
  def init(opts) do
    children = [
      %{
        id: Trace,
        start:
          {Trace, :start_link,
           [[name: @trace, role: "headless", dir: Keyword.get(opts, :trace_dir)]]}
      },
      {Driver, trace: @trace, sink_bounds: Keyword.get(opts, :sink_bounds)},
      {Endpoint,
       role: :listen,
       name: @endpoint,
       ip: Keyword.get(opts, :ip, {127, 0, 0, 1}),
       port: Keyword.get(opts, :port, 4760),
       credentials: Keyword.fetch!(opts, :credentials),
       local: %{label: Keyword.get(opts, :label, "headless"), client_kind: "headless"},
       expected: Keyword.fetch!(opts, :expected),
       handler: {Driver, Driver}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

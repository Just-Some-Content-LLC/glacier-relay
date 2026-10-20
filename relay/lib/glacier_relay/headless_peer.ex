defmodule GlacierRelay.HeadlessPeer do
  @moduledoc """
  M7-B1: the reusable headless protocol peer (`docs/design/M7_NETWORK_GHOST.md` sections 9 and
  15.2): a BEAM application part with **no game** — no command authority, no token, no native
  adapter, no motion link and no engine-writing path. It is started explicitly by its caller (it is
  not a child of `GlacierRelay.Application`) and consists of a motion trace, the driver and one peer
  endpoint that **listens** for the one allowlisted game host (loopback only in B1) — or, with
  `role: :connect` (M7-L1, design section 20.3), **connects out** to one allowlisted peer, so that a
  transport-only test between two machines can keep the initiating machine outbound-only.

  As a **source** it emits only labelled synthetic courses (`Motion.Course`; `source_kind:
  synthetic`), one stream per course run. As a **sink** it records every stream it receives in
  its trace and checks sequence, labels and the declared sampling bounds; it has no path that
  sends a received sample anywhere. A result obtained with it is never equivalent to two real game
  instances and never satisfies the M7 exit.

  Options: `:role` (`:listen`, the default, or `:connect`), `:ip`, `:port` (4760; 0 picks one) or
  instead `:network` (`Peer.Network`'s profile), `:reconnect_ms` (connect role; default none),
  `:credentials` (`Peer.TLS.credentials/1`), `:label` (this peer's label), `:expected` (`%{label,
  client_kind}` of the peer), `:trace_dir`, `:sink_bounds` (`%{center: {x, y}, half_extent_m,
  min_interval_ms}`; checks only).
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
       [
         role: Keyword.get(opts, :role, :listen),
         name: @endpoint,
         credentials: Keyword.fetch!(opts, :credentials),
         local: %{label: Keyword.get(opts, :label, "headless"), client_kind: "headless"},
         expected: Keyword.fetch!(opts, :expected),
         handler: {Driver, Driver}
       ] ++ address(opts) ++ Keyword.take(opts, [:reconnect_ms])}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # B1's loopback defaults unless a network profile is given; whatever the caller gave is passed
  # on as given, so the endpoint refuses an address declared twice
  defp address(opts) do
    given = Keyword.take(opts, [:ip, :port, :network])

    if Keyword.has_key?(given, :network),
      do: given,
      else: Keyword.merge([ip: {127, 0, 0, 1}, port: 4760], given)
  end
end

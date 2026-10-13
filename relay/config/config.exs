import Config

# The native adapter connects to this from Windows. Loopback only; WSL2's localhost forwarding
# (wslrelay.exe) makes a listener bound to 127.0.0.1 inside WSL2 reachable at 127.0.0.1 on Windows.
config :glacier_relay, GlacierRelay.Wire.Listener,
  ip: {127, 0, 0, 1},
  port: 4747,
  # One NDJSON envelope per line. A line longer than this closes the connection.
  max_line_bytes: 65_536

# M3-A (ADR 0007): the optional, read-only web subtree. Disabled by default in every environment;
# when disabled the supervision tree is exactly the three M2 children and no HTTP port is bound.
# `config/runtime.exs` enables it when GLACIER_RELAY_DASHBOARD=1.
config :glacier_relay, :dashboard,
  enabled: false,
  # M3-B projection: notifications are coalesced into one recompute per window (ms).
  coalesce_ms: 50,
  # The recent-event pane keeps this many rows per viewer: a presentation window, never evidence.
  stream_limit: 200,
  # Provenance of the evidence this node receives: :live (the wire listener) or :replay, which a
  # controlled playback environment sets explicitly (GLACIER_RELAY_SOURCE=replay); never inferred.
  source: :live

# The HTTP endpoint. Loopback only, a different port from the wire listener (4747), never
# conflated with it. Bandit serves it. No sockets, LiveViews or static assets are mounted in M3-A.
config :glacier_relay, GlacierRelayWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4748],
  server: true,
  url: [host: "localhost", port: 4748],
  pubsub_server: GlacierRelay.PubSub,
  render_errors: [formats: [text: GlacierRelayWeb.ErrorText], layout: false],
  # Only loopback origins may open a future LiveView socket (any port, so test ports qualify).
  check_origin: ["//localhost", "//127.0.0.1"],
  # Set per boot in config/runtime.exs (random; no session outlives the VM).
  secret_key_base: nil

config :phoenix, :json_library, JSON

import_config "#{config_env()}.exs"

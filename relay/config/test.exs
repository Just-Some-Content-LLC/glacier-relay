import Config

# Ephemeral port so tests never collide with a running dev listener.
config :glacier_relay, GlacierRelay.Wire.Listener, port: 0, max_line_bytes: 4_096

# The web subtree is not started by the application in tests (headless invariance); the
# web-enabled tests start `GlacierRelayWeb.Supervisor` themselves on an ephemeral loopback port.
config :glacier_relay, :dashboard, enabled: false
config :glacier_relay, GlacierRelayWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 0]

config :logger, level: :warning

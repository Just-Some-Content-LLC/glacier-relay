import Config

# Ephemeral port so tests never collide with a running dev listener.
config :glacier_relay, GlacierRelay.Wire.Listener, port: 0, max_line_bytes: 4_096

config :logger, level: :warning

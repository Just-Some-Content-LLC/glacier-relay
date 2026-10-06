import Config

# The native adapter connects to this from Windows. Loopback only; WSL2's localhost forwarding
# (wslrelay.exe) makes a listener bound to 127.0.0.1 inside WSL2 reachable at 127.0.0.1 on Windows.
config :glacier_relay, GlacierRelay.Wire.Listener,
  ip: {127, 0, 0, 1},
  port: 4747,
  # One NDJSON envelope per line. A line longer than this closes the connection.
  max_line_bytes: 65_536

import_config "#{config_env()}.exs"

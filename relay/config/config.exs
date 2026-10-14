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

# M4-A (ADR 0008): the optional mission recorder. Disabled by default; `config/runtime.exs`
# enables it when GLACIER_RELAY_RECORD=1 and takes the directory from GLACIER_RELAY_RECORD_DIR.
config :glacier_relay, :recording,
  enabled: false,
  # Absolute recordings directory; nil means $XDG_STATE_HOME/glacier-relay/recordings or
  # ~/.local/state/glacier-relay/recordings (the WSL2 filesystem, not a /mnt/ path).
  dir: nil,
  # Buffered records are written and synced at least this often (ms) or when the buffer reaches
  # batch_bytes; one datasync per flush.
  flush_ms: 100,
  batch_bytes: 262_144,
  # Segments roll at this size; the recordings directory stops recording (nothing deleted) at
  # the budget.
  segment_bytes: 67_108_864,
  budget_bytes: 1_073_741_824,
  # The soft overload policy: above the high-water mark records are discarded (with their exact
  # numbers written) down to the low-water mark. Measured only while the recorder runs its loop.
  mailbox_high: 10_000,
  mailbox_low: 1_000

# M5-A (ADR 0009): the optional command subtree. Disabled by default; `config/runtime.exs`
# enables it when GLACIER_RELAY_COMMAND=1. The command link is a third loopback port, separate
# from the wire listener (4747) and the dashboard (4748); the native adapter is its client.
config :glacier_relay, :command,
  enabled: false,
  ip: {127, 0, 0, 1},
  port: 4749,
  # One NDJSON object per line; a longer line is a protocol violation and closes the link.
  max_line_bytes: 4_096,
  # The peer's hello must arrive within this (monotonic) time of the accept.
  hello_timeout_ms: 2_000,
  # A transmitted command must be acknowledged within this time, else unknown.
  ack_timeout_ms: 2_000,
  # A terminal result must arrive within ttl_ms + grace_ms, else unknown.
  grace_ms: 1_000,
  default_ttl_ms: 5_000,
  min_ttl_ms: 100,
  max_ttl_ms: 10_000,
  # Absolute command-journal directory; nil means $XDG_STATE_HOME/glacier-relay/commands or
  # ~/.local/state/glacier-relay/commands (the WSL2 filesystem, never the game installation).
  journal_dir: nil,
  # M5 C-2A: effectful authority. Off by default: no effectful entry is ever listed in a welcome
  # or issuable. `GLACIER_RELAY_COMMAND_EFFECTFUL=1` turns it on; it also needs a run token
  # (`GLACIER_RELAY_COMMAND_TOKEN_FILE`, 64 lowercase hex characters on the Linux filesystem,
  # read once at start and never logged) for a version-2 peer to attest. Nothing here writes a
  # token or any game configuration.
  effectful: false,
  token_file: nil,
  # Effectful arming is one-shot and bounded (ms); operator evidence older than these is stale.
  effectful_ttl_default_ms: 30_000,
  effectful_ttl_max_ms: 120_000,
  evidence_max_age_ms: 120_000,
  # M5 C-2C N1: an operator-supplied `observed_at` / `collected_at` may lead this node's UTC clock
  # by at most this much (ms); anything further in the future is refused as a clock disagreement.
  evidence_clock_skew_ms: 5_000

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

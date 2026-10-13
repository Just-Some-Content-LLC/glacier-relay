import Config

# Evaluated at boot (mix run, mix test, iex -S mix, releases). Two runtime-only settings:
#
# 1. The web subtree starts only when explicitly asked for. The headless configuration used by
#    every M2 run stays the default.
# 2. The endpoint's secret_key_base is random per boot: the endpoint is a loopback diagnostic
#    tool with no persistent sessions, so nothing needs to survive a restart and no secret is
#    committed.
if System.get_env("GLACIER_RELAY_DASHBOARD") in ["1", "true"] do
  config :glacier_relay, :dashboard, enabled: true
end

if System.get_env("GLACIER_RELAY_SOURCE") == "replay" do
  config :glacier_relay, :dashboard, source: :replay
end

config :glacier_relay, GlacierRelayWeb.Endpoint,
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
  # The LiveView session-token salt, random per boot like the key base (a token never needs to
  # outlive the VM; a reconnecting page simply remounts).
  live_view: [signing_salt: Base.encode64(:crypto.strong_rand_bytes(12))]

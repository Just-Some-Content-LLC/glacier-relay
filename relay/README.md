# Glacier Relay — BEAM side

The Elixir/OTP backend of Glacier Relay: the wire listener, the mission session where evidence lands, the pure semantic model and its presentations (M1–M2; designs under `../docs/design/`), and since M3-A an optional, read-only web subtree (`../docs/design/M3_LIVE_OBSERVABILITY.md`, ADR 0007).

Deliberately small: OTP primitives for everything that owns meaning. Phoenix is a read-only consumer behind a configuration flag; no Ecto, no database, no distributed Erlang, no Node or asset pipeline.

## Toolchain

Runs in WSL2 (Ubuntu 20.04.6). Windows owns the game and the native adapter; WSL2 owns this application.

| Component | Version | Source |
|---|---|---|
| Erlang/OTP | 28.4.2 (erts 16.3.1) | precompiled `builds.hex.pm/builds/otp/ubuntu-20.04/OTP-28.4.2.tar.gz`, installed with `./Install -minimal` to `~/.local/opt/otp-28.4.2` |
| Elixir | 1.19.6 (compiled with OTP 28) | precompiled `builds.hex.pm/builds/elixir/v1.19.6-otp-28.zip` to `~/.local/opt/elixir-1.19.6` |
| Hex / rebar3 | Hex 2.5.2 | `mix local.hex` / `mix local.rebar`, user scope (`~/.mix`) |

No root was needed. `~/.local/opt/beam-env.sh` prepends both to `PATH`; it is sourced from `~/.zshrc`. Checksums were verified against `builds.txt` before installation. Dependencies are pinned in `mix.lock` (`mix deps.get`).

```sh
source ~/.local/opt/beam-env.sh
cd relay
mix deps.get
mix test
iex -S mix                                   # headless: wire listener 127.0.0.1:4747 only
GLACIER_RELAY_DASHBOARD=1 iex -S mix         # plus the loopback HTTP endpoint 127.0.0.1:4748
```

## Web subtree (M3-A, M3-B)

Disabled by default; `GLACIER_RELAY_DASHBOARD=1` (read in `config/runtime.exs`) starts `GlacierRelayWeb.Supervisor` (`Phoenix.PubSub` → `GlacierRelay.Dashboard.Projection` → `GlacierRelayWeb.Endpoint`) last under the application supervisor. When disabled the supervision tree is exactly the three children validated through M2 and no HTTP port is bound. The endpoint binds to `127.0.0.1:4748` only: `/` is the read-only LiveView dashboard (instances and transport status, the attempt's last observed state, outcomes by name, activity, timeline, uncertainty, a bounded recent-event pane), `/report` the mission report page, and `GET /report.txt` / `GET /summary.txt` the two text diagnostics; every other method or path is refused. The projection is the only web-side reader of `MissionSession`; the pages render the B7 report data unchanged with its provenance tags and never interpret events. Local development tool: no authentication, so any local process that can reach the loopback port can read the mission report. Set `GLACIER_RELAY_SOURCE=replay` only when the node is fed by a controlled playback rather than the game.

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

## Recorder (M4-A)

Disabled by default; `GLACIER_RELAY_RECORD=1` (read in `config/runtime.exs`) starts `GlacierRelay.Recording.Recorder` after the three ingestion children and before the web subtree. It subscribes to `MissionSession` for recording-grade records and appends them, in the session's record order and with the session's own receipt times, to format-1 segmented NDJSON under `GLACIER_RELAY_RECORD_DIR` (absolute; default `~/.local/state/glacier-relay/recordings/<uuid>/`, on the WSL2 filesystem). A clean stop (`init.stop`) runs the close protocol (footer, `sha256.txt`, `CLOSED`); a kill leaves the recording explicitly unclosed. Every segment after the first states why it was opened (`continuation`: roll, restart or write failure) and the durable boundary established at that moment — the last record a successful sync covered, never the last record received (M4 design section 19, correction A). Close reasons are written from a closed typed vocabulary (section 19, correction B). Health over RPC: `GlacierRelay.Recording.Recorder.health/0`. See `../docs/design/M4_MISSION_RECORDER.md` (ADR 0008) for the format, the gap vocabulary and the limits.

## Replay (M4-B)

A recording is replayed without the application, the listener, the dashboard or the game: `elixir -S mix run --no-start replay.exs <recording-directory>` reads and verifies the segments (`GlacierRelay.Recording.Reader`), folds the records in session order through the same pure `GlacierRelay.Session.Fold` the live session runs (`GlacierRelay.Recording.Replay`), and prints the summary, the B7 report and an explicit account (`GlacierRelay.Recording.Completeness`) that keeps recorder-level loss, Relay sequence gaps and unknown native-side loss apart. Envelope-only fixtures replay through `Replay.from_envelopes/2` with `transport: not_recorded`. A record in an unverified segment counts as durable only at or below a boundary a later continuation header states *and* the reader has cross-checked (an untrusted or unstated boundary elevates nothing and is reported); a close reason is reconstructed exactly only inside the typed vocabulary and is otherwise replayed as visibly qualified evidence, listed in the account (`close reasons: N exact, M qualified`). See `../docs/design/M4_MISSION_RECORDER.md` sections 18 and 19.

## Statistics (M4-C)

A pure statistics layer over replay results, offline only: `elixir -S mix run --no-start statistics.exs [--json <file>] [--group-by k1,k2] <recording-dir | fixture.ndjson>...` replays each input (`GlacierRelay.Recording.Replay`; an envelope-only `.ndjson` imports as legacy evidence) and prints `GlacierRelay.Statistics` for each — observed occurrence counts per family and event type, per attempt and per recording, with the attribution the Lifecycle fixed at receipt, durations only for attempts whose rise and fall were both observed, engine times compared only inside one contract-session clock domain, and the evidence class inherited from the completeness account (`observed_only_reasons` says why the counts are observed counts, never exhaustive totals) — and, for several inputs, `GlacierRelay.Statistics.Comparison` grouped by the given basis (scene resource, contract id, difficulty, recording, instance, attempt, disposition, mission, event family), unknown values kept explicit and last. `--json` writes the deterministic, sorted-key JSON (`glacier-relay.statistics/1`, versioned independently of the wire schema) as a derived artifact beside the recordings, which are never written. No distinct-actor count, no victory, failure, rating, survival, inventory or current-state inference. See `../docs/design/M4_MISSION_RECORDER.md` section 22.

## Command link (M5-A, offline only)

Disabled by default; `GLACIER_RELAY_COMMAND=1` (read in `config/runtime.exs`) starts `GlacierRelay.Command.Supervisor` last under the application supervisor: a loopback-only listener on `127.0.0.1:4749` (separate from the telemetry listener and the dashboard) that accepts one command link at a time, a single command authority, and a separate append-only command journal (`glacier-relay.command-journal/1`, under `GLACIER_RELAY_COMMAND_JOURNAL_DIR` or `~/.local/state/glacier-relay/commands/`, `0700`/`0600`). The peer is expected to be the native adapter in a later stage; in M5-A only the fake native peer of the tests speaks the protocol (`command_protocol_version` 1: hello, welcome, command, result). The authority is disarmed by default and armed per link by the operator (`GlacierRelay.Command.arm/0` from IEx or RPC; no browser path), issues one command at a time, correlates results by command id and link generation, journals every transition before acting, and refuses to arm or issue when the journal cannot persist the entry. The only issuable command is `relay.probe` v1, which has no effect; `player.outfit.set` v1 is documented as a reserved, non-issuable candidate. The peer is labelled *identified* (a claimed adapter id), never *authenticated*. With the flag off the supervision tree is exactly M4's. See `../docs/design/M5_COMMAND_CHANNEL.md` section 17 and ADR 0009.

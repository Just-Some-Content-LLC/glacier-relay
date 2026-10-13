# M3 Design — Live Observability

Date: 2026-10-12. Status: **design proposal, awaiting review.** Nothing in this document is installed, implemented or run: `relay/mix.exs` has no dependencies, `mix archive` shows no Hex, the supervision tree is the M1 one, and the native adapter stays at the M2 checkpoint (ZHMModSDK `relay/m2` `c5152848`, DLL `6047a9a3…`). The first M3 implementation stage needs its own authorization because it installs Hex, rebar and the Phoenix dependencies.

Inputs: `ROADMAP.md` M3 ("Phoenix/LiveView dashboard for current mission state and event stream"); `ARCHITECTURE.md` (LiveView console as one consumer of OTP-owned state; `WebEndpoint` under the application supervisor as a hypothesis); ADR 0001–0006; `M2_TELEMETRY.md` sections 2, 7, 50–52; and the BEAM sources read as they are on `main` at the M2 checkpoint (`135d6da`): `application.ex`, `wire/listener.ex`, `wire/connection.ex`, `wire/envelope.ex`, `wire/framing.ex`, `mission_session.ex`, `lifecycle.ex`, `attempt_history.ex`, `disguise.ex`, `items.ex`, `objectives.ex`, `player_state.ex`, `summary.ex`, `report.ex`, `events.ex`, `config/*.exs`, `mix.exs`, and the tests (`report_test.exs`, `wire/listener_test.exs`).

Position: M3 makes the understanding that M2 established visible. It reads the OTP-owned semantic model and shows it; it does not interpret Glacier events, add telemetry, change the wire, persist anything or send anything toward the game. ADR 0007 (proposed) records the architectural decision.

## 1. What exists (source inspection, read-only)

### 1.1 Supervision tree (`GlacierRelay.Application`)

```
GlacierRelay.Supervisor                         one_for_one
├── GlacierRelay.MissionSession                 GenServer, registered by module name; all evidence lands here
├── GlacierRelay.Wire.ConnectionSupervisor      DynamicSupervisor; one Wire.Connection (restart: :temporary) per accepted socket
└── GlacierRelay.Wire.Listener                  GenServer owning the listen socket (127.0.0.1:4747; 0 in test); a linked acceptor process
```

A listener crash rebinds the port without touching live connections or the session; a connection crash affects only that connection; a `MissionSession` crash loses its state (no persistence; an M2 property that M3 does not change).

### 1.2 Ingestion path and its cost

`Wire.Connection` frames NDJSON (`active: :once`), decodes and validates each line (`Envelope.decode/1` → `Events.validate/3`), and **casts** `{:event, pid, envelope, received_at}` to `MissionSession`; it also casts `connection_opened`/`connection_closed`. Nothing on this path waits for a consumer. In `MissionSession.handle_cast({:event, …})` the envelope is folded with the pure `Lifecycle.apply_event/3`, the fold's notes are logged, one `Logger.info` line is written, and every subscriber receives `{:relay_event, %Envelope{}}` by `send/2`. Connection evidence reaches subscribers as `{:relay_connection, :opened | :identified | :closed, info}`. The session's only synchronous surface is the `GenServer.call` API: `subscribe/0`, `state/0` (the instance map, copied to the caller), `summary/0`, `summary_text/0`, `report/0`, `report_text/0`. The last four compute `Summary.build/1` (and for the report, `Report.report/1`) **inside the session process**, so a caller of those pays its fold time on the ingestion process.

### 1.3 The existing subscription mechanism

`MissionSession.subscribe/0` registers the calling pid (monitored; removed on `:DOWN`) and from then on the pid receives every envelope and every connection notice. It is adequate as a **change signal**: it carries the envelope itself (sequence, instance id, type, payload) and the transport facts. It is not, on its own, adequate as a **state feed** for a dashboard:

- it carries raw envelopes, not the fold's result; a subscriber that wants the derived state must call `state/0` or `report/0`;
- the fold's notes (gaps, supersession, unattributed occurrences, anomalies, dispositions) are logged, not notified; they are visible only in the folded instance;
- there is no atomic "snapshot then subscribe": a consumer that calls `state/0` and then `subscribe/0` can miss an event between the two (the reverse order is safe because a recompute from `state/0` is idempotent);
- fan-out is a `send` per subscriber executed in the session process; fine for one or two subscribers, undesirable for one subscriber per browser tab.

Conclusion: keep the mechanism unchanged and give it **one** subscriber on the web side (section 3.3).

### 1.4 The semantic model and the report

`Lifecycle.Instance` (one per adapter instance id) holds attempts, contract sessions, unattributed occurrences, connections, gaps and anomalies, folded from the three evidence classes kept apart (M2 section 2). The derived views (`Disguise`, `Items`, `Objectives`, `PlayerState` over `AttemptHistory`) and the presentations (`Summary.build/1`, `Report.report/1`, `Report.render/2`) are pure functions over instances. `Report.report/1` already produces, per instance and per attempt, exactly the structured data a dashboard needs, with a provenance tag on every field: `overview`, `targets`/`non_targets` (display groups, every occurrence, no actor count), `outcome_counts`, `activity` (the four views, labelled), `timeline` (Relay sequence order, both clocks, clock domains), `uncertainty` (one list ending with the four standing limitations), plus the instance-level `observation`, `connections`, `gaps`, `unattributed`, `unpaired_contract_sessions`, `unmatched_contract_ends` and `anomalies`. **The dashboard's data source is this report data; M3 adds no second interpretation of events.**

### 1.5 Dependencies and environment

`mix.exs`: `app: :glacier_relay`, `elixir: "~> 1.19"`, `extra_applications: [:logger]`, **no deps**. Toolchain: OTP 28.4.2 / Elixir 1.19.6 in WSL2 (precompiled, no root), `~/.local/opt/beam-env.sh`. No Hex archive is installed (`mix archive`: none), no `~/.hex`, no `deps/`, no `mix.lock`. Tests use the built-in `JSON` module (Elixir ≥ 1.18). Config: listener `127.0.0.1:4747`, `max_line_bytes 65_536` (test: port 0, 4_096; logger `:warning`). The dev `final_state.exs` tool runs with `mix run --no-start` and folds envelopes itself. Windows reaches a WSL2 loopback listener through WSL2's localhost forwarding; this is the direction a Windows browser needs to reach a WSL2 HTTP endpoint, and it is already proven for port 4747.

## 2. Design questions, answered

1. **Application structure and ownership.** Phoenix as a library inside the existing `relay/` Mix project (single OTP application `:glacier_relay`). Web code lives under its own namespace `GlacierRelayWeb` (`lib/glacier_relay_web/`), the read model under `GlacierRelay.Dashboard` (`lib/glacier_relay/dashboard/`). Ownership: `MissionSession` and `Lifecycle` keep owning the facts; `Report` keeps owning the meaning; the web layer owns only presentation and the viewer's choices (which instance, which attempt, which pane).
2. **Same application or a separate one.** Same application (ADR 0007). The authoritative state is a named GenServer in this VM and the README rules out distributed Erlang; a separate OTP application would need an umbrella or a node boundary for no gain in the property that matters, which is "the web never writes". That property is enforced by the supervision placement, the single-reader projection and a boundary test (section 7.4), not by a package boundary. The whole web stack is behind a config flag so the headless mode used by every M2 run is unchanged.
3. **Are the existing subscriptions adequate?** As a change signal yes; as a state feed no (1.3). Proposal: unchanged `subscribe/0`, one subscriber (the projection), derived state fetched by a coalesced `state/0` call from that one process; two optional later refinements if measurement asks for them (section 3.6).
4. **Updates without blocking ingestion.** The ingestion path gains nothing synchronous: one extra pid in the subscriber set (one `send` per event). LiveView processes never call `MissionSession`. The projection is the only process that does, with at most one `state/0` call per coalescing window (reply = a copy of the instance map; no computation in the session). All derivation (`Report.report/1`) runs in the projection; LiveViews receive finished data over `Phoenix.PubSub` and assign it.
5. **Active adapter and attempt.** "Focus" = the instance most recently heard from (by `received_at` of its last envelope, else the latest connection). Every instance is shown as a card (id, `observation`, `received`, `last_sequence`, gaps, last heard). The focused instance's **current attempt** is `Lifecycle.current_attempt/1` (last known playing) when there is one, else the most recent attempt, labelled as such; the viewer may select any earlier attempt. The wording stays the report's: "attempt N last known playing", "stopped #n", "superseded by attempt m"; never "the game is running".
6. **Connection status separate from mission status.** Two indicators that never derive from each other: **transport** (listener bound at ip:port; per instance `observation` live / lost / never with peer, opened/identified/closed times and close reason; interruptions listed on the attempt as transport lines) and **mission** (attempt playing / stopped / superseded; disposition from contract evidence or "not observed"). A lost connection with an open attempt renders as "observation lost; attempt N last known playing", exactly as the summary does today. The projection labels each instance's `source` as `:live` (this VM's session) or `:replay` (fed from a fixture by the test/dev player), which resolves the M2 section 52.6 note: "never" under `:replay` means "no connection evidence in this replay".
7. **Live semantic event stream.** A bounded LiveView stream (`stream/3`, newest first, `limit: -200`) of the Relay envelopes themselves: sequence, instance id, Relay timestamp, `event_type`, schema version and the payload's fields as the schema carries them (an `engine_timestamp_s` and `contract_session_id` shown when present). DOM id `"#{instance_id}-#{sequence}"`, so a replayed or re-delivered envelope cannot duplicate a row. No derived wording in this pane: the envelope is already the Relay semantic event, and meaning is shown in the attempt panes. Transport notices (`:opened`/`:identified`/`:closed`) appear in the same stream as sequence-less rows tagged transport.
8. **Target outcomes by name.** Rendered from `report.attempts[].targets` and `non_targets` as they are: one display group per `{actor_name, repository_id}` with the occurrence count and every occurrence (sequence, kind, engine time, actor type, engine actor id, the engine classification, damage events, item id), the "display only, never an actor identity" label, and the target note verbatim ("the full status of all mission targets is not established; an absent outcome is not evidence of survival"). No count of actors, no attribution, no survival.
9. **Disguises, items, objectives, player state.** From `report.attempts[].activity`: the disguise view (initial, worn interval, standing with its rule, cut, anomalies; tag derived), the item table (direct counts per type and per definition; tag engine; "nothing paired"), the objective groups (opaque id, first-observed type/category, every sequence, conflicts; tag derived; "first observed"), and the player-state subjects (last observed value with sequence and metadata, occurrences, observed value changes, standing, cut, last named weapon, notes; tag last observed, "never current state").
10. **Uncertainty and last-observed status.** The attempt's `uncertainty` list rendered as its own panel (gaps with the number of envelopes never received, interruptions, supersession, unpaired or ambiguous sessions, standing cuts, anomalies, then the four standing limitations), and a tag chip on every rendered fact: `engine` / `BEAM-derived` / `last observed` / `not observed` / `transport`, with a legend. The chips come from the report's `tag` fields; templates never assign a tag themselves.
11. **Summary v2 as a mission report.** Route `/report`: the structured report (the same panes for every instance and attempt, oldest first) and the verbatim `Report.render/2` text in a `<pre>`; route `/report.txt` serves that text as `text/plain` for saving (nothing is stored server-side). A test asserts the served text equals `MissionSession.report_text/0`. The legacy `/summary.txt` (`summary_text/0`) is served the same way so run evidence stays comparable with the headless path.
12. **Reconnects, missing events, observation loss.** All of it is already in the data: a gap is listed with its range; an interruption stays on the attempt and the instance shows `lost`; a reconnect of the same instance (new connection identified) returns `live` and keeps the interruption; a new adapter instance id is a new card, never a replacement; a superseded attempt says so. Web-side: a browser disconnect reconnects the LiveView, which remounts from the projection's current snapshot (state is server-side, nothing is lost); a projection restart re-reads the session on `init` and PubSub subscriptions survive it; a `MissionSession` restart empties the dashboard (the existing M2 property, shown as "no instances"). Nothing on the web side ever asserts a mission ended because a socket closed.
13. **Rerendering during bursts.** Three measures: the projection coalesces (first event starts a short timer, e.g. 50 ms; one `state/0` read and one recompute per window; it recomputes only instances whose `received` or connection count changed, keeping per-instance reports keyed by `{received, connections}`); the event stream is a LiveView stream (append-only DOM patches, no re-render of the list); the report panes are separate assigns (`overview`, `targets`, `activity`, `uncertainty`, `timeline`) so LiveView's change tracking patches only what changed. Observed rates bound the problem: the densest burst in M2 was five outcomes in 1.75 s (B1) and runs hold 10–45 envelopes; there is no continuous state in M2.
14. **No dashboard interaction becomes a Glacier command.** There is no inbound protocol: `Wire.Connection` never sends ("nothing is ever sent back"), and no module in the web or dashboard namespaces may reference `GlacierRelay.Wire.*`, `:gen_tcp`, `MissionSession.handle_event/2`, `connection_opened/2`, `connection_closed/2` or `GenServer.cast` toward the session (boundary test, section 7.4). The LiveView's `handle_event/3` clauses are viewer choices only (`"focus"`, `"select_attempt"`, `"select_pane"`, `"clear_stream"`), each changing socket assigns and nothing else. The endpoint binds to `127.0.0.1` only, serves no API, accepts no uploads and keeps CSRF protection on. A command channel is M5 and would be a new, separately designed path that this design does not open.
15. **Testing without HITMAN.** Fixture replay into the real `MissionSession` (section 7), LiveView tests over it, the pure projection tested over fixture-folded instances, and connection-loss and multi-instance scenarios driven through the real listener with raw sockets as `listener_test.exs` already does. No live game until M3-C.

## 3. Proposed architecture

### 3.1 Diagram

```
HITMAN (Windows)                                   WSL2 / BEAM (:glacier_relay)                                  Windows browser
───────────────                                    ────────────────────────────────────────────────────────────  ────────────────
GlacierRelay.dll ── NDJSON/TCP ──► Wire.Listener ─► Wire.Connection ─cast─► MissionSession ─────────────────────
(unchanged, c5152848)              127.0.0.1:4747                              │ fold (Lifecycle), log, notify
                                                                               │ send {:relay_event | :relay_connection}
                                                                               ▼
                                                     GlacierRelay.Dashboard.Projection  (the only web-side subscriber)
                                                       coalesce → MissionSession.state/0 (one call per window)
                                                       → Report.report/1 per changed instance → snapshot (revision n)
                                                       → PubSub "dashboard:snapshot" {:snapshot, snapshot}
                                                       → PubSub "dashboard:events"   {:event, instance_id, envelope}
                                                                               │
                                                                               ▼
                                                     GlacierRelayWeb.Endpoint (Bandit, 127.0.0.1:4748) ◄── HTTP/WS ──► DashboardLive, ReportLive
                                                       routes: /  /report  /report.txt  /summary.txt                     (render report data; no interpretation)
```

Data flows left to right only. The only arrows that reach `MissionSession` from the right are `subscribe/0` (once, at projection start) and `state/0` (coalesced). Nothing reaches `Wire.*`.

### 3.2 Supervision changes

```
GlacierRelay.Supervisor                           one_for_one (unchanged strategy)
├── GlacierRelay.MissionSession                   unchanged
├── GlacierRelay.Wire.ConnectionSupervisor        unchanged
├── GlacierRelay.Wire.Listener                    unchanged
└── GlacierRelayWeb.Supervisor                    NEW, last child; started only when config :glacier_relay, :dashboard, enabled: true
    ├── {Phoenix.PubSub, name: GlacierRelay.PubSub}
    ├── GlacierRelay.Dashboard.Projection         subscribes to MissionSession on init; re-reads state on restart
    └── GlacierRelayWeb.Endpoint                  127.0.0.1:4748; LiveView sockets live under it
    (rest_for_one: a PubSub crash restarts the projection and the endpoint; an endpoint crash restarts nothing else)
```

Ingestion children start first and are never restarted by anything in the web subtree (one_for_one at the top). The web subtree is one failure boundary. With `enabled: false` (the default in `test.exs` for the existing suites, and the headless run configuration) the tree is byte-for-byte the M1 tree. `MissionSession` itself is not modified in the first slice.

### 3.3 Projection (`GlacierRelay.Dashboard.Projection`)

One GenServer. On `init`: `MissionSession.subscribe/0`, then `state/0`, compute, broadcast (subscribe-then-read, so no event is missed). On `{:relay_event, env}`: forward `{:event, env.adapter_instance_id, env}` to `"dashboard:events"` at once (cheap), note the instance as dirty, arm the coalescing timer if not armed. On `{:relay_connection, kind, info}`: forward as a transport row, mark dirty. On the timer: `state/0`, recompute the dirty instances' reports, bump `revision`, broadcast `{:snapshot, snapshot}` on `"dashboard:snapshot"`. `snapshot/0` (call) returns the current snapshot for mounts. The projection holds no evidence of its own; it is a cache of `Report.report/1` keyed by instance and invalidated by the session's own counters.

Snapshot contract:

```
%{revision: n, source: :live | :replay, listener: {ip, port} | :not_bound,
  focus: instance_id | nil,
  instances: [%{id, observation, received, last_sequence, gaps, connections, last_heard_at,
                current_attempt: number | nil,
                report: <the Report.report/1 entry for this instance, unchanged>}],
  unidentified: [...]}            # connections that closed before naming an instance
```

### 3.4 Phoenix dependencies and versions

Resolved and locked at install time (first M3 implementation authorization), recorded in that stage's record. Constraints and the latest versions seen while writing this proposal (hex.pm pages; not verified against hex.pm from this machine, which has no Hex):

| Dependency | Constraint | Seen | Role |
|---|---|---|---|
| `phoenix` | `~> 1.8` | 1.8.x (1.8.7 of 2026-05 confirmed on one index; a later patch may exist) | endpoint, router, controllers for the text routes |
| `phoenix_live_view` | `~> 1.1` | 1.1.28 (2026-03-27) | LiveView, streams, `Phoenix.LiveViewTest` |
| `phoenix_html` | `~> 4.2` | 4.x | HEEx helpers |
| `phoenix_pubsub` | `~> 2.1` | 2.1.x | projection → LiveView fan-out |
| `bandit` | `~> 1.0` | 1.x | HTTP/WebSocket server (Phoenix 1.8 default); brings `plug`, `websock_adapter`, `thousand_island` |
| `lazy_html` | test only, `~> 0.1` | 0.1.x | LiveView 1.1's test DOM (precompiled NIF; needs a C toolchain only if no precompiled binary matches WSL2's Ubuntu 20.04) |

Deliberately not added: `jason` (Phoenix 1.8 uses Elixir's built-in `JSON`; added only if a dependency demands it), `esbuild`/`tailwind`/Node (the LiveView client is served from the prebuilt `priv/static/phoenix.min.js` and `phoenix_live_view.min.js` inside the deps through `Plug.Static` with a ten-line inline `app.js`; styling is one static stylesheet), `phoenix_live_dashboard`, `telemetry_metrics`, `phoenix_live_reload`, `gettext`, `ecto`, `swoosh`, `heroicons`. Installing requires `mix local.hex` and `mix local.rebar` (network from WSL2 to hex.pm and GitHub) and produces `mix.lock`, which is committed. The existing 259 tests must stay green and unchanged.

### 3.5 LiveView ownership model

- `GlacierRelayWeb.DashboardLive` (`/`): on mount subscribes to the two PubSub topics and takes the projection's `snapshot/0`; assigns `snapshot`-derived sub-maps and the viewer's choices (`focus_id`, `attempt_number`, `pane`); streams `events`. It owns **only** viewer choices.
- `GlacierRelayWeb.ReportLive` (`/report`): the same data for every instance and attempt, plus the `<pre>` text; no choices beyond collapse/expand.
- `GlacierRelayWeb.TextController` (`/report.txt`, `/summary.txt`): `MissionSession.report_text/0` / `summary_text/0` as `text/plain`. These two calls run in the session (as today for `final_state` consumers); they are on demand, not on the event path, and can move to the projection's cached report if measurement asks.
- Function components (`GlacierRelayWeb.Components`): `instance_card/1`, `overview/1`, `outcomes/1`, `activity/1`, `uncertainty/1`, `timeline/1`, `event_row/1`, `tag/1`, `legend/1`. Each takes the corresponding report sub-map **as is**; a component never computes a fact, only lays one out.

### 3.6 Data flow and the update mechanism

Event → fold → one `send` to the projection → (a) the envelope row broadcast immediately, (b) a coalesced snapshot broadcast within one window. A LiveView applies (a) with `stream_insert/4` and (b) with `assign/3` of the changed sub-maps, comparing `revision` to drop stale snapshots. Mount order (subscribe, then `snapshot/0`) guarantees no missed revision; the stream's DOM ids make re-delivery harmless. Optional refinements, only if measured: (1) `MissionSession` publishes each folded instance into a protected ETS table it owns, so the projection reads without a call; (2) `subscribe/0` returns the current instance map atomically with the subscription. Neither is needed for the first slice.

### 3.7 Suggested dashboard layout

```
┌ Glacier Relay — live observability   listener 127.0.0.1:4747   snapshot r.142   source: live ───────────────────────┐
│ instances: [6e1b19b6… observation LIVE · 16 events · last #16 · gaps [] · heard 20:51:17Z]  [older instance cards…]  │
├──────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────┤
│ attempt 1 · Peacock · last known playing  [attempts ▾] │ recent Relay events (newest first, last 200)                 │
│ mission overview                                     │  #16 20:51:17.243Z contract.ended  exit_to_menu …  [engine]   │
│  contract … [engine telemetry · BEAM-derived pairing] │  #15 20:51:14.134Z mission.stopped …              [engine]   │
│  start #2 … stop #15 … duration 181.2 s              │  —   20:51:20Z   connection closed (peer_closed)  [transport]│
│  disposition: exited to menu [BEAM-derived]          │  …                                                            │
│  observation coverage: history intact                ├───────────────────────────────────────────────────────────────┤
│ target outcomes [engine; display grouping]           │ uncertainty and limitations (attempt 1)                       │
│  none in the stream; the full status … not established│  - {:cleared_without_compromise, …} [BEAM-derived]            │
│ non-target outcomes                                  │  - whether the mission ended … is not observable [not observed]│
│  Michel Trier (99831d97…) 1 occurrence …             │  - ContractEnd is a name only … [not observed]                 │
│ activity: [disguises] [items] [objectives] [player]  │  - … an absent outcome is not evidence of survival             │
│  player state: trespassing last observed false at #5 │  - player state is the engine's last statement … [not observed]│
│ timeline (sequence order; both clocks)  [show]       │                                                               │
├──────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────┤
│ legend: ■ engine  ■ BEAM-derived  ■ last observed  ■ not observed  ■ transport        /report  /report.txt  /summary.txt│
└───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Every line of text in the left column is the report's own wording. The page never shows a word the report tests forbid (section 7.3).

### 3.8 Component and state contracts

| Contract | Shape | Owner |
|---|---|---|
| `Projection.snapshot/0` | 3.3 | projection (read model) |
| PubSub `"dashboard:snapshot"` | `{:snapshot, snapshot}` | projection → LiveViews |
| PubSub `"dashboard:events"` | `{:event, instance_id, %Envelope{}}` and `{:transport, instance_id \| nil, kind, info}` | projection → LiveViews |
| `DashboardLive` assigns | `revision`, `source`, `listener`, `instances` (cards), `focus_id`, `attempt_number`, `attempt` (the selected attempt's report entry), `pane`; stream `events` | LiveView (viewer choices) |
| `handle_event/3` | `"focus" %{"id"}`, `"select_attempt" %{"number"}`, `"select_pane" %{"pane"}`, `"clear_stream"` | LiveView; each changes assigns only |
| Components | take report sub-maps unchanged; every rendered fact prints its `tag` | `GlacierRelayWeb.Components` |
| Config | `config :glacier_relay, :dashboard, enabled: false \| true, ip: {127,0,0,1}, port: 4748, coalesce_ms: 50, stream_limit: 200` | application |

## 4. First implementation slice (M3-A + M3-B, read-only)

**M3-A — skeleton (one authorization, offline only).** Install Hex/rebar; add the dependencies of 3.4 with `mix.lock`; `GlacierRelayWeb.Supervisor` behind the config flag; `Endpoint` on `127.0.0.1:4748`; `/report.txt` and `/summary.txt`; the boundary test; a headless check that with `enabled: false` the supervision tree's children are exactly the three M1 children. Gate: `mix compile --warnings-as-errors`; the existing 259 tests unchanged and green ×5 with the flag off; the new tests green with the flag on; `final_state.exs` unchanged; native tree clean at `c5152848`; no change under `lib/glacier_relay/wire/`, `events.ex`, `lifecycle.ex`, the derived views, `summary.ex`, `report.ex`.

**M3-B — dashboard (one authorization, offline only).** `Projection` with coalescing and the `live`/`replay` source label; `DashboardLive` with the instance cards, mission overview, target and non-target outcomes, activity panes, uncertainty panel, timeline, event stream; `ReportLive`; the tests of section 7. Gate: as M3-A plus the LiveView tests over every fixture, the forbidden-word check over rendered HTML, the connection-loss and multi-instance scenarios, and a measured upper bound on the session's `state/0` reply time and the projection's recompute time over the largest fixture (`b5_run1`, 45 envelopes) replayed at the B1 burst rate.

Potential views in scope for the first slice: adapter/connection status; active mission overview; contract session and attempt; named target outcomes; recent Relay events; disguise observations; item activity; objective occurrences; player-state last-observed values; uncertainty/observation-loss indicators; mission report. Out of scope: persistence, spatial heat maps, multiplayer, command channels, remote game control, authentication (loopback only), any non-loopback bind.

## 5. Runtime gates (M3-C — controlled live experiment, its own authorization)

Nothing native changes: the accepted DLL `6047a9a3…` is the artifact, hash-verified before install, with the same mechanical cleanup (`run-cleanup.sh`) and the M0 restoration check. The experiment adds one thing to the established run procedure: a Windows browser at `http://localhost:4748/` while the mission is played. What only a live run can validate: WSL2 localhost forwarding for the HTTP/WebSocket port (the mechanism is the 4747 one, the port is new); the transport indicator's timing against a real connection open and close (process start, mission, exit, quit); burst behaviour at real publication rates; the rendered report equal to the headless `beam-final-state` path over the same run (`/report.txt` saved beside the run evidence and compared); no change in the native log counters or the game's behaviour (the dashboard cannot affect the game, and the run proves the negative). Abort conditions are the existing ones; nothing is fixed forward during a run.

## 6. Tradeoffs and risks

- **Single application versus umbrella.** Chosen: single. Cost: the Phoenix dependency set enters the core project's `mix.lock`, and a web compile error blocks `mix test` for everyone. Mitigation: the flag keeps the runtime tree headless; the namespaces and the boundary test keep the code apart; an umbrella remains possible later without changing the design.
- **Copying state.** `state/0` copies the instance map to the projection per window and `{:snapshot, …}` copies the computed snapshot to each LiveView. Both are kilobytes at M2 sizes; a long session with many attempts grows linearly and is an M4 concern (nothing is bounded or evicted in M2). Mitigation path: ETS read copy, per-instance snapshots.
- **Two topics, two moments.** An event row can appear before the snapshot that reflects it (by at most one coalescing window). Shown as the snapshot revision; acceptable for an operator view; a test asserts eventual consistency, not simultaneity.
- **Shared singletons in tests.** `MissionSession` and the projection are named processes, so LiveView tests run `async: false` like the listener tests. Mitigation later: optional `name:` options for both.
- **Hex and network.** The install needs hex.pm and GitHub from WSL2 and a possible NIF build for `lazy_html`; the versions resolved on that day are recorded. Risk of drift between the versions named here and those resolved.
- **Wording discipline.** Templates are the new place where a reserved word could slip in. Mitigation: the report's forbidden-word regexes run over every rendered page for every fixture.
- **Memory and crash semantics.** A `MissionSession` crash still loses everything (M2 property); the dashboard makes it visible rather than hiding it. Persistence is M4.
- **Security.** Loopback only, no authentication, CSRF on, no uploads, no API. Binding elsewhere is out of scope and would need its own decision.
- **Temptation to interpret.** The largest design risk is adding "helpful" derived statements in the UI (a status pill that says "safe", a count of "targets remaining"). The contract that components take report sub-maps unchanged, plus the tag on every fact and the forbidden-word tests, is the defence.

## 7. Testing approach (no HITMAN)

1. **Pure projection tests.** Fold each committed fixture (`stage1`, `stage_a_probe`, `b1_probe` … `b6_probe`, `b5_run1`, `b6_run1`) with the `fixture_instances` pattern of `report_test.exs`; assert the snapshot's per-instance `report` equals `Report.report/1` of the same instances, `source: :replay`, `focus` and `current_attempt` as defined, revision monotonic, and that the projection never changes an instance (compare before and after).
2. **Deterministic playback into `MissionSession`.** A test-only player (`GlacierRelay.Fixtures.Player`) sends a fixture's lines through the real listener over a raw socket, optionally with pauses and with the socket closed and reopened at chosen points; the session treats it as any adapter. LiveView tests (`Phoenix.LiveViewTest`: `live/2`, `render/1`, `has_element?/2`, `render_click/2`) assert the dashboard shows the report's lines for the current attempt, the target groups, the activity panes, the uncertainty list and the event rows in order.
3. **Forbidden words.** The `@forbidden` and `@player_claims` regexes of `report_test.exs`/`player_state_test.exs` applied to the rendered HTML text of every page for every fixture, excluding the labelled limitation lines, exactly as the report tests do.
4. **Boundary.** A test reads every file under `lib/glacier_relay_web/` and `lib/glacier_relay/dashboard/` and fails on any reference to `Wire.`, `:gen_tcp`, `handle_event(`, `connection_opened`, `connection_closed` or `GenServer.cast`; and `mix xref graph --sink lib/glacier_relay/wire/connection.ex` lists no web or dashboard file.
5. **Connection loss.** Play half of `b5_run1`, close the socket: the instance card shows `lost`, the attempt shows last known playing with the interruption, the stream shows the transport row; reopen with the rest: `live`, the attempt closes from `mission.stopped`, the interruption stays listed.
6. **Multiple instances.** Two sockets with two adapter ids interleaved: two cards, focus follows the last heard, each attempt under its own instance, no cross-attribution; a third connection that closes before naming an instance appears under unidentified.
7. **Bursts.** Replay the B1 explosion window at wall-clock speed and at 10× speed: one snapshot per coalescing window at most, every event row present exactly once, final snapshot equal to the headless report.
8. **Headless invariance.** With `enabled: false`, the supervision children and the whole existing suite are unchanged.

## 8. Staged plan and the authorizations each needs

| Stage | Content | Needs |
|---|---|---|
| M3 design (this document, ADR 0007) | proposal | review |
| M3-A | Hex/rebar, dependencies with lock, web supervisor behind a flag, endpoint on loopback, text routes, boundary test | its own authorization (installs dependencies) |
| M3-B | projection, `DashboardLive`, `ReportLive`, components, fixture-driven tests, measurements | its own authorization |
| M3-C | one controlled live experiment with the unchanged accepted DLL and a Windows browser | its own authorization and the operator's readiness |
| M3 acceptance | record, roadmap status with the exit criterion as written ("Phoenix/LiveView dashboard for current mission state and event stream" has no exit sentence; one should be proposed at M3-A: *a browser on the Windows host shows a mission attempt's state and its Relay event stream from the OTP-owned model during a live run, with transport and mission status separate*) | review |

## 9. Questions that need a new authorization

1. Approve ADR 0007 (single application, loopback endpoint, projection as the single web-side reader, no web-to-wire path) or ask for the umbrella variant.
2. Authorize M3-A, which installs Hex, rebar and the dependencies of 3.4 and commits `mix.lock`.
3. Confirm the port (`4748`) and that loopback-only binding without authentication is acceptable for M3.
4. Confirm the proposed M3 exit sentence (section 8) before it is written into `ROADMAP.md`, since the roadmap's wording is not changed without approval.
5. Whether `/summary.txt` (legacy text) should be served beside `/report.txt` for run-evidence comparison (proposed yes).
6. Whether the optional `MissionSession` refinements (ETS read copy; atomic subscribe-with-state; `name:` option) may be designed into M3-B or wait for a measurement.

**Stop here. No installation, implementation or runtime step is authorized by this document.**

## 10. M3-A implementation record (2026-10-12) — Phoenix web foundation built and validated offline; M3 not closed

Authorization: M2 completion and the proposed architecture accepted; ADR 0007 accepted with two refinements (the projection as the normal web-side reader; a stage-limited exception letting the two diagnostic routes read `MissionSession`'s presentations directly until the projection exists); M3-A only. Scope delivered: dependency bootstrap, optional web supervision, loopback HTTP endpoint, the two text routes, boundary validation, headless regression gate, offline HTTP validation. **Not delivered, by design:** `Dashboard.Projection`, any LiveView, browser fan-out, event-stream UI, persistence, commands, authentication, non-loopback hosting. The native repository is unchanged at the M2 checkpoint (`c5152848`, DLL `6047a9a3…`); nothing was deployed or run against the game; the wire protocol and every event schema are unchanged.

### 10.1 Commits

| What | Ref |
|---|---|
| Dependency bootstrap (`mix.exs`, `mix.lock`, `.formatter.exs`) | glacier-relay `main` **`6012c16`** |
| Web foundation (config, `Application`, `lib/glacier_relay_web/`, `test/glacier_relay_web/`) | glacier-relay `main` **`3dc54b4`** |
| This record, ADR 0007 acceptance, roadmap exit criterion, handoff, `relay/README.md` | the commit that adds it |

### 10.2 Dependencies as resolved from Hex in the WSL2 environment

Resolved on 2026-10-12 with `mix hex.info` and `mix deps.get` (the design's section 3.4 figures were superseded: LiveView had moved to 1.2 and PubSub to 2.4). Hex 2.5.2 and rebar3 installed in user scope by `mix local.hex` / `mix local.rebar` (no root). `mix.lock` SHA-256 `24d1e73a5a0692f3a3448f577988e7f0d5567579055508064481948f92fbfa88`, committed in `6012c16`. OTP 28.4.2, Elixir 1.19.6.

| Dependency | Constraint | Resolved | Role |
|---|---|---|---|
| `phoenix` | `~> 1.8` | **1.8.15** | endpoint, router, controller |
| `phoenix_live_view` | `~> 1.2` | **1.2.12** | installed for M3-B; nothing mounted |
| `phoenix_html` | `~> 4.3` | 4.3.0 | HEEx helpers (M3-B) |
| `phoenix_pubsub` | `~> 2.4` | 2.4.1 | the web subtree's PubSub (fan-out in M3-B) |
| `bandit` | `~> 1.12` | **1.12.5** | HTTP server (`Bandit.PhoenixAdapter`) |
| `lazy_html` | `~> 0.1`, test only | 0.1.13 | LiveView's test DOM (precompiled NIF `nif-2.16-x86_64-linux-gnu` downloaded; no C build) |
| transitive | | `plug` 1.20.3, `plug_crypto` 2.2.0, `phoenix_template` 1.1.0, `thousand_island` 1.5.0, `websock` 0.5.3, `websock_adapter` 0.6.0, `hpax` 1.1.0, `mime` 2.0.7, `telemetry` 1.4.2, `elixir_make` 0.10.0, `cc_precompiler` 0.1.11, `fine` 0.1.6 | |

Not installed: Node, esbuild, Tailwind, `jason` (Phoenix is configured with Elixir's built-in `JSON`), `phoenix_live_dashboard`, `phoenix_live_reload`, `telemetry_metrics`, Ecto or any database. No generator was run; the existing application was not regenerated or overwritten.

### 10.3 Supervision and configuration

```
GlacierRelay.Supervisor                           one_for_one (unchanged)
├── GlacierRelay.MissionSession                   unchanged
├── GlacierRelay.Wire.ConnectionSupervisor        unchanged
├── GlacierRelay.Wire.Listener                    unchanged (127.0.0.1:4747)
└── GlacierRelayWeb.Supervisor                    only when `config :glacier_relay, :dashboard, enabled: true`
    ├── {Phoenix.PubSub, name: GlacierRelay.PubSub}      rest_for_one
    └── GlacierRelayWeb.Endpoint                         Bandit, 127.0.0.1:4748; (M3-B projection goes between the two)
```

`config/config.exs`: `:dashboard, enabled: false` (every environment); endpoint `http: [ip: {127,0,0,1}, port: 4748]`, `server: true`, `adapter: Bandit.PhoenixAdapter`, `pubsub_server: GlacierRelay.PubSub`, `render_errors: [formats: [text: GlacierRelayWeb.ErrorText]]`, `check_origin: ["//localhost", "//127.0.0.1"]`, `config :phoenix, :json_library, JSON`. `config/runtime.exs` (new): `GLACIER_RELAY_DASHBOARD=1` enables the subtree; `secret_key_base` is random per boot (no session outlives the VM; no secret committed). `config/test.exs`: disabled; endpoint port 0 for the web-enabled tests, which start the subtree themselves. `Application.dashboard_enabled?/0` is the single decision point. Under one-for-one at the top, nothing in the web subtree can restart an ingestion child; the tests kill the endpoint and the PubSub child and assert `MissionSession` and `Listener` keep their pids while the endpoint comes back and answers.

### 10.4 Endpoint and routes

`GlacierRelayWeb.Endpoint`: `Plug.Head` (HEAD answered as GET without a body; no `Plug.MethodOverride`), `Plug.Session` (cookie store, reserved for future interactive routes; the text routes never touch it), `GlacierRelayWeb.Router`. Router: pipeline `:browser` (`accepts html`, `fetch_session`, `protect_from_forgery`, `put_secure_browser_headers`) defined with no routes under it yet; pipeline `:diagnostics` (`put_secure_browser_headers`) with

| Route | Handler | Response |
|---|---|---|
| `GET /report.txt` | `TextController.report/2` → `MissionSession.report_text/0` | 200, `text/plain; charset=utf-8`, the B7 report text |
| `GET /summary.txt` | `TextController.summary/2` → `MissionSession.summary_text/0` | 200, `text/plain; charset=utf-8`, the legacy summary text |
| any other method on those paths | `TextController.fallback/2` | 405, `allow: GET, HEAD`, nothing read or changed |
| any other path, any method | `TextController.fallback/2` | 404, nothing read or changed |

No socket, LiveView, static file, upload, API, parser or write path is mounted. `GlacierRelayWeb.ErrorText` renders an exception inside a request as a status phrase in text; routing itself never reaches it.

### 10.5 Security assumptions (local development observability tool)

Loopback only (`127.0.0.1:4748`); no authentication is authorized at this stage, so **any local process able to reach the loopback port can read the mission report and summary.** Verified not bound to `0.0.0.0`, the WSL2 external interface (`172.23.229.225`) or any LAN address: the test connects to every non-loopback IPv4 address of the host and asserts refusal; the offline validation shows `ss` listing `127.0.0.1:4747` and `127.0.0.1:4748` only, and both a WSL2 `curl` and a Windows `curl.exe` to `172.23.229.225:4748` fail (`000`, connection refused) while `127.0.0.1:4748` answers 200. CSRF (`protect_from_forgery`) and origin checks (`check_origin` restricted to loopback hosts) are configured for the future interactive routes. No write endpoint, arbitrary file path, upload, generic RPC, shell execution or websocket command handler exists. The wire listener (4747) and the HTTP endpoint (4748) are two sockets with two purposes and are never conflated.

### 10.6 Read-only boundary (tests, `test/glacier_relay_web/boundary_test.exs` and `endpoint_test.exs`)

Compiled proof: for every module under `GlacierRelayWeb`, the BEAM file's remote-call table (`:beam_lib` `imports`) contains no call into `Wire.Listener`, `Wire.Connection`, `Wire.Framing`, `Wire.Envelope`, `Lifecycle`, `Events`, `:gen_tcp`, `:socket`, `:inet` or `:ssl`, no `GenServer.cast/call`, and the only `MissionSession` calls anywhere are `TextController` → `report_text/0` and `summary_text/0`. Source proof: no web source mentions a wire, socket, model, evidence-delivery, process-messaging or native SDK token (`ZString`, `ZRepositoryID`, `ZDynamicObject`, `ZHMModSDK`, `Mods/`, `Glacier/`, `TelemetryIntake`, …). Exported-function proof: no web module exports an evidence-delivery function. Behavioural proof over real HTTP: the router's reflection lists exactly the two GET routes plus the refusing fallback; `POST`/`PUT`/`PATCH` with an envelope-shaped body and `DELETE` on both paths return 405, `POST /events` with the whole B6 fixture returns 404, and in every case `MissionSession.state/0` is unchanged and no `{:relay_event, _}` reaches a subscriber. Nothing a browser can send publishes a Relay event or alters semantic evidence.

### 10.7 Headless regression gate

With the dashboard disabled (the default): `Supervisor.which_children/1` on the application supervisor yields exactly `[MissionSession, Wire.ConnectionSupervisor, Wire.Listener]` in the M2 order (3 specs, 3 active); no `GlacierRelayWeb.Supervisor`, `GlacierRelayWeb.Endpoint` or `GlacierRelay.PubSub` process is registered; a connection to port 4748 is refused; the wire listener is loopback, bound and answering. The existing 259 tests are unchanged and green; `summary/0`, `summary_text/0`, `report/0`, `report_text/0` are unchanged (the HTTP tests assert byte equality with them); `final_state.exs` (`--no-start`, RPC into the running node) still works (10.8). The live headless node showed the three children, `endpoint pid: nil`, `dashboard_enabled?: false`, `127.0.0.1:4747` listening and 4748 refused.

### 10.8 Offline HTTP validation (2026-10-12, 23:00Z to 23:04Z; evidence `%TEMP%\glacier-m0\hitmen\m3a-offline\`, `sha256.txt`; no HITMAN)

| Step | Result |
|---|---|
| Start with `GLACIER_RELAY_DASHBOARD=1 elixir --sname relay -S mix run --no-halt` | `ss`: `127.0.0.1:4747` and `127.0.0.1:4748` listening (same `beam.smp` pid); `beam-web.log` 0 errors |
| `GET /report.txt`, `GET /summary.txt` before any event | 200, `text/plain; charset=utf-8`, "no adapter instance has delivered an event" |
| Refusals | `POST /report.txt` 405; `DELETE /summary.txt` 405; `GET /` 404; `POST /events` (whole fixture) 404 |
| Replay `test/b6_run1_envelopes.ndjson` through the wire listener (`nc 127.0.0.1 4747`) | the normal ingestion path; nothing about it changed |
| `GET` both routes after the replay | 49-line report for `6e1b19b6…` (16 events, attempt 1 Peacock, exited to menu, observation lost after the replay socket closed) |
| Same state through RPC (`MissionSession.report_text/0`, `summary_text/0` from a second node) | **byte-identical** to the HTTP bodies |
| `final_state.exs` (unchanged tool from `wire-probe\b6`, `--no-start`) | rc 0; its `summary_text/0` section **identical** to `/summary.txt` (the tool appends one newline) |
| Windows host → WSL2 | `curl.exe http://127.0.0.1:4748/summary.txt` 200; `curl.exe http://localhost:4748/report.txt` **identical** to the WSL2 body (localhost forwarding works for the new port, the same mechanism as 4747) |
| Non-loopback | WSL2 `curl http://172.23.229.225:4748` → refused (rc 7, `000`); Windows `curl.exe` to the same → `000`, failed as expected; bind list `127.0.0.1:4747`, `127.0.0.1:4748` only |
| Stop via RPC `:init.stop` | both ports free within a second; no `beam.smp` left |
| Headless start (no variable), inspect via RPC, stop | 4747 only; 4748 refused (rc 7); children `[MissionSession, Wire.ConnectionSupervisor, Wire.Listener]`; endpoint pid nil; `dashboard_enabled?` false; both ports free after stop. (A first headless attempt right after the stop failed with "name relay@VENGEANCE seems to be in use": epmd had not yet released the name; retried once the registration was gone. Nothing was changed.) |

### 10.9 Tests and gate

| Step | Result |
|---|---|
| Dependency resolution | clean (10.2); `mix.lock` committed |
| Formatting | `mix format --check-formatted` on every changed or new file passes (`.formatter.exs` gains `import_deps: [:phoenix, :plug]`; known-good files were not reformatted) |
| Compilation | `mix compile --warnings-as-errors` clean |
| Suite ×5 (`m3a-mix5.txt`) | **279 tests, 0 failures, five consecutive runs** with `--warnings-as-errors` (259 existing + 5 headless + 10 endpoint + 5 boundary) |
| Web-enabled tests | real HTTP over a raw socket against the real application (the OTP build's `inets` HTTP client does not load `:http_util`; the test depends on nothing but the endpoint) |
| Wire / schemas | `lib/glacier_relay/wire/`, `events.ex`, `lifecycle.ex`, the derived views, `summary.ex`, `report.ex` untouched (git diff empty); the listener tests unchanged |
| Native | ZHMModSDK `relay/m2` clean at `c5152848`; no build |

### 10.10 Recorded for M3-B (not implemented)

**Subscription semantics (section 8 as accepted):** `MissionSession` subscription notifications are change signals, not authoritative snapshots. The projection subscribes; reads the current state after subscribing; coalesces subsequent notifications; rebuilds presentation snapshots from session-owned state; publishes revisions through `Phoenix.PubSub`. The envelope in a notification is never taken as the final folded instance, and the session's notification ordering is not changed. **Implementation boundary for M3-B:** `GlacierRelay.Dashboard.Projection` as a child between PubSub and the endpoint; `DashboardLive`, `ReportLive` and function components rendering `Report.report/1` data unchanged; the LiveView socket mounted in the endpoint with the loopback `check_origin`; the LiveView client served from the dependencies' `priv/static`; the decision on the two text routes (migrate to projection-owned cached data, or keep as justified on-demand diagnostic reads); the fixture player and the LiveView tests of section 7; the viewer-choice `handle_event/3` clauses, which change assigns only. Each needs its own authorization.

**Stop here. M3-B and M3-C are not authorized by this record; nothing is deployed and HITMAN is not launched.**

## 11. M3-B implementation and offline validation record (2026-10-12/13) — projection, dashboard and report page built and validated without the game; M3 not closed

Authorization: M3-A accepted; M3-B authorized (projection, LiveView dashboard, report view, fixture-driven tests, offline validation); M3-C separately gated. Flow delivered exactly as required: Glacier Relay TCP → `MissionSession` → read-only `Projection` → `Phoenix.PubSub` → LiveView → browser. `MissionSession` owns evidence; `Report` owns report semantics; the projection owns cached presentation snapshots; LiveViews own viewer selection and rendering only. **Not delivered, by design:** M3-C, persistence, remote access, authentication, non-loopback hosting, heat maps, commands, M4/M5. Native repository unchanged at `c5152848` (DLL `6047a9a3…`); wire protocol and schemas unchanged; nothing deployed; HITMAN not launched.

### 11.1 Commits

| What | Ref |
|---|---|
| `Report` wording helpers made public (`@doc false`; `render/2` byte-identical) and `MissionSession.unidentified/0` (a read) | glacier-relay `main` **`251d6be`** |
| Projection, web subtree, LiveViews, components, layout, client assets, fixture player, rendering checks, tests | glacier-relay `main` **`c9c95c9`** |
| This record, handoff, roadmap, relay README | the commit that adds it |

### 11.2 New modules and routes

| Module / file | Role |
|---|---|
| `GlacierRelay.Dashboard.Projection` | the single web-side subscriber of `MissionSession`; cached snapshots; coalescing; revisions; PubSub publication (`dashboard:snapshot`, `dashboard:events`); `snapshot/0`, `stats/0`, `refresh/0`, pure `build/4` |
| `GlacierRelayWeb.Supervisor` | `rest_for_one`: `Phoenix.PubSub` → `Projection` → `Endpoint`; started last under the application supervisor only when `:dashboard, enabled: true` |
| `GlacierRelayWeb.Endpoint` | adds the LiveView socket (`/live`, WebSocket only, session for CSRF), three read-only `Plug.Static` mounts (`/assets/phoenix/phoenix.min.js`, `/assets/live_view/phoenix_live_view.min.js`, `/assets/app.css`, `/assets/app.js`) |
| `GlacierRelayWeb.Router` | `live "/"` → `DashboardLive`, `live "/report"` → `ReportLive` under the browser pipeline (session, live flash, root layout, CSRF, secure headers); `GET /report.txt`, `GET /summary.txt`; the fallback now also answers 405 for other methods on `/` and `/report` |
| `GlacierRelayWeb.Layouts` | the root layout: CSRF meta, stylesheet, the two prebuilt client scripts and `app.js` |
| `GlacierRelayWeb.DashboardLive` | the dashboard; viewer choices only (`focus`, `select_attempt`, `select_pane`, `toggle`, `clear_events`); bounded event stream |
| `GlacierRelayWeb.ReportLive` | every instance and attempt with the same components, plus the verbatim report text; `toggle` only |
| `GlacierRelayWeb.Components` | function components that lay out report sub-maps unchanged, using `Report.overview_lines/1`, `group_lines/1`, `counts_text/1`, `activity_lines/1`, `line_text/1`, `tag_text/1`, `connection_line/1`, `stray_lines/1`; `dashboard_body/1` renders the whole page from a snapshot so the empty state is testable without a socket |
| `priv/static/app.css`, `priv/static/app.js` | one stylesheet (two-column grid, one column under 960 px); ten lines of client code that connect the LiveSocket with the page's CSRF token |
| `test/support/fixture_player.ex` | deterministic playback through the real listener with the instance id rewritten per test, optional pacing from envelope timestamps, waits on session notifications |
| `test/support/rendering_checks.ex` | the established forbidden-word regex over the visible text of rendered HTML (limitation lines and verbatim JSON payload cells excluded) |

Configuration added: `:dashboard, coalesce_ms: 50, stream_limit: 200, source: :live`; `GLACIER_RELAY_SOURCE=replay` (runtime) or a `source: :replay` start option labels a controlled playback environment; the label is never inferred from the traffic. `live_view: [signing_salt: …]` is random per boot like the key base.

### 11.3 Projection snapshot contract (as implemented)

```
%{revision: n,                       # monotonic within the VM, across projection restarts (persistent term)
  source: :live | :replay,           # configured provenance, never inferred
  listener: %{ip, port, basis: :configured} | :not_configured,   # read from configuration, never by calling the listener
  built_at: DateTime,
  focus: instance_id | nil,          # an instance with a live connection, else the newest last envelope
  instances: [%{id, observation: :never | :live | :lost, received, last_sequence, gaps,
                connections: [..], last_event: %{sequence, event_type, timestamp} | nil,
                current_attempt: n | nil, latest_attempt: n | nil,
                report: <the Report.report/1 entry for this instance, unchanged>}],
  unidentified: [..],                # connections that closed before naming an instance
  report_text: "…"}                  # Report.render/2 over the same instances and unidentified list
```

Events topic: `{:event, instance_id, %Envelope{}}` for every envelope, `{:transport, instance_id | nil, :opened | :identified | :closed, info}` for transport notices; distinct, never merged, never a mission fact. Startup and restart: subscribe, then `state/0` + `unidentified/0`, build, publish; a notification is a change signal, never a snapshot. Coalescing: one pending timer at most (50 ms); each window reads the session once, recomputes only instances whose fingerprint `{received, last_sequence, connections, anomaly count}` changed, bumps the revision and publishes. `stats/0`: recomputes, snapshots published, events and transport notices seen, dirty ids, recomputed instances, read and recompute latencies (last, max, total).

### 11.4 Measured coalescing and latency (`m3b-perf.txt`, `projection_perf_test.exs`; WSL2, no HITMAN)

| Measurement | Result |
|---|---|
| b5_run1 (45 envelopes) at full speed | 1 snapshot, 1 recompute for 45 events; ingest (send → last notification) 2.5–3.1 ms with the dashboard enabled, 2.4–2.8 ms disabled |
| `MissionSession.state/0` + `unidentified/0` read | 35–816 µs (max over runs) |
| Recompute (`build/4` incl. `Report.report/1` and `render/2`) | warm 0.5–3.7 ms for a 45-envelope instance; **cold 80–102 ms** for the first recompute in a fresh VM (code loading), 44 ms in the live node's first replay |
| B1 window (18 envelopes) at the observed publication rate (1.65 s) | 18 snapshots, 18 recomputes: every event sat in its own 50 ms window, as designed |
| B1 window accelerated (full speed) | 1 snapshot, 1 recompute; final report identical to the authoritative report |
| `GET /report.txt` (the M3-A exception) during the 45-envelope burst | 8 requests; min 0.4–3.1 ms, **max 76–254 ms** (the maximum includes the request that coincides with the cold recompute and the session's own `report_text` fold; warm requests are milliseconds) |
| 200-row event window from real envelopes | 79,736 bytes flat size (about 80 KB per viewer) |
| Snapshot broadcasts per burst | equal to recomputes (one per window) |
| Observable ingestion backpressure | none measured: the dashboard adds one `send` per event to the session's path; end-to-end ingest differs by well under a millisecond per run |

No threshold is set from these numbers. Recommendation for M3-C: treat a warm recompute above 50 ms per window, a session read above 5 ms, or an ingest difference above 10 ms against headless as a finding to investigate, and record cold-start separately (the first recompute after boot is expected to cost tens of milliseconds once).

### 11.5 Tests (`m3b-mix5.txt`)

**311 tests, 0 failures, five consecutive runs** with `--warnings-as-errors` (259 from M2, 20 from M3-A, 32 added here). Projection (`projection_test.exs`): `build/4` equals the B7 report and text on all ten fixtures with nothing recomputed on a second build; empty state; unidentified evidence; `:live` unless the environment says `:replay`; late start reads the session; burst coalescing with every event in the authoritative timeline and strictly increasing revisions; dirty recomputation; a connection close is never a stop and a reconnect continues the instance (the interruption stays on the record; the attempt then stops from `mission.stopped`); several adapters and the focus rule; the events topic's two message kinds per instance; crash and restart with a higher revision and untouched ingestion pids; no mutation of session evidence. Performance (`projection_perf_test.exs`): 11.4. Dashboard (`dashboard_live_test.exs`): the empty state renders without a socket and claims nothing; a replayed mission through the real listener, newest events first, with the limitations and the forbidden-word check; transport and mission status separate through live → lost → reconnect → stopped; viewer choices change presentation only with the session state unchanged; the bounded window (230 synthetic lifecycle envelopes: at most 200 rows in the pane, 115 attempts and 230 events in the report). Report page (`report_live_test.exs`): the structured panels, the four limitations, the verbatim `<pre>` text equal to the snapshot's and the session's `report_text/0`, collapsing changes presentation only; a later snapshot updates the page. Boundary (`boundary_test.exs`, now covering `GlacierRelay.Dashboard` too): compiled remote-call tables (no wire, socket, validation, folding or delivery calls; the projection's only session calls are `subscribe/0`, `state/0`, `unidentified/0`; LiveViews and components call the session not at all; no `GenServer.cast`), exported functions, source tokens, and the LiveViews' event names (`clear_events focus select_attempt select_pane toggle`; `toggle`). Endpoint (`endpoint_test.exs`): pages and assets served GET-only, the socket path refused without an upgrade, path traversal 404, every other method 405 on the known paths. Headless (`headless_test.exs`): unchanged.

Two test-side lessons, recorded: `Phoenix.PubSub` subscriptions are `Registry` registrations and the registry links the subscriber, so a test that stops the web subtree traps exits first; the bounded-window test renders 230 inserts into a page carrying 115 attempts and needed a longer wait (it was flaky at 3 s, stable at 10 s; a presentation cost of the synthetic case, not of real runs).

### 11.6 Browser asset provenance

Served read-only from the resolved dependencies: `deps/phoenix/priv/static/phoenix.min.js` (25,556 B; defines the global `Phoenix`) and `deps/phoenix_live_view/priv/static/phoenix_live_view.min.js` (124,124 B; defines the global `LiveView`; LiveView 1.2.12), mounted with `Plug.Static` `from: {:phoenix, "priv/static"}` / `{:phoenix_live_view, "priv/static"}` restricted to those two files. No Node, bundler, Tailwind or generated asset; the application's own `app.js` (505 B) and `app.css` (3,969 B) are plain files under `priv/static`. Paths were verified against the installed versions, not assumed.

### 11.7 Offline validation (2026-10-13, 03:50Z to 03:56Z; evidence `%TEMP%\glacier-m0\hitmen\m3b-offline\`, `sha256.txt`; no HITMAN)

| Step | Result |
|---|---|
| Start `GLACIER_RELAY_DASHBOARD=1 elixir --sname relay -S mix run --no-halt` | `127.0.0.1:4747` and `127.0.0.1:4748` listening (one `beam.smp`); web subtree children `[Phoenix.PubSub.Supervisor, Dashboard.Projection, Endpoint]` |
| Pages and assets (WSL2 curl) | `/` 200 html (empty state: "no adapter instance has delivered an event"), `/report` 200, `/report.txt` and `/summary.txt` 200 text, `app.css` 200 `text/css`, `app.js` and both client libraries 200 `text/javascript` |
| Refusals | `POST /` 405, `POST /report` 405, `POST /events` (whole fixture) 404, `GET /live/websocket` without an upgrade 400, `GET /assets/../mix.exs` 404 |
| WebSocket handshake (WSL2 curl; cookie + CSRF token from the page) | **`HTTP/1.1 101 Switching Protocols`**; foreign `Origin` → **403** (`check_origin`, logged as "Could not check origin", the only error line in the web log); without the CSRF token → 101 at the transport, but Phoenix then loads no session (`Phoenix.Socket.Transport.connect_session/4`), so the join is refused (next row) |
| **LiveView join over a real WebSocket from the Windows host** (`ws-join.ps1`, .NET `ClientWebSocket`, `ws://localhost:4748/live/websocket`, Origin `http://localhost:4748`, the session cookie, the page's CSRF, session and static tokens) | state `Open`; `phx_join` → `phx_reply` **`"status":"ok"`**, 13,362 bytes rendered, `liveview_version 1.2.12`, carrying the replayed instance id, "stopped at #15" and the limitation line (`ws-join-reply.json`); clean close. The same join **without** the CSRF token → `{"status":"error","response":{"reason":"stale"}}`. Localhost forwarding carries the WebSocket upgrade from Windows to WSL2. (`curl.exe` on Windows could not be made to print the 101; the .NET client is the record.) |
| Replay `b6_run1` through the wire listener, then read the pages | dashboard and report pages carry the instance, "observation lost", "stopped at #15", Michel Trier, the player-state line, the limitation line, the bounded-window label; `/report.txt` **byte-identical** to `MissionSession.report_text/0` over RPC; projection snapshot revision 2, source live, 1 instance, stats `recomputes 2, events_seen 16, transport_seen 3` |
| Non-loopback | Windows `curl.exe` to `172.23.229.225:4748` → refused; bind list `127.0.0.1:4747`, `127.0.0.1:4748` only |
| Stop via RPC `:init.stop` | both ports free, epmd name released, no `beam.smp` left |
| Headless start, RPC inspection, stop | `127.0.0.1:4747` only; 4748 refused; children `[MissionSession, Wire.ConnectionSupervisor, Wire.Listener]`; `Web.Supervisor`, `Endpoint`, `PubSub`, `Projection` pids all nil; `dashboard_enabled?` false; both ports free after stop; headless log 0 errors |

### 11.8 Headless, restart and security boundaries

Headless mode is byte-for-byte the M2 tree (tested and inspected live). Inside the web subtree, a projection crash restarts the projection and the endpoint (rest_for_one; its LiveViews remount from the recovered snapshot, read from the session, with a higher revision); an endpoint crash restarts only the endpoint; neither touches `MissionSession` or the listener (tested). A browser disconnect remounts from the current snapshot; a projection restart never assumes its mailbox held history. Security assumptions unchanged from M3-A: loopback only, no authentication, any local process reaching the port can read the report; the LiveView socket accepts loopback origins only and a join needs the session cookie and the page's CSRF token; no write route, upload, API, socket command handler or path from the browser to the wire (the compiled-call boundary test now covers the projection as well). The two text routes keep their M3-A implementation (direct read-only session calls) so that their bytes stay comparable with the headless tools; their latency under the fixture burst is in 11.4 and shows no ingestion problem, so no migration is proposed.

### 11.9 Unresolved issues (recorded, none blocking)

1. The first recompute after boot costs tens of milliseconds (code loading); a warm-up is not added to production. M3-C should read `Projection.stats/0` after the run to separate cold from warm.
2. `GET /report.txt` during a burst showed a 76–254 ms maximum in the test VM, dominated by cold paths and the session's own fold of `report_text/0`; warm requests are milliseconds. If M3-C shows it mattering, the M3-A exception can migrate to the projection's cached `report_text` (same bytes for the same state) as a separate refinement.
3. Stopping a test-supervised endpoint logs a Phoenix `PoolDrainer` ETS error (`GlacierRelayWeb.Endpoint` config table already gone when the socket pool drainer terminates); cosmetic, test-only, not seen on `:init.stop` of the real node.
4. `curl.exe` on Windows did not print the WebSocket 101 (the handshake was proven with the .NET client instead); not an endpoint issue.
5. The B1 window at its observed rate produces one snapshot per event (events 50 ms or more apart); coalescing only merges denser bursts, as intended. The window is configurable (`coalesce_ms`).
6. The `:replay` source label exists but no committed tool sets it yet; the fixture player in tests runs under `:live` through the real listener, and the projection test proves the label is not inferred.

### 11.10 Proposed controlled M3-C runtime validation (its own authorization; ask the operator first)

Artifacts frozen: the accepted M2 DLL `6047a9a3…` (hash-verified on install, unchanged), BEAM glacier-relay `main` at the M3-B record commit with `GLACIER_RELAY_DASHBOARD=1`, the Windows browser at `http://localhost:4748/`. Script: the B6 route (menu → Paris → enter and leave a trespass zone → draw and holster the loadout pistol → exit to menu → quit), with the dashboard open on a second screen. What only the live run validates: the browser's own LiveView client over localhost forwarding (the .NET join proved the transport); transport timing against a real process start, mission and quit; the event pane and the panels updating within one coalescing window at real publication rates; `Projection.stats/0` warm latencies under real bursts; `/report.txt` equal to the headless `final_state.exs` path over the same run; no change in the native log counters (`captured = normalized + malformed`, `published = received`) and no change in game behaviour. Evidence: operator screenshots at defined moments (menu, after the trespass, after the quit), `beam-events.ndjson`, `beam-final-state.txt`, `report.txt`, the projection stats over RPC, the native log and `compare.py` reconciliation as in every M2 run. Pass criteria: every M2 run criterion unchanged; the dashboard shows the attempt and its stop with transport and mission status separate; no fact on screen is absent from `/report.txt`; the forbidden-word check passes over the saved page HTML. Abort conditions and cleanup are the existing ones (`run-cleanup.sh`, hash-verified return to M0); nothing is fixed forward during the run.

**Stop here. M3-C is not authorized by this record; nothing is deployed and HITMAN is not launched. M3 is not closed.**

## 12. M3-C controlled live runtime experiment (2026-10-13, 04:35Z to 05:01Z) — the live flow demonstrated; transport, semantics and operations reported separately; M3 not closed

Authorization: one controlled run with the frozen artifacts (glacier-relay `main` `7d976f2`; ZHMModSDK `relay/m2` `c5152848`; accepted DLL `6047a9a3278fdd725c55bdc16ac47f832436afb2f5a6f2260488a436a6009d65`, 10,155,008 B, hash-verified before and after install; tag `research/m2-telemetry` on both repositories), the dashboard-enabled BEAM (`GLACIER_RELAY_DASHBOARD=1`, `127.0.0.1:4748`) and the operator's Windows browser. **No production code, native artifact, wire schema or dependency was changed**; nothing was fixed forward; the game was restored to M0 and hash-verified. Evidence: `%TEMP%\glacier-m0\hitmen\m3c-run1\` (79 files hashed in `sha256.txt`; native log `relay-20261013-044108-28372.log` SHA-256 `219369bd…`). Operator = the user, directed step by step in chat; no operator screenshots were produced (the operator reported what the browser showed at each gate; the browser-side artefacts are the server's socket logs and the Windows-host LiveView joins captured by `capture.ps1`).

### 12.1 Pre-flight (04:35Z–04:39Z)

Both repositories clean at the frozen commits; tags verified; accepted DLL and PDB hashes verified in `b6-accepted-artifacts\`; game at M0 (26/26 hashes, `mods.ini` `b90b4c5e…`, 107 retail files listed and hashed, no relay/hitmen/probe artefact under `mods\`); HITMAN not running; ports 4747 and 4748 free; WSL2 16 CPUs, 62 GB available. BEAM started with the in-node watcher script `m3c_watch.exs` (read-only subscribers printing every session notification and every projection publication with receipt time): wire `127.0.0.1:4747`, HTTP `127.0.0.1:4748`, application children `[MissionSession, Wire.ConnectionSupervisor, Wire.Listener, GlacierRelayWeb.Supervisor]`, web children `[PubSub, Dashboard.Projection, Endpoint]`; baseline BEAM memory 72.9 MB, 504 processes; projection snapshot r1, source `live`, empty state ("no adapter instance has delivered an event", no claim about the game); the Windows-host LiveView join (`capture.ps1 preflight`) succeeded; `172.23.229.225:4748` refused from Windows. The operator confirmed readiness ("Yes, deploy now"); the DLL was installed at 04:39:26Z (installed copy `6047a9a3…`), `mods.ini` switched to the relay variant (`a66a44ed…`), the installed listing recorded (one added file).

### 12.2 R1 — main-menu gate (04:41Z–04:44Z)

HITMAN3.exe started at 04:41:12Z; the native log shows the module attached, "Init: one detour registered (ZAchievementManagerSimple_OnEventSent, read-only); lifecycle is polled", the TCP sink connected to `127.0.0.1:4747` at 04:41:29.123Z, adapter instance `46669277-bc3d-4f66-9471-55e14a5d10ae`, main-menu scene stages 5–8. BEAM: `SESSION CONNECTION opened` at 04:41:29.1348Z, projection snapshot r2 (instances `[]`). The operator's browser LiveView socket connected (BEAM logged `CONNECTED TO Phoenix.LiveView.Socket` and the mount at 04:43:03Z, after earlier reloads at 04:36–04:42Z). **The operator reported that the browser did not update at the main menu.** This is the designed behaviour: nothing is published at the menu, and an instance is identified only by its first envelope, so the open connection stays unidentified and no instance card exists; the dashboard showed the empty state correctly. **Finding (presentation):** an open-but-unidentified connection is transport evidence the session holds in its connection map but does not expose, so the dashboard cannot show "an adapter connected, no instance yet"; the R1 criterion "a new instance card appears" is not satisfiable at the menu with the M2 adapter. Recorded for a later presentation refinement; not a defect of the run.

### 12.3 R2 — mission entry (04:46Z–04:47Z)

Paris loaded on the B6 route. Native published `contract.started #1` and `mission.playing #2` at 04:46:36.344Z and `disguise.equipped #3` (`StartingSuit`, `874c4c48…`) at 04:47:07.347Z. BEAM identified the connection at .367Z and received #1/#2 at .380Z; projection snapshot r3 (built .429Z, broadcast seen .486Z: the first recompute with an instance, cold, 56.6 ms) and r4 for #3. The report at that point: attempt 1 Peacock, contract session `2516104340…` LOCATION_PARIS difficulty 2, starting disguise `874c4c48…` hitman suit, correlated `next_rise`, start #2, stop not observed, last known playing, disposition not observed, history intact, no target outcome ("none in the stream"). **The operator reported the browser updated live** (card, attempt, event rows without a reload). Windows-host captures `r2-dashboard.html` and the live join carry the same facts; the initial disguise equals the paired session's starting disguise (B3's pattern again).

### 12.4 R3 — player-state route (04:48Z–04:49Z)

Native published `player.trespassing #4` (true, `room_id 6`) at 04:48:44.140Z, `#5` (false, `room_id 6`) at 04:48:54.077Z, `player.illegal_weapon #6` (true, the nested weapon object: ICA19 Red Trinity `fca954f6…`) at 04:49:10.172Z, `#7` (false, no object) at 04:49:18.427Z. BEAM receipts 1.2–2.3 ms after the native timestamps; snapshots r5–r8 built 50–51 ms after each receipt (one window each; warm recompute under a millisecond). The report's player-state line: "trespassing last observed false at #5 (room_id 6), 2 occurrences, 1 observed value change; illegal weapon last observed false at #7 (last named weapon ICA19 Red Trinity fca954f6… at #6), 2 occurrences, 1 observed value change [last observed, never current state]"; `room_id` printed as the engine's number; the weapon as evidence beside the occurrence; no duplicate attempt or actor record. **The operator reported the browser updated live for each step.** No unscripted combat occurred (0 died, 0 pacified); nothing was synthesised. Name-only engine events in the run: `HeroSpawn_Location`, `Level_Setup_Events` ×7, `OpportunityStageEvent` ×3, `OpportunityEvents` ×2, `AmbientChanged`, `IntroCutEnd` (all unsupported by design; `ContractFailed` captured after the attempt counters).

### 12.5 R4 — activity and outcomes

No actor, item or objective occurrence happened; the dashboard showed "target outcomes observed: none in the stream; the full status of all mission targets is not established; an absent outcome is not evidence of survival", "non-target outcomes observed: none in the stream", items 0, objectives none, and the one disguise occurrence. Nothing was invented; the M2 semantic contract is unchanged.

### 12.6 R5 — exit and quit (04:51Z–04:58Z)

Exit to the main menu: native "mission playing: true -> false" and `mission.stopped #8` at 04:51:24.263Z, attempt counters at that moment "seen 21, captured 6, unsupported 15, dont_send 0, unreadable 0, truncated 0; queue pushed 6, dropped 0; normalized 6, malformed 0, outside attempt 0, ungated published 1"; `contract.ended #9` (`ContractFailed`, "Contract ended manually: User pressed exit to Main menu", `exit_to_menu`) at 04:51:27.958Z. BEAM: r9 and r10; the report: stop #8 (the predicate fell), duration 287.9 s, disposition "exited to menu" attached from the paired session's `contract.ended #9` (after the stop), observation still live. **The operator reported the browser showed the stop**; the `r5a` capture (menu, game running) has "stopped at #", "exited to menu", "observation live (a connection is open)" and no "last known playing". Quit: HITMAN3.exe exited at 04:58:32Z; the socket closed at 04:58:26.8415Z (`:peer_closed`), projection r11 with the instance `lost`, **no new event after the close** (last session event remains #9), the attempt still stopped at #8 with its disposition. **The operator reported "observation lost, attempt unchanged"**; the `final` capture confirms it from the Windows host, and the report page remained readable.

### 12.7 Browser and BEAM equivalence at quiescence (04:59Z)

Captured: `MissionSession.state/0`, `report/0`, `report_text/0`, `summary_text/0`, `Projection.snapshot/0`, `Projection.stats/0` (the `rpc-*.txt` files), `beam-final-state.txt` and `beam-events.ndjson` from the unchanged `final_state.exs`, `/report.txt` and `/summary.txt` from WSL2 and from Windows (`curl.exe`), the dashboard and report pages, and the Windows-host live join. Results: **`/report.txt` byte-identical to `MissionSession.report_text/0`** from WSL2 and from Windows; `/summary.txt` likewise; **the projection's per-instance report maps equal `MissionSession.report/0`**; the projection's `report_text` equals the session's and equals `Summary.render_report(state, unidentified)`; the final dashboard page shows the bounded-window label with all nine rows (nine events, limit 200) and no fact that is absent from the report. The run produced no dense burst, so the window limit was not reached.

### 12.8 Timing (`timing-lines.txt`; warm and cold apart)

| # | native publication | BEAM session receipt | Δ | projection snapshot built | Δ from receipt | note |
|---|---|---|---|---|---|---|
| 1, 2 | 04:46:36.344 | .380 | 36 ms | r3 .429 (broadcast seen .486) | 49 ms + 56.6 ms recompute | cold: first recompute with an instance; the receipt Δ includes the socket's identification on its first envelope |
| 3 | 04:47:07.347 | .3616 | 15 ms | r4 .4128 | 51 ms | warm |
| 4 | 04:48:44.140 | .1418 | 1.8 ms | r5 .1929 | 51 ms | warm, recompute under 1 ms |
| 5 | 04:48:54.077 | .0793 | 2.3 ms | r6 .1299 | 51 ms | |
| 6 | 04:49:10.172 | .1732 | 1.2 ms | r7 .2238 | 51 ms | |
| 7 | 04:49:18.427 | .4293 | 2.3 ms | r8 .4799 | 51 ms | |
| 8 | 04:51:24.263 | .2646 | 1.6 ms | r9 .3158 | 51 ms | |
| 9 | 04:51:27.958 | .9609 | 2.9 ms | r10 .0118 | 51 ms | |
| close | 04:58:26.8415 (BEAM) | — | — | r11 .8928 | 51 ms | transport only |

Stats at the end: 11 recomputes, 11 snapshots, 9 events, 3 transport notices, session read max 140 µs (total 915 µs), recompute max 56.6 ms (cold r3), last 336 µs; BEAM memory 72.9 → 77.9 MB, processes 504 → 506; 11 LiveView socket connections over the run (the operator's browser and its reloads, plus six host-side captures); 0 browser disconnect events logged by BEAM. Every event sat in its own 50 ms window: the run never produced a burst denser than the window (events 8–96 s apart), so **coalescing of real bursts was not exercised live** (offline-covered in section 11). Browser update latency was **not measured**: instrumenting it needs production code; the operator observed updates "live" at each gate and the host-side joins returned within about 2 s, dominated by the .NET client's connect (2.04–2.11 s). As recorded in section 11, the projection rebuilds the whole `report_text` on every snapshot; with one instance that is the same cost as the instance's report.

### 12.9 Native and BEAM reconciliation (the M2 procedure)

`compare.py`: native published 9, BEAM reconstructed 9, sequences 1–9 on both sides, **0 field mismatches**, every sequence on attempt 1, one adapter instance. Counters: seen 21 = captured 6 + unsupported 15; captured 6 = normalized 6 (malformed 0); normalized 6 = 5 attempt-gated published (#3–#7) + 1 ungated published (#1); published 9 (telemetry 6 + lifecycle edges 2 + `contract.ended` after the counters line) = received 9; gaps none; BEAM rejected 0, warnings 0, errors 0; queue dropped 0, truncated 0, unreadable 0; native WARN 0, ERROR 0, FAULT 0 (78 INFO lines). Prior vocabulary behaved as accepted: contract pairing by `next_rise`, the initial disguise equal to the starting disguise, the exit disposition from the engine's reason after the stop, player state as in §48.

### 12.10 Operational isolation

Exactly one detour (the log's Init line; no other hook line); no native write path exists in the frozen DLL; no inbound game command path; both listeners bound to `127.0.0.1` only (`ss`), the WSL2 external address refused from Windows; the web subtree's three documented processes only (web children `[PubSub, Projection, Endpoint]`; the application's four top-level children); process count 504 → 506 over the run (LiveView sessions). Dashboard interaction during the run was limited to the operator's page and the host-side joins; no Relay event or evidence change originated from the web (session events: 9, all from the wire; the boundary itself is established by the M3-B tests, not claimed proven by the run). The operator reported no gameplay instability; the game loaded, played and quit normally.

### 12.11 Cleanup (05:00Z)

`run-cleanup.sh`: BEAM stopped by RPC (`init.stop`; the launcher had exited), watcher exited, `GlacierRelay.dll` removed, `mods.ini` restored byte-identically (`b90b4c5e…`), retail listing identical (107 files), hashes identical, **M0 26/26**, no relay/hitmen/probe artefact under `mods\`; both ports free; no `beam.smp` left; epmd name released. Evidence hashed (79 files).

### 12.12 Verdicts (independently supported)

| | Criterion | Verdict | Basis |
|---|---|---|---|
| A | Windows browser LiveView connectivity during HITMAN | **PASS** | BEAM logged the browser's socket connects and mounts while the game ran; the operator confirmed live updates at R2, R3, R5a, R5b; six host-side LiveView joins succeeded during the run |
| B | Transport connectivity and mission state separated | **PASS** | R5a: stopped at #8 with observation live; R5b: observation lost with the attempt unchanged and no new event; "last known playing" absent after the stop |
| C | Live updates of overview and player-state activity | **PASS** (operator-observed) | the watcher's projection lines and the r2/r3 captures; the operator reported each step updating live |
| D | Snapshot agreement with authoritative BEAM state | **PASS** | per-instance report maps `==` `MissionSession.report/0`; `report_text` equal; captured at quiescence |
| E | Byte-identical `/report.txt` at quiescence | **PASS** | WSL2 and Windows `curl` both byte-identical to `report_text/0`; `/summary.txt` likewise |
| F | Bounded event feed without invented or lost evidence | **PASS** | nine rows for nine events under a visible 200-row label; the report holds all nine; nothing synthesised in R4 |
| G | Projection behaviour during real bursts and measured latencies | **PARTIAL** | latencies measured (read ≤ 140 µs, warm recompute ≤ 1 ms, cold 56.6 ms, one window per event); **no dense burst occurred, so live coalescing is unverified**; browser update latency not measured |
| H | Native/BEAM reconciliation and prior semantic regression | **PASS** | 9/9, 0 mismatches, counters reconciled, 0 drops/rejections/gaps/warnings/faults; prior vocabulary as accepted |
| I | Read-only isolation and game stability | **PASS** for what a run can show | one detour, loopback binds, documented processes only, no web-originated evidence, normal load/play/quit, no instability reported |
| J | Mechanical rollback and M0 verification | **PASS** | DLL removed, `mods.ini` identical, 107 files identical, 26/26 |

Unverified or not produced, stated plainly: live coalescing under a dense burst (G); precise browser update latency (G); operator screenshots (none were taken; the operator's statements and the host-side captures stand in); an open-but-unidentified connection is not visible in the dashboard (12.2 finding); the bounded window's limit was never reached live.

### 12.13 Recommendation

The M3 exit criterion as agreed — *a browser on the Windows host displays a live HITMAN mission attempt and its Relay event stream from OTP-owned state, with transport connectivity and mission lifecycle shown separately* — was demonstrated on this run for one attempt on the B6 route. Recommend **accepting M3 and closing it with these limitations stated**: live coalescing under dense bursts is offline-evidence only; browser update latency is unmeasured; the dashboard does not show an open connection before its first envelope; no screenshots exist for this run. Post-M3 presentation refinements to carry forward, none reopening M3: expose open unidentified connections as transport evidence; split the `:engine` tag into observed/authored (M2 section 52.6); label replay sources when a playback tool exists. The native adapter stays at the M2 checkpoint. **M3 is not closed by this record.**

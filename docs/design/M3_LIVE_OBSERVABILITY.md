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

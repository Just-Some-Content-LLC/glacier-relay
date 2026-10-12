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

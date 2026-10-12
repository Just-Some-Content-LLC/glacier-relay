# ADR 0007 — Live observability is a read-only projection of OTP-owned mission state

**Status:** Accepted (2026-10-12; proposed the same day with the M3 design, `docs/design/M3_LIVE_OBSERVABILITY.md`), with two refinements recorded under *Refinements at acceptance*. Scope: **M3 — Live observability only.** Nothing here authorizes a command channel (M5), persistence (M4) or any change to the native adapter or the wire.

## Architectural rule

`MissionSession` and the existing pure semantic model own mission evidence and derived state. Phoenix is a read-only consumer. No controller or LiveView may call the session's evidence-delivery functions (`handle_event/2`, `connection_opened/2`, `connection_closed/2`), cast to it, or reach the wire.

## Refinements at acceptance

1. **The projection is the normal reader.** The M3-B `GlacierRelay.Dashboard.Projection` will be the normal web-side reader of `MissionSession` and the publisher of read-model snapshots (revisions over `Phoenix.PubSub`). Its subscription semantics are recorded in the M3 design, section 8: a session notification is a change signal, not an authoritative snapshot; the projection subscribes, then reads the current state, coalesces later notifications, rebuilds presentation snapshots from session-owned state, and publishes revisions. The session's notification ordering is not changed for this.
2. **Stage-limited exception (M3-A).** Until the projection exists, the two diagnostic text routes (`GET /report.txt`, `GET /summary.txt`) call the existing read-only presentation API of `MissionSession` directly (`report_text/0`, `summary_text/0`). These are on-demand reads of OTP-owned state, outside the event path. M3-B decides whether they migrate to projection-owned cached data or remain as explicitly justified on-demand diagnostic reads; either way the boundary test keeps every other session function out of the web namespace.

## Context

M2 closed with an OTP-owned semantic model (`Lifecycle.Instance` per adapter instance, held by `MissionSession`) and a pure mission report over it (`Report.report/1`, M2 section 51) in which every fact carries its provenance and the standing limitations are printed. The roadmap's M3 line is "Phoenix/LiveView dashboard for current mission state and event stream". `ARCHITECTURE.md` placed a `WebEndpoint` under the application supervisor as a hypothesis and named the LiveView console as one consumer of OTP-owned state.

The BEAM application today has no dependencies, one GenServer where evidence lands, a `send`-based subscription that carries raw envelopes and transport notices, and synchronous read calls whose derivations run inside the session process. Windows reaches WSL2 loopback listeners through localhost forwarding (proven for the wire port).

## Decision

1. **The dashboard is a projection, not a model.** The data shown is `Report.report/1` (and the instance-level facts) exactly as the pure functions produce it. No module in the web layer interprets a Glacier or Relay event, derives a status, counts actors, or writes a fact of its own; components lay out report sub-maps unchanged and print the tag each carries.
2. **One application, one reader.** Phoenix and LiveView are added as libraries inside `:glacier_relay`, in separate namespaces (`GlacierRelayWeb`, `GlacierRelay.Dashboard`), under one web supervisor placed last in the existing tree and enabled by configuration. One process, the projection, is the only web-side subscriber of `MissionSession` and the only web-side caller of its read API, coalescing updates and fanning out over `Phoenix.PubSub`. LiveView processes never call the session.
3. **Ingestion is never blocked by observation.** The event path gains one `send`; derivation for the web runs in the projection; the session's read API is called at most once per coalescing window by that single process.
4. **Transport status and mission status are shown separately and never derived from each other**, as the model already keeps them (M2 section 2).
5. **No path from the browser to the wire.** The endpoint binds to loopback, serves no API and accepts no uploads; the web and dashboard namespaces may not reference `Wire.*`, sockets, or the session's evidence-delivering functions, and a test enforces it. `handle_event/3` clauses change viewer choices only.
6. **Replay is labelled.** An instance fed from a fixture is shown as `replay`, so "observation never" under replay reads as "no connection evidence in this replay" (M2 section 52.6).

## Consequences

- M3 can be built and tested entirely from the committed fixtures and the real listener; a live run validates only the forwarding of the new port, timing against a real connection, and burst behaviour.
- The Phoenix dependency set enters the core project; the headless configuration keeps the runtime tree identical to M1's, and every M2 test stays as it is.
- Optimisations that touch `MissionSession` (an ETS read copy; an atomic subscribe-with-state; a `name:` option) are deferred until measured.
- A later non-loopback bind, authentication, persistence or any command path is a new decision, not an extension of this one.

## Alternatives rejected

- **LiveViews subscribing to `MissionSession` directly and calling `report/0` per event**: puts a report fold on the ingestion process per browser tab per event; simplest, but wrong-shaped from the start.
- **A separate OTP application or umbrella**: needs a node boundary or an umbrella for a property ("the web never writes") that placement and a boundary test already give; the README rules out distributed Erlang.
- **A dashboard that re-folds envelopes itself**: duplicates the model, can diverge in transport evidence, and reopens interpretation outside the pure modules.
- **Node/esbuild asset pipeline**: unnecessary for a loopback operator view; the prebuilt LiveView client in the dependencies is served statically.

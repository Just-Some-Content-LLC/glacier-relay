# Roadmap

## M0 — Research baseline
**Goal:** reproducible builds and documented assumptions.

Exit:
- Current WOA version recorded.
- Organization ZHMModSDK fork builds.
- Existing Hitmen experiment documented.
- Adapter development workflow documented.

Kill/re-scope trigger: upstream tooling cannot operate against the current game version.

## M1 — First semantic event
**Goal:** Glacier -> native adapter -> wire -> BEAM.

Exit: a running WOA mission causes one versioned semantic event to be received and validated by Elixir.

## M2 — Telemetry
Capture a bounded useful vocabulary: mission lifecycle, player state, kills/pacifications, disguises, items and objectives.

Exit: mission summary generated from events rather than manual state inspection.

## M3 — Live observability
Phoenix/LiveView dashboard for current mission state and event stream.

## M4 — Mission recorder
Persist event streams, derive statistics, timelines and eventually spatial analysis/heat maps.

## M5 — Command channel
BEAM -> adapter -> Glacier.

Exit: one safe, reversible semantic command changes observable game state.

## M6 — Second Hitman
Reproduce and stabilize the upstream experimental `Hitmen` second-player entity on the current game.

Exit: one game instance contains a controllable local player and a distinct externally driven Hitman representation.

## M7 — Network ghost
Two PCs, same mission. Each instance renders the other player's externally driven Hitman.

Exit: bidirectional movement/input representation survives a bounded test session.

## M8 — Shared-world slice
Synchronize a deliberately small set of semantic facts: selected doors, one NPC lifecycle, one item lifecycle, and objective state.

Exit: both clients converge after scripted interactions.

## M9 — Constrained co-op
Complete one selected mission under documented restrictions.

Exit criteria must include desync instrumentation and a repeatable test scenario.

## Beyond M9
Only after measurement: broader actor authority, inventories, combat/projectiles, ragdolls, disguise/enforcer semantics, mission scripting, reconnect/snapshots, Freelancer research, matchmaking, plugins, public hosting.

No date commitments are attached to research milestones.

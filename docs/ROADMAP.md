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

**Status: ✅ COMPLETE (2026-10-06).** Met three times in one controlled run: HITMAN 3.280.0.0 emitted `mission.playing` (envelope v1, schema v1) on the Paris load, a Paris restart and the Sapienza load; each crossed TCP loopback from Windows into the WSL2 BEAM and was validated into `MissionSession` state (sequences 1, 2, 3, no gaps, no drops, no faults). Evidence and design: `docs/design/M1_FIRST_SEMANTIC_EVENT.md` (sections 13 to 15, commit `3bb397e`); ADR 0005. Code: ZHMModSDK `relay/m1` `a28840e6` and `relay/` at this commit. The exit criterion above is recorded as originally written. Tag: `research/m1-first-semantic-event`.

## M2 — Telemetry
Capture a bounded useful vocabulary: mission lifecycle, player state, kills/pacifications, disguises, items and objectives.

Exit: mission summary generated from events rather than manual state inspection.

**Status: in progress.** Stage A (bounded mission lifecycle: `mission.stopped`, attempts derived from events, connection evidence kept separate, first event-derived summary) passed its runtime experiment on 2026-10-06 (five events, two bounded attempts, one last-known-playing attempt whose process quit from inside the mission; `docs/design/M2_TELEMETRY.md` section 13). Stage A alone does not complete M2. B0 (2026-10-07) established Glacier's own telemetry stream as the preferred M2 surface (ADR 0006); B1 (telemetry normalization + `actor.died`/`actor.pacified`) passed its controlled runtime experiment on 2026-10-07 and is accepted (16 envelopes, 12 engine-authored actor outcomes → 12 Relay events, 0 field mismatches, two attempts correctly bounded; `M2_TELEMETRY.md` section 26); the normalization boundary is validated as the M2 production path. B2 (contract lifecycle: `contract.started`/`contract.ended`, BEAM correlation of contract sessions to attempts by stream order, attempt disposition from engine reasons) passed its controlled runtime experiment on 2026-10-08 and is accepted (10 envelopes, 3 contract sessions correlated to 3 attempts by both ordering rules, 0 field mismatches, 0 anomalies, dispositions from contract evidence only, direct quit left explicitly unobserved; section 29). B3 (disguises: `disguise.equipped`/`disguise.compromised`/`disguise.compromise_cleared`, BEAM derived view with explicit unknowns) is implemented and validated without the game (section 31); its controlled runtime experiment on 2026-10-08 passed as a pipeline (30 envelopes, 0 mismatches, B1/B2 rows intact) but **did not validate the disguise vocabulary**: all nine engine disguise occurrences were rejected as malformed because their `Value` is not a `ZString` on the engine side (section 32). B3 is not accepted; the next step is a bounded intake change under its own review. Validated vocabulary so far: mission lifecycle, kills/pacifications, contract lifecycle; disguises, items, objectives and player state remain, and the exit criterion above is not met. Design and records: `docs/design/M2_TELEMETRY.md`. Code: ZHMModSDK `relay/m2` `9f746cad`, `relay/` here.

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

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

**Status: in progress.** Stage A (bounded mission lifecycle: `mission.stopped`, attempts derived from events, connection evidence kept separate, first event-derived summary) passed its runtime experiment on 2026-10-06 (five events, two bounded attempts, one last-known-playing attempt whose process quit from inside the mission; `docs/design/M2_TELEMETRY.md` section 13). Stage A alone does not complete M2. B0 (2026-10-07) established Glacier's own telemetry stream as the preferred M2 surface (ADR 0006); B1 (telemetry normalization + `actor.died`/`actor.pacified`) passed its controlled runtime experiment on 2026-10-07 and is accepted (16 envelopes, 12 engine-authored actor outcomes → 12 Relay events, 0 field mismatches, two attempts correctly bounded; `M2_TELEMETRY.md` section 26); the normalization boundary is validated as the M2 production path. B2 (contract lifecycle: `contract.started`/`contract.ended`, BEAM correlation of contract sessions to attempts by stream order, attempt disposition from engine reasons) passed its controlled runtime experiment on 2026-10-08 and is accepted (10 envelopes, 3 contract sessions correlated to 3 attempts by both ordering rules, 0 field mismatches, 0 anomalies, dispositions from contract evidence only, direct quit left explicitly unobserved; section 29). B3 (disguises: `disguise.equipped`/`disguise.compromised`/`disguise.compromise_cleared`, ids only, BEAM derived view with explicit unknowns) was implemented and validated without the game (section 31); its first controlled run on 2026-10-08 passed as a pipeline but did not validate the vocabulary — every engine disguise `Value` was rejected as not a string (section 32); the type-discovery experiment of 2026-10-09 read the engine type as `ZRepositoryID` (section 34); the intake correction (one exact-name branch rendering the 16-byte id through an engine-independent formatter, section 35) was gate-validated and its controlled run on 2026-10-09 passed its five criteria (9 envelopes, 0 mismatches, all four names across the typed intake, the initial outfit equal to the paired contract's starting disguise, derived view per the fold contract; section 36). **B3 is accepted for its bounded scope on the observed build** — ids-only occurrences, the corrected conversion, the conservative fold; five live occurrences across two outfit definitions; no persistence, witness-clearing or engine-state claim (section 37). Validated vocabulary so far: mission lifecycle, kills/pacifications, contract lifecycle, disguises. B4 (items: `item.picked_up`/`item.thrown`/`item.removed_from_inventory` v1, independent definition-based occurrences, direct counts per definition, no pairing, the shared bounded-history model) was designed (section 38), implemented and gate-validated without the game (section 39), ran its controlled experiment on 2026-10-09 (section 40: 11 live occurrences over five definitions, 16/16 envelopes, 0 mismatches, 0 losses) and **is accepted for its bounded scope on the observed build (section 41)**; it establishes no instance identity, inventory state, recovery of the same object or removal/throw rule, and `ItemDropped`/`ItemDestroyed` stay unsupported. B5 (objectives: `objective.completed` v1, ungated publication with BEAM attribution fixed at receipt, display grouping without objective state) was designed (section 42), implemented and gate-validated without the game (section 43), ran its controlled completion experiment on 2026-10-09 (section 44: 45 envelopes, 0 mismatches, two `ObjectiveCompleted` across the typed intake with payloads intact; on that route the completion transition was names only — `exit_gate`, `ExitInventory`, `ContractEnd` — and the predicate fell only on return to the main menu) and **is accepted for its bounded objective-occurrence scope on the observed build (section 45)**; it establishes no objective-state completeness or mission completion, and `ContractEnd` remains a name only (B2 follow-up). B6 (player state) has its archaeology and design in section 46 (awaiting review; `Hero_Health`/`Hero_Dead` payloads unknown, a death run never performed); summary v2 and the completion decision follow, and the exit criterion above is not met. Design and records: `docs/design/M2_TELEMETRY.md`. Code: ZHMModSDK `relay/m2` `97946eb1` (accepted B5 checkpoint; B4 `12ea5586`, B3 `84b93778`), `relay/` here.

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

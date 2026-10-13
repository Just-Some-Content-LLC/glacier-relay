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

**Status: ✅ COMPLETE (2026-10-12).** Both sentences above are recorded as originally written. The goal is satisfied on HITMAN WOA 3.280.0.0 (Steam build 24833614, ZHMModSDK 4.1.1) by the accepted stages: mission lifecycle (Stage A, `mission.playing`/`mission.stopped`, section 13), kills/pacifications (B1, `actor.died`/`actor.pacified`, section 26), disguises (B3, three `disguise.*` events, section 37), items (B4, three `item.*` events, section 41), objectives (B5, `objective.completed`, section 45) and player state (B6, `player.trespassing`/`player.illegal_weapon`, section 49), with contract lifecycle (B2, `contract.started`/`contract.ended`, section 29) added beside the goal's list; every event is a bounded, versioned, engine-independent Relay schema normalized from one engine-authored stream (ADR 0006), and each stage's vocabulary crossed the typed native intake in its own controlled run with field-for-field native/BEAM agreement. The exit criterion is satisfied by the event-derived summary that has existed since Stage A (`GlacierRelay.Summary`, pure over `Lifecycle.Instance`; every run's `beam-final-state.txt` is that summary) and by the **final milestone deliverable, the B7 mission report** (`Summary.report/1` / `render_report/2`, section 51): a mission overview, named target and non-target outcomes with the engine's own classification, the disguise, item, objective and player-state views, a sequence-ordered timeline with both clocks, and one uncertainty list, every fact tagged with its provenance, generated from the stored events alone; the verbatim report over the section 48 run is in section 51, and nothing in producing it inspects game memory or state. Code: glacier-relay `relay/` BEAM `d68d7fb` (B7) on `802b5fe` (B6); ZHMModSDK `relay/m2` `c5152848` (accepted B6 native adapter; clean DLL SHA-256 `6047a9a3278fdd725c55bdc16ac47f832436afb2f5a6f2260488a436a6009d65`, preserved with PDB, tests, probe and gate files). Tests: 25/25 native, 259 Elixir ×5 with warnings as errors, standalone wire probe 22/22 with 0 mismatches, ten legacy summaries byte-identical. Evidence: `%TEMP%\glacier-m0\hitmen\` run directories `m2-run1`, `b0-run1`, `b1-run1` … `b6-run1` and the accepted-artifact directories. **Scope of the success: the documented engine build and the observed event vocabulary on the observed routes (Paris and Sapienza, menu/exit/restart/quit routes), not every HITMAN mode, location, route or engine build.** It does not establish mission completion or failure, player death, ratings, kill attribution, unique actor identity, inventory state, current disguise or player state, objective completeness, spatial telemetry or multiplayer authority (section 52 lists the limitations and the research candidates). Record: `docs/design/M2_TELEMETRY.md` section 52. Tag: `research/m2-telemetry` on both repositories.

**History.** Stage A (bounded mission lifecycle: `mission.stopped`, attempts derived from events, connection evidence kept separate, first event-derived summary) passed its runtime experiment on 2026-10-06 (five events, two bounded attempts, one last-known-playing attempt whose process quit from inside the mission; `docs/design/M2_TELEMETRY.md` section 13). Stage A alone does not complete M2. B0 (2026-10-07) established Glacier's own telemetry stream as the preferred M2 surface (ADR 0006); B1 (telemetry normalization + `actor.died`/`actor.pacified`) passed its controlled runtime experiment on 2026-10-07 and is accepted (16 envelopes, 12 engine-authored actor outcomes → 12 Relay events, 0 field mismatches, two attempts correctly bounded; `M2_TELEMETRY.md` section 26); the normalization boundary is validated as the M2 production path. B2 (contract lifecycle: `contract.started`/`contract.ended`, BEAM correlation of contract sessions to attempts by stream order, attempt disposition from engine reasons) passed its controlled runtime experiment on 2026-10-08 and is accepted (10 envelopes, 3 contract sessions correlated to 3 attempts by both ordering rules, 0 field mismatches, 0 anomalies, dispositions from contract evidence only, direct quit left explicitly unobserved; section 29). B3 (disguises: `disguise.equipped`/`disguise.compromised`/`disguise.compromise_cleared`, ids only, BEAM derived view with explicit unknowns) was implemented and validated without the game (section 31); its first controlled run on 2026-10-08 passed as a pipeline but did not validate the vocabulary — every engine disguise `Value` was rejected as not a string (section 32); the type-discovery experiment of 2026-10-09 read the engine type as `ZRepositoryID` (section 34); the intake correction (one exact-name branch rendering the 16-byte id through an engine-independent formatter, section 35) was gate-validated and its controlled run on 2026-10-09 passed its five criteria (9 envelopes, 0 mismatches, all four names across the typed intake, the initial outfit equal to the paired contract's starting disguise, derived view per the fold contract; section 36). **B3 is accepted for its bounded scope on the observed build** — ids-only occurrences, the corrected conversion, the conservative fold; five live occurrences across two outfit definitions; no persistence, witness-clearing or engine-state claim (section 37). Validated vocabulary so far: mission lifecycle, kills/pacifications, contract lifecycle, disguises. B4 (items: `item.picked_up`/`item.thrown`/`item.removed_from_inventory` v1, independent definition-based occurrences, direct counts per definition, no pairing, the shared bounded-history model) was designed (section 38), implemented and gate-validated without the game (section 39), ran its controlled experiment on 2026-10-09 (section 40: 11 live occurrences over five definitions, 16/16 envelopes, 0 mismatches, 0 losses) and **is accepted for its bounded scope on the observed build (section 41)**; it establishes no instance identity, inventory state, recovery of the same object or removal/throw rule, and `ItemDropped`/`ItemDestroyed` stay unsupported. B5 (objectives: `objective.completed` v1, ungated publication with BEAM attribution fixed at receipt, display grouping without objective state) was designed (section 42), implemented and gate-validated without the game (section 43), ran its controlled completion experiment on 2026-10-09 (section 44: 45 envelopes, 0 mismatches, two `ObjectiveCompleted` across the typed intake with payloads intact; on that route the completion transition was names only — `exit_gate`, `ExitInventory`, `ContractEnd` — and the predicate fell only on return to the main menu) and **is accepted for its bounded objective-occurrence scope on the observed build (section 45)**; it establishes no objective-state completeness or mission completion, and `ContractEnd` remains a name only (B2 follow-up). B6 (player state: `player.trespassing`/`player.illegal_weapon` v1, attempt-gated occurrences, BEAM last-observed reading per subject with explicit unknowns, never a current-state claim) was designed (section 46, approved 2026-10-12 with refinements), implemented and gate-validated without the game on 2026-10-12 (section 47: clean build, 25/25 native, 222 Elixir ×5, standalone wire 22/22 with 0 mismatches), and ran its first controlled experiment the same day (section 48: 16 envelopes, 0 mismatches, both names in both boolean forms across the typed intake, the nested weapon object intact, 0 malformed/drops/gaps); **accepted for its bounded two-event scope on the observed build (section 49)**; it establishes no current player state, safety, possession, inventory, health or death; `Hero_Health`/`Hero_Dead` remain research candidates (payloads unknown, a death run never performed, a separate authorization). B7 summary v2 is designed (section 50) and implemented and validated offline (section 51: `Summary.report/1` / `render_report/2`, an additive BEAM-only presentation over the existing records — mission overview, named-target view, sequence-ordered timeline with both clocks and per-session clock domains, one uncertainty list, four provenance tags; 259 tests ×5; legacy summaries byte-identical; no native or wire change). Section 50 assessed the goal as achieved and the exit criterion as met in substance and recommended closing M2 after B7 with the limitations stated; B7 passed architectural review on 2026-10-12 and M2 was closed (section 52). Design and records: `docs/design/M2_TELEMETRY.md`. Code: ZHMModSDK `relay/m2` `c5152848` (accepted B6 checkpoint; B5 `97946eb1`, B4 `12ea5586`, B3 `84b93778`), `relay/` here.

## M3 — Live observability
Phoenix/LiveView dashboard for current mission state and event stream.

Exit (agreed 2026-10-12): a browser on the Windows host displays a live HITMAN mission attempt and its Relay event stream from OTP-owned state, with transport connectivity and mission lifecycle shown separately.

**Status: in progress.** Design and ADR 0007 accepted 2026-10-12 (`docs/design/M3_LIVE_OBSERVABILITY.md`). M3-A (Phoenix web foundation) implemented and validated offline the same day (design section 10): Phoenix 1.8.15 / LiveView 1.2.12 / Bandit 1.12.5 inside the existing `relay/` application, an optional web supervisor behind configuration (headless tree identical to M2's three children), a loopback-only endpoint on `127.0.0.1:4748` serving `GET /report.txt` and `GET /summary.txt` from the existing read-only presentations, boundary and headless-invariance tests, 279 Elixir tests ×5; standalone Windows-to-WSL2 HTTP connectivity verified. M3-B (design section 11, 2026-10-13): the read-only `Dashboard.Projection` (the single web-side subscriber of `MissionSession`; subscribe, read, build, publish; 50 ms coalescing; monotonic revisions), the LiveView dashboard at `/` and the report page at `/report` rendering the B7 report data unchanged with its provenance tags, transport and mission status shown separately, a bounded recent-event pane, prebuilt client assets from the dependencies, fixture-driven tests through the real listener (311 Elixir tests ×5), and offline validation including a real LiveView join over WebSocket from the Windows host. M3-C (one controlled live experiment with the unchanged accepted DLL and a browser) needs its own authorization; the exit criterion is not yet demonstrated live. The native adapter is unchanged at the M2 checkpoint.

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

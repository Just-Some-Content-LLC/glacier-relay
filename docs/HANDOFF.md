# Handoff checkpoint

Updated: 2026-10-09, after the B3 acceptance review (M2 design section 37, accepted) and the revised B4 item-telemetry archaeology/design (section 38, awaiting design review). This is the compact state for a fresh context; the records it points to are authoritative. Every "current" ref must be re-verified before use. All times UTC.

## Refs and artifacts

| What | Where | Ref / hash |
|---|---|---|
| Docs and BEAM (`relay/`) | glacier-relay `main` | the commit that updates this file (verify `git log -1`); §36 runtime record **`c1653e4`**, §34 record `1bfcb5e`; contains BEAM correction `63184c4`, B3 runtime record `b94b627`, diagnostic prep `2145594`. BEAM code unchanged since `63184c4` |
| Native adapter (**accepted B3 checkpoint, §37**) | ZHMModSDK `relay/m2` | **`84b93778f58c136a36382df6bc08d60a99d6650b`** (section 35 intake correction; ran in section 36) on top of `4a616cf9` (B3 diagnostic; ran in section 34) and `e9001ee4` (B3 implementation; ran in section 32) |
| Clean DLL at `84b93778` (accepted checkpoint; ran in section 36; hashed in the build tree and on the installed copy; **preserve a copy before any rebuild**) | `ZHMModSDK/_build/relay-x64-Debug/Mods/GlacierRelay/GlacierRelay.dll` | SHA-256 `61fe553859667c22145cbfd353e8a3a7717384e056dfa78beee6120cf494bdbc` (10,069,504 bytes); probe `cd13ef10…` |
| Clean DLL at `4a616cf9` (ran in the type-discovery experiment, section 34) | preserved with PDB, probe and tests in `%TEMP%\glacier-m0\hitmen\b3diag-artifacts\` (`sha256.txt`) | SHA-256 `ac6b784ae18299c4d4724c3129525c9fe8ed5113886c946c0f154d28258a4a4e` |
| Clean DLL at `e9001ee4` (ran in B3) | rebuilt only from that commit; no copy kept | `c045f92a813ef70d5b92fe8f06d38c999af41fda7cc9c7552044117d0043ef1b` |
| Clean DLL at `9f746cad` (ran in B2) | — | `0e10e2839c568ae86cb74cdef5fca78445b9c909405ea20da62b3876ea730e30` |
| M0 anchors | glacier-relay tag `research/m0-baseline` `2d67579`; SDK baseline `5cc7f1b1` (untagged) | 26 M0 hashes: `%TEMP%\glacier-m0\installed-sha256.txt` |
| M1 | tag `research/m1-first-semantic-event` on both repos; SDK `relay/m1` `a28840e6` | |
| Frozen research | SDK `research/hitmen-revival` `7ab0eceb`; `research/actor-probe-b0` `ebaa0eb4` | |
| Game | HITMAN WOA 3.280.0.0, Steam 24833614, SDK 4.1.1, mods Editor/FreeCam/SkipIntro/NoPause | `mods.ini` at M0 = `b90b4c5e…`; relay variant = `a66a44ed…` |
| BEAM toolchain | WSL, OTP 28.4.2 / Elixir 1.19.6 via `~/.local/opt/beam-env.sh` | listener 127.0.0.1:4747 |

Game state at this checkpoint: restored to M0 and hash-verified after the section 36 run (2026-10-09 01:17Z); no Relay DLL installed.

## Accepted milestones

- M0 complete; Hitmen archaeology frozen; M1 complete (`M1_FIRST_SEMANTIC_EVENT.md` §13–15).
- M2 Stage A (mission attempts, observation loss) — runtime-validated (`M2_TELEMETRY.md` §13).
- M2 B0 — research probe; B1 — `actor.died`/`actor.pacified` v1 validated (§26); B2 — `contract.started`/`contract.ended` v1 and BEAM correlation validated (§29); **B3 — `disguise.equipped`/`disguise.compromised`/`disguise.compromise_cleared` v1, ids only, with the `ZRepositoryID` intake conversion and the conservative fold — accepted for its bounded scope on build 3.280.0.0 (§37; evidence §36: five live occurrences, two outfit definitions; no persistence, witness-clearing or engine-state claim).**
- ADR 0006 accepted (M2 scope only).

## B3 (disguise): history of the three runs (records preserved; accepted in §37)

- Design §30 (fold contract §30.8); implementation §31 (SDK `ddc9987f`, `0a62c03c`, `e9001ee4`; BEAM `b04ff57`, `e7620e7`, `5c4d332`, review fix `63184c4`); 128 Elixir tests; wire 22/22.
- Runtime §32 (2026-10-08 22:46–23:35Z, evidence `%TEMP%\glacier-m0\hitmen\b3-run1\`, native log `ce60de92…`): pipeline PASS (30 envelopes, 0 mismatches, B1/B2 rows intact, 0 ERROR/FAULT) but **all nine disguise occurrences rejected: `Value is not a string`**. Zero `disguise.*` events ever crossed the wire from the game.
- **Confirmed at runtime (section 34, 2026-10-09, SDK `4a616cf9`, DLL `ac6b784a…`, evidence `b3diag-run1\`):** the copied `Value` of all four names is `Kind::Unsupported` with engine type name **`ZRepositoryID`** (6/6 samples; one `StartingSuit`, two `Disguise`, two `DisguiseBlown`, one `BrokenDisguiseCleared`). The earlier "not a `ZString`, kind unknown, type a hypothesis" qualification is superseded by this measurement. Its two open points — that the 16 bytes rendered dashed equal the B0 corpus ids, and the field/byte-order question — were closed by §35 (field-semantic rendering, tested from the byte image) and §36 (5/5 live ids equal to the corpus strings).
- Event-name chronology from the **§32** run (ids unknown): a `BrokenDisguiseCleared` co-occurred with a `Disguise` at an outfit change; re-equipping the compromised outfit emitted only `Disguise` (HUD: compromised — operator observation); witness kills afterwards emitted no clear (HUD later: not compromised). No persistence or causation conclusion is drawn.

## The fixture/intake coverage gap (corrected statement)

The B0 corpus was captured with the engine's `ZDynamicObject_ToString` (JSON), so the original fixtures and normalizer tests were JSON-level while the production intake is type-level (`TelemetryIntake::Copy`: `ZString`, bool, numbers, objects, arrays, and since §35 `ZRepositoryID`; anything else `Unsupported` with the type name; empty/null/void → `Null`). The earlier blanket claim "no test can exercise the engine-type dimension without the engine" was too broad. Precisely: the **conversion** from the engine's 16-byte `ZRepositoryID` image to the dashed id is engine-independent (`Src/RepositoryId.*`) and is tested offline from the byte image (`Tests/RepositoryIdTests.cpp`, `Tests/Fixtures/B0DisguiseBytes.h`), as is everything downstream of it; the SDK's declaration of the type is pinned by `static_assert`. What still needs the engine is only (1) that the runtime value behind `GetData()` has the SDK-declared layout, (2) that the engine's JSON writer renders the same field semantics (Relay's text == the B0 id for the same outfit), and (3) that `GetData()` points at the inline 16-byte value as it does for `ZString`. A *new* vocabulary's `Value` type is still confirmed only by a production run (the §33 diagnostic reports it); a *known* type's conversion no longer is.

## B3 intake correction (§35) and its runtime experiment (§36) — accepted (§37)

- §35 (SDK `84b93778`, docs `b84a1ce`): exact `ZRepositoryID` branch in `TelemetryIntake::Copy` → `Kind::String` via the engine-independent `RepositoryId` (fields copied by name; no `ZGuid`, no `ToString`); byte-image fixture and known-answer tests; gate green (clean build, 25/25, Elixir 128 ×5, imports identical, wire 22/22 with byte-built ids == fixture). Clean DLL `61fe5538…`.
- **§36 run (2026-10-09 01:05–01:17Z, evidence `%TEMP%\glacier-m0\hitmen\b3fix-run1\`, native log `56b319c8…`): PASS on its five criteria.** 9 envelopes, 0 mismatches, `malformed 0`, `dropped 0`, `outside attempt 0`, 0 WARN/ERROR/FAULT. `StartingSuit` → `disguise.equipped #3` `initial` `874c4c48…` **== the live paired `contract.started` starting disguise**; `Disguise` → #4 `2018db77…` (locker); `DisguiseBlown` → #5 `2018db77…`; change back to the suit → `Disguise` #6 `874c4c48…` and `BrokenDisguiseCleared` #7 naming `874c4c48…` (the outfit put on; +26 ms engine time; indices 46–47 right after it were never delivered, so a follow-up `DisguiseBlown` is neither observed nor excluded). Derived view `:not_observed → :not_observed → :compromised → :unknown (rule 3) → :cleared (rule 2, anomaly :cleared_without_compromise)` — §30.8 exactly. Operator observations kept separate. Game restored and hash-verified; nothing signalled. §36's text was reconciled against the raw log in the §37 commit (indices 1–54, fall/capture 1 ms apart, negative claims reworded to "not captured").
- Unobserved, retained (§37): re-equip of a compromised outfit; clear by witness elimination with ids; second `DisguiseBlown`; §34's change-time pair ids; the undelivered 46–47; other clearing paths; display names.

## B4 (items): archaeology and design (§38, revised after review), **awaiting design review; nothing implemented**

Evidence classes kept apart: B0 payloads (24: `ItemPickedUp` 12 over 7 definitions, `ItemRemovedFromInventory` 6, `ItemThrown` 6 — one JSON shape, `InstanceId` empty in all 24 sampled, `Category` null 24/24, each B0 throw beside a removal with identical `Timestamp` — an observation, not a rule), names only (B1 and B3: 6+2+3 = 11 per removal/thrown name; `ItemDropped` 7+3, `ItemDestroyed` 1), **runtime field types established: none**, static hypotheses (SDK `eItemType`/`eActionRewardType` names match the JSON strings; `ZItemConfigDescriptor` has `ZRepositoryID m_ItemID`). §22's "one shared item shape" not inherited. Proposal (first implementation): `item.picked_up` / `item.thrown` / `item.removed_from_inventory` v1 only, each occurrence published independently; `item_repository_id` required (definition id; `item_instance_id` only when non-empty); attempt-gated; BEAM direct counts and per-definition summary, throws counted from `item.thrown` alone, no pairing (deferred with its conditions in §38.10), no inventory/holding derivation, history bounded as B3 (later attempts cannot change an earlier view); bounded escaped per-field malformed detail with its limits stated (copied kinds ≠ exact engine types; normalization = contract compatibility); malformed supported events are recorded validation failures, run continues. `ItemDropped`/`ItemDestroyed`: research candidates — no production row; smallest separately authorized observation-only diagnostic described in §38.9 (allowlisted `Value` copy through the existing `CopyValue`, logged shape, no publication). Coverage boundary stated: byte-derived ids exercise the production `RepositoryId` renderer + downstream; hand-built objects/arrays exercise downstream only, never `TelemetryIntake::Copy` or its array branch. Script: pick up, throw, re-pick, second definition, exit (no drop in the first run).

## Next step: B4 design review

Decide on §38 as revised (three-name scope, direct counts, the per-field detail and its limits, the §38.9 diagnostic as a separate authorization). Then B4-R1… implementation under its own authorization, gate, and a bounded run under its own authorization. B5 objectives and B6 player state follow; B7 summary v2 and the M2 completion decision after them.

## Remaining questions

- ~~Dashed rendering of the engine's runtime `ZRepositoryID` bytes versus the B0 corpus strings~~ — shown equal in §36 (5/5 ids). The `kind=Null` metadata proposal of §33 is moot for these four names.
- The change-time `BrokenDisguiseCleared` named the **newly equipped** outfit in §36 (one observation); why the engine clears an outfit it never reported blown, and which ids §34's clear+blown pair named, are unknown. Whether the HUD-visible clearing after witness kills (§32) has a stream counterpart; whether a second `DisguiseBlown` ever occurs for an open compromise; what re-equipping a compromised outfit emits with ids visible — all unobserved.
- Offline (backend-unreachable) emission; `ContractEnd`; `Hero_Dead`; player death reasons — still unobserved.
- Restart path `ContractStart` ordering has three observed variants (after the rise, same frame; next frame; before the rise) — both BEAM pairing rules cover them.

## Standing rules (unchanged)

Every runtime experiment needs its own explicit authorization; operator-in-the-loop; no fix-forward during a run; one root cause per commit; docs on `main`, native on `relay/m2`; the roadmap's M2 exit criterion and numbering are not changed; "complete" never appears in a summary. Cleanup is mechanical: `%TEMP%\glacier-m0\hitmen\run-cleanup.sh <evidence-dir>` — RPC stop, exact PIDs only, never a name-pattern kill.

## Evidence directories

`%TEMP%\glacier-m0\hitmen\`: `b0-run1` (the B0 corpus: `relay-20261007-014849-93996.log`, the only item payloads), `m1-run1`, `m2-run1`, `b1-run1`, `b2-run1`, `b3-run1`, `b3diag-run1`, `b3fix-run1`, `b3diag-artifacts` (the §34 DLL/PDB/probe/tests), `wire-probe\{m2,b1,b2,b3,b3\clean,b3\fix,b3\diag,b3\fix2}`, build logs (`b3-clean.log`, `b3diag-clean.log`, `b3fix-clean.log`), hashes (`b3fix-sha256.txt`), import dumps (`m2-imports.txt`, `b3-imports.txt`, `b3diag-imports.txt`, `b3fix-imports.txt`), build scripts (`build-relay-{clean,incr}.cmd`, `tests25.cmd`, `imports-m2.cmd`), `run-cleanup.sh`.

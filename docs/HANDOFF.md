# Handoff checkpoint

Updated: 2026-10-08, after the B3 diagnostic preparation (M2 design section 33). This is the compact state for a fresh context; the records it points to are authoritative. Every "current" ref must be re-verified before use. All times UTC.

## Refs and artifacts

| What | Where | Ref / hash |
|---|---|---|
| Docs and BEAM (`relay/`) | glacier-relay `main` | the commit that adds this file (verify `git log -1`); contains BEAM correction `63184c4` and the B3 runtime record `b94b627` |
| Native adapter | ZHMModSDK `relay/m2` | **`4a616cf9`** (B3 diagnostic) on top of `e9001ee4` (B3 implementation; the DLL that ran in section 32) |
| Clean DLL at `4a616cf9` (not deployed) | `ZHMModSDK/_build/relay-x64-Debug/Mods/GlacierRelay/GlacierRelay.dll` | SHA-256 `ac6b784ae18299c4d4724c3129525c9fe8ed5113886c946c0f154d28258a4a4e` |
| Clean DLL at `e9001ee4` (ran in B3) | rebuilt only from that commit; no copy kept | `c045f92a813ef70d5b92fe8f06d38c999af41fda7cc9c7552044117d0043ef1b` |
| Clean DLL at `9f746cad` (ran in B2) | — | `0e10e2839c568ae86cb74cdef5fca78445b9c909405ea20da62b3876ea730e30` |
| M0 anchors | glacier-relay tag `research/m0-baseline` `2d67579`; SDK baseline `5cc7f1b1` (untagged) | 26 M0 hashes: `%TEMP%\glacier-m0\installed-sha256.txt` |
| M1 | tag `research/m1-first-semantic-event` on both repos; SDK `relay/m1` `a28840e6` | |
| Frozen research | SDK `research/hitmen-revival` `7ab0eceb`; `research/actor-probe-b0` `ebaa0eb4` | |
| Game | HITMAN WOA 3.280.0.0, Steam 24833614, SDK 4.1.1, mods Editor/FreeCam/SkipIntro/NoPause | `mods.ini` at M0 = `b90b4c5e…`; relay variant = `a66a44ed…` |
| BEAM toolchain | WSL, OTP 28.4.2 / Elixir 1.19.6 via `~/.local/opt/beam-env.sh` | listener 127.0.0.1:4747 |

Game state at this checkpoint: restored to M0 and hash-verified after the B3 run; no Relay DLL installed.

## Accepted milestones

- M0 complete; Hitmen archaeology frozen; M1 complete (`M1_FIRST_SEMANTIC_EVENT.md` §13–15).
- M2 Stage A (mission attempts, observation loss) — runtime-validated (`M2_TELEMETRY.md` §13).
- M2 B0 — research probe; B1 — `actor.died`/`actor.pacified` v1 validated (§26); B2 — `contract.started`/`contract.ended` v1 and BEAM correlation validated (§29).
- ADR 0006 accepted (M2 scope only).

## B3 (disguise): implemented, run, **not accepted**

- Design §30 (fold contract §30.8); implementation §31 (SDK `ddc9987f`, `0a62c03c`, `e9001ee4`; BEAM `b04ff57`, `e7620e7`, `5c4d332`, review fix `63184c4`); 128 Elixir tests; wire 22/22.
- Runtime §32 (2026-10-08 22:46–23:35Z, evidence `%TEMP%\glacier-m0\hitmen\b3-run1\`, native log `ce60de92…`): pipeline PASS (30 envelopes, 0 mismatches, B1/B2 rows intact, 0 ERROR/FAULT) but **all nine disguise occurrences rejected: `Value is not a string`**. Zero `disguise.*` events ever crossed the wire from the game.
- **Confirmed:** the copied `Value` of `StartingSuit`, `Disguise`, `DisguiseBlown`, `BrokenDisguiseCleared` is not a `ZString`. **Unconfirmed:** the copied kind, the engine type(s), whether all four share one. `ZRepositoryID` is a hypothesis with static support only.
- Event-name chronology from that run (ids unknown): a `BrokenDisguiseCleared` co-occurred with a `Disguise` at an outfit change; re-equipping the compromised outfit emitted only `Disguise` (HUD: compromised — operator observation); witness kills afterwards emitted no clear (HUD later: not compromised). No persistence or causation conclusion is drawn.

## The fixture/intake coverage gap

The B0 corpus was captured with the engine's `ZDynamicObject_ToString` (JSON). Every fixture and normalizer test is therefore JSON-level; the production intake is type-level (`TelemetryIntake::Copy`: `ZString`, bool, numbers, objects, arrays; anything else `Unsupported` with the type name; empty/null/void → `Null`). No test can exercise the engine-type dimension without the engine. A new vocabulary's `Value` type is confirmed only by a production run.

## Next step (prepared, not authorized)

§33: SDK `4a616cf9` makes the disguise rejection warning report the copied kind and, for `Unsupported`, the engine type name (escaped, ≤64 bytes), through the existing log path; nothing else changes. A **type-discovery run** (§33, one of each of the four names, then exit and quit) would read the types. After that, a bounded intake change (one new type branch, type-built fixture, gate, run) needs its own review.

## Remaining questions

- Engine type per disguise name (the run above). If `kind=Null`, a one-byte Null-reason code in the intake is the smallest further metadata copy (proposal only).
- Which id the change-time `BrokenDisguiseCleared` names; whether the HUD-visible clearing after witness kills has a stream counterpart; whether a second `DisguiseBlown` ever occurs for an open compromise.
- Offline (backend-unreachable) emission; `ContractEnd`; `Hero_Dead`; player death reasons — still unobserved.
- Restart path `ContractStart` ordering has three observed variants (after the rise, same frame; next frame; before the rise) — both BEAM pairing rules cover them.

## Standing rules (unchanged)

Every runtime experiment needs its own explicit authorization; operator-in-the-loop; no fix-forward during a run; one root cause per commit; docs on `main`, native on `relay/m2`; the roadmap's M2 exit criterion and numbering are not changed; "complete" never appears in a summary. Cleanup is mechanical: `%TEMP%\glacier-m0\hitmen\run-cleanup.sh <evidence-dir>` — RPC stop, exact PIDs only, never a name-pattern kill.

## Evidence directories

`%TEMP%\glacier-m0\hitmen\`: `m1-run1`, `m2-run1`, `b0-run1`, `b1-run1`, `b2-run1`, `b3-run1`, `wire-probe\{m2,b1,b2,b3,b3\clean,b3\fix,b3\diag}`, build logs (`b3-clean.log`, `b3diag-clean.log`), import dumps (`m2-imports.txt`, `b3-imports.txt`, `b3diag-imports.txt`), build scripts (`build-relay-{clean,incr}.cmd`, `tests25.cmd`, `imports-m2.cmd`), `run-cleanup.sh`.

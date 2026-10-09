# Handoff checkpoint

Updated: 2026-10-09, after the B3 intake correction was implemented and validated without the game (M2 design section 35). This is the compact state for a fresh context; the records it points to are authoritative. Every "current" ref must be re-verified before use. All times UTC.

## Refs and artifacts

| What | Where | Ref / hash |
|---|---|---|
| Docs and BEAM (`relay/`) | glacier-relay `main` | the commit that updates this file (verify `git log -1`); section 34 record `1bfcb5e`; contains BEAM correction `63184c4`, B3 runtime record `b94b627`, diagnostic prep `2145594`. BEAM code unchanged since `63184c4` |
| Native adapter | ZHMModSDK `relay/m2` | **`84b93778`** (section 35 intake correction; gate-validated, **never run in the game**) on top of `4a616cf9` (B3 diagnostic; ran in section 34) and `e9001ee4` (B3 implementation; ran in section 32) |
| Clean DLL at `84b93778` (not deployed) | `ZHMModSDK/_build/relay-x64-Debug/Mods/GlacierRelay/GlacierRelay.dll` | SHA-256 `61fe553859667c22145cbfd353e8a3a7717384e056dfa78beee6120cf494bdbc` (10,069,504 bytes); probe `cd13ef10…` |
| Clean DLL at `4a616cf9` (ran in the type-discovery experiment, section 34) | preserved with PDB, probe and tests in `%TEMP%\glacier-m0\hitmen\b3diag-artifacts\` (`sha256.txt`) | SHA-256 `ac6b784ae18299c4d4724c3129525c9fe8ed5113886c946c0f154d28258a4a4e` |
| Clean DLL at `e9001ee4` (ran in B3) | rebuilt only from that commit; no copy kept | `c045f92a813ef70d5b92fe8f06d38c999af41fda7cc9c7552044117d0043ef1b` |
| Clean DLL at `9f746cad` (ran in B2) | — | `0e10e2839c568ae86cb74cdef5fca78445b9c909405ea20da62b3876ea730e30` |
| M0 anchors | glacier-relay tag `research/m0-baseline` `2d67579`; SDK baseline `5cc7f1b1` (untagged) | 26 M0 hashes: `%TEMP%\glacier-m0\installed-sha256.txt` |
| M1 | tag `research/m1-first-semantic-event` on both repos; SDK `relay/m1` `a28840e6` | |
| Frozen research | SDK `research/hitmen-revival` `7ab0eceb`; `research/actor-probe-b0` `ebaa0eb4` | |
| Game | HITMAN WOA 3.280.0.0, Steam 24833614, SDK 4.1.1, mods Editor/FreeCam/SkipIntro/NoPause | `mods.ini` at M0 = `b90b4c5e…`; relay variant = `a66a44ed…` |
| BEAM toolchain | WSL, OTP 28.4.2 / Elixir 1.19.6 via `~/.local/opt/beam-env.sh` | listener 127.0.0.1:4747 |

Game state at this checkpoint: restored to M0 and hash-verified after the type-discovery run (2026-10-09); no Relay DLL installed.

## Accepted milestones

- M0 complete; Hitmen archaeology frozen; M1 complete (`M1_FIRST_SEMANTIC_EVENT.md` §13–15).
- M2 Stage A (mission attempts, observation loss) — runtime-validated (`M2_TELEMETRY.md` §13).
- M2 B0 — research probe; B1 — `actor.died`/`actor.pacified` v1 validated (§26); B2 — `contract.started`/`contract.ended` v1 and BEAM correlation validated (§29).
- ADR 0006 accepted (M2 scope only).

## B3 (disguise): implemented, run, **not accepted**

- Design §30 (fold contract §30.8); implementation §31 (SDK `ddc9987f`, `0a62c03c`, `e9001ee4`; BEAM `b04ff57`, `e7620e7`, `5c4d332`, review fix `63184c4`); 128 Elixir tests; wire 22/22.
- Runtime §32 (2026-10-08 22:46–23:35Z, evidence `%TEMP%\glacier-m0\hitmen\b3-run1\`, native log `ce60de92…`): pipeline PASS (30 envelopes, 0 mismatches, B1/B2 rows intact, 0 ERROR/FAULT) but **all nine disguise occurrences rejected: `Value is not a string`**. Zero `disguise.*` events ever crossed the wire from the game.
- **Confirmed at runtime (section 34, 2026-10-09, SDK `4a616cf9`, DLL `ac6b784a…`, evidence `b3diag-run1\`):** the copied `Value` of all four names is `Kind::Unsupported` with engine type name **`ZRepositoryID`** (6/6 samples; one `StartingSuit`, two `Disguise`, two `DisguiseBlown`, one `BrokenDisguiseCleared`). The earlier "not a `ZString`, kind unknown, type a hypothesis" qualification is superseded by this measurement. Still unconfirmed: that the 16 bytes rendered dashed equal the B0 corpus ids (expected), and the SDK's `ZGuid::ToString` byte order versus the engine's JSON writer.
- Event-name chronology from that run (ids unknown): a `BrokenDisguiseCleared` co-occurred with a `Disguise` at an outfit change; re-equipping the compromised outfit emitted only `Disguise` (HUD: compromised — operator observation); witness kills afterwards emitted no clear (HUD later: not compromised). No persistence or causation conclusion is drawn.

## The fixture/intake coverage gap (corrected statement)

The B0 corpus was captured with the engine's `ZDynamicObject_ToString` (JSON), so the original fixtures and normalizer tests were JSON-level while the production intake is type-level (`TelemetryIntake::Copy`: `ZString`, bool, numbers, objects, arrays, and since §35 `ZRepositoryID`; anything else `Unsupported` with the type name; empty/null/void → `Null`). The earlier blanket claim "no test can exercise the engine-type dimension without the engine" was too broad. Precisely: the **conversion** from the engine's 16-byte `ZRepositoryID` image to the dashed id is engine-independent (`Src/RepositoryId.*`) and is tested offline from the byte image (`Tests/RepositoryIdTests.cpp`, `Tests/Fixtures/B0DisguiseBytes.h`), as is everything downstream of it; the SDK's declaration of the type is pinned by `static_assert`. What still needs the engine is only (1) that the runtime value behind `GetData()` has the SDK-declared layout, (2) that the engine's JSON writer renders the same field semantics (Relay's text == the B0 id for the same outfit), and (3) that `GetData()` points at the inline 16-byte value as it does for `ZString`. A *new* vocabulary's `Value` type is still confirmed only by a production run (the §33 diagnostic reports it); a *known* type's conversion no longer is.

## B3 intake correction (§35): implemented, gate-validated, **not deployed, not run in the game**

SDK `84b93778`: exact `ZRepositoryID` branch in `TelemetryIntake::Copy` → `Kind::String`, 36-char dashed lowercase via the engine-independent `RepositoryId` (fields copied by name at the boundary; no `ZGuid`, no generic coercion, no `ToString`, no engine allocation; eight `static_assert`s pin the SDK declaration). Tests: independent known-answer vector (`33 22 11 00 55 44 77 66 88 99 aa bb cc dd ee ff` → `00112233-4455-6677-8899-aabbccddeeff`, raw and typed, and not the in-order dump), leading zeros, high-bit bytes, the three B0 ids from their images, the 8 events through normalizer and frame with byte-built values, no-relaxation checks; the wire probe's `b3` step builds disguise values from the images. Gate observed 2026-10-09: clean build 0 relay warnings, 25/25, Elixir 128/128 ×5, imports/exports identical to the diagnostic DLL (only `.text` +1 page), wire `b3` 22/22 with 0 field mismatches and the eight byte-built ids equal to the committed fixture's B0 strings; evidence `wire-probe\b3\fix2\`, `b3fix-clean.log`, `b3fix-sha256.txt`, `b3fix-imports.txt`. Details: `M2_TELEMETRY.md` §35.

## Next step (proposed, not authorized): the §35 controlled run

Freeze SDK `84b93778` / DLL `61fe5538…` (re-hash before install) and glacier-relay at this commit. Script as §33; pass criteria (§35): (1) `disguise.equipped` `initial` id == the paired session's `starting_disguise_repository_id`, no `:initial_differs_from_contract`; (2) all four names normalize and publish inside their attempt (`malformed 0` for them, no §33 warning); (3) native↔BEAM 0 mismatches and the derived view stays conservative (`:unknown` after any change); (4) the change-time clear/blown ids are recorded verbatim without assuming which outfit they name. Discrepancies recorded, not fixed forward; mechanical cleanup; game at M0 after.

## Remaining questions

- Dashed rendering of the engine's runtime `ZRepositoryID` bytes versus the B0 corpus strings — the offline conversion is tested from the byte image (§35); whether the engine's value has that image is shown only by the correction's run. The `kind=Null` metadata proposal of §33 is moot for these four names.
- Which ids the change-time `BrokenDisguiseCleared` (and, in §34, the `DisguiseBlown` 2 ms after it) name; whether the HUD-visible clearing after witness kills has a stream counterpart; whether a second `DisguiseBlown` ever occurs for an open compromise.
- Offline (backend-unreachable) emission; `ContractEnd`; `Hero_Dead`; player death reasons — still unobserved.
- Restart path `ContractStart` ordering has three observed variants (after the rise, same frame; next frame; before the rise) — both BEAM pairing rules cover them.

## Standing rules (unchanged)

Every runtime experiment needs its own explicit authorization; operator-in-the-loop; no fix-forward during a run; one root cause per commit; docs on `main`, native on `relay/m2`; the roadmap's M2 exit criterion and numbering are not changed; "complete" never appears in a summary. Cleanup is mechanical: `%TEMP%\glacier-m0\hitmen\run-cleanup.sh <evidence-dir>` — RPC stop, exact PIDs only, never a name-pattern kill.

## Evidence directories

`%TEMP%\glacier-m0\hitmen\`: `m1-run1`, `m2-run1`, `b0-run1`, `b1-run1`, `b2-run1`, `b3-run1`, `b3diag-run1`, `b3diag-artifacts` (the §34 DLL/PDB/probe/tests), `wire-probe\{m2,b1,b2,b3,b3\clean,b3\fix,b3\diag,b3\fix2}`, build logs (`b3-clean.log`, `b3diag-clean.log`, `b3fix-clean.log`), hashes (`b3fix-sha256.txt`), import dumps (`m2-imports.txt`, `b3-imports.txt`, `b3diag-imports.txt`, `b3fix-imports.txt`), build scripts (`build-relay-{clean,incr}.cmd`, `tests25.cmd`, `imports-m2.cmd`), `run-cleanup.sh`.

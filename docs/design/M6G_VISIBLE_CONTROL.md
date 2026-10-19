# M6-G — One bounded, observable external action on the visible Agent48 (design, 2026-10-18)

**Status:** sections 1–5 are the design, from read-only source examination. Section 6 is the reviewed M6-G1 contract. Section 7 records M6-G1: `candidate.transform.set` v2 `step_y` implemented and validated **offline** (build of record native5 `f271d129…`, not installed; evidence `m6g1-offline\`, sealed `b65c87ff…`). Section 8 records the review's bounded acceptance of M6-G1 and its three qualifications. Section 9 records **M6-G2 run 1** (2026-10-19; evidence `m6g2-run1\`, sealed `86901008…`): native5 installed once, ONE v2 `step_y` applied exactly (y 14.83 → 15.08), six samples held over 10 s, the operator saw an instantaneous, animation-free shift that the retained continuous recording covers, ONE approved v2 restoration returned the stored transform bit-exactly to P, and the game was restored byte-for-byte. M6 is not complete; nothing is tagged.

**Authorization:** "M6-E3 Acceptance and Bounded Visible-Control Design". The acceptance addendum is `M6E_VISUAL_PLACEMENT.md` section 13.

**Evidence:** `%TEMP%\glacier-m0\hitmen\m6g-design\` (10 files, sealed; manifest `sha256.txt` `cd1e7856557c0256b690f7c049e473f97b7bc1482d391969d5f128a8b1f6e6ae`):
- `checks.txt` — what was performed now, and what is referenced;
- `source-facts.txt` — every cited site, with its git blob;
- `geometry-attempt2.txt`;
- `checker-report.txt` — the one independent source check, with the tool-runner's verification.

**The question:** can BEAM request one bounded change to the visible, separately identified candidate, and observe numerically and on screen what happens, without disturbing Agent 47?

## 1. The choice: ONE compiled +0.25f world-y step

**The operation:** from M6-E3's state (Agent48 at P, identity rotation, the accepted package `5ac64848…`):
- copy every preimage word, and replace only `Trans.y` (`w[10]`) with `Trans.y + 0.25f` in binary32;
- from E3's words, `416d47ae` → **`417147ae`** (14.83 → 15.08), an exact sum.

The request preserves `Trans.x`, `Trans.z` and the nine rotation words. That is not a promise that the engine keeps them; every observed change is recorded.

**The direction,** from measured positions only; no model-forward is inferred:

| | To Agent 47 | Bearing offset seen from Agent 47 | To the row centre lines (+y / −y) | Nearest planter centre |
|---|---|---|---|---|
| P (E3) | 5.748 m | +1.32° | 2.842 / 2.836 m | 3.37 m |
| **P + 0.25 y** | **5.759 m** | **+3.81°** | **2.592** / 3.086 m | 3.17 m |
| P + 0.25 x | 5.498 m | +1.38° | 2.842 / 2.836 m | 3.24 m |

- **The line of sight runs along x.** Agent 47 stands at (−83.744, 14.697). With the camera moved by the mouse only, the line of sight from his position to P runs almost exactly along world x.
- **A +x step is mostly depth:** about 3–4% apparent size, and 0.25 m closer to him.
- **A +y step is lateral:** about 2.5° as seen from his position. That is about 1.7° from a camera roughly 2.5 m behind him — an estimate, since the camera's position and field of view are not measured.
- **+y moves Agent48 away from the line through Agent 47** (it already stands +0.133 m in y from him), so it does not move behind his silhouette in the E3 framing; its distance to him stays approximately the same (5.748 → 5.759 m; section 6, item 2).
- **It goes 0.25 m toward the +y planter row.** The planters' and trees' extents, the floor at P + 0.25 y and NPC occupancy are not measured. The table gives centre distances, not clearance.

**Compared with the existing vertical lift at P** (no code cost, already qualified):
- **What the lift adds:** whether the z return recurs at the content-defined location, and whether a transient of six frames or fewer is visible. That is near the limit of an operator's eye or a 30–60 fps phone recording, so a negative result would be ambiguous.
- **What the y step adds** is the first horizontal component, at the visible location: what this intervention does at its sampled frames, and, if it holds, a sustained lateral shift that may be visible. It is not a controlled axis-only comparison with M6-F's z trials (other origin, initialization and run): neither a held nor a returned y step identifies or excludes a return mechanism (section 6, item 3).
- **The decision:** the y step, at the cost in section 3. Neither result identifies the writer, and neither precommits another run. A +x step would cost the same but measures visually only as depth.

## 2. The control contract (existing mechanisms; references, not copies)

- **Identity:** the compiled candidate (`007c57a6ea581f8c` / `feede715906f747f`), freshly resolved on the applying frame. It must be distinct from Agent 47 and absent from the four registry slots. The spatial interface, a clean preimage, and the parent and generation rules all apply (`TransformApply::EvaluateTransform` rules 1–4, unchanged; M6-F record sections 2–3).
- **Expectation:** one specific, recently completed `relay.inspect.candidate_transform/1`, verified by the issuing authority (`TransformBinding`, M6-F record 11). Every word is re-checked natively on the applying frame.
- **Nothing peer-chosen:** no entity, matrix, distance, direction, script, function or address. The step is compiled; the BEAM replica only cross-checks `requested_world_words`.
- **Authority:**
  - token-verified link;
  - attended operator authority;
  - fresh one-shot effectful arming;
  - **one forward per process on both sides, shared with the v1 lift**;
  - no retry or budget reset after an uncertain outcome.
- **The call:** one guarded call through the existing single `SetObjectToWorldMatrixFromEditor` site (`TransformApplier.cpp:72`, unchanged). Around it, as today:
  - the result-capacity check;
  - the link re-read;
  - the checked "applying" line;
  - honest fault and timeout outcomes (`unknown` is never "unapplied");
  - the exact preimage;
  - the same-frame postimage, separate from the later samples.
- **Restoration:** only through the existing planner (M6-F record 15.5).
  - It must be bound to a later exact inspection that still shows the postimage, and approved separately.
  - It goes to the journaled preimage (`c2b2fae1 416d47ae bfc2d6ba`, identity rotation).
  - No parent-relative writes, no automatic inverse, no repeated call against a return.
  - At baseline, nothing is sent.
- **Stops:** drift, an uncertain effect, a dirty or unqualified state, an identity or control change, an authority restart or an audit failure ends effectful issuance.
- **Sampling:** the existing finite sampler (`m6f_follow.exs`: +0, +250 ms, +1, +2, +5 and +10 s). Its classes come from the apply result's own preimage and requested words. M6-F2b's first sample — about six frames / 58 ms after the call (M6-F record 16.4) — is a reference from the earlier DLL and run, not a guarantee; the new build's offline timing and any later game's actual timing are measured (section 6, item 5).

## 3. Change-impact map (verified by one independent read-only check; `checker-report.txt`)

**Reused unchanged:**
- **Native:**
  - the identity, registry, spatial and expectation rules;
  - `MandatoryResultFits`;
  - the link re-read and the checked writer;
  - `ITransformApplier` / `TransformApplier.cpp`;
  - the read-back;
  - `ClassifyWorld` / `ClassifyLocal` / `ClassifyControl` and `RestoreFacts` (none depends on the mode);
  - the effect rules and the fault latch;
  - the inspection entry.
- **BEAM:**
  - the token holder, attestation, arming and journal;
  - `TransformReadback.decode_apply` / `classify_later`;
  - the authority's later-frame and restoration classification — both keyed on the name and the result's words (`authority.ex:1389`, `:1787`).
- **Tooling:** `m6f_follow.exs`'s schedule and classes (`:229`, `:440`), the evidence guard, `readiness.py`, the installer and cleanup kit, the `cmd.exs` inspections.

**Compatibility:** `candidate.transform.set` **v1 stays exactly as it is.** Its modes are `lift` | `restore`, a v1 restore restores only a v1 lift, and v1 is still decoded and advertised. Its decoder already refuses `step_y` (`CommandProtocol.cpp:357`).

The step is **`candidate.transform.set` v2**, `mode` `step_y` | `restore`:
- the same expectation keys as v1;
- `step_y` carries no target and no `restore_of`;
- a v2 `restore` restores only a v2 step;
- a restore is always issued at its forward's version.

**The surfaces that change** (at `3b892cad` / `18deb0f7`):

| Layer | Sites | Change |
|---|---|---|
| Native protocol | `CommandProtocol.h` `Entry` (:97, :108), `TransformMode` (:116), `TransformRequest` (:124–126, the Lift default); `CommandProtocol.cpp` `Lookup` (:61), `IsEffectful` (:68), `TransformModeText` (:71–73), the decode (:341–401) | `CandidateTransformSet2`; `TransformMode::StepY`; a v2 decode beside the untouched v1 one; the request carries its entry |
| Native target | `TransformObservation.h` (:35, :80), `.cpp` (:7–13) | `k_StepY = 0.25f` and `StepYTarget` (`w[10]`); `LiftTarget` unchanged |
| Native apply | `TransformApply.cpp` the target (:172), the ledger rule (:181), the applying line (:591), the budget (:605), the ledger update (:754); `TransformApply.h` `Ledger` (:43–75, no mode today) | "forward" = lift or step_y (one shared budget). Without this, a StepY would fall into the restore branches. The ledger records the forward's entry and mode; a restore at another entry is refused with a new closed reason. The applying line names `/1` or `/2` |
| Native wiring | `CommandScheduler.cpp` (:640); `CommandLink.cpp` (:332); `GlacierRelay.cpp` (:150) | dispatch v2 to the same path; advertise `/2` under `effectful` only; the inert line unchanged |
| Native tests | `TransformApplyTests`, `TransformObservationTests` (:112–121, :213), `CommandProtocolTests`, `CommandLinkTests`, `CommandSchedulerTests`, `CommandProbe` (the FAKE apply; the "/1" applying-line literal at :642), `FakeTransformApplier` | the step target from E3's words; the shared budget; a v2 restore of a step; cross-version refusals; the probe's log-fault modes matching `/2`; the v1 regression unchanged |
| BEAM | `schema.ex` (:76–82, :185–203); `transform_words.ex` (:24–30, :166); `authority.ex` `check_transform` (:1061–1103) incl. `:restore_of_not_a_lift` (:1094–1096), the bind arm (:1105–1118), the budget (:1207–1223), the status (:1990); `transform_binding.ex` (:49); `transform_restore.ex` (:237 version, :240 / :304 mode, the plan :52–91); `command.ex` `lift_candidate/2` (:102), `restore_candidate/2` (:164–166, issues v1) | the v2 entry; `step_y_target/1`; a step clause; one forward budget across versions (status keys kept, documented); `TransformBinding.step/3`; the plan carries the forward's version and the restore is issued at it; cross-version restores refused; `Command.step_candidate/2` |
| BEAM tests | `transform_words_test`, `transform_binding(_unit)_test`, `transform_restore_test`, `transform_effectful_test`, `authority_redaction_test` | the step, its refusals, the shared budget, the restore plan of a step |
| Tooling | `cmd-m6f.exs` `lift_guard` (:208–232), `lift_prepare` (:251–275), `lift_report` (:279–301), actions :485 / :508 (`restore` :681 and `observe-later` :730 reused); `cmd_m6f_args.exs`; `xcheck.py` (:39, :265–273); `follow-matrix.sh` (:161–162); `cmd.exs linkcheck` (:208–209) | `step` / `step-follow` with a step guard, preparation and report (the cross-check `requested = StepYTarget(preimage)`); `xcheck.py --step`; the matrix counts forwards of both kinds; **the inert linkcheck also requires `/2` absent**, and the effectful check allows it |

**Cost:** one target function, five native branch sites and three wiring sites; in BEAM, one clause, one budget predicate, one binding, the planner's version and mode guards, and one public function; two tooling actions and their checks — plus tests and a new build of record. The inert path's code is unchanged, but a new binary needs its own startup evidence at any future run's main menu.

**Not available from source** — these remain experimental uncertainties:
- whether the engine keeps a horizontal world change on this unspawned hero, and what returned M6-F's z (not traced);
- whether a return goes to P;
- whether the drawn figure follows the stored transform;
- what `SetObjectToWorldMatrixFromEditor` triggers beyond the stored fields;
- the floor, collision, NPC occupancy and reaction at P + 0.25 y.

No source fact rules the step out. Native compares all twelve words, and the only z-specific checks are the lift's own cross-checks.

## 4. The visual measurement

**Availability first:** before any runtime decision, the operator names:
- the capture method (E3 used a phone; Snipping Tool and Steam F12 are also available);
- a commitment to **retain** one continuous recording, and where it will be saved.

Without that, the visual record is not attempted. Stills are never presented as motion evidence.

**The procedure:**
- **The view:** held before anything is armed, in the F12-2 framing — the figure visible beside Agent 47, with the planter pair and the fountain as fixed references. No search, camera tool or repositioning.
- **The recording:** it starts before the call and runs past the last follow sample (more than 10 s after it), with one F12 still before and after. The expected change is a lateral shift against fixed scenery — an estimated tens of pixels at the E3 framing, an estimate rather than a mapping.

**Six separate verdicts:**
1. request and invocation;
2. same-frame stored transform;
3. later samples, with their actual native frames and times;
4. the visual response — the operator's words verbatim, with the frame comparison separate;
5. identity and controls;
6. restoration eligibility and, only if approved and performed, its evidence.

**Interpretation:**
- A numeric step with no seen motion may be a missed transient, occlusion or a render that does not follow.
- A seen shift without matching inspection context is qualified, not attributed.
- No outcome prescribes another run or writer tracing.

## 5. The smallest next authorization (proposed, not granted): M6-G1, offline

Implement `candidate.transform.set` v2 `step_y` per section 3 — native on `relay/m2`, BEAM and tooling on `main` — with:
- the unit tests;
- the FAKE-probe matrix extended by the step cases: applied / held, returned, uncertain; the budget shared with a v1 lift; a v2 restore of a step; cross-version refusals; v1 unchanged;
- one build of record, not installed;
- the standard native and BEAM gates;
- a dry run of the new actions;
- a pinned offline readiness record.

Not included: installation, launch, real token or camera action. The attended run (M6-G2) needs its own authorization, the capture commitment and a fresh Ready.

M6 stays open; no tag.

## 6. The M6-G1 reviewed contract (reconciliations recorded before code)

**Authorization:** "M6-G1 offline visible-step implementation authorization". It accepts this design as the basis for M6-G1, offline implementation and validation only. These items are binding clarifications; sections 1, 2 and 4 were corrected in place where marked.

1. **The target:** `StepYTarget(preimage)` copies all twelve world words and replaces only word 10 with binary32 `y + 0.25f`. For E3's snapshot that is `416d47ae` → `417147ae`, an exact delta of 0.25. The request keeps z and rotation unchanged; that is not a promise about the engine's post-state.
2. **The axis:** world y is not model-relative sideways motion. The geometric choice is plausible for the recorded view, but the camera origin, projection and clearance are not established. The distance to Agent 47 stays approximately the same (5.748 → 5.759 m), not exactly.
3. **No categorical inference:** a held y step does not disprove a whole-transform return mechanism, and a returned one does not identify one. M6-F's z trials used the old origin; this trial uses the content-placed candidate at P. Axis, location, initialization and run context differ, so this is not a controlled axis-only comparison. Each result describes this intervention at its sampled frames.
4. **Held means sampled:** held samples are agreement at the samples, not continuous persistence or guaranteed visible motion. A recording may add visual evidence; by itself it does not identify an engine writer.
5. **Timing:** the 58 ms first read belongs to the earlier DLL and run. It is kept as a reference; the new build's offline timing and any later game's actual timing are measured, not inherited.
6. **The caller-level RPC bounds:** `cmd-m6f.exs` currently applies its bounded RPC behaviour (`rpc_ms`) only when `action == "lift-follow"`. `step-follow` inherits the same bounds, stop checks, uncertain-issuance handling, sealed-root and label protections and deferred reporting. The sampling engine itself does not change.

**The versioned capability contract.** This uses the existing command-link protocol. Command entry version 2 is not a transport-protocol version: no protocol-3 handshake, socket, service or alternate transport.

| Command entry | Forward mode | Restoration |
|---|---|---|
| `candidate.transform.set/1` | `lift` | a v1 restore of an eligible v1 lift only |
| `candidate.transform.set/2` | `step_y` | a v2 restore of an eligible v2 step only |

- **Refused:** v1 `step_y`; v2 `lift`; unknown versions; any axis, distance or target on a forward; cross-version restoration. There is no downgrade, and no retry through another version when a capability is absent.
- **Capability identity is (name, version)** — in lookup, advertisements, validation, stored command records and audit.
  - A peer advertising only v1 does not enable v2.
  - Effectful-disabled paths omit and refuse both versions.
  - A transport-v1 peer stays inert-only.
- **Carrying the version through:**
  - The accepted forward's version and mode go into the native ledger and the journal-derived BEAM restoration plan.
  - `restore_candidate/2` issues the plan's verified original version — never a default literal or a caller-selected override.
  - The authority's issuance decision compares the requested restore version with the journaled original, including calls that bypass the convenience facade.
  - The native gate enforces the match independently, before its setter.
  - Historical v1 journal entries already carry their version. v1 plans are derived from that evidence without rewriting journals or requiring new fields in old records.
- **One shared forward budget** across v1 lifts and v2 steps on each side; no per-mode budget.
  - The documented difference stays: native consumes at invocation, BEAM accounts conservatively for accepted, in-flight and uncertain effects.
  - A new mode, id, arming, reconnect or restoration never resets it.
  - An authority restart stays an operational hard stop for an attended run, never a recovery technique.
  - Existing status field names (`transform_lift_budget`, `transform_lift_consumer`) stay for compatibility, documented as shared by both forwards. New evidence distinguishes a v1 lift from a v2 step.
- **Binding:** the v2 step needs the same specific, recent, completed exact inspection, verified by the issuing authority against its own journal and current context. Canonical expectation values come from that evidence: no caller-asserted binding map, no implicit latest-inspection shortcut.
- **Native revalidation on the applying frame** stays complete: identity, distinctness, registry absence, generation, parent, the clean exact expectation, a finite and non-no-op target, the budget, the capacity, the link and the checked pre-call line. Unsupported internal entry / mode combinations are refused, never fallen through into another operation. There is no extra setter, direct field write, physics write, input, activation or registry operation.
- **Restoration is never an automatic inverse.** It needs the original preimage, a later exact inspection and journal / ledger eligibility, and is refused for uncertain, dirty, drifted, already-returned, ambiguous or otherwise ineligible evidence. It cannot refill the forward budget. World, parent-relative, parent, dirty-state and whole-snapshot facts stay separate.

## 7. M6-G1 — implementation and offline gate record (2026-10-18)

**Authorization:** "M6-G1 offline visible-step implementation authorization" (section 6). Offline only. Nothing was installed and HITMAN was not launched; no real run token was provisioned, and no camera operation, content generation or game command took place. Ephemeral offline test tokens and FAKE-engine commands ran inside guarded test roots. M6-G2 is not authorized; section 7.9 is a proposal. M6 stays open; nothing tagged.

### 7.1 Identities

| What | Identity |
|---|---|
| Starting checkpoint (verified, `m6g1-offline\checkpoint.txt` PASS) | glacier-relay `main` `1aba9b58` · ZHMModSDK `relay/m2` `3b892cad` · native4 `806de7a9…` intact · content `5ac64848…` / `58e9a10f…` / `9433888b…` · manifests `5121856e…` (M6-E3) and `cd1e7856…` (M6-G design) · six sealed roots and four committed recordings unchanged · the complete game baseline, M0 26/26 · no relay process, port or token file |
| Reconciliation (docs, before code) | glacier-relay `b0f9c85d` (section 6) |
| Native | ZHMModSDK `relay/m2` **`06a2c48c`** (the entry, gate, ledger and tests) · **`76c407f3`** (the command probe, tests only); both pushed |
| BEAM | glacier-relay `main` **`8a1fa37c`** (schema, authority, binding, planner, facade, tests); pushed |
| Tooling | glacier-relay `main` **`ff828880`** (`cmd-m6f.exs`, `cmd.exs`, `xcheck.py`, `follow-matrix.sh`, the tooling test, README); pushed |
| Corrections after the matrix and the independent check (7.5, 7.7) | glacier-relay `main` `ff692019` (the matrix's step-blind checks) · `925e8be` (BEAM: the binding's restore version required; direct tests) · `656a428` (the `cmd-m6f.exs` header) · **`874d404c`** (the at-p world's one known xcheck line); pushed. `874d404c` is the commit of record of the gate, the matrix and record (a) |
| Offline readiness record (a) | `m6g1-offline\readiness-attempt2\record-a.json` **`e74a68586a9e4c6032d90f8ec3112240b5ed605d1c886547fad103595b24aa0f`** (139 checks ok; run id `m6g1-offline`; qualifies, does not authorize) |
| **Build of record `native5`** (clean, `-j 1`, from `76c407f3`; NOT installed, not tagged, not a replacement for native4) | `GlacierRelay.dll` **`f271d1292096bbcdfed41a89f0162d430944042789f1975ea69a80883d5e4280`** (11,069,952 B) · PDB `884b5a9e…` · `GlacierRelayTests.exe` `4d64a572…` · `GlacierRelayCommandProbe.exe` `6de83c7c…` · `GlacierRelayWireProbe.exe` `8a2c0cd3…` (`m6g1-offline\native5\artifacts.sha256`) |
| Evidence | `%TEMP%\glacier-m0\hitmen\m6g1-offline\` (state root `~/.local/state/glacier-relay-m6g1-offline`), sealed, **4,566 entries, manifest `sha256.txt` `b65c87ff2f82b865d85734ddd1cea06ab3ecb15240dbed7a17dcf30f653fdf3b`** (written last, after every writer stopped; verified) |

native4 (`806de7a9…`), its tree, and every older binary, tag, recording, exception list and sealed root are preserved unchanged.

### 7.2 What was implemented

**Native (`06a2c48c`, 9 source files):**
- `CommandProtocol`: entry `candidate.transform.set/2` with `TransformMode::StepY`. The decode is shared with v1, and version-specific refusal texts say which modes each version takes. A forward carrying `target_world` or `restore_of` is refused, and the request records its version.
- `TransformObservation::StepYTarget`: all twelve words are copied and only word 10 is replaced with binary32 `y + 0.25f`.
- `TransformApply`:
  - gate rule 0 refuses every (version, mode) pair outside v1 {lift, restore} and v2 {step_y, restore}, before any target is computed;
  - a command-entry version that differs from the request version is refused (`entry_mode_unsupported`);
  - the one forward budget is consumed by either forward at the call, after the checked applying line, and the ledger records the forward's version and mode;
  - a restore of another version's forward is refused (`restore_version_mismatch`);
  - the applying line names the version and mode (`applying candidate.transform.set/2 mode step_y`).
- `CommandScheduler`: v2 dispatches into the same transform path.
- `CommandLink`: `candidate.transform.set/2` is advertised only under the effectful setting.

The setter call site, the detour, the observation model, the native revalidation, the capacity and the log discipline are unchanged.

**BEAM (`8a1fa37c`):**
- `Schema`: `{"candidate.transform.set", 2}` takes `step_y | restore`; it is effectful, `:token_verified`, with the mission-generation precondition.
- `TransformWords.step_y_target/1`: a cross-check replica only.
- `Authority`:
  - per version, it accepts only that version's forward;
  - one shared forward budget (`forward_consumes?`: accepted and not verifiably unapplied);
  - it compares a restore's version with the journaled original whichever facade is used;
  - the status keys `transform_lift_budget` / `transform_lift_consumer` are kept and documented as shared.
- `TransformBinding.step_y/3`: the same one specific, recent, exact inspection; `restore/5` checks the plan's version.
- `TransformRestore`: plans v1 lifts and v2 steps, carrying the journaled version and mode. Historical v1 records already carry their version and are used without rewriting.
- `Command.step_candidate/2`; `Command.restore_candidate/2` issues the plan's version.

**Tooling (`ff828880`):**
- `cmd-m6f.exs` `step` / `step-follow` reuse the lift's guarded path through one forward descriptor. That includes the bounded `rpc_ms` (now for `step-follow` too), the stop before every read, uncertain issuance, the sealed-root and label refusals, and the deferred reports.
- The step's evidence is named `step.*`, with `step.entry-is-v2-step_y`. The lift's texts and EVIDENCE names are unchanged.
- `xcheck.py --step`; the `cmd.exs` linkcheck covers every `candidate.transform.set/<n>`.
- `follow-matrix.sh` is parametrized by environment variables; its defaults are the M6-F2a / F2b lift behaviour.
- The finite sampler is unchanged (at most six reads, one in flight).

### 7.3 Offline proof against the authorization's list

Native tests are in `TransformObservationTests.cpp`, `TransformApplyTests.cpp` and `CommandLinkTests.cpp` on `relay/m2`. BEAM tests are in `transform_step_v2_test.exs` (14 tests) and `transform_restore_test.exs`. The matrix is the FAKE probe `6de83c7c…` with the reviewed BEAM application (7.4).

| Required (authorization section 6) | Where it is shown |
|---|---|
| E3's exact words, only word 10 changed (`416d47ae` → `417147ae`), signed zeros kept; non-finite and unchanged targets refused | native: the step target on E3's words with a planted −0, its no-op and non-finite cases (`target_equals_current`, `target_not_finite`); BEAM: the words replica; matrix: `xcheck --step` `step-requested-is-compiled` on every step phase |
| version / mode combinations and cross-version refusals, including native-only inputs | native: the decode of v2, v1 `step_y` / v2 `lift` / v0 / v3 refused, the refusal table run for both versions, the unsupported (version, mode) pairs reached natively and the command / request version mismatch (`entry_mode_unsupported`); BEAM: the schema test, the authority's per-version mode check |
| multi-version advertisement, a v1-only peer, effectful-off, a transport-v1 peer | native: the effectful hello carries `/1` and `/2` and no `/3`; the inert hello carries neither; a version-1 link refuses `/2`. BEAM: a v1-only peer gets `:entry_not_advertised_to_peer`, effectful off gives `:effectful_disabled` with neither in the welcome, a transport-v1 peer gets `:peer_protocol_version_1`; tooling: the linkcheck covers every `candidate.transform.set/<n>` |
| the shared budget in both orders; fresh ids, re-arming and restoration give no allowance; pre-call refusals vs uncertain / in-flight consumption | native: the qualified step then a lift refused, and the reverse order; the scheduler dispatch with the shared budget; an unaccepted applying line consumes nothing. BEAM: the step ladder, the other order, a verified refusal leaving the budget, an unknown step consuming it across a reconnect and a fresh arming, a restoration never refilling it. Matrix: `step-refused` (budget 1, arming unconsumed), `issue-timeout` (uncertain issuance, the step applied meanwhile, no read) |
| a journal-derived v2 plan transmits a v2 restore; a v1 plan still transmits v1; forged metadata, version substitutions and altered targets fail | BEAM: the v2 plan and transmission, the v1 plan, forged / version-substituted / altered restorations, a v2 restore of a v1 lift; native: cross-version restores (`restore_version_mismatch`), every v2 restore substitution refused against the record; matrix: `restore.version-is-the-original's` on every restoration |
| the complete step-follow → sample → eligibility → fake approval → fresh arming → restore workflow, including the stale-sample path | matrix step-kit: `kit-held`, `restore-held`, `restore-aged` (the just-in-time path and the DIRECT stale refusal), `restore-returned`, `restore-drifted` through the M6-G2 kit's `op.sh`, `seq-step.sh` and `seq-restore.sh` in dry-run mode |
| the fake held / returned / drift / dirty / unchanged / unavailable / uncertain / fault outcomes; log failures on the `/2` line | native: the step's setter outcomes — unchanged, elsewhere, axes elsewhere, local follows, dirty post-state, read-back unavailable, a generation / parent / entity change after the call, a fault during the call, a control change — each with one invocation and the budget consumed, restorable only when changed with the control unchanged; the checked `/2` applying line (no call on an unaccepted line, the budget not consumed); matrix step-direct: `returned`, `drifted`, `dirty`, `near`, `slow`, `fault`, `exit-after-call` |
| the v2 binding refusals (missing, stale, foreign, wrong generation, twin-bit, unqualified) | BEAM: the v2 binding refusals and the stale / old-link test; matrix: `step-refused` (stale binding refused by the authority after the local guard passed) |
| operator stop, bounded RPCs, uncertain issuance, link loss, authority restart | matrix step-direct: `operator-stop`, `issue-timeout`, `disconnect`, `no-link`, `authority-restart` |
| v1 compatibility; no dynamic-atom regression | the unchanged v1 tests in both suites (25 native runs, five BEAM suites); matrix lift-regression on native5; no `String.to_atom` on wire or journal input (the independent check, 7.7) |

### 7.4 The gate

Every gate run below ran in sequence, never alongside another run that used ports, a BEAM node or the build tree.

**Native** (`gate-attempt1`, `native5\`):
- **Clean build:** `-j 1`, tree `_build/relay-x64-Debug`, rebuilt from an empty directory. 0 Relay-owned warnings. The one warning is the third-party ZHMTools `ZHMEnums.cpp` C4244 (MSVC `utility(274)`), the same one native4's build reported.
- **Tests:** **25 / 25** consecutive runs of `GlacierRelayTests.exe` `4d64a572…`, exit 0 every time.
- **Raw import / export symbols vs native4: 0 added, 0 removed (202 / 202).** The expected engine-import growth was zero, and it is zero. The imported DLLs are unchanged.
- **Source scans:**
  - one `AddDetour` site, one `ZHitman5_SetOutfit->Call` (OutfitApplier.cpp), one `->SetObjectToWorldMatrixFromEditor(` (TransformApplier.cpp), no other `->Call(`;
  - `SetProperty(` / `SetTransform(` / `m_pPhysicsObject` / `Activate(` / `SendInput` / `keybd_event` / `mouse_event`: 0;
  - the transform applier is constructed only under the effectful setting;
  - `forward_budget = 1`, consumed at the call;
  - `k_LiftZ` and `k_StepY` once each;
  - `/1` and `/2` advertised, both inside `if (m_Options.effectful)`.
- **Line bounds (run 1):** the candidate's good read set is 3,562 B and its maximal observed set 4,009 B. The transform inspection is 2,643 B, the v1 lift result 3,864 B and the v2 step result 3,845 B, all of 4,096 (47 entries each for the two results).
- **Capability lists:** the effectful hello carries `/1` and `/2` and nothing else of that name; the inert hello carries neither.

**BEAM** (`beam-gate-attempt2`, relay `874d404c`, after the verifier's corrections):
- `mix compile --warnings-as-errors` (dev) and `MIX_ENV=test mix compile --warnings-as-errors`: ok. The scoped format check (command lib and tests, test support): ok.
- **Five full suites: 618 tests, 0 failures each, exit 0** (seeds 247988, 137993, 155303, 695372, 7060). `beam-gate-attempt1` on `ff828880` gave the same: 618 / 0 × 5.
- Areas alone: the M6-F / M6-G1 transform files 73 / 0, the command directory 176 / 0, headless + boundary 16 / 0.
- Tooling tests: `cmd_m6f_args_test` 11 / 0, `m6f_follow_test` 33 / 0, `readiness_test.py` OK.
- `gate-attempt1` also recorded that, compared with `b0f9c85d`, the recording, wire, web and token-holder code, `mix.exs` and `mix.lock` are unchanged (0 lines); the four committed recordings are unchanged; and the whole-tree format check lists 12 files, all M2-era (`lib/glacier_relay/{attempt_history,disguise,events,lifecycle,player_state,summary}.ex` and six tests) and none of them this stage's.
- **Disclosure:** the test files are not warning-free. Four untouched command test files emit warnings while compiling; their last changes are `eade3aa`, `a91a5fb` and `a6d23fe`, all from earlier stages:
  - `candidate_inspection_test.exs`: nine OTP 27 `0.0` pattern warnings;
  - `players_inspection_test.exs`, `transform_binding_test.exs` and `effectful_test.exs`: an unused default argument each.
  So `mix test --warnings-as-errors` (`gate-attempt1`) completed all five suites at 618 / 0 and then exited 1 on those warnings alone. The gate of record uses the established form of the M6-F1a … F2b gates (compile with warnings as errors, then plain `mix test`). The files this stage added or changed emit no warnings. Cleaning the four files is a separate test-hygiene item and was not done here.

**Matrix** (`follow-matrix.sh` at `874d404c`, the native5 probe `6de83c7c…`, the BEAM application at `874d404c`, one group at a time):

| Group (attempt of record) | Phases | Result |
|---|---|---|
| `step-direct` (`matrix-step-direct-attempt3`; `M6F2A_FORWARD=step`, `at-p` world) | returned, drifted, dirty, near, slow, fault, exit-after-call, disconnect, authority-restart, operator-stop, no-link, step-refused, issue-timeout | **PASS, 0 failures** (81 checks ok) |
| `step-kit` (`matrix-step-kit-attempt2`; the M6-G2 kit's `op.sh` / `seq-step.sh` / `seq-restore.sh` in dry-run mode) | kit-held, restore-held, restore-aged, restore-returned, restore-drifted | **PASS, 0 failures** (75 checks ok) |
| `lift-regression` (`matrix-lift-regression-attempt2`; v1 on native5, the default world) | returned, fault, lift-refused | **PASS, 0 failures** (16 checks ok) |

What the groups show:
- **The steps and samples:** every step phase's request is the compiled target (`xcheck --step` `step-requested-is-compiled`, `step-entry-is-v2`). Every follow-up sample was on time, except the one slot the slow phase is designed to miss (700 ms frames: 5 on time, 1 missed, no catch-up).
- **Restoration:** every restoration was issued at version 2 (`restore.version-is-the-original's`). After `restore-held`'s one restoration, the world and parent-relative words are bit-equal to the pre-step inspection.
- **The second forward:** refused by `op.sh`, by `cmd-m6f.exs` called directly (its local guard: budget consumed) and by the authority. The independent journal check counted one forward, its armings and its consumption in every phase.
- **The FAKE first observation:** +4 to 5 frames, +61 to 78 ms native, at 10 ms frames. This is a property of the FAKE probe, not a prediction (7.8).
- **Per-sample cross-check:** the `at-p` world's one known xcheck line (7.5, item 4) is named and tolerated only in kit-held. No other NOT line occurred.

**Drift rule** (`deps-attempt3`, against the final `run_manifest.py`): the kit's drift check on a scratch clone, **7 / 7**:
- passes: HEAD = A, one docs-only commit, two docs-only commits;
- fails: a tools commit, a relay commit, a docs-only head that does not descend from A, a non-docs file renamed into `docs/`.
The real repository was unchanged and the clone removed. It ran with `python -I -B`, so no `__pycache__` was written into the kit; `scripts/drift-test-NOTE.txt` records this.

**Final state** (`final-checks.txt`, after every other writer stopped and before the manifest):
- the game verified against the complete baseline (`content-verify.sh`), M0 26 / 26, no patch300 file and no relay file under `mods\`;
- no HITMAN, probe, test or `beam.smp` process, and no listener on 4747–4749;
- no token file, an empty state root, and no token-shaped value anywhere in the root;
- the accepted package set, the six sealed roots' manifests, native4 and native5 (5 / 5 each), the decoded matrix pin and record (a) all unchanged;
- both repositories clean and on their upstreams (`874d404c`, `76c407f3`).

### 7.5 Preliminary failures (preserved)

All of these are preserved in `m6g1-offline\`, each with a NOTE beside it. None of them is of record.

1. **`native\build-incr-A`:** the incremental build failed to compile. A `\n` inside a Python heredoc string put a literal newline into a `CommandProbe.cpp` `printf`. It was fixed before the commit; builds B–D passed, and the clean build of record followed.
2. **`gate-attempt1`, BEAM half:**
   - It ran `mix test --warnings-as-errors`. All five suites completed at 618 / 0 and then exited 1, solely on the warnings of four untouched test files (7.4).
   - The gate of record is `beam-gate-attempt2`, in the established form. `beam-gate-attempt1` is the same form on `ff828880`, superseded by the corrections below.
   - The native half of `gate-attempt1` is of record.
3. **`matrix-step-direct-attempt1`** (1 failure):
   - The step-refused check expected the lift's `follow.lift-not-issued-no-read`, while `cmd-m6f.exs` correctly wrote `follow.step-not-issued-no-read`. The behaviour was as designed: the authority refused before transmission, with no read, the budget still 1, and 0 forwards in the journal.
   - The same pattern was found by reading in kit-held. Both were fixed in `ff692019`.
4. **`matrix-step-kit-attempt1`** (16 failures), from two causes:
   - **kit-held:** every sample had exactly one NOT line, `transform-hero-words-vs-entity-translation`. The probe's `at-p` mode seeds the transform words at P but keeps its entity inspection's default hero translation. That is a FAKE-world inconsistency, not a step result. Since `874d404` the matrix names and tolerates exactly that line, in `at-p` mode only; the probe is unchanged.
   - **restore-held / restore-aged:** the kit's `restore-eligibility.py`, adapted in this stage, sliced `-step` but still tested `endswith("-lift")`. So `seq-restore.sh` refused before arming (exit 10), and nothing was armed or issued; the other failures in those phases followed from it. The kit file was corrected.
5. **Superseded passes:** `matrix-step-direct-attempt2` and `matrix-lift-regression-attempt1` both passed with 0 failures at `ff692019`. After them, `relay/lib` (`925e8be`, the verifier's M2 / N6, no behaviour change) and two tools (`656a428`, `874d404`) changed, and every group's tooling table binds those. So the groups were re-run once on `874d404` (`matrix-reruns-NOTE.txt`).
6. **`readiness-attempt1`:** `run_manifest.py prep` raised on the matrix groups' `absent` rows. These are files `follow-matrix.sh` names but a group does not use: the lift kit's `seq-lift.sh` and the M6-F1b old-path kit. No manifest was produced and the gate refused the empty record. The generator now checks each absent path as absent instead of hashing it. A dry run into the scratchpad then showed only the two reuses keyed to the previous `run_manifest.py` invalidated. Both were re-run (`run-rehearsal-attempt2`, `deps-attempt3`) before `readiness-attempt2`, the record of record. `run-rehearsal-attempt1` and `deps-attempt1` / `-attempt2` passed and are superseded.

### 7.6 The M6-G2 kit, rehearsal and offline record

**The kit** (`m6g1-offline\kit\`; 28 files and `SOURCE.txt`, which gives every file's sha256 and source):
- 11 files are byte-identical copies from the M6-F2b and M6-E2 kits; 16 were adapted; `RUNBOOK.txt` is new. The adapted branches:
  - `op.sh`: `step` / `step-follow`; `lift` / `lift-follow` refused; one forward per run; at most two effectful armings.
  - `seq-step.sh` (from `seq-lift.sh`):
    - R3's exact inspection must classify `at_P_exact` against the E2 matrix (`placement.py`, matrix `cd90df8d…`), otherwise it stops before arming;
    - `xcheck --step`;
    - 18 step and 14 follow EVIDENCE lines.
  - `seq-restore.sh`: `--step`, 20 restore EVIDENCE lines.
  - `restore-eligibility.py`: the `-step` label.
  - `ident.exs`: `ident.v2-step-advertised` required at the baseline.
  - The installer group (`r1-install.sh`, `cleanup-m6g2.sh`, `record-check.py`, `run_manifest.py`, `refresh.sh`, `make-readiness.sh`): native5 `f271d129…`, `effectful = true`, the run ids `m6g2-run1` / `m6g2-run1-rehearsal`, and this stage's qualifications.
  - `verify-after.sh`: exactly one v2 step, at most one v2 restoration, no lift and no outfit command; v1 and v2 received-line counts.
- **Exercised end to end** (dry-run mode) by the step-kit matrix group (7.4).

**Installer rehearsal** (`run-rehearsal-attempt2`, **PASS, 0 failures**; scratch copies only, the real installation read and never written):
- **V:** a valid record installs the exact delta; the settings file holds the five reviewed lines with `effectful = true`, and `mods.ini` = `mods.ini.run`. The cleanup then restores the tree byte for byte with the exact 100-ns creation / write ticks, and the original `mods.ini` with `crash_reporting = true`.
- **Refused before any write**, with the scratch sentinels unchanged:
  - P: a wrong pin;
  - X: another readiness tool;
  - Y: a changed manifest;
  - S1 / S2: a stale record;
  - N: a not-ready record;
  - R: another run's record;
  - O: another state root;
  - M: a missing record;
  - I: a changed INI;
  - D: a changed DLL;
  - A0 / A1: the M6-C2 package, before / after the record;
  - **W0 / W1** (new): the native4 DLL in place of native5, before the record (a not-ready record, refused by the gate) and after it (refused at the copy boundary).
- **B:** a late failure rolls back.
- **K:** the sentinel and timestamp comparisons are not vacuous.
- **C:** the real game root and the run's state root are refused.
- **Disclosed:** case V's message still says `effectful = false`, text inherited from the E2 kit. The check on the same line compares against `effectful = true` and passed, and the installed copy reads `effectful = true` (`run-rehearsal-attempt1-NOTE.txt`; attempt 2 is the same script).

**Drift rule** (`deps-attempt3`, 7 / 7): as in 7.4, re-run against the final `run_manifest.py`.

**Offline readiness record (a)** (`readiness-attempt2`): `record-a.json` `e74a68586a9e4c6032d90f8ec3112240b5ed605d1c886547fad103595b24aa0f`, pinned (`record.sha256`), relay commit `874d404c`. **ok, 139 checks:** 126 performed now, 13 reused, 0 cached, 0 FAIL, 0 INVALIDATED. The reuses are the gate's three parts, the three matrix groups, the installer rehearsal, the drift test, and the earlier unchanged qualifications (the guard self-test, the timestamps test, the readiness / placement tests, the content rehearsal), each keyed to the identities it ran with. Seven files a matrix group recorded as absent are checked absent now. The native source scan was performed now: the source changed, so the earlier cache did not hit. The gate passes the pin and refuses a wrong one. Every qualification the M6-G2 installer's `record-check.py` requires of record (a) is present and ok. It qualifies the run; it does not authorize anything, and no installer gates on it. The M6-G2 refresh (`kit/refresh.sh`) would produce record (b) after the operator's confirmation. That is the ONE record the installer gates on.

**The refresh, previewed** (`preview-check-attempt1`, **PASS, 0 failures**; read-only for the game; a scratch confirmation; run id `m6g2-run1-preview`, which the live installer never accepts):
- `kit/refresh.sh` reused record (a) by its pin, made the real pre-install captures and produced record (b)-preview `refresh-attempt1`: ok, 135 checks.
- The installer's binding steps held on its copies: the pin, the tool, the manifest, and record (a) as `readiness-a` names it.
- `readiness.py gate` passed: created after the confirmation, at most 1,800 s old.
- `record-check.py` LIVE refused exactly the one check a preview inside M6-G1 cannot carry, the absent `root-m6g1-offline` (the root was not sealed yet). As the live run id it also refused the run id.
- `relied-on.py`: 32 references verified. The four captures resolve through the gated copy.
- The first refresh that carries the sealed-root check would be M6-G2's own.
- Disclosed: the harness's console message names the E2 root, adaptation text; the check greps the M6-G1 root (`preview-check-attempt1-NOTE.txt`).

### 7.7 The independent check

One independent verifier read the native diff `3b892cad..76c407f3` and the BEAM / tooling diff `b0f9c85d..ff828880` against section 6. It was read-only, ran nothing and delegated nothing. Its report and the disposition are `m6g1-offline\checker-report.txt` and `checker-disposition.txt`.

**No BLOCKER and no MAJOR.** It confirmed by reading:
- the version / mode pairs on both sides, and that no unsupported pair reaches the setter;
- the word-10-only target;
- (name, version) as the capability identity throughout;
- `/2` advertised only under the effectful setting;
- the v1-only peer, effectful-off and transport-v1 refusals;
- v1 unchanged, including historical v1 journals (checked on `m6f2b-run1`'s journal);
- no dynamic atoms;
- one budget shared and never reset on either side;
- the same exact-inspection binding;
- restoration at the plan's version, checked by the authority, by the binding and natively;
- `step-follow` inheriting the bounded and guarded path;
- the sampler unchanged.

| Finding | Disposition |
|---|---|
| M1 (MINOR): two step-blind checks in `follow-matrix.sh` | fixed, `ff692019` (found independently by `matrix-step-direct-attempt1`) |
| M2 (MINOR): `TransformBinding.restore/5` defaulted `version \\ 1` (fail-closed, but a default literal) | fixed, `925e8be`: required and integer-guarded |
| M3 (MINOR): the binding's journal-plan version check was unreached by any test (the authority's record check refuses first) | fixed, `925e8be`: direct tests for a v2 step's plan and a v1 lift's plan |
| N6: stale docs (`restore_candidate/2`, the `cmd-m6f.exs` header; the M6-F2b kit's v1-only received-line count) | fixed, `925e8be` / `656a428`; the M6-G2 kit's `verify-after.sh` counts v1 and v2 |
| N1: natively an effectful protocol-v1 link is not refused; the BEAM authority refuses it, and an effectful run always provisions a token (protocol v2). The native test "a version-1 link refuses v2" proves only the effectful-off decode | recorded; pre-existing, unchanged |
| N2: on the setter-not-called path natively the budget is consumed (`unavailable`) while BEAM does not count `:unavailable`; the next forward is then refused natively | recorded; pre-existing, fails safe |
| N3 / N4 / N5 / N7: no BEAM-side one-restore guard (native enforces it); entry-vs-version unreachable; restore-without-target unreachable; float64 → binary32 cross-check rounding exact for one addition | recorded |

### 7.8 Runtime unknowns (not answered offline)

Not answered offline, and not inferred from the FAKE probe:
- **native5 in HITMAN:** whether the build loads, attaches its one detour and advertises both entries without a WARN / ERROR / FAULT. This is its first runtime use.
- **The engine's answer to the step:** the same-frame post-state of the one setter call with word 10 changed and the parent-relative words that follow, whether the twelve stored words equal the request, and the later samples' classes. M6-F's z results (a return within six frames) do not predict a y result at P: the axis, location, initialization and run context all differ (section 6, item 3).
- **Timing:** the FAKE first sample here (7.4) and M6-F2b's +58 ms are references, not predictions.
- **Visibility:** whether a 0.25 m lateral shift is visible from the operator's view, whether the render follows the stored transform, and what a continuous recording shows. Clearance, floor and NPC occupancy at P + 0.25 y are not measured.
- **Restoration:** eligibility depends on the runtime samples. Whether the engine accepts the preimage again is not established.
- **The writer** of any return, and the candidate's spawn / activation semantics, stay open (M6-E3 13.3); no writer tracing is proposed.

### 7.9 The proposed M6-G2 checkpoint (not authorized)

Prepared and not executed: `m6g1-offline\kit\RUNBOOK.txt`, with the kit pinned by record (a) (7.6). An M6-G2 authorization would need to cover:
1. **Frozen inputs:**
   - the accepted M6-E3 package set (`5ac64848…` / `58e9a10f…` / `9433888b…`);
   - the native5 DLL `f271d129…` with `effectful = true`;
   - the BEAM node started with the authority on and disarmed;
   - `mods.ini.run` `f4f44345…`;
   - record (a) of this stage and its pin;
   - glacier-relay `main` at record (a)'s commit or a docs-only descendant (the refresh's drift rule); ZHMModSDK `76c407f3`.
2. **Before any token, node or installation step:**
   - the operator names an available recording method and its save location, and commits to keeping one continuous recording; no software is installed and nothing uploaded;
   - then a fresh, explicit Ready, recorded verbatim with the capture answer;
   - without the commitment the visual record is not attempted.
3. **R1–R3:** the installation is gated on ONE refreshed post-confirmation record (b). The main menu is native5's first runtime use: both entries advertised, one detour, no WARN / ERROR / FAULT, else stop before Paris. Then one stationary Paris attempt, with R3's exact inspection classified at_P_exact against the E2 matrix, else stop before arming.
4. **R4, the ONE v2 step:**
   - only after the operator's separate step go-ahead, with the framing set and the recording started before issuance;
   - `seq-step.sh`: just-in-time binding, qualification, attestation, ONE arming, `step-follow` with six exact samples (+0, +250 ms, +1, +2, +5, +10 s);
   - the recording runs past the last sample; no fps or synchronization is claimed.
5. **R5:** six separate verdicts:
   1. request and invocation;
   2. the same-frame stored transform;
   3. the later samples with their actual frames and times;
   4. the recorded or reported visual response;
   5. identity and controls;
   6. restoration eligibility.
   A numeric step without seen motion, or a seen shift without matching inspections, is qualified, not attributed.
6. **R6:** at most ONE restoration, at the plan's version (v2), only if eligible and after a separate approval and a fresh arming. Already-at-baseline submits nothing.
7. **R7:**
   - a normal exit;
   - the exact-boundary capture after the exit;
   - the rollback with exact timestamps, the complete baseline and M0 26/26;
   - `verify-after.sh`: exactly one v2 step, at most one v2 restoration, no lift and no outfit command;
   - the sealed manifest; the record appended; then stop for review.
8. **Excluded:** a restart, a second forward, escalation, a camera mod, walking, a collision test, fallback placement, automatic writer tracing or a repeat.

## 8. M6-G1 accepted (bounded) — the review's qualifications

**Authorization:** "Glacier Relay — M6-G1 acceptance and conditional M6-G2 visible-runtime authorization" (2026-10-18). M6-G1 is accepted for its demonstrated offline implementation and validation scope (section 7), with three explicit qualifications, preserved and not repaired:

1. **Test-warning exception.** The original M6-G1 authorization asked for five suites with warnings as errors. The literal `mix test --warnings-as-errors` runs completed 618 tests with 0 failures but **exited 1** on warnings in four unchanged test files: `candidate_inspection_test.exs`, `players_inspection_test.exs`, `transform_binding_test.exs` and `effectful_test.exs`. They are not successful warnings-as-errors test runs. For this bounded runtime decision the documented alternative gate is accepted: application compilation with warnings as errors, then five plain `mix test` passes at 618 / 0, plus the targeted / area and native gates (7.4). The warnings and the failed exit statuses stay in `m6g1-offline\gate-attempt1\`. This is a test-hygiene exception, not permission to suppress future warnings, redefine failing commands as passing, or weaken assertions; no warning-cleanup commit was required before M6-G2.
2. **Fake-world cross-check exception.** The matrix's named at-p FAKE-probe entity / transform inconsistency (`transform-hero-words-vs-entity-translation`, tolerated in `kit-held` at-p only, `874d404c`) qualifies that synthetic cross-check only. It does not invalidate the separately exercised step and restoration paths, and it does not establish the complete consistency of the FAKE world. It is **not** carried into a live run: a real-game disagreement is judged under the runtime control and identity rules. (In M6-G2 run 1 that line read ok in every set: 9.4.)
3. **Stale harness messages.** The rehearsal's `effectful = false` message and the refresh preview's old-root wording are disclosed presentation artifacts; the documented predicates and generated files are the evidence. Sealed outputs are not rewritten and no gate is rerun for wording. The live installed setting is `effectful = true`.

## 9. M6-G2 run 1 — the ONE attended visible-step run (2026-10-19)

**Evidence:** `%TEMP%\glacier-m0\hitmen\m6g2-run1\` (claimed 2026-10-19T02:37:17Z with the state root `~/.local/state/glacier-relay-m6g2-run1`; 362 files; manifest `sha256.txt` `8690100871411cce7324a03c4aa4a01e0909cb28f6810d874d2c07ed19d29cd3`, written last after every writer stopped; sealed). The analysis is `verdicts.txt`; the operator's words are verbatim in `operator-confirmation.txt`, `checkpoint-reply-1.txt`, `checkpoint-reply-2.txt` and `operator-observations.txt`, kept separate from the tool-runner's analysis.

### 9.1 Inputs and preparation

- **Frozen identities** (section 1 of the authorization), verified by `precheckpoint.txt` (PASS, every check ok) before the checkpoint: glacier-relay `main` `f155dc88` (clean, = origin; drift from record (a)'s commit `874d404c`: `docs/` only); ZHMModSDK `relay/m2` `76c407f3` (clean; native commit `06a2c48c` its parent); the M6-G1 seal `b65c87ff…` (4,566 entries, no unlisted file) and the M6-E2 seal `2ef6a0a8…` re-verified; native5 `f271d129…` (11,069,952 B), checked different from native4; the visual-placement `chunk0patch300` `5ac64848…`, checked different from the M6-C2 origin package; `chunk27patch300` `58e9a10f…`; `packagedefinition` `9433888b…`; matrix `cd90df8d…`; `mods.ini.run` `f4f44345…`; record (a) `e74a6858…` gate PASS (139 ok); the game at its complete baseline, M0 26/26, no process, port or token.
- **The checkpoint** (`checkpoint-presented.txt`, 02:41:47Z) disclosed native5's first load, the first y step at the placed candidate, the unmeasured clearance / collision / streaming / NPC effects, a possible effect after a crash or timeout, gameplay consequences not undone by a restoration, token possession not being process identity, SDK Sentry reporting off and engine / OS reporting unestablished, dump sensitivity and the logical token deletion.
- **The recording plan.** The operator's first reply was "Ready" alone; the run paused before anything was written (`checkpoint-reply-1.txt`). The operator then proposed Xbox Game Bar; a read-only check found it installed with capture enabled and the default folder present, and the operator made a short test recording. The confirmation (03:04:40Z) names Xbox Game Bar, `C:\Users\steve\Videos\Captures`, the commitment "I commit to retaining one continuous recording from before the step through the last sample.", and the Ready. No software was installed and nothing was uploaded.
- **R1.** Record (b) `refresh-attempt1\record-b.json`, pin `edef5b5d5978c1bbb667bb08fe3248621cc4a5d2f3242fca83835aac09dce79c` (136 ok: 135 performed now, 1 reused — record (a)), created after the confirmation; the token (03:09:34Z); the node with the authority on and disarmed (03:09:36Z); ONE installation gated on that record (03:10:13Z, `r1-install-attempt1`): the delta exactly the authorized set, `GlacierRelay.ini` with `effectful = true`, `mods.ini` = `mods.ini.run` (crash reporting off for the run), backups and exact Windows timestamps captured.

### 9.2 R2 — native5's first runtime use (main menu)

HITMAN started 03:12:30Z. The native log (`relay-20261019-031224-63092.log`) shows the module attached, ONE detour (`ZAchievementManagerSimple_OnEventSent`, read-only), protocol v2 welcomed with 9 allowlisted entries, and the effectful allowlist naming `candidate.transform.set/1` (lift | restore) and `/2` (step_y | restore) behind the one shared forward ledger; 0 WARN / ERROR / FAULT. The authority advertised exactly the documented 9 capabilities (`ident.v2-step-advertised` ok); token verified; effectful enabled and disarmed; forward budget 1; audit intact. The inert menu reads found the candidate absent, as expected (xcheck 13/13). No effectful negative test was sent.

### 9.3 R3 — the visible starting context (Paris)

One Paris attempt, Agent 47 stationary; `mission.playing` rose 03:19:13Z. `r3-ct` (frame 74351) classified **at_P_exact** against the package's decoded matrix: world words `c2b2fae1 416d47ae bfc2d6ba` with the identity rotation, the parent-relative translation bit-equal, not dirty, the local hero's start inside the earlier spread. Agent48 `feede715906f747f` in brick `007c57a6ea581f8c`: ZHitman5, the authored character id, flags 3, distinct from the local hero `69bdf7f855ea15e0`, spatially distinct, not in the registry (slot 0 local, slots 1–3 empty); xcheck 16/16. The operator framed the figure with the mouse only and started the Game Bar recording ("Recording started"); the step go-ahead was requested only after that.

### 9.4 R4 / R5 — the ONE v2 step and the six findings

The operator's separate go-ahead, verbatim: "Go ahead with the step" (03:24:54Z). `seq-step.sh` (exit 0): identity SAME; the just-in-time binding inspection `r4-ct` (frame 95269) bit-equal to R3 (xcheck 18/18); the telemetry attestation (adapter `d8190690-…` from the session log and the native log, agreeing with the command link's); ownership `exactly_one_hitman`; ONE arming; `step-follow`.

1. **Request and invocation.** Exactly one `candidate.transform.set/2` mode `step_y`, command `2448303c-8a81-494a-9209-cae140807738`, bound to the authority-verified inspection at age 28.3 s of 60 s; journal ladder effectful_consumed → accepted → transmitted → received → terminal **applied** (frame 97990, native 03:25:31.818Z); setter called, invocation completed, pre-call line written; 18 / 18 step EVIDENCE lines ok.
2. **Same-frame state.** The applying frame's postimage equals the requested bits: only world word 10 changed, `416d47ae` → `417147ae` (y 14.83 → 15.08 m); x, z and the nine rotation words copied bit for bit; parent unchanged; clean; same entity.
3. **Later sampled state and timing.** All six slots ran (one in flight, no catch-up, none missed) and read **held** (bit equality with the postimage): +5 frames / +52 ms, +30 / +309 ms, +104 / +1,053 ms, +202 / +2,059 ms, +495 / +5,052 ms and +986 frames / +10,059 ms native; requests 0.8–2.9 ms after their planned offsets, round trips 55.9–60.4 ms; the journal's classes agree. A later just-in-time snapshot (frame 124377, about 4.5 min after the step) still read held. This is agreement at the sampled frames only: it is not continuous persistence and it identifies no writer.
4. **Recorded and reported visual response.** The operator, verbatim: "I witnessed as agent 48 translated immediately from one space to the next without any sort of animation present. The camera was not moved from its original location, and the movement was instantaneous. The recording has ended." The continuous Game Bar recording is retained: `operator-media\step-recording-HITMAN 3 2026-10-18 20-23-41.mp4`, 220,254,716 B, sha256 `b959fc534cc3004a5edbb31f38a71c2d13e60f4ad8fbdfdbe03329ff51c7051e` (the source kept in the operator's folder). Its file times (start 03:23:41Z by name, last write 03:26:40Z) bracket the step and the last sample; no video / game-frame synchronization is claimed, and the tool-runner did not open or analyse the video. The F12 stills requested before and after the step are not in evidence. The reported jump is the visual report of a direct transform write, not walking or animation.
5. **Identity and controls.** Identity SAME at every check (node, authority, journal, link generation 1, adapter); the candidate's identity, distinctness and registry absence unchanged in every Paris set; mission generation unchanged; the local hero's world translation words bit-equal in every set, his rotation words alternating by 1–2 ULP between sets (recorded as within tolerance, not equality; never attributed to the setter; the step's own hero control "unchanged"). Every xcheck 0 NOT; 531 EVIDENCE lines ok, 0 NOT. The at-p FAKE tolerance of 8.2 was not used.
6. **Restoration eligibility.** Eligible: the schedule complete, the last slot held and journal-agreed, R4 done, no stop marker.

### 9.5 R6 — the ONE v2 restoration

The operator's separate go-ahead, verbatim: "Go ahead with the restoration" (03:29:50Z). `seq-restore.sh` (exit 0): sample s5 was 253 s old, so ONE just-in-time snapshot (`r6-jit-ct`, frame 124377) was taken solely for the 60 s window — held, bit-equal to s5, xcheck 23/23; the planner's plan (version 2, target the journaled preimage); fresh attestation; the second and last one-shot arming; ONE `candidate.transform.set/2` `restore`, command `a0a09f03-8b65-4b05-abc5-0485c8407130` (`restore_of` the step), bound at age 43.8 s of 60 s, terminal **applied** (frame 128639); 20 / 20 restore EVIDENCE lines ok. The later exact observation (`r6-post-ct`, frame 129930) against the pre-step binding inspection: world bit-equal (y 14.83), parent-relative bit-equal, parent equal, dirty clean → clean, all 20 candidate fields identical, registry unchanged; the restoration's own later class held. No new recording was confirmed for the restoration: its visual coverage is **missing**, recorded, and not retried. Restoring the transform values does not undo gameplay consequences.

### 9.6 R7 — exit, boundary, rollback

The operator exited normally ("Closed"): `mission.playing` fell 03:31:53Z, `contract.ended` published 03:31:56Z, the link closed (`peer_closed`) 03:32:09Z, HITMAN exited 03:32:15Z. `cap-final` was taken at the settled boundary (8 records, 8 durable, 0 pending, link closed) before the node stopped; the fresh-node replay at that boundary holds in every comparison; the three-way reconciliation passes. The native log is 106 lines, INFO only; it ends at the main-menu load (the benign shutdown notice did not appear). The mechanical rollback (`cleanup-attempt1`) removed the packages, the DLL and the settings file and restored `packagedefinition.txt` and `mods.ini` with their exact Windows timestamps; the complete baseline verified twice (cleanup and `verify-after-attempt1`), M0 26/26, the hitmen ids absent from 145 package indexes, the token in 0 scanned files and its file removed (logically; no secure-erasure claim), no process or port, 0 new crash-dump files. The 35 relied-on references, the native5 artefacts and the installed package set are unchanged.

**Counts** (journal `a4cbe74e-…`, 92 entries, contiguous, closed): v2 steps **1**, v2 restorations **1**, v1 lifts 0, outfit commands 0; effectful armings 2, consumed 2; refusals 0, unknown 0, anomalies 0; 17 commands, all applied (11 exact transform inspections, 4 inert players / entity reads, the step, the restoration).

**Disclosed presentation artifacts** (sealed-kit wording; the checks test the right values): the installer's line "installed DLL bytes = the native4 build of record" (it checks native5's `f271d129…`); `verify-after.sh`'s "lift / restore results 1 (expected 0)" (M6-E3's inert expectation; the 1 is the approved restoration); "token-named paths 27 (pre-run 13)" (an inherited constant; file names of check outputs such as `no-token-files.out`, one added by this run; the value scan found 0).

### 9.7 What this run does and does not establish

- **Established, for this run:** native5 loads and advertises both setter versions in HITMAN; ONE compiled +0.25f world-y write through the one setter applied exactly on its frame; the stored transform agreed with it at six sampled frames over 10 s and again about 4.5 min later; the operator saw and the recording retains an instantaneous, animation-free shift of the visible Agent48 with the camera unmoved; ONE evidence-bound v2 restoration returned the stored transform bit-exactly to P; the game was restored byte-for-byte.
- **Not established:** continuous persistence between samples; what the render did between the reported frames, beyond the operator's report and the retained video; any writer or mechanism behind the M6-F z return versus this held y step (different axis, location, content and run: no causal comparison is made); clearance, collision or NPC effects at P + 0.25 y; any gameplay consequence; walking, animation, control or multiplayer behaviour.
- **Hard stop.** One step and one restoration were the run's whole effectful budget; no repeat, second deployment, activation, pathing, input injection, registry / physics / controller change, collision test, writer tracing, networking expansion or tag. M6 is not complete. Next: review of this record.

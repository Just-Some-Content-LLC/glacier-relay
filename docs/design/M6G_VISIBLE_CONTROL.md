# M6-G — One bounded, observable external action on the visible Agent48 (design, 2026-10-18)

**Status:** design only, from read-only source examination. Nothing implemented, built, generated, installed or launched; no token, no command. M6 is not complete; nothing is tagged.

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

# M7-B2 — the native side of the motion contract, offline (record)

**Status:** DONE offline (2026-10-19); **accepted** for its demonstrated offline scope (section 13, 2026-10-20).
- Native6 is a **build of record only**: never installed, never loaded in HITMAN, not an accepted runtime artefact. No tag was created or moved.
- Every engine answer in this stage came from the FAKE transform world of the native tests and the command probe. That is FAKE-engine evidence: it shows what the native code does with the values it reads, never what the engine does with the call.
- M7 is not complete. A synthetic headless peer is not a second game, a numeric box is not a cleared route, and a compiled DLL is not proof that it loads or runs correctly in HITMAN.

**Authorization:** "Glacier Relay — M7-B1 acceptance and M7-B2 native offline implementation". M7-B1 is accepted with this stage for its demonstrated scope (`M7B1_OFFLINE_RECORD.md` section 12).

**Contract:** `M7_NETWORK_GHOST.md` sections 15 and 17 (17 governs), ADR 0010 with amendments 1–13, and `M7B1_OFFLINE_RECORD.md` 11.7 (the B2 delta). Nothing in the contract was widened; the implementation choices inside it are in section 4.

**Evidence:** `%TEMP%\glacier-m0\hitmen\m7b2-offline\` (guarded; sealed after this record).

## 1. Basis, commits, artefacts

**Checkpoint** (`checkpoint-checks.txt`, PASS, read only):
- glacier-relay `b6d4b4f` = origin, clean; its parent `6d33f1d` is the B1 correction's gate source, and the relay tree `da39d5e4` is unchanged by the docs commit between them;
- ZHMModSDK `relay/m2` `76c407f3` = origin, clean; the last production change `06a2c48c`; the M6 tag objects on both repositories unchanged;
- native5 `f271d129…` (its manifest verifies), the content `5ac64848…` / `58e9a10f…` / `9433888b…`, by identity;
- the seals of M6's closure, M7-A, M7-B1 (re-verified 36 / 36) and the B1 correction (re-verified 60 / 60);
- M0 26 / 26; no game process; no project port; epmd observed (pid 45286), not changed.

No content rehearsal, historical audit, media review or native5 requalification was repeated; no integrity trigger arose.

**Commits** (ZHMModSDK `relay/m2`, on `76c407f3`; all changes under `Mods/GlacierRelay`):

| Commit | Content |
|---|---|
| `d503678a` | the motion protocol: `MotionProtocol` (the 4750 codec), `Attestation::MotionAttestMac`, the two motion-gated command entries, the command link's `motion` option and `AttestedGeneration` |
| `0b6bcac6` | `MotionLink`: the outbound loopback client and its bounded queues |
| `17887d08` | the enforcement: `Motion::Controller`, `TransformApply` (`IdentityFailures`, `CommonGate`, `ApplyMotionRestore`, the M6 gate's `motion_holds`, `Ledger::restore_confirmed`), the scheduler's dispatch and exclusion, the plugin's `[motion]` wiring |
| `55efad1c` | five native test suites |
| `41fbd800` | the command probe's motion mode (tests only); **the immutable draft the verifier reviewed** |
| `3bf1d72c` | the verifier's corrections (section 8) |
| `8129d721` | the verifier's findings as reproducers, and the two tests whose expectations the corrections change |

`3bf1d72c` alone does not build the test and probe targets: the link interface gained `ControlRoom`, which the fakes implement in `8129d721`. The history was not rewritten. The intermediate commits before it were not built individually; the gate covers the final tree.

The BEAM is **unchanged**: the relay tree is still `da39d5e4`. No BEAM correction was needed for interoperation.

**Build of record native6** (`native6\`, `artifacts.sha256`; clean build `build-clean6`, `-j 1`, on `8129d721` with 0 uncommitted changes):

| File | SHA-256 |
|---|---|
| `GlacierRelay.dll` (11,396,096 B) | `91a7098f0189bfc1b7c30903aac7a690cda27e931857d9fba7e709410099ecf7` |
| `GlacierRelay.pdb` (36,466,688 B) | `071b94ced532480cc090673aefda75c7cfa09efb52bd3fb8d01092d9b4d40488` |
| `GlacierRelayTests.exe` (7,798,784 B) | `633e79c6e6f0b9e00b82723e5f2fdc79605587c42648e6f90839c78317d4c03b` |
| `GlacierRelayCommandProbe.exe` (4,280,832 B) | `8315c6d185b487b41826131933d1fa28cd0d5ea75c3987dd26d175cda74b033f` |
| `GlacierRelayWireProbe.exe` (4,170,752 B) | `3b680472ef6c6c5190e08c510e498639a60b0b0f59bff657caf69157689d111f` |

## 2. The native implementation map (contract → code → test)

| Contract (design 15, 17) | Native code (ZHMModSDK `Mods/GlacierRelay`) | Proven by (native suites; end-to-end scenarios) |
|---|---|---|
| 15.5 binding: hello naming the current token-verified command link; welcome; attest = HMAC(token, `motion\|nonce\|mg\|cg\|adapter`); the binding lives only with that command link and that connection | `MotionLink` (`Handshake`, `Loop`'s command-link check, `Disconnect`); `Attestation::MotionAttestMac`; `CommandLink::AttestedGeneration` | MotionProtocol (BEAM's own MAC vector), MotionLink (binding, refusal, timeout, invalid welcome, command-link change, new serial); `binding`, `wrong-token` |
| 15.6 bounded transport: 1,024-byte lines and partials, strict decoding, bounded queues, the 200 ms motion send deadline | `MotionProtocol::DecodeFromBeam`; `MotionLink` (`k_InboundCapacity` 16, `k_ControlCapacity` 32, `k_SampleCapacity` 8, `SO_SNDTIMEO`) | MotionProtocol (every kind, 22 bad lines, edges), MotionLink (seven violations, the send deadline against a socket nobody reads) |
| motion off = M6 | `CommandLink` advertises the motion entries only on a motion version-2 link; `CommandProtocol` decodes them only with the settings; nothing of the motion path is constructed with `[motion]` off | MotionProtocol `Advertisement` (the literal M6 list); `motion-off`, `m6-motion-off` |
| 15.4 / 15.5 share: the local hero only, finite, no catch-up, autonomous stops, bounded output | `Motion::Controller::Share` / `StepShare` / `CloseShare` | MotionShare (open, refusals, cadence, gap, dirty, full queue, stops); `share` (native ↔ host trace ↔ sink, value for value) |
| 15.3 / 15.5 / 17.4 session admission without a setter call; the opening snapshot; the limits | `Controller::OpenSession` (`CommonGate`, `IdentityFailures`, the expectations, the M6 ledger, the budget, the retained record) | MotionSession `Admission` (16 refusals, budgets, ids) |
| 17.1 / 17.4 time on the native clock: deadlines first, the re-check before the call | `Controller::Step` (deadlines at the post-drain time → bindings / transitions → messages → share → session); `Dispatch` (a target stamped at or after a deadline never accepted); `ApplyPending` (the checked line, then signal / bindings / latch, and the clock last) | MotionSession `Time` (at / before / after every deadline; the write delayed across a deadline; a close during the write); MotionVerifier F1; `stall`, `beam-pause` |
| 15.5 per-frame pre-call checks; the untouched words; the reference; area and displacement inclusive, no exemption | `ApplyPending` | MotionSession `Application`, `FrameChecks` (exact binary32 edges on both axes and directions; equality at a representable bound; 12 refusals; 6 transitions) |
| 15.5 the first uncertain post-call result ends application | `ApplyPending` (the post-read classification) | MotionSession `PostCall` (11 classes); `inexact` |
| 15.4 / 17.4 close: no arming, never behind traffic; a pending target accounted; a qualified final snapshot; a close for a closed session harmless | `Dispatch`, `CloseSession` | MotionSession `Time`, `Evidence`; `stall` (BEAM's close for the closed session) |
| 15.5 acknowledgements and reports that reconcile with BEAM's checks (superseded 0) | `Ack`, `MaybeReport` (one per frame at most) | MotionSession `Application`; `session-restore` (every ack and report equal to BEAM's trace records; every report `agrees`) |
| required evidence that cannot be delivered; room for a call's evidence | `Controller::Control` / `Condemn` (`m_EvidenceLost`, the condemned serial, `Drop`); `IMotionLink::ControlRoom` ≥ 2 before a call | MotionSession `Evidence`; MotionVerifier F2, F5 |
| 15.4 exclusivity, budgets, the retained record, `confirm_baseline` | `HoldsTransform` / `RecordBlocks` / `RecordAtBaseline`; the scheduler's `motion_holds` and `NoteInvocation`; `TransformApply` `Reason::MotionSessionHeld`, `Ledger::restore_confirmed` | MotionRestore `Exclusion` (the real scheduler), `OneCallPerFrame`, `M6RestoreConfirmation`; `baseline-then-m6` |
| 17.2 the restoration result | `TransformApply::ApplyMotionRestore` (the M6 result's `Facts` / `AppendFacts` / `Reduce`) and `RestoreSession` | MotionRestore `Restoration` (every field; 11 refusals; 5 attempted-without-proof classes; proven non-application); `session-restore` (BEAM judged `restored`) |
| the identity rule shared with M6 | `TransformApply::IdentityFailures` (steps 1–3 of `EvaluateTransform`) | MotionRestore `IdentityRuleIsM6s` (16 variants, rule for rule) |
| link loss, BEAM termination | `Step`'s binding check; `MotionLink::Disconnect`'s signal | MotionSession `FrameChecks`; `link-drop`, `beam-kill` (the native log's order) |

## 3. Frame, thread and clock ownership

**Threads.**
- **The game's frame thread** (`OnFrameUpdate` → `ObserveFrame`): the scene and lifecycle observation and `RelayFrame::Process` first, then `ScheduleCommand` (at most one command), then `Motion::Controller::Step`. Every engine read and the one setter call of the motion path happen here and only here: the read-only inspector (`InspectCandidateTransform`, guarded) for samples, final snapshots and baseline checks; the transform applier (`EngineTransformApplier`: `Observe` → `Invoke` → `ReadBack` → `Release`) for the session's targets and the motion restore. The candidate and the local hero are resolved afresh on every frame of use; the applier's handles are released on every path before the frame ends.
- **The motion link's network thread** (`MotionLink::Loop`): connect, bind, read, decode, copy values into the inbound queue, write the queued lines. It includes no engine header (the gate's source scan) and touches no frame-thread state: the two threads meet only in `MotionLink`'s mutex-protected queues, binding and statistics, and in the `Signals` counter (advanced under that mutex with the message it signals).
- **The command link's network thread** (unchanged) and the telemetry sink's (unchanged).

**No socket work on the frame thread.** The frame thread only queues lines (`SendControl`, `SendSample`, each a bounded `push_back` under the mutex) and reads values. It never waits on a socket or an acknowledgement.

**The clock.** One native monotonic clock: `steady_clock` milliseconds, the same function for the frame's `now_mono_ms`, the re-read immediately before a call, and the link thread's receipt stamps. BEAM's clock is never read, compared or subtracted; `native_mono_ms` on the wire is this clock.
- The session's reference instant is the **opening frame's** native time (`opened_ms`).
- **Duration:** closed when `now ≥ opened_ms + duration_ms`.
- **Target silence:** closed when `now ≥ silence_ref + silence_close_ms`, where `silence_ref` starts at `opened_ms` and is refreshed **only** by a target of this session, on this binding, with a sequence number beyond every earlier one, stamped by the link thread before both the duration and the silence deadline, and accepted into the empty pending slot — to that target's **receipt time** (the link thread's stamp, never later than the frame). Nothing else refreshes it: not a duplicate, an older or a foreign target, not a refused one, not a close, a report or any other line.
- **Apply interval:** a call only when `now ≥ last_call + min_apply_interval_ms`; skips do not count as calls.
- **Order on every frame:** (1) the deadlines, at a processing time read **after** the inbound drain (the later of the frame's time and the clock), so every drained target was stamped no later than it (verifier F1); (2) the bindings and the transitions; (3) BEAM's messages in arrival order; (4) the share's sample; (5) the session's pending target, then its report; (6) evidence that could not be queued ends the session.
- **Immediately before the call**, after the checked pre-call line: the cancellation signal (any close or binding end queued since the frame's drain) is compared, and if it moved the new messages are processed first and the target waits; both bindings and the latch are re-checked; then — last (verifier F7) — the clock is read again and both deadlines are applied.
- **A stalled frame callback** runs nothing off the frame; on its return step (1) applies first.
- **Not claimed:** the last check does not make the engine call atomic; a process fault inside the call is the existing fail-stop (no terminal result is guaranteed); the game is not a real-time system.

## 4. Implementation choices inside the contract

- **One pending slot, refused rather than superseded.** BEAM keeps one target in flight and its report check requires `superseded` 0. A second target while one is pending is therefore a BEAM violation: the native refuses it (`pending_slot_occupied`), acknowledges the pending one `refused / session_closed`, and ends application. `superseded` exists in the reports and stays 0. (The B1 fake supersedes silently; BEAM ends the session either way.)
- **An inexact postimage is acknowledged `uncertain`**, with the observed x / y words and `exact: false` (the fake answers `applied` with `exact: false`). BEAM's counters then agree: the target is uncertain, never applied.
- **The current x / y must equal the reference.** Section 15.5 names every word except x / y. The native also requires the current x / y to equal the reference (the last exact postimage, else the opening snapshot): an unexplained horizontal change is refused (`position_changed`), never written over. This is what makes a `skipped_identical` claim an observation of the frame's read, not an assumption.
- **The displacement cap is `max_speed × credit`**, as 15.5 states. BEAM's own allowance is the smaller `speed × min(Δr, credit)`; the native is its independent backstop.
- **Boundaries, in double over the exact binary32 values:** `|t − anchor| ≤ half_extent` per axis and `√(Δx² + Δy²) ≤ cap` (inclusive). A target exactly at a representable bound (0.125 m) is inside; one binary32 step beyond is not.
- **A missing hero read is no sample.** The share consumes the sequence number, so the sink sees a gap; a dirty read is sent with `dirty: true`. No catch-up: after a slow frame, one sample, then the next one interval later.
- **The share admits only the local hero** (registry slot 0, read through the established stored-field reads of `ObserveCandidateTransform`), never the candidate (`hero_is_the_candidate` when the hero's authored id is the candidate's or the lookup returns it).
- **Close reasons** are BEAM-compatible text: `duration`, `target_silence`, `beam:<reason>`, `refused:<code>`, `uncertain:<reason>`, `motion_link_lost`, `command_link_lost`, `evidence_undeliverable`, and the transitions (`mission_not_playing`, `generation_changed`, `transition_epoch_changed`, `scene_changed`, `frame_thread_changed`).
- **`[motion] max_sessions`** (1–4, default 1) is the native's per-process session budget; it is never reset.

## 5. Exclusion, records, restoration

**The native record** of the last session: `restorable` (closed clean with a qualified final snapshot, its `ghost.closed` queued, never invoked upon by a restore), `restored`, or `invalidated` (an unclean or unreported close, an attempted restoration without proof). It persists for the process, across reconnects.

**The M6 exclusion.** The scheduler asks `HoldsTransform` before every `candidate.transform.set` apply. It holds while a session is open or its record is retained unreleased; the M6 gate then refuses with `motion_session_held` (both versions, forward and restore). A motion open is refused while an M6 forward consumed its budget without a restoration confirmed on its own frame (`Ledger::restore_confirmed`: effect changed, world `target`, control unchanged), while a session is open or retained, or once the budget is spent. **At most one setter call per frame** across both paths: the scheduler notes its call, and the session defers to the next frame.

**`confirm_baseline` without a release command.** BEAM's `confirm_baseline` is a journal release with no engine write and no command. The native meets it by observation: a `restorable` record is released when an exclusive operation's own frame read (the M6 command's, or a motion open's) shows the candidate at the session's opening preimage — all twelve world words, clean, the same parent and generation. Nothing is written for it, no budget changes, and an invalidated record is never released this way (`baseline-then-m6` end to end).

**The restoration** (`candidate.motion.session/1` `restore`; design 17.2) is `TransformApply::ApplyMotionRestore`. Its result reuses the M6 transform result's encoding (`AppendFacts`, `Reduce`, `MandatoryResultFits`), so it carries exactly the 17.2 names: `mode`, `restore_of`, `requested_world_words`, `postimage_world_words`, `world_match`, `postimage_local_words`, `postimage_parent`, `postimage_dirty`, `post_same_entity`, `generation_post`, `hero_control`, `setter_called`, `effect`.
- **Before the call:** the common gate; the identity rule; the fresh expectation groups; the record — restorable, `restore_of` = the open's command id, the target = the opening preimage (never a caller's target), the current words = the native close's final words, the opening parent, the session's generation, the same command link; no other session open; the capacity.
- **The call:** the checked line, the command link re-read after it, then one `Invoke` of the opening world matrix. The parent-relative words are observed and reported, never written or required equal.
- **The record afterwards:** `restored` only when every same-frame fact held natively (called, effect changed, world `target`, same entity, generation, parent, control unchanged, local words observed); an invocation without that proof **invalidates** it (no second restore, no baseline release); a proven non-application (refused, the line unwritten, the link changed at the call, the setter unavailable) leaves it `restorable` and reports `setter_called` false and effect `none`.
- **Native looser than BEAM? Never in this direction:** native `restored` implies BEAM's `judge_restore` would say `restored` (the verifier checked this). The native can be stricter. It cannot know BEAM-only reasons (`ack_timeout`, `report_disagrees`) or a `ghost.closed` lost after it was queued; BEAM gates issuance there.

## 6. Bounded I/O

| Bound | Value | On reaching it |
|---|---|---|
| a line from BEAM; a buffered partial | 1,024 B | a violation: the link closes |
| inbound messages not yet drained | 16 | a violation (BEAM keeps one target in flight) |
| queued control lines | 32 | refused; the binding is condemned and the session ends `evidence_undeliverable` |
| room required before a setter call | 2 control lines (its acknowledgement and a close) | no call; the binding is condemned |
| queued samples | 8 | the newest refused and counted |
| lines written between two reads | 4 | the next read |
| a write | the 200 ms send deadline (`SO_SNDTIMEO`) | the link drops; the session closes on the loss |
| reconnect | backoff 1 s doubling to 30 s, reset only after 5 s bound | — |

The worst case of every native line (`MotionProtocol::WorstCaseLineBytes`, measured by the tests): `motion.hello` 159, `motion.attest` 279, `hero.sample` 242, `share.closed` 557, `ghost.applied` 665, `ghost.report` 436, `ghost.closed` 746 bytes — all within BEAM's 1,024. The motion command results (the share's, the session open's, the restore's) pass the scheduler's `ReduceToFit` and `WithinLineBound`, as every result does: a result that still does not fit the command protocol's 4,096 bytes is withheld and counted (`unbounded`), never sent oversized; the restore builds its result through the M6 reduction (`Reduce`, `MandatoryResultFits`). The tests check that the open and restore results they produce fit; their **worst case is not measured** (unlike the M6 results'), and no test reached a reduction of a motion result.

## 7. Offline proof

**Native suites** (`GlacierRelayTests.exe` `633e79c6…`; the gate ran it 25 times: **25 / 25 passed, exit 0 in 25 / 25**, after the build of record's own run). The new suites are MotionProtocol, MotionLink, MotionSession, MotionRestore, MotionShare and MotionVerifier, with 54, 43, 87, 56, 35 and 19 `CHECK` sites (294); every M2–M6 suite runs in the same executable, unchanged, and passes. The harness reports failures, not the number of checks executed (several sites run in loops). Measured in every run: the worst-case line sizes (section 6), and the send deadline against a socket nobody reads: dropped after **235–256 ms** across the 25 runs (`SO_SNDTIMEO` 200 ms plus the poll).

**Mutation check** (development, not of record): four deliberate source mutations of the session's bounds and the restore's invalidation (`dev-4-mutations`); three were caught. The survivor turned the area check's `>` into `>=` on x and could not be caught, because a test boundary at 0.1 m is not representable in binary32, so equality never happened (`dev-5-area-mutation`). Exact-equality cases at a representable bound (0.125 m: a 125 mm half extent; speed 1,250 × credit 100) on both axes and in both directions were added; the mutation was then caught (`dev-6-area-mutation`). The source was restored from copies taken before the mutations, and the draft was committed from it.

**End to end, the matrix of record** (`matrix-attempt9`, `run-matrix.sh` with native6's `GlacierRelayCommandProbe.exe` `8315c6d1…`): the real native motion link and controller in the probe, the B1 BEAM host (glacier-relay `b6d4b4f`, relay tree `da39d5e4`), and the headless peer in a second OS process. Throwaway credentials were provisioned in the ext4 state root (mode 600, never printed) and shredded afterwards. **13 / 13 scenarios, 82 / 82 checks:**

| Scenario | Checks | What it shows (native ↔ BEAM) |
|---|---|---|
| `binding` | 7 | the motion link bound to the current token-verified command link (same adapter, command generation, motion generation); the welcome lists both motion entries; one binding, no violation; no token in the probe's output |
| `motion-off` | 5 | no motion link without the setting; the welcome is exactly M6's |
| `m6-motion-off` | 7 | the M6 v2 step and restore applied exactly with motion off; the welcome is M6's; the M6 ledger forward and restore |
| `wrong-token` | 5 | the command link not token-verified, so no motion binding: native connects 0 |
| `share` | 10 | 15 samples relayed, 0 gaps; **every relayed and every sink sample equal to the native's line, value for value** (15 / 15); dirty samples labelled; `share.closed` names what it queued; the share closes `native:duration`, confirmed; the hero moved, the candidate did not; no setter call |
| `session-restore` | 12 | 8 targets applied, closed `operator` (confirmed by BEAM); **every acknowledgement equal to the native's line value for value (31 / 31)**; every report agrees (6); the host's native close is the native's `ghost.closed`; the restoration judged `restored` with every 17.2 fact; the candidate back at the opening preimage; exclusivity released |
| `baseline-then-m6` | 7 | course complete, closed at baseline; BEAM submits no restore (`already_at_baseline`) and releases without a write; the native released its record on the M6 command's own frame read; the M6 step then applied |
| `inexact` | 6 | the first inexact postimage closes `uncertain:postimage_mismatch` (applied 3, uncertain 1); never restorable; acknowledgements 24 / 24 equal |
| `stall` | 6 | a frame stall: BEAM closes on its own deadline (`ack_timeout`, unknown); the native closes on its own clock, with no call after the stall; BEAM's close for the already-closed session is harmless |
| `z-drift` | 4 | an untouched word (z) changed before a call: the native refuses without a call (`untouched_word_changed`; applied 3, skipped 20, refused 1); BEAM closes on the refusal, confirmed |
| `beam-pause` | 4 | BEAM paused mid-session: BEAM ends the session `stall` (unknown); the native stops on its own clock |
| `link-drop` | 4 | the motion link dropped: BEAM `link_lost` (unknown), the native closes on the loss |
| `beam-kill` | 5 | the BEAM node halted mid-session: the native closes on its own; **3 calls, 0 after the loss** (by the native log's order); the probe ends at its failsafe |

The same matrix ran twice in development: `matrix-attempt7` on the draft `41fbd800` (13 / 13) and `matrix-attempt8` on the corrected development build (13 / 13). Attempts 1–6 failed on driver defects (section 12).

## 8. The one focused verifier

One independent, read-only verifier reviewed the immutable draft `41fbd800`, limited to native thread ownership, expiry and cancellation, bounded I/O, and restoration and exclusion (`verifier-basis.txt`). Its report is `verifier-report.txt`, verbatim: **1 blocker, 3 minor, 6 notes**, no crash path. Every boundary was otherwise found sound, including: no engine access off the frame; every handle released on every path; signals ordered with their messages; native `restored` never looser than BEAM's judgement; motion off leaves M6 exactly as it was.

Every finding with a testable claim was **reproduced on the unchanged draft first** (`verifier-findings\before-fix-verifier.log`: 12 checks failed, each control passed), then corrected in `3bf1d72c` and pinned in `8129d721` (`verifier-disposition.txt`, with a NOTE correcting one attempt number in it):
- **F1 (blocker), confirmed:** the frame's time was taken before the inbound drain, so a target the link thread stamped at the silence deadline could be accepted, refresh the silence clock and be applied after the deadline (`invokes 1` on the draft). Now the processing time is read after the drain, and a target stamped at or after either deadline is never accepted.
- **F2 (minor), confirmed:** a `share.closed` that could not be queued dropped the link but did not stop the session's call on that binding. Now a binding whose drop the controller requested is condemned: no call, no admission, no line.
- **F3 (minor), confirmed:** a close's final snapshot was qualified without the session's generation, parent or local hero. Now it must be the session's own candidate, else the close is unclean.
- **F4 (minor), confirmed:** the motion restore re-read the command link before its checked line, not after. Now it re-reads it immediately before the call (the M6 apply's accepted order is unchanged).
- **F5 (note), confirmed:** a call was made even with no room left for its acknowledgement. Now a call needs room for its acknowledgement and a close.
- **F6 (note), confirmed:** a record stayed restorable after a close BEAM never received. Now it is invalidated, as BEAM's `close_unknown` is.
- **F7–F10 (notes), applied:** the clock is the last check before the call; no logging under the link's mutex; the backoff resets only after a stable binding (tested); bounded flush bursts with the drop checked between lines, and a select error during the binding ends the attempt.

Two existing tests asserted the draft's behaviour on purpose and now assert the corrected one (F5: no call; F6: an invalidated record).

## 9. Performed, reused, untested

| | Performed in this stage | Reused (unchanged inputs; not repeated) | Not tested |
|---|---|---|---|
| Native | the clean build of record (`-j 1`, 0 errors, 0 Relay-owned warnings); 25 / 25 test runs; import / export comparison with native5 (0 added, 0 removed, 202 / 202 symbols; imported DLLs unchanged); source scans (one setter site, one outfit site, one detour, no listener, connect sites 3, loopback-only motion host, no write / input / physics / registry operation, no engine header in the motion sources, motion constructed only under `[motion] enabled`, default false); line bounds | native5's artefacts (verified untouched by the gate); the M6 tags and content, by identity | the plugin wiring in HITMAN (below); the engine's reaction to any call; the frame cost of the motion path (F4); a motion result at its worst-case size |
| End to end | the matrix of record, 13 / 13 on native6 | — | BEAM's motion send deadline against a native that stops reading (the native's own deadline is tested); a failed hand-over of an accepted socket on BEAM's side; more than one session per process; `max_sessions` above 1 end to end |
| BEAM | strict compiles (dev, test: exit 0); scoped format (exit 0; the whole-tree format check reports the 12 pre-existing M2-era files, informational); areas `motion-peer` 177 / 0, `command` 207 / 0, `headless-boundary` 21 / 0; **five full `mix test --warnings-as-errors` runs: 831 tests, 0 failures, exit 0 each, seeds 14249, 524173, 289116, 979378, 161827** | the B1 BEAM itself, unchanged (relay tree `da39d5e4`); the B1 correction's seal | — |
| Integrity | the checkpoint (`checkpoint-checks.txt`); leftover processes and ports; 0 token-like strings in the gate's outputs; the final scans and the seal | the earlier seals, re-verified at the checkpoint | — |
| Out of scope | — | — | real engine behaviour, the F2 instrument, any LAN, the MacBook, two games |

**Plugin wiring the standalone tests do not exercise** (compiled into native6, never run):
- `GlacierRelay::OnEngineInitialized`'s `[motion]` settings and the construction of the link and the controller;
- `ScheduleCommand`'s `Motion::Frame` (the frame callback's thread, scene, predicate, generation and epoch values, `InspectCandidateTransform` as the inspector, `EngineTransformApplier` as the applier);
- the real `ObserveCandidateTransform` reads at the share's rate and on every apply frame (frame cost unmeasured; F4);
- `EngineTransformApplier::Invoke` driven by a session (only its fake was).

## 10. The F2 instrument (a sketch for the later experiment, not built)

F2 (the candidate's words on engine frames +1 … +4 after each apply) stays unmeasured. The smallest instrument, if a later stage authorizes it: during an open session only, after each exact apply, read the candidate's twelve world words and dirty flag through the existing read-only inspector on the next four frames (no new hook, setter or recorder). Keep one window at a time (a window starts only after the previous one ended, so not every apply gets one), at most four reads per window. Write one bounded native log line per window: the apply's sequence number, the frame offsets, the words, and whether each read equals the postimage. It is evidence of the stored words at those frames, never of the cause of a change.

## 11. Next (proposed, not granted): M7-C

ONE attended run on the one Windows HITMAN host, under its own authorization and a fresh readiness, with nothing else changed:
- native6 installed for the run with `[command] enabled`, `[command] effectful`, `[motion] enabled` and a throwaway run token, and the accepted placement content (`5ac64848…` / `58e9a10f…` / `9433888b…`);
- the B1 BEAM host with motion on, and the headless peer in a second OS process on the same machine;
- **source:** one finite share of the operator's hero (for example the fountain walk) to the headless sink: the moving-hero sampling and its dirty fraction (F5);
- **destination:** one short, slow synthetic out-and-back from P along y 14.833 (design 15.9: 1.0 m at 0.5 m/s with holds), applied to the visible Agent48 under the native per-frame checks. The operator watches and records; one approved restoration; then rollback;
- **measured on the real engine for the first time:** the native's per-frame refusals and closes, repeated setter writes and x writes, frame cost (F4), and optionally the F2 sketch if separately authorized.

M7-L (the MacBook) and M7-D (two real instances) remain later, each with its own authorization.

## 12. Disclosures

- **The evidence root's claim** was made from zsh, so its claim record's `guard_sha256` is empty; the guard's hash is in `checkpoint-checks.txt`. Every later step ran through bash.
- **Development iterations are kept:** `dev-builds\dev-1` … `dev-10` and the three mutation builds (section 7), including the failing ones.
- **Matrix attempts 1–6 failed** on defects of the driver, never of the native. Each attempt is kept:
  - the comparison read the probe's block-buffered output before the probe exited (the retained data already showed 31 / 31 equal); it now compares after the probe stops;
  - the at-baseline restore lacked its effectful arming;
  - a `grep -c … || echo x` appended "x" to a count;
  - a vacuous `|| true` and a vacuous `then`.

  The `beam-kill` check was strengthened to use the native log's order.
- **Gate attempt 1 failed (1)** on a defect of the gate script: it runs with globbing off, so the clean build's log was never read, and the send-deadline range was blank (`gate-attempt1-NOTE.txt`). Every other step of that attempt passed and stands. After the fix, only the affected step ran again, as `gate-attempt2` (PASS: build-clean6 on `8129d721`, 0 uncommitted, `EXIT=0`, 0 errors, 0 Relay-owned warnings).
- **Warnings:** the clean build reports three, none Relay-owned:
  - two cargo future-incompatibility notices for `binrw` 0.15.0 in the SDK's Rust helper;
  - one C4244 instantiated from ZHMTools' generated `ResourceLib\Src\Generated\HM3\ZHMEnums.cpp`.

  native5's log has the same and a CMake warning. No warning exception is claimed or inherited.
- **The matrix of record's banner shows "3 uncommitted" in glacier-relay:** this record and the two documents edited with it, docs only. The relay tree `da39d5e4` is unchanged.
- **`verifier-disposition.txt`** names its development matrix `matrix-attempt9`; it was `matrix-attempt8` (`verifier-disposition-NOTE.txt`; the capture was not rewritten).
- **Unbuilt commits:** the intermediate commits were never built individually, and `3bf1d72c` alone does not build the test targets (section 1).
- **Where the native differs from the B1 fake:** two behaviours, inside the contract (section 4).

## 13. Bounded acceptance (2026-10-20)

**Authorization:** "Glacier Relay — M7-B2 acceptance and M7-C attended motion experiment".

M7-B2 is **accepted for its demonstrated offline scope**: the real native protocol, motion link, controller and restoration implementation (ZHMModSDK `relay/m2` `8129d721`; the build of record native6 `91a7098f…`), tested against an injected FAKE engine, the real B1 BEAM host and a local headless peer in a second OS process. Sections 1–12 stay exactly as recorded; the evidence `m7b2-offline` (sealed, 506 entries, `16e38abe…`) is not rewritten, and its failed first seal and the guard-metadata limitation of its claim record stay as disclosed.

The acceptance establishes **no** native6 behaviour inside HITMAN: not the plugin wiring (section 9), not any engine answer to a setter call, not the frame cost, not the sampler on a moving hero. Those are M7-C's to observe, under its own record. M7 is not complete; its goal and exit are unchanged.

Review basis (as the authorization states it): the pushed source, tests and records were inspected by the architectural review; the local artefact hashing, the executed gate results and the Windows baseline checks are this record's evidence, re-verified by M7-C where M7-C relies on them (`m7c-run1\checkpoint.txt`: native6's five artefacts and its manifest, the B2 seal in full, the relay tree `da39d5e4…` and tools tree `26f03fe1…` at the current head).

M7-C run 1 (2026-10-20), native6's first and only load in HITMAN so far, is recorded separately in `M7C_ATTENDED_RECORD.md`; it does not amend this record.

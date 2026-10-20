# M7-C — the attended motion experiment, run 1 (record)

**Status:** DONE (2026-10-20); **accepted** for its demonstrated, bounded one-host scope (section 11, 2026-10-20). M7 stays open.
- One attended HITMAN load and one Paris attempt with native6 installed, then a full rollback. Two sequential, separately approved phases: **one** finite read-only share of the local hero to the headless sink, then **one** bounded synthetic destination session for Agent48. It ended at its opening words, so the session was released at baseline. **No restoration** was eligible or sought.
- The source share and the destination course were separate phases. The hero's motion was **not** mirrored onto Agent48; the destination's samples were a synthetic course from a headless peer on the same machine. This is not a LAN, MacBook, two-game, input, animation or multiplayer test.
- No tag was created or moved. M6 stays closed. **M7 is not complete**: its goal and exit (bidirectional representation between two PCs) are unchanged.

**Authorization:** "Glacier Relay — M7-B2 acceptance and M7-C attended motion experiment". M7-B2 is accepted with it for its demonstrated offline scope (`M7B2_NATIVE_RECORD.md` section 13).

**Contract:** `M7_NETWORK_GHOST.md` sections 15 and 17, as implemented by M7-B1 (`M7B1_OFFLINE_RECORD.md`) and M7-B2 (`M7B2_NATIVE_RECORD.md`). Nothing in the contract, the BEAM or the native was changed for this run.

**Evidence:** `%TEMP%\glacier-m0\hitmen\m7c-run1\`, sealed: 3,545 files, manifest `sha256.txt` `5da4a64afff678b692d484570245dbf9bbbcd57948882d6dbb046d53fb8f9ee5` (verifies). The run's analysis is `verdicts.txt`; the operator's words are verbatim in `operator-confirmation.txt` and the `operator:` lines of `operator-actions.log`.

## 1. Basis

**Checkpoint** (`checkpoint.txt`, PASS, 75 checks, read only):
- glacier-relay `099f0b2d` = origin, clean (relay tree `da39d5e4`, tools tree `26f03fe1`); ZHMModSDK `relay/m2` `8129d721` = origin, clean; the tags unchanged;
- native6's five artefacts (the DLL `91a7098f…`, 11,396,096 B) and their manifest; native5 unchanged;
- the seals of M7-B2 (506 / 506, `16e38abe…`), M7-B1 and its correction, M6's closure, M6-G2, M6-G1 and M6-E2, re-verified in full;
- the placement content `5ac64848…` / `58e9a10f…` / `9433888b…` (M6-E3's, accepted); M0 26 / 26; the beam builds dev (88 modules, `fa525644…`) and test (100 modules, `0f8cd633…`), never rebuilt.

**Installed for the run** (`r1-install-attempt1`; the delta verified as exactly this set):
- `Runtime/chunk0patch300.rpkg`, `Runtime/chunk27patch300.rpkg` added; `Runtime/packagedefinition.txt` `6c88d12d…` → `9433888b…`;
- `Retail/mods.ini` `b90b4c5e…` → `f4f44345…` (SDK crash reporting off for the run only);
- `Retail/mods/GlacierRelay.dll` = native6, and a nine-line `GlacierRelay.ini`: `[command] enabled`, port 4749, **`effectful = true`**, the run token; `[motion] enabled`, port 4750, `max_sessions = 1`.

**Limits** (constants of the run kit, never typed live): share ≤ 60,000 ms at 50 ms; session 20,000 ms, half extent 1,250 mm, 1,000 mm/s, credit 100 ms; BEAM forward 50 / stall 250 / lag growth 100 / acknowledgement 200 ms; native apply 40 / silence 1,000 ms; budgets 1 on both sides, never reset.

## 2. Preparation (offline; about 74 minutes)

**The control method.** M6's runs drove the relay through named nodes registered with the shared epmd. Design 15.7 rules that out for M7. This run used a **non-distributed run console** instead (`kit/console.exs`):
- one VM, `nonode@nohost`: no node name, no distribution listener, no epmd use;
- it hosts the relay in start-beam.sh's effectful shape, with the motion subtree configured in-process;
- it owns the headless peer: a second OS process, also non-distributed, listening on `127.0.0.1:4760` with per-run TLS credentials;
- the peer's environment is stripped of every relay and run variable, so it holds no token, no token path and no authority API;
- operator actions are requests to the console's spool. The M6 tools (`cmd.exs`, `cmd-m6f.exs`, `ident.exs`, `capture_boundary.exs`, `final_state.exs`) are evaluated in the console as mechanically derived copies; the diffs are in `kit/KIT-DIFF.txt`.

**The kit** (`kit/`, 42 files; the third freeze is the one of record, `kit/SOURCE.txt` `55b81852…`; freezes 1 and 2 are kept). New:
- `console.exs` `f04498f2…`, `cmd-m7c.exs` `39ed6e33…`, `con.sh` `4ae9def7…`, `seq-dest.sh` `e151a5f9…`, `reconcile-motion.py` `7306c7cb…`;
- `gen-creds.exs`, `start-console.sh`, `RUNBOOK.txt`.

Everything else is the M6-G2 kit adapted to native6 and `[motion]`. No native or BEAM application code changed, nothing was rebuilt or regenerated, and no dependency was installed.

**Qualifications of record:**

| Step | Result |
|---|---|
| `dry-run-A-attempt3` | PASS 35 / 35, 111 s. Against the frozen native6 probe: the live sequence — the share to its duration, then the course to its end, then at_baseline and `confirm_baseline`, no restoration. |
| `dry-run-B-attempt3` | PASS 30 / 30, 42 s. The operator's close mid-course, with a target in flight that the native refused `session_closed`, then the one restoration, judged `restored`. |
| `run-rehearsal-attempt1` | PASS, 0 failures. Install and rollback on a scratch game tree with native6 and the nine-line INI, including case V: planted credentials shredded. |
| `deps-attempt1` | drift test PASS |
| `readiness-attempt2` | record (a): ok 145 (131 performed now, 14 reused), pin `ae6341471dc6381643e212ee82528b1f8c0add20d3c3fa8e4cd8314c3651a0e8` |
| `refresh-attempt1` | preview of record (b): ok 147 under run id `m7c-run1-preview`, which the installer refuses |

Not rerun: the 25 native loops, the five application suites, the B2 matrix and the historical archive. Record (a) reuses them by identity.

**Kept failed and superseded attempts:**
- `dry-run-B-attempt1` FAIL (23 / 7): the kit counted `not_open` (a sample received after the operator's close) as a critical refusal (`-NOTE.txt`, `-NOTE-2.txt`);
- the freeze-2 passes (`dry-run-A-attempt2`, `dry-run-B-attempt2`, `readiness-attempt1`) are superseded (`freeze2-superseded-NOTE.txt`) by two kit changes found in review and development, not by a failure of record:
  - the headless peer had inherited the token file's *path* (never its value);
  - a native `session_closed` refusal of the target in flight at a close was counted critical;
- four development iterations, `dev-dry-run-*`.

## 3. The run (UTC, 2026-10-20)

| Time | Step |
|---|---|
| 00:30Z | checkpoint presented: the disclosures, limits and course, and the three questions |
| 01:48Z / 01:51:09Z | the operator's reply (recording method, retention commitment, "Ready"), then a bare "Ready" (deviation 2) |
| 01:51:21–01:54:57Z | refresh: **record (b)** ok 147 (146 now, 1 reused = record (a)), pin `345e80087ac29a9675d26b7f0846ab3771878cbafd489fd048efbdacfd7ef42d` |
| 01:55:24–01:55:34Z | the token; the per-run TLS pair (host leaf `94ea3a95…`, headless leaf `28a05bf9…`); the console (os pid 1658422) and the headless peer (os pid 1658543), peer identified |
| 01:56:09Z | installed (gated on record (b): the readiness gate PASS, under 30 minutes old) |
| 01:57:15Z | HITMAN started (pid 46844): **native6's first load**; adapter `341b6df3-…`; command link 1, motion link 1, peer connection 1 for the whole run |
| 02:00:44Z | Paris (`_Scene_FashionShowHit_01`) playing |
| 02:04:13Z / 02:04:24.350Z | share go-ahead; the share opened on frame 50118 |
| 02:05:24.359Z | the share closed by its duration |
| 02:07:18Z / 02:07:42Z | recording started (Game Bar), and the operator said so |
| 02:08:35Z | the course presented |
| 02:10:11Z | destination go-ahead |
| 02:10:15–02:10:18Z | attestation; **one** effectful arming; the stream started 02:10:18.007Z; the session opened on frame 85557 |
| 02:10:22.061–02:10:28.056Z | 78 setter calls (frames 85944–86528) |
| 02:10:30.061Z | native close on frame 86725, clean |
| 02:12:19.88Z / 02:12:41.77Z | the R6 inspection → `at_baseline`; `confirm_baseline` journaled |
| 02:14:28Z | HITMAN exited; the links had closed at 02:14:27.48Z |
| 02:14:53Z | `cap-final`, with the console still running |
| 02:15:09–02:22:46Z | cleanup and full rollback; verify-after |
| 02:26:50Z | sealed |

## 4. Results

**R2, the main menu (native6's first load):**
- The native log shows:
  - "module attached" (one FreeLibrary detach and re-attach at load, as in M6-G2) and "Init: one detour registered";
  - the eleven-entry allowlist and "motion enabled: … `player.pose.share/1` (read-only), `candidate.motion.session/1` (EFFECTFUL …); max sessions 1 per process";
  - the motion link "bound as motion link generation 1 to command link generation 1", and the scheduler's first frame.
- Native WARN / ERROR / FAULT lines: **0**, here and for the whole run.
- The identity baseline is ok, with both motion entries advertised and the binding agreeing. The idle motion status is 9 / 9.
- The candidate is absent at the menu; the cross-check has 0 NOT lines of 13.
- No share, no session and no setter request at the menu.

**R3, Paris and the share:**
- Agent48 was `at_P_exact` at frame 34834: (−89.49, 14.83, −1.522178), identity rotation, not dirty, and distinct from the local hero at (−83.744, 14.697, −1.522). The cross-check has 0 NOT lines of 16.
- **The one share** read the local hero every 50 ms for 60 s and was closed by its duration, confirmed by the native:
  - native: 1,100 ticks, 1,100 sent, last sequence 1,100. Intervals were 50 ms minimum, 54.6 ms mean and 107 ms maximum.
  - host: relayed 1,099, all qualified. It refused one, sequence 2, for `rate`: it arrived 39 ms after sequence 1, below the host's 45 ms floor (finding 2).
  - sink: 1,099, equal to the host's value for value.
- The operator walked during the share (x −94.3 … −81.1, y 10.5 … 20.1) and stopped at (−83.51, 15.00).

**R4, the stationary qualification:**
- Agent48 was bit-equal to R3 at the same generation, `at_P_exact`; the cross-check has 0 NOT lines of 18.
- The local hero at (−83.510, 14.998, −1.521) became the new control baseline (finding 4).
- **The one course**, planned from the anchor's exact words (`c2b2fae1` / `416d47ae`), all seven course checks ok: `out_and_back` along negative world x, 1.0 m at 0.5 m/s. That is a 4.0 s stationary prefix, 2.0 s out, a 2.0 s hold, 2.0 s back and a 2.0 s hold: 241 samples over 12,000 ms, with the y word constant. The first changing sample is at 4,050 ms.

**The one destination session:**
- Before the stream, the identity check was SAME, and the binding inspection was bit-equal to R4 and at P. Then the telemetry attestation and one effectful arming (30 s).
- **Admission:** the session was active 152 ms after the stream's start, more than 1 s before the first changing sample.
- **The native's checked lines:** 78 attempted `SetObjectToWorldMatrixFromEditor` calls, targets 82–201, frames 85944–86528:
  - every call's preimage equals the previous call's requested x (the first one's is the opening), so the chain has 0 breaks;
  - the requested x stayed within [−90.49, −89.49]: the far point `c2b4fae1` was reached at target 121 (02:10:24.025Z);
  - y was `416d47ae` on every call;
  - 152 identical targets were skipped; 0 refused, 0 uncertain; no native superseded line.
- **The end:** `stream_end:course_complete` after 11,945 ms. The close was confirmed by BEAM and reported clean by the native. The native's final world words are **bit-equal to the opening words**.
- **R6:** a fresh inspection read exactly the opening words, so the decision was `at_baseline`. `confirm_baseline` was journaled (`motion.session.at_baseline`) with nothing submitted and no engine call. **No restoration.**

**Testimony and recording** (not a measurement):
- The operator, verbatim: "I witnessed as agent 48 slowly translated 1 m away on the X axis, and then held momentarily, afterward he slowly translated back to his point of origin. Unlike the first time that we tried this, the movement was not instantaneous, rather it was a translation over a period of time."
- The recording is kept by the operator and was not copied into evidence: `C:\Users\steve\Videos\Captures\HITMAN 3 2026-10-19 19-07-18.mp4`, 417,940,283 B, sha256 `6a1fc3dbfc200d5d8fc3a92786a46b8f3086fc2afb11eb6d6ac5c9c5b4a87d90`. It runs 02:07:18–02:13:02Z (00:05:46), which spans the session and the release. It has not been reviewed.

## 5. Reconciliation (`verify-after-attempt1/reconcile-motion.txt`: RECONCILE: PASS)

- **Share:** native sent 1,100 → host relayed 1,099 + refused 1 (`rate`) → sink 1,099, equal value for value.
- **Destination:**
  - peer sent 241 = 3 before the session's activation (sequences 1–3, unrouted) + 238 during the session + 0 after its close;
  - the 238 were validated, and 230 forwarded; 8 were superseded in BEAM's pending slot before forwarding;
  - 230 acknowledged = 152 `skipped_identical` + 78 `applied` = native received 230, applied 78, skipped 152;
  - the 78 applied acknowledgements equal the 78 native checked lines by sequence, frame, requested x/y and reference chain.
- **Journal:** one journal (`d00b00db…`), 74 entries, contiguous from 1. It accepted 1 share, 1 session open, 0 motion restorations, 0 `candidate.transform.set`, 0 outfit commands, and had 1 effectful arming.
- **Health:** audit intact; trace and audit ok; `trace_dropped` 0; send failures 0; unknown ids 0. The three-way recorder reconciliation returned rc 0.

## 6. Boundary, rollback, secrets

- **Boundary:** `cap-final` at record 8, taken after the game's exit with the console still running. The fresh-node replay at that boundary PASS: the instances, summary and report are term-equal, and the text is byte-equal. 5 events were reconstructed and 0 unattributed. After it: an orderly console stop.
- **Rollback** (`cleanup-attempt1`; content-verify was re-run independently by verify-after):
  - the game tree is byte-identical to the complete pre-deployment baseline: a 253-file listing with sizes and exact mtimes, every Retail hash, chunk0 and chunk27;
  - `mods.ini` `b90b4c5e…` (crash reporting on again) and `packagedefinition.txt` `6c88d12d…` were restored with their exact Windows creation and write times;
  - the hitmen ids appear in 0 of 145 package indexes; M0 26 / 26.
- **Secrets:**
  - the run token's value was found in 0 files: the evidence root, the state root (recording, journal, traces, spool), the native logs, and the game's `mods/` and `mods.ini`;
  - the token file was removed and the seven credential files shredded. This is a logical deletion, not secure erasure.
  - the crash-dump locations have 0 new or changed files; 0 BEAM warnings or errors;
  - the journal holds one 128-bit attestation challenge nonce, as M6-G2's does, and 0 MAC values.
- **Unchanged:** native5 and native6; the beam builds (no rebuild); the 44 relied-on references; the committed recordings.

## 7. Findings

1. Every `mix run` VM of Elixir 1.19 holds one loopback ephemeral listener owned by `Mix.Sync.PubSub` (here `127.0.0.1:46839`). It is attributed and accepted by `start-console.sh`. It was also present, unnoticed, in the M6 nodes.
2. The host's source rate floor (90 % of the interval, measured on arrival) refused one share sample whose arrival transport jitter had compressed. The native's own interval was at least 50 ms throughout.
3. R3's inert arm stays in force through the share, so R4's and R6's inert arms answer `already_armed`. The state was the intended one: inert armed, effectful not armed. The kit checks the call's answer instead of the state. Rehearsed (dry run A), but not flagged there.
4. The R4 control baseline lies outside the earlier content-backed start spread, because the authorized share walk ended elsewhere.
5. The cleanup's private-key count (8, expected 0) matches its own pattern: kit scripts, their diffs, and reports quoting the scan line. There are 0 PEM armour lines in the root. A key-material scan should anchor on the armour. The installer rehearsal shows the same self-match (5 files).
6. The cleanup prints an inherited "pre-run baseline 13" for token-named paths (M6-G2 printed 27 against the same 13). This run added 4 such paths, all `no-token-files.out` readiness outputs.

## 8. Deviations and disclosures

1. **The control method** (section 2) replaces M6's named-node RPC through the shared epmd.
2. **The confirmation.** The operator's first reply was recorded verbatim, but the readiness check matches only a reply line that *begins* with the Ready. A bare "Ready" was requested and appended verbatim as a second reply, with the first 11 lines' sha256 `1841ba21…` (unchanged), before the refresh read the file. An earlier attempt to append a quotation of the first reply's Ready sentence as a reply line was blocked by the permission system and not retried.
3. **Operator-shell mistakes, with no effect:**
   - a zsh `====` separator stopped one chained command before the pre-install journal, which was then re-run alone;
   - zsh passed "label action" as one argument to four R2 calls. `con.sh` refused them at its argument check, before any label was claimed or any request submitted.
4. **During preparation:**
   - one read-only epmd `names` query in a scratch test (the answer: no names);
   - the kit was frozen three times;
   - the failed and superseded attempts of section 2 are kept.

## 9. What this establishes, and what it does not

**Established, at sampled frames, on the real engine, once:**
- native6 loads in HITMAN and binds its motion link to the token-verified command link;
- the read-only share samples a moving local hero at about 18 Hz for a minute, with all samples qualified;
- a bounded synthetic session can drive Agent48 through **repeated** setter calls along **x**: 78 calls, each with its exact preimage, and a clean end at the bit-exact opening words;
- the operator saw a gradual 1 m translation out and back. M6-G2's single step was instantaneous.

**Not established:**
- continuous physical or rendered tracking: the values are exact at sampled frames, and the visual account is testimony and an unreviewed recording;
- collision and physical coupling;
- the per-frame cost (F4) and F2's +1 … +4 frames;
- any effect of the setter on other engine state (that Agent48 is a complete-but-unspawned hero remains M6-D's hypothesis H1, not an observed diagnosis; wording corrected at acceptance, section 11);
- the native "released at baseline" path (the release was BEAM-journaled; no later exclusive operation read the record);
- any live restoration, the operator's stop, or a refusal path;
- a moving source driving the destination;
- a second machine, a second game, or any multiplayer property.

## 10. Next (proposed, not granted)

Architectural review of this record. Kit corrections for a later run, script-only:
- check the inert arm's state rather than its answer;
- anchor the key scan on the PEM armour;
- drop the stale token-name constant;
- let the confirmation check accept a reply containing a Ready sentence, or ask for a bare Ready.

Candidate next stages, each under its own authorization:
- the F2 / F4 instruments;
- a live source → destination mapping on the one host;
- M7-L (the headless peer on the MacBook);
- M7-D (two real game instances).

## 11. Bounded acceptance (2026-10-20)

**Authorization:** "Glacier Relay — M7-C acceptance and M7-L1 offline peer-network preparation". M7-C run 1 is **accepted for its demonstrated, bounded one-host scope**: a finite share of a moving real local hero to the local headless sink, followed by a separately approved synthetic course that drove Agent48 through repeated native setter calls and ended at its opening state. The phases were sequential; a real player's motion did not drive the candidate. Sections 1–10 and the verdicts are kept as run. M7 stays open; M6 stays closed; no tag was created or moved.

**The accounts accepted:**
- **Share:** the native sampled 1,100 times during the finite 60 s share. The host relayed 1,099; sequence 2 was refused by the receiver-time rate guard. The sink received those same 1,099 values. The nominal interval was 50 ms; the achieved native cadence was about 18.3 Hz (reported intervals 50 / 54.6 / 107 ms minimum / mean / maximum), not a regular 20 Hz stream.
- **Destination, by layer:** the peer sent 241 samples = 3 before activation + 238 during the session. Of the 238, 8 were superseded in BEAM before forwarding. The native received and answered 230 = 152 skipped-identical + 78 applied.
- **The course:** one 12-second, one-metre out-and-back along negative world x at the proposed course speed of 0.5 m/s, inside the fixed per-run limits (20 s, ±1.25 m, 1.0 m/s, 100 ms credit). The exact same-frame results and the checked preimage chain are observations at the recorded frames, not continuous collision or rendering guarantees.
- **Demonstrated for this build (native6 `91a7098f…`) and this route:** the first live native6 load and binding, real source sampling, and repeated destination application.
- **The end:** a native-confirmed clean close and a fresh, exact at-baseline inspection; BEAM journaled the baseline release without an engine write. The native's later release on an exclusive operation was not exercised, and no motion restoration was attempted. No additional command is needed to close that coverage row.
- **After the exit:** the boundary at record 8, a successful replay and reconciliation, the reported complete byte-and-timestamp rollback, and the logical removal of the credentials.

**What the review checked.** The architectural review checked the remote heads and the committed records — not the local suite executions, the video's contents or the Windows restoration. That distinction stands. For this acceptance the inputs it relies on were verified locally (`m7l1-offline\checkpoint-attempt2`, 33 / 33 ok): both heads and the tags unchanged, the m7c-run1 seal re-hashed in full (3,545 / 3,545), native6 and the placement content by identity, and the video by hash in place.

**The video.** It stays with the operator, outside every seal and Git: `C:\Users\steve\Videos\Captures\HITMAN 3 2026-10-19 19-07-18.mp4`, 417,940,283 B, sha256 `6a1fc3dbfc200d5d8fc3a92786a46b8f3086fc2afb11eb6d6ac5c9c5b4a87d90` (unchanged before and after). It was inspected **once**, with existing built-in tools (the M6 closure's WinRT still script and System.Drawing; nothing installed or uploaded): 13 stills and one crop strip, in `m7l1-offline\media-review\` (`README.txt`), not in the sealed C root.
- Visible: the courtyard, the HUD and Agent 47 in the foreground fixed in every still; a second suited figure standing on the carpet before the fountain.
- From 176 to 186 s that figure stands at one screen position; at 188 and 190 s it stands further into the scene, at two different displaced positions; at 192 s it is at or near the first position, and from 194 s at it.
- The duration-based start estimate places the native's calls at about 186.4–192.4 s, consistent with the stills; the file's creation time is not consistent with them and is not used. No native frame, world distance or direction is derived from the pixels.
- **What it supports:** the operator's report of a displacement away and back against fixed scenery within the session's interval. Stills 2–3 s apart cannot show continuity between them, so "gradual" remains the operator's testimony.

**Wording correction.** Section 9 said "Agent48 remains an unspawned hero, M6-D's hypothesis"; it now reads that complete-but-unspawned remains a hypothesis (M6-D2's H1: supported, not proven), not an observed diagnosis. Agent48's absence from the player registry (M6-D1b) and the behaviour observed here are established separately.

**Still not established:** collision; physical coupling; the callback's execution cost (F4); observations at +1 … +4 frames (F2); a moving source driving the destination; LAN; the MacBook; a second game; animation; multiplayer.

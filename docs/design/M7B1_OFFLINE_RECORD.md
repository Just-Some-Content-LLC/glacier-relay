# M7-B1 — offline implementation record (BEAM, fake native endpoints, owned loopback peers)

**Status:** DONE offline (2026-10-19); **corrected** the same day (section 11: deadlines at event and send boundaries, and the restoration result); **accepted** for its demonstrated offline scope (section 12).
- M7 is **not** complete, and nothing here has run against HITMAN.
- Every native answer in this stage came from a test fake (`Test.FakeMotionNative`). That makes it fake-native evidence, never evidence of what the DLL does.
- A synthetic course is not walking, a numeric box is not a cleared route, and a headless peer is not a second game instance.

**Authorization:** "Glacier Relay — M7-B1 offline implementation authorization" with "Glacier Relay — M7-A review and M7-B1 bounded offline implementation".

**Contract:** `M7_NETWORK_GHOST.md` section 15, committed as `340a95a4` before any code. ADR 0010 is accepted as amended, for this scope only.

**Evidence:** `%TEMP%\glacier-m0\hitmen\m7b1-offline\` (guarded; sealed after this record).

## 1. Basis and commits

**Checkpoint** (`checkpoint-checks.txt`, PASS, read only):
- glacier-relay `2a66d0e3` = origin;
- the M6 tag object `4a05ddaa` → `4ee9dd39`;
- `relay/` and `tools/` unchanged since `874d404c`;
- ZHMModSDK `76c407f3` = origin, its tag object `7cfed869`;
- native5 `f271d129…` and the content `5ac64848…` / `58e9a10f…` / `9433888b…`;
- the M6 closure manifest `b3966444…`;
- the M7-A design seal `cc73bfb4b515f0d9986c9e4c1afa684a6c813dc2a276a1aeb97fbdcc2e615c87`, verified 9 / 9;
- M0 26 / 26; no game process; no project port bound.

These identities were reused, not requalified: no native, content, game or historical audit was repeated, and no integrity trigger arose.

**Commits** (responsibility-separated, in order):

| Commit | Content |
|---|---|
| `340a95a4` | docs: the reviewed contract (section 15), ADR 0010 accepted as amended |
| `1a2aece`, `a583af3` | test-only: the known compile warnings, in **five** files (see 8.6) |
| `c90c8d7` | the pure contract modules: codecs, the destination and share state machines, courses, the clock |
| `9bf94da` | runtime integration: the authority's motion entries, binding and exclusivity; the hub, links, listener and trace; the TLS peer link; the headless peer; the facade; configuration (off) |
| `bfe69d6` | the tests and fakes; **the exact draft the verifier reviewed** (`verifier-basis.txt`) |
| `1277c26` | format only: twenty draft files that were never formatted (8.6) |
| `1f085d3`, `0f22a05` | the verifier's corrections and their tests (section 7) |

## 2. What exists now (everything off by default)

`config :glacier_relay, :motion, enabled: false`. Nothing enables it at runtime in B1; tests start it explicitly. With it off:
- the supervision tree and the command subtree are exactly M6's;
- no motion or peer port is bound;
- an M6 peer's welcome is byte-for-byte the welcome it saw before.

All of these are tested (`headless_test`, `link_binding_test`).

| Part | Modules | Role |
|---|---|---|
| Control plane | `Command.Schema` (`player.pose.share/1` inert, `candidate.motion.session/1` effectful `open` / `restore`, both motion-gated), `Command.MotionControl`, `Command.Authority` hooks, `TokenHolder.verify_motion/6` | binding of the 4750 link; issuance from the operator's statement or approval plus one exact inspection verified from the journal; exclusivity; budgets; the restart latch; restore and baseline eligibility from the verified journal |
| Data plane | `Motion.Hub`, `Motion.Link`, `Motion.Listener` (`127.0.0.1:4750`), `Motion.Supervisor`, `Motion.Trace` | one bound motion link, one share and one session; timers; the required trace |
| Pure rules | `Motion.Destination`, `Motion.Source`, `Motion.Course`, `Motion.Codec`, `Motion.LineCodec`, `Peer.Codec`, `Motion.Clock` | section 15.3–15.9 as functions of explicit time |
| Peer link | `Peer.TLS`, `Peer.Connection`, `Peer.Endpoint` | TLS 1.3, per-side CA plus pinned leaf; one peer, one connection; bounded; loopback only in B1; the game host connects out |
| Headless peer | `GlacierRelay.HeadlessPeer`, `HeadlessPeer.Driver` | trace, driver and listening endpoint: no authority, token, motion link or engine path; synthetic sources only; a recording sink that never forwards |
| Operator API | `GlacierRelay.Motion` | `open_share`, `close_share`, `open_session`, `close_session`, `restore_session`, `confirm_baseline`, `status`. Opening and restoring go through the authority only; closing needs no arming |

## 3. Contract to code

| Contract (section 15) | Implemented by | Proven by |
|---|---|---|
| 15.2 identities | the peer pin / label / kind; the boot; the connection generation; the stream; `source_kind`; mission generations local only; identity mapping only | `tls_test`, `session_test` "local approval and binding", `codec_trace_test` (no adapter or session field on the peer link) |
| 15.3 acquisition and bounds | `Destination`: no exemption; the reference is a confirmed apply; `≤` boundaries; one in flight; pacing; withheld refusals; distinct sequence numbers | `destination_test` (33), including the exact 0.125 m boundary and one binary32 step beyond it |
| 15.3 ends application | the first uncertain result, inexact postimage, refusal, acknowledgement mismatch or timeout, report gap or disagreement, trace or audit loss, stall, lag, area, duration | `destination_test`, `session_test` "first uncertainty", `corrections_test` A |
| 15.4 lifecycle and close | close on the motion link with no arming: requested / transmitted / confirmed / unknown; close while in flight, with a degraded audit or with an unanswered native | `session_test` "close", `corrections_test` B |
| 15.4 exclusivity and budgets | v1 / v2 forwards **and restores** refused while a session is not released; a motion open refused while an M6 forward is unrestored; `max_sessions`; one session per stream; the restart latch | `session_test` "exclusivity", `corrections_test` C, J, O |
| 15.4 restoration | a native-confirmed clean close; the journaled preimage; a later inspection on the same adapter and generation equal to the final words; fresh arming; `already_at_baseline` released by `confirm_baseline` | `session_test` "lifecycle", `corrections_test` D, E, G |
| 15.5 binding and native rules | the hello, welcome and HMAC attest bound to the current token-verified command link; dropped with it; at most two link processes; the native rules modelled by the fake (8.3) | `link_binding_test` (9), `corrections_test` K, `session_test` native-autonomy tests |
| 15.6 freshness and bounds | lag growth as intervals within one clock; stall → close with no resumption; 1 KiB lines; `active: :once`; 200 ms handler deadlines; 8 / 16 credits; stale drop; 500 / 200 ms send deadlines; ping and idle | `destination_test` "freshness", `tls_test` "bounded sending", `session_test` / `two_process_test` delayed traffic |
| 15.7 authentication and isolation | `Peer.TLS` / `Peer.Endpoint` / `Peer.Connection`; non-distributed peers; loopback-only binds | `tls_test` (14), `two_process_test` (sockets, `nonode@nohost`), `boundary_test` |
| 15.8 evidence | `Motion.Trace` bounds and markers; health-gated effects; accounting; clock domains labelled | `codec_trace_test`, `corrections_test` A, section 6 |
| 15.9 courses | `Motion.Course` (5 profiles × 2 senses), each starting stationary at the anchor's exact words with explicit transitions | `source_course_test` |

## 4. The exact local test topology

**In-VM topology** — one test VM (`MIX_ENV=test mix test`, `nonode@nohost`, no epmd contact), holding:
- **The game host:** `Command.Supervisor` (journal; authority with an ephemeral test token; command listener `127.0.0.1:<ephemeral>`) with `Motion.Supervisor` (trace, hub, motion listener `127.0.0.1:<ephemeral>`, and the peer endpoint connecting out).
- **The fake native** (`Test.FakeMotionNative`): a version-2 attested command-link client and a bound motion-link client, with its own 10 ms frame timer.
- **The in-VM headless peer** (`HeadlessPeer`): its endpoint listens on `127.0.0.1:<ephemeral>`.

**Two-process tests** run the headless peer in a **second OS process**:
- the command is `elixir -pa _build/test/lib/*/ebin -e GlacierRelay.Test.HeadlessHarness.main()`, which loads the compiled test build and compiles nothing;
- it is not distributed, and is driven over standard input and output (`@@`-prefixed JSON lines);
- it listens on `127.0.0.1:<ephemeral>` and is the only listening socket of its pid (`ss`); it has no IPv6 listener;
- it reads PEM credentials (`0600`, in a test-owned temporary directory);
- it halts when its standard input closes, and `on_exit` checks that its pid is gone.

**Credentials:** generated per test with OTP's `public_key` test data (a per-side CA and leaf, ECDSA P-256 / SHA-256), passed in memory as functions or files, and removed with the test directories. The run token is the tests' ephemeral constant and never a real one.

**Not touched:** the shared epmd (pid 45286, `0.0.0.0:4369` / `[::]:4369`); every listener that is not the project's (`environment-facts.txt`); WSL, firewalls; the Mac. After the gate, no BEAM process or project port remained (`gate.txt`).

## 5. Results

**Gate of record** (`beam-gate-attempt1\`, on `0f22a05` with the relay tree `ba0810ee`; commands and exit statuses in `gate.txt` and each file): **PASS.**

| Step (commands as recorded) | Result |
|---|---|
| `mix compile --warnings-as-errors --force` (dev, 72 files); `MIX_ENV=test mix compile --warnings-as-errors --force` (83 files) | exit 0 / 0 |
| scoped `mix format --check-formatted`: every file this stage added or changed, the command lib and tests, the test support, `config/*.exs` (as mix globs) | exit 0 |
| whole-tree format check (informational) | exit 1, on exactly the 12 M2-era files M6-G1 listed; none of this stage's |
| areas, each `MIX_ENV=test mix test --warnings-as-errors`: motion and peer; command; headless and boundary | 127 / 0, 176 / 0, 21 / 0; exit 0 each |
| five full suites, `MIX_ENV=test mix test --warnings-as-errors --seed S` (seeds 70366, 919900, 966643, 410752, 634578) | **750 tests, 0 failures, exit 0** each; no compile warning (no warning exception is inherited) |
| after the gate | no BEAM process, no project port |

**Counts:** 750 tests: M6's 618 plus 132 new.
- **Motion and peer, 127:**
  - destination 33;
  - session 26;
  - corrections 17;
  - source / course 14;
  - TLS 14;
  - binding 9;
  - codecs / trace 8;
  - two-process 5;
  - headless peer 1.
- **Boundary and invariance, 5.**

The draft's sanity runs (not of record) were 733 / 0, then 750 / 0, each with `mix test --warnings-as-errors` exiting 0.

## 6. Bounded trace examples

`trace-examples.txt` — one owned loopback scenario on the final inputs (`scripts/trace-examples.exs`):
1. a 1 s share to the sink;
2. a session on a short out-and-back course, closed by the stream's end and released at baseline;
3. a second session whose fake returns an inexact postimage.

The journal and both traces are copied whole. They contain neither the token nor any key (checked by the script).

- **Topology:** command `46065`, motion `41955`, headless `41897`, all `127.0.0.1`; `nonode@nohost`.
- **Share:** 19 relayed, 19 received; the reconciliation is complete.
- **Session 1:** closed on `stream_end:course_complete`, confirmed; 15 applied and 27 `skipped_identical`; restorable; released by `confirm_baseline` (`at_baseline`).
- **Session 2:** closed on `postimage_mismatch` at the first inexact apply; 1 uncertain, unresolved 15; not restorable (`closed_unclean`).
- **Sizes:** journal 48 records; host trace 211 (55 samples, 54 forwards, 54 acknowledgements, 10 reports, 4 RTTs); headless trace 92.
- **Note:** the console's echoed command line misprints the script's path; the path is `scripts/trace-examples.exs`. It is kept as written.

Three records, as written:

```text
{"allowance_m":0.102,"beam_mono_ms":3570,"distance_m":0.0,"event":"destination.forward","pos":"c2b2fae1,416d47ae","reference_seq":null,"seq":3,...}
{"beam_mono_ms":3572,"event":"destination.ack","frame":1134,"native_mono_ms":1330,"outcome":"skipped_identical","seq":3,...}
{"agrees":true,"event":"destination.report","native_counts":{"applied":0,"received":5,"skipped":5,...},"native_mono_ms":1580,"report_seq":1,...}
```

The first forward is the acquisition. Its distance from the opening snapshot is 0, and its allowance is 2 m/s × 51 ms, because the credit was not yet reached. `native_mono_ms` is the fake's own clock and is never subtracted from `beam_mono_ms`.

## 7. The one focused verifier

**The verifier:** one independent, read-only agent on the immutable draft `bfe69d6`, limited to authority, bounds, freshness and authentication. Its report is `verifier-report-attempt2.txt`, verbatim. `verifier-report.txt` is a failed first extraction, kept and explained in `verifier-report-NOTE.txt`.

**Findings:** no blocker; three majors; twelve minors. All were applied (`verifier-disposition.txt`), with I applied in part (8.4) and N fixed but untested.
- **A:** trace or audit loss while an open was in flight did not end application.
- **B:** close was refused while an open was in flight, and uncertain opens were left to the native's silence timer.
- **C:** an authority or journal restart reset the budgets and the exclusivity. This was inherited from M6's per-process budget. It is now latched with motion on (M6 is unchanged with motion off). The residual: a node or whole-application restart clears the latch, so the attended-run rule still applies above it.

## 8. Findings, deviations, failed attempts

1. **TLS on the installed OTP 28 / ssl 11.5.4** (`tls-probe\`):
   - a self-signed leaf is refused (`selfsigned_peer`) even when it is in `cacerts`. That is why each side uses a CA and a pinned leaf, never an accepting callback;
   - `reuse_sessions` is incompatible with TLS 1.3 only, so it is not set;
   - `send_timeout` returned `{:error, :timeout}` after about 209 KB had been buffered on loopback. Delayed traffic is therefore real, and the stall rule closes before it can play out (`session_test`, `two_process_test`).
2. **Contract clarifications** — not new protections:
   - **`confirm_baseline`:** without it, a session whose candidate a fresh inspection shows already at its preimage would have blocked every transform write for the authority's life. It is journaled, needs no arming, and submits nothing.
   - **Pre-activation drops:** a native sample that reaches the hub before the authority's confirmation activates the share is dropped and counted (`unknown_ids`); the sink shows it as a gap. Nothing is buffered for later.
   - **One session per stream** (J).
   - **Close states for a share** (F).
   - **Reports** start after the first target.
3. **The B2 native contract** as the fake defines it (to be reviewed with B2), on top of section 15.5:
   - one `ghost.applied` per target, so per-apply postimages are evidence and F1 is per apply;
   - a pending target is refused as `session_closed` before `ghost.closed`;
   - `skipped_identical` means no setter call;
   - the untouched-word check runs before every call;
   - reports start after the first target.
4. **Wording deviation from 15.6:** the peer sender does not drop the oldest sample. Above 8 queued it refuses the **newest**, at the producer, and counts it; any sample older than 100 ms when its turn comes is dropped as stale. Either way, no stale sample is sent and every drop is counted.
5. **Labels:** in B1 a "game" stream comes from the fake native's share and is labelled "B1 fake native — not a game". `source_kind` is authenticated-peer provenance only.
6. **Hygiene:**
   - **Warnings:** M6-G1's record named four warning files; its gate output shows a fifth (`wire/listener_test.exs`, an Elixir 1.19 `hd/1` type warning). All five were fixed test-only, with the same semantics. `listener_test.exs` remains among the pre-existing unformatted M2-era files, which were left alone.
   - **Formatting:** the draft was formatted with directory arguments, which `mix format` skips silently, so twenty files were left unformatted (`draft-format-check.txt`). Commit `1277c26` is formatting only.
   - **Vacuous assertions:** two draft assertions were vacuous (a fallback mapped an earlier refusal to the expected error). They are now strict.
7. **Failed attempts, kept:**
   - **The first smoke run** failed on `reuse_sessions`. Its supervisor report printed part of a test certificate. Credentials now enter as functions or files, and the endpoint's state is redacted.
   - **The verifier report:** the first extraction was wrong (`verifier-report.txt`).
   - **During development:** test iterations fixed timing and fault-placement errors in the tests themselves. None was a contract violation, and they are not separate evidence attempts.
8. **epmd and isolation:** observed and reported, not changed. B1 used no named node. Project-owned listeners during the tests were the ephemeral loopback ports only.

## 9. Untested; remaining engine and remote-host uncertainties

**Untested in B1:**
- native sampling of a moving hero and its dirty fraction (F5);
- native enforcement of 15.5 (the fake is not the DLL);
- repeated setter writes and x writes on the real engine;
- F2 (+1 … +4 frames), still unmeasured; the smallest instrument is in 15.8;
- frame cost (F4);
- collision and physical coupling (F6);
- any TLS path that is not loopback;
- MacBook compatibility (OTP, `ssl`, firewall);
- LAN behaviour;
- two real game instances and every claim of section 9 that needs them.

**Not exercised as the real thing:** delayed traffic in a real network, as opposed to suspended processes and loopback buffers; the motion link's 200 ms send deadline, which is configured but never filled (it would need about 200 KB at 20 Hz); N.

**Known residual:** the restart latch does not survive a node or whole-application restart. Above that, the attended-run rule (an authority restart ends the run) governs.

## 10. Next

**Proposed (not granted): M7-B2, native, offline.** In ZHMModSDK:
- the read-only slot-0 sampler;
- the motion link client with the attested binding;
- the session applier on the one setter site, with section 15.5's per-frame checks and autonomous closes;
- `ghost.applied` / `report` / `closed`;
- the native mirrors of the exclusivity and the restart rule;
- optionally, the F2 instrument.

Its proof would be a native6 build of record (not installed) with:
- 25 / 25;
- the import / export comparison;
- exactly one setter site;
- the FAKE matrix: probe ⇄ host node ⇄ headless peer on one machine.

B2 is not a game run. M7-C (attended), M7-L (the MacBook) and M7-D (two real instances) each need their own authorization and fresh readiness.

## 11. Correction: deadlines at event and send boundaries, and the restoration result (2026-10-19)

**Authorization:** "Glacier Relay — M7-B1 focused deadline and restoration correction" — one BEAM / test-only correction pass for two review findings, with their regression tests and concise contract and record amendments. The demonstrated B1 progress is accepted. Its timing and restoration-release rules were not frozen as B2's contract until this pass. The normative result is design **section 17**. No native, content, game, LAN, Mac or real credential was involved. **Evidence:** `%TEMP%\glacier-m0\hitmen\m7b1-correction\` (guarded; sealed after this record).

### 11.1 Basis

`checkpoint-checks.txt` (PASS, read only):
- glacier-relay `ce3c0ced` = origin, clean; its parent is `0f22a05`, the B1 gate's checkpoint (relay tree `ba0810ee`, unchanged by the docs commit);
- the M6 tags on both repositories unchanged; ZHMModSDK `relay/m2` `76c407f3` = origin;
- native5 `f271d129…` and the content `5ac64848…` / `58e9a10f…` / `9433888b…`, by identity only;
- the M6 closure `b3966444…`, the M7-A seal `cc73bfb4…`, and the B1 seal `ae6ab0e5…`, which re-verified 36 / 36;
- M0 26 / 26; no game process; no project port bound; epmd observed (pid 45286) and not changed.

Nothing native, no content rehearsal and no historical archive audit was repeated.

### 11.2 Before the fix: the review's counterexamples, executed

The review had inspected the source but not run its counterexamples. They were run first, against the unchanged production code (`before-fix-attempt1\`). The working-tree delta, which contained only test files and test support, and the hashes of the files as run are recorded; byte copies are in `files-as-run\`. The reproducers assert the required behaviour, so every failure message shows the actual one.

**Result: 31 reproducers, 28 failed, 3 passed** (the controls). The 127 existing motion and peer tests passed with the extended fake. Both findings were **confirmed**; no part was refuted (`diagnosis.txt`).

**Finding A.** Only `tick/2` checked deadlines:
- `Destination.sample/3` forwarded the first in-area sample at t = 300 with a stall of 250, and at the inclusive bound t = 250, without a tick. It forwarded again at the duration bound.
- `Destination.applied/3`:
  - released a pending target at the duration bound;
  - for a target sent at 50, an exact acknowledgement at 251 released the pending target and was counted applied (the elapsed timeout was never recorded);
  - a 260 ms answer while closing was counted applied.
- `Destination.native_closed/3` confirmed a close at its 1,000 ms deadline. After the tick had declared a close unknown, it **overwrote** it to confirmed and emitted a second close summary. (That second case was pure-level only: through the hub the unknown close drops the link and ends the session, so no later `ghost.closed` reaches it.)
- `Source.hero_sample/3` relayed at t = 1,001 and t = 1,000 after a 1,000 ms share. `Source.native_closed/3` had both late-confirmation defects.

Through the hub (socket evidence: the fake's log of every `ghost.target` line it read, and the headless sink's reconciliation):
- **H-A1:** a sample queued before the stall timer (mailbox order checked) and processed after the deadline was written: targets `[1, 2]`. The session then ran on.
- **H-A3:** an exact acknowledgement queued before its 200 ms timer and processed after it released the pending target: targets `[1, 2, 3]`.
- **H-A4:** hero sample 20, queued before the share's duration timer and processed after it, reached the headless peer.
- **H-A5:** a forward decided before the duration bound had its required trace write held across the bound by an injected trace stand-in. It was written afterwards: targets `[1, 2]`.

**Finding B.** `MotionControl.on_terminal/3` released a restore on `applied` plus target-equal world words. Each of eleven one-fact variations was released, and the next real M6 forward (`step_candidate`) was accepted. The variations were:
- a dirty post cache;
- the dirty state absent;
- another parent;
- another entity;
- another generation;
- control changed;
- control unavailable;
- the effect uncertain;
- the invocation not reported;
- the requested words absent;
- the parent-relative words absent.

All eleven shapes are admitted by the production result decoder (`observed` is any bounded map of field objects), so they are reachable wire conditions. A `precondition_failed` result carrying a reported invocation and a changed effect returned the session to `closed_clean`, and `confirm_baseline` then released it.

### 11.3 The correction

| Commit | Content |
|---|---|
| `fbec9b8` | test support only: the fake's restoration-result fields and one-fact faults, its target-line log, held motion output and share overrun; `Test.TraceProxy`. The 127 existing motion and peer tests were unchanged by it |
| `1066016` | **A:** `Destination` / `Source` `expire/2` before every event and `before_send/3` at the send boundary; `Hub` calls both after the trace write; `Peer.Connection` `not_after`; late answers and late confirmations as evidence; the `withdrawn` count fixed (below). Tests: the A reproducers as run, `deadline_send_test`, a connection case, and two existing tests adjusted (below) |
| `d4720b6` | **B:** `MotionControl.judge_restore/2`; the authority journals `motion.session.restore_judged` before the judgement takes effect. Tests: the B reproducers as run (byte-identical), `motion_restore_judge_test` (internal inputs labelled), `restore_journal_test`, and the displaced-restore test now also asserts its judgement |
| `905d22e`, `c7a3490` | the verifier's findings applied (11.4), and their tests (including the hub-level share tests of its gap T1) |
| `6d33f1d` | test-only: H-A5 made independent of the fake's own duration close (gate attempt 1, 11.5) |

**After the fix** (`after-fix-attempt1\`, the same command and seed on `c7a3490`): **31 reproducers, 0 failures**, and 48 new tests, 0 failures. `deadline_hub_test` changed once more after that run, test-only (`6d33f1d`), and the gate of record covers it.

**Final rules:** design 17.1 (time) and 17.2 (the restoration result).

**Also found while correcting:**
- **`withdrawn/2`:** its increment was discarded, because a record update read the old counts. B1's `withdrawn` count (a target the trace refused) could never rise. The bump now comes first. The new cancellation path had the same pattern in its first draft, which a hub test caught.
- **Three existing destination tests were adjusted:**
  - the lag-growth test now acknowledges each target in time; it had relied on the sample path ignoring a 200 ms deadline;
  - the native-initiated close's input moved from t = 1,000, past the stall, to t = 200, and the after-deadline case is a new test;
  - a third, the closing `next_deadline` assertion, changed later with F7 (11.4): 250 (the acknowledgement), then 1,060.
- **The reproducers as committed:**
  - `restore_result_test` is byte-identical to the file as run;
  - `deadline_order_test` lost one unused default argument (a compile warning in the before-fix run);
  - `deadline_hub_test`'s H-A5 gained a fake session overrun and an open-session assertion (`6d33f1d`).

  Each difference is recorded (`after-fix.txt`, the commit messages).
- **One draft assertion was wrong:** an unsynced journal entry is not absent from the file. It is the authority that counts it as not persisted. The assertion was corrected before commit.

### 11.4 The verifier

One independent, read-only verifier reviewed the immutable draft `d4720b6`. It was limited to the two corrected boundaries, with no forks and no lens sweep (`verifier-basis.txt`). Its report is `verifier-report.txt`, verbatim.

**Result: no blocker and no major.** It found no path that produces a target or relayed sample after its deadline, no way a late answer resolves an unknown outcome or a late confirmation confirms an unknown close, no release without every listed fact, no crash from decoded inputs, and no M5 / M6 change.

**Dispositions** (`verifier-disposition.txt`):
- **F1 (minor):** `stream.end` named a sample cancelled at the send boundary. A share now reports only what the peer connection accepted (`handed`). `sent` means handed to the connection; a later drop by the connection is a gap at the sink.
- **F2 (minor):** the judgement ignored the result's own identity and comparison. It now also requires `mode` `restore`, `restore_of` (this restore's session open) and `world_match` `target`, as M6's accepted qualification does. Other fields are journaled with the terminal and not judged, and the doc says so.
- **F3 (minor):** the journaled closed summary was computed before the same event's late evidence. It is now computed after the whole event.
- **F4 (note):** the timed-out target is kept apart from an earlier mismatch marker.
- **F5 (note):** a link loss applies an already-passed acknowledgement deadline. A failed write keeps the class "attempted, outcome unknown", which is what it is.
- **F6 (note), not changed:** a native close processed after a BEAM deadline is recorded as BEAM's deadline close, confirmed, with the native's reason beside it (design 17.1). The resulting `ghost.close` to a closed native session is in the B2 delta.
- **F7 (note):** while closing, the acknowledgement deadline is scheduled.
- **T1 (test gap):** `deadline_share_hub_test` covers the share's send boundary through the hub and the connection's `not_after` end to end (30 / 30 repeated runs).
- **T2 (tests):** the in-time-answer-while-closing control was added and the `not_after` test was made margin-free. The hub suspensions (about 50–80 ms against 200 / 500 ms call deadlines) were kept.

While writing the T1 tests, two test-only mistakes were fixed before commit: a 40 ms window that could miss the 50 ms cadence, and an assertion that assumed one queued sample where two can be queued.

### 11.5 Gate and trace scenario

**Gate of record: `beam-gate-attempt2\` on `6d33f1d` (relay tree `da39d5e4`), PASS.** The commands and exit statuses are in `gate.txt` and each file.

| Step | Result |
|---|---|
| `mix compile --warnings-as-errors --force` (dev, 72 files); `MIX_ENV=test mix compile --warnings-as-errors --force` (84 files) | exit 0 / 0 |
| scoped `mix format --check-formatted` (B1's globs: the motion, peer, headless and command lib and tests, the test support, `config/*.exs`) | exit 0 |
| whole-tree format check (informational) | exit 1, on the same 12 M2-era files as B1's list; none of this stage's |
| areas: motion and peer; command; headless and boundary (each `MIX_ENV=test mix test --warnings-as-errors`) | 177 / 0, 207 / 0, 21 / 0; exit 0 each |
| five full suites, `MIX_ENV=test mix test --warnings-as-errors --seed S` (seeds 761930, 257607, 135268, 587268, 970298) | **831 tests, 0 failures, exit 0** each; no compile warning; no warning exception inherited |
| after the gate | no BEAM process, no project port |

**Counts:** 831 = B1's 750 + 81 new.
- reproducers 31: deadline order 13, deadline hub 4, restoration result 14;
- send boundary and the verifier's cases 13;
- share send boundary through the hub 2;
- restoration judgement 31;
- restoration journal 2;
- one TLS case;
- one destination case.

The existing tests' changes are listed in 11.3 and 11.4.

**Attempt 1 failed** (`beam-gate-attempt1\`, kept, with `beam-gate-attempt1-NOTE.txt`). On `c7a3490`, everything passed except full run 2 (seed 671013, 831 tests, **1 failure**, exit 2): H-A5's crossing step held no forward decision. The most likely cause — consistent with the evidence, not proven — is that the fake opens its session before BEAM activates it and closes it on its own clock at its open + 1,000 ms, so under full-suite load the session was closed natively before the sample injected at BEAM's bound − 60 ms. The fix was test-only (`6d33f1d`): a fake session overrun, and an assertion that the session is still open before the crossing. The gate script's summary column was blank for that run, because its regex expected "failures" while ExUnit printed "1 failure". The exit status was counted all the same. The regex now matches both forms, and the script as run is kept as `scripts/beam-gate-as-run-attempt1.sh`. The whole gate was rerun as attempt 2, because test inputs had changed.

**The retained trace scenario** (`trace-examples-attempt1\`, `scripts/trace-examples.exs`, on `6d33f1d`; fake native, owned loopback, `nonode@nohost`, not distributed; the journal and both traces copied whole after a check for the token and key material):
- **Topology:** command `38885`, motion `33157`, headless `35999`, all `127.0.0.1`.
- **A finite share:** closed `duration`, confirmed; 19 native samples, 19 relayed, 19 handed, 0 cancelled. At the sink: 19 received, last 19, 0 gaps, complete.
- **A clean session**, on a course ending 0.2 m from P: closed `stream_end:course_complete`, confirmed. 24 forwarded = 8 applied + 16 `skipped_identical`; 0 uncertain, 0 cancelled, 0 late; restorable. It was then **restored**: `motion.session.restore_judged` recorded `restored`, releases `true`, no reasons; its facts include mode `restore`, world_match `target`, dirty `false`, the same entity, control `unchanged`, invocation `reported`, effect `changed`. Exclusivity `:ok` afterwards.
- **An inexact session:** closed `postimage_mismatch` at the first inexact apply, confirmed. 12 forwarded = 5 applied + 6 skipped + 1 uncertain; 1 pending dropped on close; unresolved 15; not restorable (`closed_unclean`).
- **Sizes:** journal 55 records; host trace 153 (36 forwards and 36 acknowledgements, 38 samples, 19 relayed, 6 reports, 3 RTTs); headless trace 73. No deadline fired in this nominal scenario (no `ack_timeout`, `send_cancelled` or `ack_late` record). The deadline paths are evidenced by the reproducers, not by this example.

### 11.6 Performed, reused, untested

| Evidence | Status |
|---|---|
| Before-fix reproducers on the unchanged checkpoint; after-fix on the final code | **performed** (`before-fix-attempt1\`, `after-fix-attempt1\`) |
| Pure deadline, send-boundary and judgement rules; hub ordering with mailbox order checked; socket-level target and sample evidence; restoration end to end with the next M6 forward and new session as proof of exclusion | **performed**, fake native, owned loopback |
| Gate of record (compiles, scoped format, areas, 5 × 831 / 0) | **performed** (attempt 2; attempt 1 failed and is kept) |
| The retained trace scenario | **performed** |
| One focused verifier | **performed** (`d4720b6`) |
| The checkpoint identities (native5, content, M6 tags, B1, M7-A and M6 seals), M0, epmd | **reused** by identity, read only; the B1 seal re-verified |
| B1's TLS probes, the two-process harness, and B1's evidence | **reused**, not repeated (the two-process tests ran in every full suite) |
| Native qualification, content rehearsal, historical archive audit, game run, LAN, Mac | **not performed** (not authorized) |
| The failed socket hand-over cleanup (`:ssl.controlling_process` error) | **untested**: no existing seam; no injection framework was built |
| The motion link's 200 ms send deadline under a filled socket | **untested** (configured; never filled) |
| Real native enforcement of 17.1 / 17.2, real engine writes, moving-hero sampling, frame cost, F2, collision and coupling, two real game instances | **untested** (B2 and later)

### 11.7 The B2 handoff delta

What B2's native must enforce **independently** (design 17.4), beyond section 15.5:
- **Time on its own clock.** Every target is judged on its applying frame against the session's duration and target silence before the call, never after a queued timer. There is one pending slot and an acknowledgement for every target.
- **The restoration result** of 17.2, on the call frame:
  - `mode` and `restore_of`;
  - `requested_world_words`;
  - `postimage_world_words` and `world_match`;
  - `postimage_local_words`;
  - `postimage_parent`;
  - `postimage_dirty`;
  - `post_same_entity`;
  - `generation_post`;
  - `hero_control`;
  - `setter_called` and `effect`.

  These are the M6 transform result's names. A non-application status must not report an invocation or a change.
- **Close tolerance.** A `ghost.close` for a session it has already closed is ignored.
- **Unchanged from 15.5:** the pre-call checks, the untouched-word rule, the uncertain post-call close, and the autonomous closes.

The BEAM side does not depend on any of this for its own guarantees. It will judge the native's answers by these rules.

## 12. Bounded acceptance (2026-10-19)

**Authorization:** "Glacier Relay — M7-B1 acceptance and M7-B2 native offline implementation".

M7-B1 and its focused deadline and restoration correction (section 11) are **accepted for their demonstrated scope**: the BEAM, the fake native endpoint and owned loopback peers, including the headless peer in a second, non-distributed OS process over pinned TLS 1.3. Sections 1–11 stay exactly as recorded; nothing in them is rewritten by this acceptance.

The acceptance does **not** extend to:
- native enforcement of any rule — that is M7-B2's (`M7B2_NATIVE_RECORD.md`);
- any engine behaviour, any LAN, the MacBook, or two real game instances;
- the completion of M7, whose goal and exit are unchanged.

`Test.FakeMotionNative` is an interoperability and testing aid. It is not proof that a native enforces anything, and it is not the specification where it differs from the reviewed contract (design sections 15 and 17 govern). B2 implements two behaviours differently from the fake, inside the contract, and records why (`M7B2_NATIVE_RECORD.md` section 4): a second target while one is pending is **refused** (the fake supersedes it silently and counts it), and a postimage that differs from the request is acknowledged **`uncertain`** (the fake answers `applied` with `exact: false`). The BEAM judges both identically: application ends and the session is never restorable.

# M7-L3 — preparation of one game-host-to-MacBook LAN experiment (record)

**Authorization:** "Glacier Relay — M7-L2 acceptance and bounded one-game LAN preparation" (2026-10-20). It does two things:
- accepts M7-L2 run 1 for its demonstrated transport scope (`M7L2_LAN_TRANSPORT_RECORD.md` section 17);
- authorizes one sequential, offline, tooling- and documentation-only preparation pass for a later one-game LAN integration experiment.

M7-L3 is the working label of that next subdivision of M7-L.

**Status: preparation DONE offline (2026-10-20); ACCEPTED for its demonstrated offline scope (section 12). The attended run authorized with that acceptance STOPPED before live execution: the sealed `dest-wait` cannot establish its stationary-prefix admission (section 13). Option A was then implemented and validated offline (section 14: the source-sequence admission correction, 2026-10-20); two pre-existing defects found by its rehearsals remain for a decision. Awaiting review.** The later experiment would join two capabilities already demonstrated separately:
- M7-C: on one host, a real-player share to a headless sink, then a synthetic course driving Agent48;
- M7-L2: transport and accounting between the Windows/WSL host and the MacBook.

This pass did the following:
- corrected the kit's socket record;
- wrote the MacBook's game-facing headless peer;
- derived the game host's run kit from M7-C's;
- rehearsed the whole two-machine sequence on owned loopback against the frozen native6 probe.

It did **not** involve a game launch or installation, a Mac contact, a LAN socket, a live credential, or any change to the firewall, router, WSL or epmd. M7 stays open; M6 stays closed; no tag.

**Evidence:** `%TEMP%\glacier-m0\hitmen\m7l3-prep\`, claimed 2026-10-20T19:46:31Z, **sealed**: 4,247 entries, manifest `11cabfcc88070277f8826a7c67ab55f392e6769c394e01ea98a7b3582acbfc7e`. It verifies, has 0 unlisted files, its temporary manifest was written outside the root, and the guard refuses the root. The state root `~/.local/state/glacier-relay-m7l3-prep` is empty.

**Commits** (glacier-relay `main`; pushed):

| Commit | Content |
|---|---|
| `ff52ff6` | the M7-L2 acceptance (L2 record section 17; design section 26; this record opened) |
| `86c9071` | the socket observation (`tools/peer-transport/sockets.exs`) and its use in `peer.exs` |
| `aff8193` | the game-facing peer (`game-peer.exs`, `go.sh`), `start.sh` / `stop.sh` accepting it, `rebundle.sh` |
| `0ca801d` | a test-harness fix (the stand-in host's FIFO; section 9) |

The relay tree is unchanged (`90d40033`); the kit tree is now `2fd701c8`.

## 1. Basis

**Checkpoint** (`checkpoint-attempt1`, `readiness.py`, **43 / 43 ok**, read only):
- main `c3ea445d` = origin, clean; only `docs/` differs from the qualification source `9541c02`; its trees: relay `90d40033`, kit `4f473706`; `tools/content-deployment` `abf0a388`;
- ZHMModSDK `relay/m2` `8129d721`, clean; the tags unchanged (`6ee99b44…`);
- the WSL runtime by file hash;
- **the relay's existing dev build**, by a new read-only check (`build-identity.exs`):
  - 89 modules;
  - every source digest in Mix's compile manifest equals that file's blob in the frozen tree, and the manifest's sources are exactly the tree's `relay/lib/**/*.ex`;
  - ebin identity `aae979a5…`.

  This is the code the game host's console runs, and it is never rebuilt. It was compiled by the M7-L1 correction gate's `compile-dev` step (2026-10-20T08:34Z).
- native6: its five artefacts re-hashed (the DLL `91a7098f…`, the command probe `8315c6d1…`); native5;
- the placement content and the pinned Agent48 matrix;
- **the M7-L2 seal re-hashed in full** (242 / 242, `ecc8d118…`), including the preserved Mac runtime archives (aarch64 `2d59451e…`, x86_64 `d2268e54…`, Elixir `d69db875…`);
- the qualified bundle: its archive, and its sealed copy re-hashed (98 / 98, file set exact);
- the M7-C seal by its manifest, with the 46 kit and script files this pass derives from re-hashed against it;
- no BEAM or game; the project ports free; WSL `nat`; no Erlang boot file.

**Review basis (kept):** the architectural review read the pushed L2 record, its runtime amendment and the relevant kit code. It did not re-hash the PC or Mac evidence, inspect the USB stick, or run the exchange independently.

**Claim record:** the root was claimed from zsh, so `.evidence-root` has an empty guard hash. This repeats M7-L1's qualification (`claim-NOTE.txt`); the guard's identity is checked by the checkpoint instead.

## 2. The M7-L2 acceptance

Recorded in `M7L2_LAN_TRANSPORT_RECORD.md` section 17 and committed first (`ff52ff6`). The original verdicts and the failed reconciliation check are unchanged. The listener limitation is kept: "the connector listens on nothing" is supported, not established, and the historical check is not rewritten as PASS. Repeating L2 to change that verdict is not needed.

## 3. The socket-observation correction (`86c9071`)

**The defect.** M7-L1's `PeerKit.listeners()` counted every TCP port without a peer as a listener (`:enotconn`). A client socket that is still connecting has no peer either. That is how M7-L2's connector record came to list its own outbound socket.

**The correction:** `tools/peer-transport/sockets.exs`, `PeerKit.Sockets.observe/0`. It is an operator measurement, not a monitor. Having no peer no longer means anything.

- **The VM's view (always):** every `tcp_inet` port, classified by its explicit inet-driver state (`:inet.info/1`): `listen`, `connecting`, `connected`. Each entry carries its local and remote address and its owning Erlang process. A socket that closes during the observation is counted, not classified.
- **The kernel's view of this OS process (when available):**
  - Linux: `ss -tanpH`, this pid's lines only;
  - macOS: `lsof -nP -a -p <pid> -iTCP -F pnT`. **The macOS branch was tested through its parser only and never executed on a Mac.** There, the operator's second-terminal `lsof` stays the runtime check.
- **Two queries, never one result.** Each view carries its own time, and they are reported side by side, never presented as one atomic result.
- **The verdict:**
  - `observed`: the VM listing is complete and the kernel's listening set agrees;
  - `ambiguous`: an entry is unclassified, or the kernel disagrees;
  - `unavailable`: the VM listing failed. A failed query is never an empty success.
  - `no_listener?` and `only_listener?` are true only for an `observed` result.
- **One observation per reporting point.** `peer.exs` takes one at the endpoint start, one at identification and one at the finish, and writes each to the console and the event from the same result. M7-L2's two back-to-back calls had been presented as one record.
- **Its consumers:**
  - `peer.exs` and `game-peer.exs`;
  - the game host's console (its start-up listeners);
  - `cmd-m7l3.exs` `peer-connect` / `peer-close`: the console never listens beyond loopback;
  - `reconcile-l3.py`;
  - the kit rehearsal's new checks.

**The proof** (the attempts of record):

| Attempt | Result | What it shows |
|---|---|---|
| `sockets-test-attempt2` | **8 tests, 0 failures** | the controls below |
| `kit-rehearsal-attempt2` | **99 / 99** | M7-L1's cases, the kit's own socket record in both successful exchanges, and the M7-L2 race replayed (below) |

**The controls in `tools/peer-transport/tests/sockets_test.exs`:**
- an actual listener: reported as listening, with its owner, and the kernel agrees;
- a connecting client (SYN-SENT behind a full accept queue on loopback): reported as connecting, never as a listener. M7-L1's heuristic, run on the same socket, lists it;
- an established connection on both ends; and a VM holding only a client socket has no listener;
- the closure race;
- an observation failure (enumeration, state query, unexpected result): reported as unavailable;
- a disagreeing kernel listing: ambiguous;
- the `ss` parser, and the `lsof` field parser (parser only).

**The kit rehearsal's socket checks:**
- In both exchanges, the kit's own record agrees with the independent `ss` snapshot. The connector's three observations are `observed` with no listener; its connected socket appears only under connected. The listener's observations show only its socket.
- **The M7-L2 race replayed** on loopback (`l2-race`): a connector whose destination never completes a handshake. The kit's record caught the connecting socket `127.0.0.1:55688` under `connecting`, with `listening` empty in every observation; M7-L1's heuristic would have listed exactly that socket.

**Not changed:** the endpoint, the transport contract, the relay. No dependency, no host configuration, no socket-state dump.

## 4. The game-facing peer (`aff8193`)

`tools/peer-transport/peer.exs` is not a game peer:
- it plays its course from (0, 0);
- it starts it by itself once identified;
- it expects headless identities on both sides;
- it ends on two independent streams.

`game-peer.exs` is the MacBook's side of the experiment. It shares `peer.exs`'s `PeerKit` module **byte for byte**, so the bundle, configuration, network, runtime, credential, approval and output checks are the same code (the tests check this). What differs:

- **It only listens:** one declared private socket, for one declared game host. The game host's identity must have `client_kind` game and the expected label (design 20.2: only a headless peer listens; the game host connects out).
- **Phase 1, the share:** it records the host's real-player share in its sink and sends nothing back. Nothing received ever reaches its source.
- **Phase 2, the course:** only on the operator's `go.sh <out_dir>` does it send **M7-C's one course**. That course is `Motion.Course.out_and_back` from P's exact words `c2b2fae1,416d47ae`: 1.0 m along negative world x at 0.5 m/s, a 4,000 ms stationary prefix, 2,000 ms holds, 50 ms interval.
  - **The course is fixed.** It is compiled into the script; the configuration names the profile and the anchor, and both must equal the compiled values.
  - **It is checked before any socket,** against the generator's actual output: 241 samples, 12,000 ms, the first changing sample 82 at 4,050 ms, 1.0 m along −x only, the y word constant, both ends at the anchor, `Course.check` against M7-C's session limits.
  - **Its digest is printed** (`COURSE DIGEST 35b0d005…`) and equals M7-C's presented plan sample for sample. The game host's course plan prints the same digest, and the operator relays the Mac's.
- **One go per run.** It is refused before identification, while the share's stream is open (the phases never overlap) or after a course has run. A refused go is final.
- **The end.** The run ends when the game host closes the connection or the lifetime ends (60–900 s); it never reconnects.
  - **Exit status:**
    - 0: ended by the host, every inbound stream transport-complete, the course (if any) ended `course_complete`;
    - 3: the lifetime ended;
    - 4: the connection ended before identification or during the course;
    - 5: the host ended it with the share open;
    - 6: stopped; 7: the endpoint failed.
  - **Socket observations** are taken at the endpoint, the identification, the go and the finish.
- `start.sh` takes the kit script as an optional fourth argument; `stop.sh` accepts either peer; `go.sh` checks the recorded pid's command line as `stop.sh` does and never signals a process.

**Tests** (`game-peer-tests-attempt2`, **47 / 47**), against a stand-in game host (`tests/fake-host.exs`), not the relay's:
- PeerKit's identity with `peer.exs`;
- ten refusals before any socket;
- the normal sequence:
  - the share recorded transport-complete;
  - one go;
  - the 241-sample course received contiguous, its digest = M7-C's, declared synthetic with M7-C's description;
  - `stream.end` `course_complete`;
  - the host's close → exit 0;
  - every observation `observed` and listening only on its socket, which an independent `ss` view confirms;
- a go before identification, and a go during the share (both refused);
- the host closing during the course (exit 4) and during the share (exit 5);
- `stop.sh` (exit 6) and the lifetime (exit 3);
- a known-key scan of everything written (0 hits).

## 5. The bundle of record

`tools/peer-transport/rebundle.sh` builds a **kit-only bundle**. It refuses unless the qualified bundle verifies exactly and the commit's relay tree equals the one in the qualified `BUNDLE.txt`. It then copies the qualified bundle's compiled modules **byte for byte** and takes the kit from `git archive` of one commit. Nothing is compiled.

`rebundle-attempt1`, from commit `aff8193`:

| | |
|---|---|
| Directory | `m7l3-prep\bundle\peer-transport-aff81930c639\` |
| MANIFEST.sha256 | **`d8680690f104b96e6e415add30b6ff7acc20f746e1d0ced66bb2973d685e2d52`** |
| Archive | `3dff4ef4d94bfc386a24d6509658cf2d94d2ce0cc33032131e44748fda55f705` |
| Files | 101 listed |
| Compiled modules | its 90 `ebin/` lines are identical to the qualified manifest `20987b6c…` |
| Kit | every kit file equals commit `aff8193`'s |

The old bundle and its hashes are untouched, and its manifest does not cover the new kit. The application's 888 / 0 qualification and the M7-L2 runtime qualification are reused by identity; the kit's own qualifications are the new tests above.

## 6. The game host's run kit (`m7l3-prep\kit\`, frozen)

**Freeze.** The kit has 47 files. `SOURCE.txt` (`b0253ced…`) records each file's sha256 and whether it is identical, derived or new; `KIT-DIFF.txt` holds the 23 derivation diffs.
- 20 files are byte-identical copies:
  - M7-C's in-process M6 tools, placement, compare, decode and probe scripts, and the watcher;
  - L2's `logger-check.sh` v2;
  - `sockets.exs`;
  - `build-identity.exs`.
- The derivations were made by explicit, asserted edits (`scripts/derive-*.py`) wherever they were mechanical.

**What changed from M7-C, and why:**

| File | Change |
|---|---|
| `console.exs` | No local headless peer. The motion peer is Motion.Supervisor's qualified game-host connector (connect only) under design 20's `lan_ipv4` profile, from ONE pinned host-peer configuration (`host_peer.exs`: the Mac's socket, the host's `creds.exs` credentials, the Mac's leaf pin, the Mac configuration's and the bundle's hashes, the course digest). **No `reconnect_ms`**: one attempt at start, refused while the Mac listener is not up and never retried. Listeners recorded by `sockets.exs`. |
| `start-console.sh` | The host-peer configuration and its sha256. `mix run --no-compile` (the existing dev build). **`ERL_CRASH_DUMP_BYTES=0`**: the VM now holds both the run token and a LAN peer key. The listeners checked twice, by the console's own observation and by `ss`. |
| `cmd-m7l3.exs` | `peer-connect <window>`: the ONE operator-requested connection, at most 60 s, an attempt a second until one registers, never again. `logger`: the live console's own logger. Host-side share accounting. `course-plan`: also P's words and the Mac's digest. `counts`. **`dest-wait`** instead of `dest-run` (section 7). `peer-close`: waits up to 20 s for the Mac's stream to end, closes, checks no reconnection and no LAN listener. |
| `ident.exs`, `con.sh` | No peer link at the R2 baseline. A `peer-baseline` taken once after `peer-connect`, which every later check compares. The L3 action scope, with once-only counts for `peer-connect`, `share-open`, `dest-wait`, `restore`, `confirm-baseline` and `peer-close`. |
| `seq-dest.sh` | `prepare`: plan and go-ahead; R4 at P; the relayed Mac digest; identity; the binding inspection; qualification; the attestation; the unrouted baseline. The coordinator's GO comes next, then `arm-wait`: the one arming, then `dest-wait`, then the identity check. |
| `reconcile-l3.py` | M7-C's joins with the Mac's returned trace. The Mac's own record and socket observations. The host's console sockets. The no-session branch. |
| `make-l3-configs.py`, `validate-configs.exs` | Both peer configurations from one set of values; an independent cross-check (19 checks) of socket, prefix, initiator, labels, crossed pins, the Mac configuration's hash, the bundle and the course digest. |
| Install, rollback and readiness chain | The kit locates itself (live installation requires `m7l3-run1/kit`). The run ids `m7l3-run1(-a, -rehearsal, -preview)`. `cleanup-l3.sh`: no headless peer; the host key is **known in a material scan** of the evidence root and the state root's outputs **before** `creds-host` is shredded. `finalize-manifest.sh`: the temporary manifest outside the root. `verify-after.sh`: the Mac's returned outputs reconciled, the dev build re-identified. `run_manifest.py` / `record-check.py`: the L3 identities and qualifications (section 8). |
| `route-check.sh`, `creds-host.sh`, `scan-host.sh`, `usb-out.sh`, `arrival.sh` | M7-L2's helpers with the kit's own roots and the L3 bundle. `route-check.sh` now takes the expected source and interface as arguments, so the initiator is re-derived, never assumed from M7-L2. |

**The console's own logger** (the actual launch runtime; `m7 <label> logger`; every dry run): six checks ok, the same conditions as `logger-check.sh` v2:
- SASL not started and its reports off;
- the translator `sasl: false`;
- exactly `:default` plus OTP ssl's stock `:ssl_handler`;
- crash dumps off;
- a SASL-domain marker absent from `console.log` while an ordinary marker is present.

## 7. The proposed run: the choreography, the limits and the timing

The full runbook is `kit/RUNBOOK.txt`. The Mac's steps are in `packets/M7L3-MAC-PACKET-TEMPLATE.txt`, and the combined permission table in `packets/M7L3-PERMISSION-TABLE-TEMPLATE.txt`. The sequence:

1. **Preparation at the run.**
   - Claim `m7l3-run1` from bash; copy the kit verified against this seal.
   - Make record (a) from this pass's attempts of record.
   - Mac packet 1:
     - the bundle, `logger-check.sh` and the runtime archives;
     - the runtime installed inside the run directory with **the clean boot** (M7-L2's amendment, carried as a fixed step);
     - `compat-check` and `logger-check`, both passing outright, **before** any credential or TLS step;
     - the Mac's address and permission state read, and its own credentials.
   - On the PC:
     - `route-check` for the initiator as the Mac will see it;
     - the host's credentials;
     - the second-channel pin comparison;
     - `make-l3-configs.py`, then `validate-configs.exs`, then Mac packet 2.
2. **One combined permission table** (both machines and the game), then ONE fresh standalone "Ready". Nothing carries forward from M7-L2 or M7-C.
3. **R1.** Refresh (b), the token and the console. Its one start attempt toward the Mac is refused, as disclosed. The installation; HITMAN.
4. **R2** (menu). The identity baseline without a peer; the console's logger; `mstatus idle-no-peer`; the inspections.
5. **R3** (Paris).
   - Qualified at P; **the recording started now**; the share go-ahead.
   - **Only then** the Mac listener: the operator relays its `lsof` line and its `COURSE DIGEST` line.
   - `peer-connect`. The Mac's peer_up observation names the admitted connection, which must come from the initiator.
   - The peer baseline; ONE share (60 s).
6. **R4.**
   - The controls; the course plan, whose digest must equal the Mac's; the destination go-ahead.
   - The Mac operator pre-types `go.sh` without pressing Enter. `seq-dest prepare`.
   - **The coordinator's GO, at once,** then `seq-dest arm-wait`: one arming and the wait.
7. **R5.** The course. The operator's stop closes the session; the Mac's stream runs on to its end, unrouted.
8. **R6.** The decision: release at baseline, or a separately approved restoration. Then `peer-close`; the Mac prints FINISHED, and **the operator relays the shell's own `exit $?`** (M7-L2's exit status was kit-recorded only).
9. **R7.**
   - The game's exit and the final capture; `cleanup-l3`.
   - The Mac scans its outputs with its key known, removes its credentials and returns the outputs.
   - `arrival` PASS, and only then the Mac directory removed by its exact path.
   - `verify-after`; the seal, with the temporary manifest outside the root.

**Limits** (constants of the kit, never typed):
- **The share:** 60 s at 50 ms.
- **The destination session:** 20 s, ±1.25 m, 1.0 m/s, credit 100 ms; budgets 1. These are M7-C's.
- **The course:** M7-C's (241 / 12 s), not L2's 201-sample course.

**The timing design** (the reason for the order above):
- **Game loading and approvals do not consume the Mac's lifetime.** The Mac starts after R3 and the share go-ahead, with the recording already running. The proposed lifetime is **600 s**.
  - From the Mac's start, the expected budget is: the `lsof` relay (~60 s); the share (75 s); R4 (~20 s); the destination go-ahead (human); prepare (~10 s); arm-wait (≤ 30 s); the course (12 s); R6 (~30 s).
  - That is about six minutes plus the go-ahead's time.
  - If the lifetime ends first, the remaining phase does not happen. Nothing is extended.
- **`peer-connect`:** a window of at most 60 s.
- **The arming and the wait.** The arming keeps the committed 30 s TTL. `dest-wait` waits at most **25 s** inside it, and the binding inspection must be at most 60 s old at the open (the authority's rule).
- **The human "go" is measured in the stream's own samples, not by clocks across machines.** The session must open while the stream is still stationary:
  - at most **55** of its samples received before the open;
  - active by its sample **62**, about 1 s before the first changing sample 82.

  An early go is tolerated: the arming's identity gate takes about 3 s, during which the stream may already have started. A late go opens nothing.
- **`peer-close`** waits up to 20 s for the Mac's stream to end.
- **No new protocol.** The host never starts or stops the Mac's course, and no new network control message exists. Without a session, the Mac's samples are counted unrouted and authorize nothing.

## 8. Qualifications of record, reuse and what is not carried

| Attempt | Result |
|---|---|
| `sockets-test-attempt2` | 8 tests, 0 failures |
| `game-peer-tests-attempt2` | 47 / 47 |
| `kit-rehearsal-attempt2` | 99 / 99 |
| **`dry-run-A-attempt1`** | **PASS 49 / 49 (118 s):** the live sequence with the 60 s share (below) |
| **`dry-run-B-attempt1`** | **PASS 46 / 46:** the changed stop orchestration (below) |
| **`dry-run-C-attempt1`** | **PASS 38 / 38:** no go within the wait (below) |
| `run-rehearsal-attempt1` | **PASS (0 failures):** M7-C's installer and cleanup cases on a scratch game model, retargeted to L3. Case V plants real throwaway `creds.exs` credentials: the cleanup's known-key scan reports 0 hits, and the 4 files are shredded. |
| `deps-attempt1` | **DRIFT TEST PASS** (7 cases), for the derived `run_manifest.py` |

**Dry run A,** the live sequence:
- the console and the native6 probe; the game-facing peer from the bundle as a second loopback process, started only after R3; `peer-connect` identified in 220 ms;
- **the share:** native 950 ticks / 950 sent → host relayed 950 → the Mac sink 950, value for value;
- **the course:** 241 sent; 2 samples before the activation, then 239 during the session;
  - 220 forwarded (19 superseded) → 66 applied + 154 skipped-identical;
  - the native closed `course_complete`, clean, at the opening words;
- R6 at baseline → `confirm_baseline`, no restoration;
- `peer-close`; the Mac exited 0, `ended_by_host`;
- every Mac observation `observed` on its one socket, and the console's on loopback only.

**Dry run B,** the stop orchestration (no share):
- the operator closed the session mid-course;
- the Mac's stream ran on: 122 samples after the close, 3 counted `not_open`, never forwarded;
- R6 restore-eligible → the one restoration, judged `restored`, back at the opening words;
- `peer-close` waited for the Mac's stream end; the Mac exited 0.

**Dry run C,** the late go:
- `dest-wait` timed out after 25,006 ms and opened nothing (a HARD STOP; a later arming is refused);
- the late go's 241 samples arrived entirely unrouted;
- the Mac exited 0.

All of these are synthetic, with native-fake engine values: they prove the operator sequence's wiring and accounting, not LAN timing, a game or a Mac.

**Readiness previews** (this kit's readiness chain exercised inside this root; the run ids are refused by the live installer):
- `readiness-attempt2`, record (a) `m7l3-prep-a`: **ok 187 / 187** (170 performed now, 17 reused), pin `9e764bf3…`. The gate passes with the pin and refuses a wrong one.
- `refresh-attempt1`, record (b) `m7l3-prep-preview`: **ok 185 / 185**, pin `43f603a2…`. The game was read only; its two key files were captured.

**Reused by identity (not repeated):**
- the M7-L1 correction's BEAM gate of relay tree `90d40033` (888 / 0 ×5; `gate-beam-l1`);
- native6's 25-run loop, its import / export comparison and source scans, and its clean build;
- the accepted placement content; M7-L2's transport evidence and Mac runtime archives;
- the guard, timestamp, readiness, placement and content tests.

**Not carried:** the B2 BEAM gate and the B2 matrix, which are keyed to relay tree `da39d5e4` (M7-L1 changed it). The L3 dry runs are this kit's integration qualification against the native6 probe, and the 888 / 0 gate covers the BEAM at `90d40033`.

## 9. Disclosures and retained failures

1. **`game-peer-tests-attempt1` FAILED** 18 of 47 (`-NOTE.txt`).
   - The harness made the stand-in host's FIFO in its case directory. Under this root, on the Windows drive (drvfs), `mkfifo` is not supported, so the host never connected.
   - My development runs had used `/tmp`.
   - Fixed in the harness only (`0ca801d`: the FIFO in the Linux-filesystem state directory). No kit or bundle file changed.
   - Because that commit changed the kit tree, `sockets-test-attempt1` and `kit-rehearsal-attempt1` (both PASS) are superseded by attempt 2 (`tests-attempt1-superseded-NOTE.txt`).
2. **`readiness-attempt1`** was not ready: 186 ok, and the one FAIL was `relay-head`, because the acceptance and tooling commits were not yet on origin. They were final, so they were pushed (`c3ea445..0ca801d`) and the preview re-run (`-NOTE.txt`).
3. **The development iterations** are not of record (`dev-iterations\README.txt`; `dev-dry-run-*` in the root). They found defects that I fixed before the attempts of record:
   - the harness's request counter in a subshell;
   - **a defect of `game-peer.exs`**: a mid-course disconnect was reported as exit 0, because the driver ends a running course itself on a lost link;
   - the rehearsal's loose `peer_up` match, and the race case's connect window;
   - **`peer-close` cutting the Mac's still-running stream** after an operator stop (`dev-dry-run-B-attempt1`, FAIL 2).

   They ran on a development bundle of the working tree. Its throwaway keys were removed with `rm -rf` between iterations (a logical removal, not shredding); the last set was scanned against the retained outputs (0 hits) and shredded.
4. **The "PRIVATE KEY" text hits** in the kit rehearsal's work tree (2 files) are the scanner self-test's planted negative controls, not key material. Its own known-key scan reported 0 hits.
5. **A scratchpad removal** was refused by the coordinator tool's safety check, because its target was a shell variable. The removal was re-issued with literal absolute paths, as the check suggested.
6. **An `erl_crash.dump`** (2026-10-19, a throwaway VM's boot-time syntax error, from an earlier stage) is in the coordinator's scratchpad. It predates this pass, is not evidence and was left untouched; whether to keep it is the operator's decision.
7. **The bundle's `work/` directory** (the `git archive` extraction `rebundle.sh` used) stays inside the bundle's output directory and the seal. It is outside the bundle itself and holds no secret.

## 10. The later operator checkpoint: what is genuinely unresolved

**Fixed by this preparation:**
- the code, kit, bundle, content and native identities;
- the course and every limit;
- the order and the timing rules;
- the stop paths;
- the transfer channel (the USB stick and the conversation as the second channel), unless the operator changes it;
- the Mac run-directory pattern;
- retention: removal after a verified arrival.

**To be observed, refreshed or decided at the run** (never assumed from M7-L2 or M7-C):
1. **The authorization itself**, which approves the game and LAN permissions together.
2. **The run id and roots** (`m7l3-run1`; the Mac's `/Users/justsomedude/dev/glacier-relay/runs/m7l3-run1`, new and used only for this run).
3. **The addresses:** the Mac's en0 address and prefix; the Windows Wi-Fi address and the WSL NAT address; **the initiator as the Mac will see it** (from `route-check`; it is M7-L2's 192.168.1.11 only if the route still says so); port 4760 free on the Mac.
4. **The prior OS permissions,** read and never changed: the Windows firewall per profile and the Hyper-V WSL policy; the Mac application firewall (off in M7-L2: still not a firewall-on qualification); Local Network access for the Mac's launch terminal.
5. **Fresh per-run credentials** on both sides, and their second-channel comparison.
6. **The digests:** the packet `SHA256SUMS`, the Mac configuration and the host-peer configuration.
7. **The Mac runtime's re-installation** (the archives are the preserved ones) and its clean-boot result; `compat-check` and `logger-check` passing.
8. **The durations proposed for approval:**
   - the Mac peer's lifetime, 600 s (or another value from 60 to 900 s);
   - the `peer-connect` window, 60 s;
   - `dest-wait`, 25 s inside the 30 s arming.
9. **The recording method and save location,** and its retention.
10. **At the run:** the standalone "Ready"; the share go-ahead; the destination go-ahead; the coordinator's GO; any restoration go-ahead.

## 11. What this establishes, and what it does not

**Establishes, offline and on owned loopback only:**
- **The corrected socket record:** a connecting client is never reported as a listener, and a failed query is never an empty result. M7-L2's race reproduces, and is classified correctly.
- **The game-facing headless peer:** its course is M7-C's, sample for sample, and its start is the operator's alone. It cannot run a course during the share, after a refused go, or twice.
- **The adapted game-host run kit drives the whole two-machine sequence** against the frozen native6 probe: the late peer connection; the share to the remote sink; the destination session fed by the remote stream, admitted inside its stationary prefix; the operator's stop with the remote stream running on; the restoration; the late-go refusal; the closes; the cross-process reconciliation.
- **The install, rollback and readiness chain** retargeted, rehearsed and previewed.

**Does not establish:**
- anything on the MacBook;
- any LAN, firewall or Wi-Fi behaviour;
- LAN timing, one-way delay or motion-to-display latency;
- the real game, native6 under HITMAN across a LAN, collision, or a second game;
- real-player mirroring, multiplayer, or M7 completion.

A later, separately reviewed authorization and fresh operator approvals govern the one-game LAN experiment.

## 12. The review's acceptance (bounded; 2026-10-20)

**Authorization:** "Glacier Relay — M7-L3 reviewed attended one-game LAN authorization" (2026-10-20), dispatched by Stephen. It does two things:
- accepts this preparation for its demonstrated offline scope;
- authorizes, after one combined operator checkpoint, one attended HITMAN load and one Paris attempt on the Windows host, connected to one Mac headless peer. Section 13 records why that run did not start.

- **Accepted, for its demonstrated offline scope:** sections 3–8 as rehearsed on owned loopback against the frozen native6 probe:
  - the socket correction;
  - the game-facing peer;
  - the bundle of record;
  - the PC run kit and its dry runs;
  - the install / rollback / readiness chain.

  Section 11's limits stand.
- **The review's basis:**
  - It inspected this record, the socket-observation code, the game-facing peer and the GO helper.
  - It did not independently execute or re-hash the PC run kit, its local rehearsal outputs or the sealed artefacts.
  - In particular, the sealed `dest-wait` was supported by this record, not by an independent source inspection in that review.
- **Kept as written:** the retained failures of section 9. The claim record's missing guard hash stays disclosed (`claim-NOTE.txt`), beside the independently pinned checkpoint identity.
- **Outside the run:** the pre-existing scratchpad `erl_crash.dump` (2026-10-19).
  - It is not copied, uploaded, inspected or deleted, and is treated as potentially sensitive.
  - Its retention is a separate decision, not a run prerequisite.
- M6 stays closed. M7-C and M7-L2 keep their bounded acceptances. M7 stays open. No tag.

## 13. The coordinator's `dest-wait` inspection before the checkpoint: a tooling gap; the run stopped before live execution (2026-10-20)

**The instruction.** The authorization required the coordinator, before the Ready, to inspect the sealed `dest-wait` gates and report their precise meaning. If "the actual code cannot establish its claimed stationary-prefix admission", the coordinator was to stop before live execution with that specific tooling gap, without reinterpreting the rule or changing qualified files. The code cannot establish it, so the run stopped here.

**The bytes inspected:**
- `m7l3-prep\kit\cmd-m7l3.exs`, sha256 `533bed531d611afe5a6a1db1bb6313db9309003888507d03bf12293ed321ae61`. This equals its line in the seal manifest, which re-hashes to `11cabfcc…`.
- The relay at tree `90d4003303d721035f23e91c8939b4b4a61d6338` (`relay/lib` `156ac80b…`, identical at `9541c02` and `695d410`): `motion/hub.ex`, `motion/destination.ex`, `peer/connection.ex`, `headless_peer/driver.ex`. Their compiled modules are the console's dev build and the bundle's `ebin`.

**What the two admission gates compute:**

| Gate | The code | What it establishes |
|---|---|---|
| `dest.stream-early-enough-to-open` | `k_pre` = the hub's `unrouted_samples` counter minus its value at `prepare`; `k_pre <= 55` before `open_session` | The host received at most 55 samples unrouted since `prepare`. With no Mac stream at `prepare` and exactly one new stream, they are that stream's. |
| `dest.session-confirmed-before-the-first-changing-sample` | Active within `t_seen` + 3,050 ms on the host clock (`t_seen` = the stream's first sight in the hub's map), and `k_act <= 61` | The session became active within that host-clock window, with at most 61 samples received by then. |

Neither gate reads a sample's source sequence number or source time. Two texts describe the source position, but the code measures a receipt count:
- section 7's wording ("measured in the stream's own samples … active by its sample 62");
- the code's comment ("the stream's own sequence measures how early the session is").

**Why the count is not the source position.** The count equals the latest received sequence number only if the Mac sent every one of samples 1 … k. The committed source can omit samples while its schedule advances (`start + k × interval`):
- **Spacing:** after a scheduler delay, an overdue sample less than 45 ms after the last one sent is not sent (`spaced`).
- **Backlog:** above 8 queued samples, the producer drops the sample (`dropped`).
- **Stale:** a queued sample that waited more than 100 ms in the Mac's connection is discarded before it is written (`samples_stale`). The driver has already counted it as sent.

TLS keeps the rest in order, and the host's receive path drops nothing. So after g omissions, the latest received sequence number is k + g. The host cannot see g before the stream's end (`stream.end` carries `last_seq` and `sent`):
- `Hub.status().peer.streams` shows only `source_kind`, `src_clock`, `label` and `course`;
- the hub's per-stream `received` field is never incremented;
- an unrouted sample only increments the hub-wide counter. It is not traced, and its sequence number is not kept.

The host's elapsed time does not close the gap. Its time since the stream's first sight is a lower bound on the source's schedule, not an upper bound, unless one-way delay is bounded, and the run has no such bound.

**Consequence.** `k_act <= 61` implies only that the latest received sequence number is at most 61 + g. The claimed property is that the session is active before sample 82 reaches the host. It therefore holds only while g <= 20, and g is unobservable when the gate decides.

If the property fails, the first routed sample is already displaced from P. The Destination has no acquisition exemption:
- A first target within 1.0 m/s × min(Δr, 100 ms) of the opening snapshot, so at most 0.1 m, is forwarded. That is an acquisition step inside the session's limits, not M7-C's exact course from P.
- A larger one is withheld (`refused_displacement`, never clamped).

This follows from the contract; the path was not executed. The session's safety envelope holds; the stationary-prefix admission and its exact-P opening do not.

**What the evidence shows:**
- On loopback, dry run A omitted nothing. 2 samples arrived unrouted at activation, and the session then received sequences 3–241: 239 distinct samples, all validated.
- In M7-L2's one LAN run, the Mac's source omitted none (`spaced`, `dropped`, `samples_stale` and `samples_expired` all 0; 201 of 201 sent).
- Neither shows that omissions cannot occur across the Wi-Fi LAN.

**Not done (the stop):**
- no `m7l3-run1` evidence root or state directory claimed (the run id stays unused);
- no kit copy, readiness record, packet or USB write;
- no Mac contact or runtime;
- no credentials or run token;
- no console, installation, game launch or LAN socket;
- no permission table presented, and no Ready asked for.

The qualified files are unchanged. The authorization's run-specific values were not exercised and do not carry forward:
- the 600 s Mac lifetime, contingent on Stephen's approval in the table;
- the accepted start-up connection attempt.

**The gap, for a decision.** The host has no observation of a new stream's source position before a session is bound to it. Three ways to close it; each needs its own authorization, and none is started:
- **A (recommended): make the source position observable.** The hub keeps, per open peer stream, the count and the highest sequence number it received unrouted, and shows them in `Hub.status()`. `dest-wait` then gates on that sequence number (<= 55 at the open, <= 61 at activation) and records the count–sequence gap. This is an application change:
  - a new relay tree and a rebuild of the console's dev build;
  - the relay suites;
  - for the Mac bundle, which carries the compiled modules: either a new bundle identity, or a reviewed statement that the Mac peer does not load the hub.
- **B: verify afterwards (kit only).** `dest-wait` records the session's first routed sequence number from the host trace, and judges "admitted in the prefix" only if it is below 82.
  - This establishes the fact afterwards but prevents nothing; the acquisition step of at most 0.1 m stays possible.
  - It changes a qualified kit file and relies on the Destination's envelope.
- **C: run with the count gate as a disclosed limitation**, and reconcile afterwards from both machines' files (the Mac's per-sample source outcomes and stale count; the host's first routed sequence number). This changes the stated admission rule, which only the reviewer can do.

## 14. The source-sequence admission correction (option A; 2026-10-20)

**Authorization:** "Glacier Relay — M7-L3 source-sequence admission correction" (2026-10-20), dispatched by Stephen. It chose option A of section 13 and authorized one sequential, offline BEAM / test / operator-tooling pass, implemented and validated here. Options B and C are not used. Sections 12–13 stand as written. The attended run of section 12 is **not** resumed by this pass: `m7l3-run1` stays unused, and the corrected artifacts return for review first.

**Basis, kept apart:**
- **Source reasoning:** the architectural review read the committed Hub, facade, activation, Destination and source paths, and section 13. It did not execute a counterexample or inspect the sealed kit.
- **Coordinator-reported observations:** section 13's reading of the sealed `dest-wait`.
- **Newly performed tests:** everything below. Each is an attempt directory in `m7l3-admission\` (index: `ATTEMPTS.txt`).

**Evidence:** `%TEMP%\glacier-m0\hitmen\m7l3-admission\`.
- Claimed from bash 2026-10-20T22:53:32Z, so the claim record carries the guard hash `426347f2…`.
- **Sealed:** 6,009 entries, manifest `655ec5f875759d3413e569c3a8af0a56d9838da13f06ac5f0bedc7b9b310be2e`. It verifies and has 0 unlisted files. The temporary manifest was in the state root, and the guard refuses the root.
- The state root `~/.local/state/glacier-relay-m7l3-admission` is empty.
- **Final scan:** 6,009 files, 0 key material. The 4 armour-like texts are the scanner's own source and its negative fixtures.
- **Frozen-basis checkpoint:** 37 / 37 (`checkpoint-attempt1`):
  - the Git refs and trees, the SDK and the tags;
  - native6's artefacts re-hashed;
  - the m7l3-prep seal, with its kit, bundle, packets and scripts re-hashed against it;
  - the sealed `cmd-m7l3.exs` (`533bed53…`);
  - the old Mac bundle;
  - the preserved Mac runtime archives;
  - the old dev build (`aae979a5…`);
  - no process, ports free.

**Commits** (glacier-relay `main`; pushed):

| Commit | Content |
|---|---|
| `75b9532` | the contract, before code: design section 29 (normative) and ADR 0010 amendment 15 |
| `4ea020f` | the strict counterexample, on its own (it passes against the unchanged application code) |
| `abf3922` | the correction: `Motion.StreamProgress` and `Motion.Admission` (new), `Motion.Hub`, `Motion.Destination`, the `Motion` facade, `Command.MotionControl` |
| `8613481`, `4666102` | the regressions; then AD-5 / AD-6 asserting the behaviour before the reason |

The application tree is now `62ad2803` (it was `90d40033`); the kit tree is unchanged (`2fd701c8`). No native, wire, codec, limit, deadline or budget change.

### 14.1 Before and after

| | Before (sealed `dest-wait`, `533bed53…`) | After |
|---|---|---|
| What admits the session | the hub's count of unrouted samples received since `prepare`: <= 55 before the open, <= 61 at activation (kit only) | the stream's own **highest observed source sequence**: <= 55 at preparation and <= 61 when the native's open result is processed, both inclusive, the sample qualified and at exactly P; then the **first target** a qualified prefix sample at exactly P with sequence <= 81, confirmed before anything displaced |
| Where it is enforced | `dest-wait` only (a status reading, then a later open) | `dest-wait` (its reading); the hub at `prepare_session` (its current record); the hub at activation (the same record, before any sample is routed); the destination at its first target |
| Receipt 2 at source sequence 83 | admitted; sequence 84 (0.075 m) applied as the first target (the counterexample) | refused at preparation; nothing issued |

The numbers belong to the opted-in course (`stationary_prefix`: anchor, course text, 55 / 61 / 82), never to motion in general. A session opened without an admission keeps the earlier contract exactly (the counterexample still passes on the corrected code).

### 14.2 Per-stream progress and its context (design 29.2)

The hub keeps `progress` for every stream open on the current connection, updated for every processed sample (unrouted, opening, or routed), and shows it in `Hub.status()`:
- `received`; `advanced` / `not_advanced` (duplicates and older samples, which never move `high` or overwrite it);
- `first_seq`; `index_gaps` (observed gaps, cause not inferred);
- `high`: sequence, x / y words, `qualified`, source time and receiver time, kept apart; nil until the first sample.

The record is invalidated with its context:
- it is gone with the stream (`stream.end`), the connection and the boot;
- a stream identity that ended on the connection and is opened again is marked `reopened` and cannot qualify;
- a new connection generation starts with no streams;
- a stream bound once is never bound again.

Decision evidence goes to the trace (`hub.admission`, at both phases) and the journal (`motion.session.admission_not_met`; the activation entry's `admission`). The authority journals the admission with the approval and checks its anchor against the qualified inspection's x / y (`admission_anchor_not_the_inspection`).

### 14.3 How the three races are closed

- **Status reading versus preparation:** the hub decides at `prepare_session` from its own current record (AD-4: an earlier reading of 50, then 56 at P, is refused).
- **Progress while the open is in flight:** the record is re-evaluated when the authority's cast with the native-open result is processed, before any sample is routed. A failure takes the existing close-on-activation path: the open was issued and applied natively, no target is sent, and nothing is refunded (AD-5).
- **The first target:** a prefix observation at activation is not enough.
  - While acquiring, a sample past the prefix or off the anchor closes the session unforwarded, even inside the 0.1 m bound. That covers both a displaced 83 as the first routed sample (AD-6, dry run E) and an anchor sample still pending and superseded by a displaced one (unit).
  - The one in-flight slot keeps a displaced target behind the acquisition target.
  - Acquisition is established only by its acknowledgement at the anchor: `skipped_identical` or exact `applied`.

The guarantee is a locally qualified start in processed observations and forwarded targets. It is not proof that the Mac is stationary, that no newer bytes sit in transport buffers, or anything about freshness or latency.

### 14.4 Tests, controls and the gate

- **The counterexample:** `counterexample-old-code-attempt1`, then the committed bytes on a copy of `4ea020f`. Against the old code, receipt 2 at sequence 83 passes the former count gate and sequence 84 is applied.
- **New tests: 35.**
  - **Pure (17):** progress semantics; validation; inclusive bounds 55 / 56 and 61 / 62; acquisition.
  - **Integration (17):** on the real fake native and motion socket, checking the `ghost.target` lines the fake read and what it applied.
  - **The counterexample (1).**

  The integration cases (AD-1 … AD-8) are:
  - M7-C's unchanged course from the real headless driver over TLS;
  - receipt 2 at 83 refused, with nothing issued;
  - benign prefix omissions pass;
  - the current record wins over an earlier reading;
  - crossing 61 while the open is in flight closes before any target, with 61 itself inclusive;
  - a displaced 83 after a valid activation is closed unforwarded;
  - nothing manufactures eligibility: unqualified, off-anchor, none, older-after-higher, course, another stream, unknown, reopened, a new generation, the inspection's anchor, non-synthetic, malformed;
  - stream end, operator close and peer loss while opening keep their reasons.
- **Controls:** on disposable copies of the committed tree. The unmutated control is 35 / 35. Each protection removed alone makes its regressions fail:

  | Protection removed | Failures | Including |
  |---|---|---|
  | Preparation check | 6 | AD-2 |
  | Activation check | 4 | AD-5, whose session then **activated** |
  | First-target gate | 4 | AD-6, where **sequence 83's target bytes reached the native** and were applied (printed `~c"S"`) |
- **The BEAM gate of record** (`beam-gate-attempt1`; `4666102`, relay tree `62ad2803`; seeds 271828 314159 161803 141421 577215, declared before the runs):
  - strict dev and test compiles, and the scoped format check;
  - the areas: 269 (peer + motion), 207 (command), 21 (headless + boundary), 11 (web endpoint);
  - **five full suites, 923 / 0** (888 + 35). PASS; no leftover process or port.
- **The console's build:** the gate's compile-dev step built the dev build `acbe456c80426e3826e3d7eaa42020d3d3eb4e2ca0d6b9990280a956efb8da15` (91 modules), identified by `build-identity.exs` against `4666102`. The dry runs ran it.

### 14.5 The bundle, the kit and the packets

- **The bundle:** `bundle.sh` of `4666102`. The source-bundle path was used, never the kit-only rebundler.
  - Name `peer-transport-46661029c862`, 103 listed files (91 modules).
  - `MANIFEST.sha256` `645624b4b1213e7bb8cc73b2c59ae4d1ab6f96e1d51a9a7aff5724b6a118ae83`.
  - Archive `768cc8db823af85a50cdbcd253290334f6b7584a4cfe5507d18b5cc3f9f541e2`.
  - `game-peer.exs` and the rest of the kit are the commit's, unchanged.
  - Tested on the new bundle: game-facing peer tests 47 / 47; kit rehearsal 99 / 99.
- **The PC kit:** `m7l3-admission\kit\`, 49 files, copied from m7l3-prep and verified against its seal (49 / 49). Ten files changed; the diffs are in `kit-derivation\KIT-DIFF-ADMISSION.txt`, and `SOURCE.txt` (`a8771106…`) was appended:
  - **`cmd-m7l3.exs`** (`05d32c78…`), whose `dest-wait`:
    - waits for exactly one new stream, with a sample, under the current pinned peer and its generation;
    - shows the stream's source progress, and gates on it rather than on unrouted deltas;
    - opens with the admission and the peer generation;
    - reads the hub's activation evidence from the journal;
    - checks the acquisition. `counts` also records the streams' progress;
  - `seq-dest.sh`;
  - `RUNBOOK.txt` (`73bda90a…`);
  - `run_manifest.py`:
    - the new bundle, the dev build and this gate (the M7-L1 gate is historical only);
    - the socket controls reused by their actual file identities;
    - this root once sealed;
  - `record-check.py` and `relied-on.py`;
  - and the bundle path in `cleanup-l3.sh`, `creds-host.sh`, `run-rehearsal.sh` and `scan-host.sh`.
- **The packet templates** (`m7l3-admission\packets\`):
  - the Mac packet (`7ae9f649…`): the new bundle and its counts;
  - the permission table (`78f18ef8…`): the corrected code and the admission line.

  The m7l3-prep templates stay sealed there, superseded.
- **Superseded readiness pins** (kept, never overwritten): m7l3-prep's record (a) preview `9e764bf3…` and record (b) preview `43f603a2…`.

### 14.6 The rehearsals against the frozen native6 probe

All dry runs used the run console, the corrected kit, bundle and build, and the frozen native6 probe.
- **A, B and C** use the unchanged game-facing peer from the new bundle.
- **D and E** use `scripts\scripted-peer.exs`, a rehearsal control and never a kit or bundle file. It is `game-peer.exs`'s listener and declaration, sending M7-C's exact course words for the sequence numbers the driver releases: the game-facing peer cannot omit chosen indices.

Of record (the final harness `d3117c56…`):

| Dry run | Result | What it shows |
|---|---|---|
| A (attempt 5) | PASS 50 / 50 | share 948 sent → 948 relayed → 948 recorded by the Mac's sink, value for value; admitted at source sequence 2 (preparation) and 4 (activation); acquisition at sequence 5 at P; 66 applied; course complete at the opening words; reconciliation |
| B (attempt 3) | **FAIL 40 / 47** | the operator's close and the admission and acquisition checks ok; then finding 1 below (one boundary refusal) → the kit's HARD STOP → the restoration refused under it |
| C (attempt 2) | PASS 38 / 38 | no stream within the wait: nothing opened, HARD STOP |
| D (attempt 1) | PASS 39 / 39 | receipt 2 at source sequence 83: nothing opened; the former gate's quantity (2 <= 55) reported beside it; the stream ends unrouted |
| E (attempt 1) | PASS 42 / 42 | admitted at sequence 1; then 83 … 241 released the moment the session was active: closed `acquisition_missed:past_prefix:83` before any target; the probe attempted no setter call; HARD STOP; R6 read-only at baseline |

**Also:**
- the installer / cleanup rehearsal: PASS; in case V the known-key scan is clean before the 4 credential files are shredded;
- the drift test: PASS, 7 cases;
- **record (a) preview: NOT READY.** 188 ok and 1 FAIL (`dryrun-b`), 0 invalidated, 17 reused; pin `24939057…`. Every entry this correction rewired is ok. The refresh (b) preview needs an ok record (a) and was not performed.

**Retained failures and superseded attempts** (all kept; `ATTEMPTS.txt`):
- A attempts 2 and 4 failed on finding 1. Attempts 1 and 3 passed with earlier harness versions.
- B attempts 1 and 2 failed on finding 2; every PC-side check passed in them.
- C attempt 1 failed only on the sealed harness's message pattern, since `dest-wait` now says "no stream with a sample".
- The harness's E check was fixed twice, the second time for a stray quote caught by `bash -n` before any run.
- The first kit verification record was cut to three lines by a pipe; the complete record supersedes it.
- An attempt to remove a scratch copy through a variable was refused by the safety check; it was redone with literal paths, and the scratch copy was left in the scratchpad.

### 14.7 Findings for a decision (pre-existing; not changed here)

1. **The unchanged envelope's boundary refusal becomes the kit's HARD STOP.**
   - **The mechanism:** after a supersession forced by forward pacing, a two-step target can be forwarded at exactly 50 ms of credit. Float32 position words put it at 0.0500031 m against an allowance of 0.05 m, so it is withheld (`refused_displacement`). That is correct and harmless: the course goes on.
   - **The kit's response:** the M7-C-derived `dest.no-uncertain-no-refusal` treats any BEAM refusal as critical. The session is classified a HARD STOP, and the baseline release or restoration is then refused.
   - **The rate (diagnostic, not of record):** on the same course with no admission, on the fake native, 4 of 8 runs on the **old** code and 1 of 8 on the corrected code. In the dry runs here it was 2 of 5 A runs and 1 of 3 B runs. None of m7l3-prep's six rehearsal sessions or M7-C's one live session hit it.
   - **Status:** this pass is barred from timing-policy relaxation. The decision (the kit's classification, the destination's boundary arithmetic, or accepting it) is the reviewer's.
2. **`game-peer.exs` can crash at its very end** (line 574, unchanged since `aff8193`).
   - **The mechanism:** after its course ends, the peer reads `Endpoint.status` and then `Connection.status`. The host's `peer-close` closes about 20 ms after the stream end, and in B's timeline the connection exited between the two reads.
   - **The effect:** exit 1, with no `summary.json`. The Mac's finish record is lost; this is not a safety issue.
   - **Status:** a live run can meet it whenever `peer-close` lands at the stream end. The pass required the game-facing peer's behaviour unchanged, so it was not fixed.
3. **The fake native echoes `ghost.closed` reasons unbounded**, where native6 bounds them to 64 bytes. This was met while writing the tests. The new reasons are kept short instead (`"beam:" + reason` within 64 bytes); the fake is not changed.

### 14.8 Performed, reused, not executed

- **Reused by identity:**
  - native6, its loop, imports, scans and clean build;
  - the content;
  - the socket observer's controls;
  - the Mac runtime archives;
  - the accepted L2 evidence;
  - the guard, timestamp, readiness, placement and content tests.
- **Not executed:**
  - the activation-boundary race against the probe: only in ExUnit, with the fake's delayed open answer, since it is not deterministic with the probe;
  - the refresh (b) preview;
  - anything on a Mac, a LAN, the game or a live credential;
  - the macOS `lsof` branch.

No timing claim is made.

**Next (not granted):** review. The attended run needs the two findings decided and a fresh authorization with new game and LAN approvals; nothing resumes automatically. M6 closed, M7-C and M7-L2 accepted, M7 open; no tag.

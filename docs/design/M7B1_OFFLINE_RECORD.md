# M7-B1 — offline implementation record (BEAM, fake native endpoints, owned loopback peers)

**Status:** DONE offline (2026-10-19), awaiting architectural review.
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

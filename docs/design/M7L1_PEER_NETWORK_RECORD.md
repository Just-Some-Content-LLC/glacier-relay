# M7-L1 — the opt-in peer-network profile and the transport-test kit (record)

**Status:** DONE offline (2026-10-20), awaiting review. **Corrected** by a later, separately authorized pass (section 14, appended; sections 1–13 unchanged, their gate still NOT MET as recorded): the default listener's refusal and acceptor lifecycle, `Motion.Hub.abandon`, and the three failing test families; its own five-suite gate on the corrected inputs PASSED.
- Implemented and qualified **on the Windows/WSL host only, on owned loopback sockets**.
- No LAN socket was bound or contacted. Nothing ran on the MacBook, and no firewall, WSL, router or epmd setting was touched.
- No HITMAN, DLL, content or real credential was involved.
- No tag was created or moved. M7 stays open; M6 stays closed.

**Authorization:** "Glacier Relay — M7-C acceptance and M7-L1 offline peer-network preparation":
- M7-C run 1 accepted for its bounded one-host scope (`M7C_ATTENDED_RECORD.md` section 11);
- one M7-L1 pass: an explicit, opt-in peer-network profile and a minimal two-machine transport-test kit.

**Contract:** `M7_NETWORK_GHOST.md` section 20 and ADR 0010 amendment 14 (commit `47c2147`), written and committed **before** the code.

**Evidence:** `%TEMP%\glacier-m0\hitmen\m7l1-offline\`, sealed, 732 entries, manifest `4cf04a32299ffa1180c821a80061467312e480969b666ba5a768433897462d89` (verifies; its temporary file was written outside the root; 0 unlisted files). The external M7-C video is referenced by hash only; the 13 stills are in the root. Also the state root `~/.local/state/glacier-relay-m7l1` (ext4; the disposable rehearsal credentials, removed after their scan).

## 1. Basis

**Frozen inputs, verified locally** (`checkpoint-attempt2`, `readiness.py`, 33 / 33 ok, read only):
- glacier-relay `main` `4abbdd3e` = origin, clean (relay tree `da39d5e4`); the M7-B2 acceptance `8d9f9083` is an ancestor;
- ZHMModSDK `relay/m2` `8129d721` = origin, clean;
- every tag on both repositories unchanged;
- the runtime by file hash (OTP 28.4.2, Elixir 1.19.6);
- native6 (`91a7098f…`, its five-file manifest re-hashed) and the placement content (`5ac64848…` / `58e9a10f…` / `9433888b…`), by identity;
- the sealed `m7c-run1` root re-hashed in full (3,545 / 3,545, manifest `5da4a64a…`), and the M7-C video by hash in place (`6a1fc3db…`, 417,940,283 B);
- the game at M0 (26 / 26, no run files); no HITMAN or BEAM process; the project ports free; the shared epmd (pid 45286, `0.0.0.0` / `[::]:4369`) present, reported and not touched.

Checkpoint attempt 1 was refused by `readiness.py` itself before any check, because my manifest generator left out its `checks` list. It is kept with a note.

**What the review checked.** The architectural review checked remote heads and committed records, not the local suite executions, the video's contents or the Windows restoration. That distinction is kept. This pass verified only the inputs it relies on, not the historical archive.

## 2. M7-C acceptance

Recorded first, as `M7C_ATTENDED_RECORD.md` section 11 (commit `6e82059`), with HANDOFF and ROADMAP, without closing M7 or touching any tag.
- The accounts are recorded by layer, exactly as the authorization states them.
- The section 9 wording on Agent48 was corrected to a hypothesis.
- The retained video was inspected **once**, as 13 stills and one crop strip (`m7l1-offline\media-review\`), using built-in tools. They show the second figure displaced away and back against fixed scenery inside the session's interval. "Gradual" stays testimony, and no frame alignment is inferred.

## 3. The boundary amendment, before code

`M7_NETWORK_GHOST.md` section 20 and ADR 0010 amendment 14 were committed as `47c2147` before any code: what does not change; the one `lan_ipv4` profile; the headless connector; what is not authorized.

## 4. The implementation

| Commit | What |
|---|---|
| `f08edd3` | relay: `Peer.Network` (new, pure); `Peer.Endpoint` on the socket plan; `HeadlessPeer` `role: :connect`; the listen socket redacted from `format_status`; docs and config comments |
| `5fd1663` | relay tests: policy, loopback endpoints, wiring, two processes |
| `160d4eb` | tools: the peer transport kit (the verifier's frozen draft ends here) |
| `0ed6633` / `210646f` / `2f8c172` | the verifier's findings: relay lib, relay tests, kit |
| `8ef739a` / `f9d7f93` | gate attempt 1's correction: exact accounting in the tests; transport completeness in the kit |
| `3d55a8e` / `aae5999` | gate attempt 2's correction: flow-only assertions for the game-host share tests; connection drops in the exact accounting |
| `dba921b` | kit rehearsal attempt 1's correction: `scan.exs` self-test names distinct when case is ignored; planted material always removed |

The final trees are relay `5f63cde9` (gate attempt 3 ran on it; unchanged since) and kit `tools/peer-transport` `4f473706` (the kit rehearsal of record ran on it). No wire schema, codec, `Peer.Connection` limit, TLS policy, motion rule, authority, native or other listener changed.

**The profile** (`Peer.Network`). Without a `:network` option the endpoint keeps B1's rule unchanged: `{127, 0, 0, 1}` only, otherwise `{:not_loopback, ip}`. With `network: [profile: :lan_ipv4, ...]`:

| Rule | Detail |
|---|---|
| One socket per role | listen: `listen: {address, port}` plus `initiator: address`; connect: `connect: {address, port}`. The profile's role must equal the endpoint's role, and `:ip` / `:port` may not also be given. |
| Addresses | IPv4 4-tuples or strict dotted quads only. `127.0.0.1` and RFC 1918 private unicast are allowed. Refused: 0/8, the rest of 127/8, multicast, reserved, the limited broadcast, link-local, any other range, hostnames, shorthand, IPv6. |
| Prefix | `prefix_length` 8–30, declared. Its network and broadcast addresses are refused, the initiator must be inside it, and a private initiator may not be the listener itself. |
| Port | 1024–65535 |
| Kind | only a `client_kind: "headless"` endpoint may listen. `Motion.Supervisor`'s game-host endpoint is connect-only, so a listen profile there is refused. |
| Errors | `{:network_profile, reason}`, before any socket |

**The endpoint under the profile.**
- **Listener:** binds exactly the declared socket and checks its name. It accepts TCP itself and closes, before any TLS byte, a connection from anyone but the initiator (`refused_address`) or a second connection (`refused_busy`). It then upgrades with `:ssl.handshake/3` under the same TLS options (`TLS.upgrade_options/1`). It survives a handshake that raises or exits, and stops if its acceptor dies.
- **Connector:** checks its peer name.
- **Test seam:** an injected `:socket_module` (never taken from configuration) lets tests see the exact non-loopback listen and connect call without any network.

**HeadlessPeer** takes `role: :connect`, so a game-free transport test keeps its initiator outbound-only. Its source stays synthetic-only and its sink record-only.

## 5. The kit (`tools/peer-transport/`, prepared, never run on a Mac)

| File | Role |
|---|---|
| `bundle.sh` | the bundle from one exact commit (`git archive`, MIX_ENV=prod, an isolated build path, a copy of the fetched deps; lock checked): the relay's compiled modules plus the kit, `BUNDLE.txt`, `MANIFEST.sha256`, a `.tar.gz` and its sha256 |
| `compat-check.sh` | read only (no write, socket, install, Mix, shim execution or other project's files): OS, the runtime as resolved, ssl/crypto/public_key, TLS 1.3, P-256, ECDSA in memory, the test-certificate functions, JSON, distribution at start, the flag variables and boot files, bundle loadability, the port, the IPv4 addresses (listed, not chosen), the macOS firewall state; then MISSING PREREQUISITES |
| `creds.exs` | per machine: its own CA and a leaf (the CA key is never written); only the public CA and identity file cross; import checks the digest and prints the pin for a second channel |
| `peer.exs` | the peer (details below) |
| `start.sh` / `stop.sh` | `start.sh`: one printed launch command, the flag and library variables removed, crash dumps off, boot files and shims refused. `stop.sh`: TERM, then KILL, only to the recorded pid whose command line is that run's peer, re-checked before the KILL |
| `scan.exs` | material-based scan, with a self-test |
| `tests/rehearsal.sh` | the loopback qualification |

**`peer.exs`.** It runs as one non-distributed process.

Its checks, all before any socket and before ssl, each refusing with exit 2:
- the bundle as an exact file set;
- the configuration's sha256, schema, role and profile;
- the bundle pin and the runtime pin;
- the credentials (key 0600; the key must decode);
- the approval;
- the course and limits;
- an exclusive output directory.

Then ssl starts and TLS 1.3 is checked. It runs one bounded synthetic exchange each way, records the peer's identity at identification, and writes `peer.pid`, `events.ndjson`, `trace/` and `summary.json`.

"Complete" means transport completeness:
- received equals the source's sent;
- the last sequence numbers agree;
- nothing arrived twice;
- gaps are the source's own skips, reconciled against the other summary.

Exit codes: 0 / 2 / 3 / 4 / 5 / 6 / 7 / 124 (README). After any connection ends, the run ends; it never reconnects.

**Inherited kit issues** (authorization section 5; the sealed C scripts are untouched):

| Issue | In the new kit |
|---|---|
| `already_armed` treated as failure | not applicable: the transport kit arms nothing |
| a key scan matching names or its own pattern text | `scan.exs` counts only decodable key material and known-key encodings (DER, base64, hex, the BEAM's byte lists, an EC key's private scalar); names and pattern text are information only; the self-test keeps class-specific positive controls (13) and negatives (6) |
| the stale constant "13" | none: every count is computed from the files scanned now |
| a manufactured bare "Ready" / any occurrence of "ready" as consent | the approval record keeps the operator's reply verbatim (JSON); only a whole standalone reply equal to an accepted form counts, bound to the configuration and bundle sha256s and a maximum age; nothing is composed from another message; a no-game stage asks for no HITMAN "Ready" |

## 6. Qualification

**Tests added: 35** (the full suite grew from 831 to 866):
- `peer/network_test` (18): B1's loopback acceptance and refusal unchanged; every `lan_ipv4` rule as pure inputs; refusals before any socket call; the exact listen and connect calls of accepted non-loopback profiles through an injected socket module (no LAN address is bound or contacted).
- `peer/network_endpoint_test` (12, on `127.0.0.1` only):
  - headless-to-headless TLS 1.3 with one stream each way, and the exact bound socket;
  - closed before any TLS byte: a non-initiator (connecting from `127.0.0.2`) and a second connection;
  - refused: a wrong pin, a foreign-CA client, a right-CA unpinned leaf, no certificate, TLS 1.2, a wrong hello label;
  - a port conflict fails closed; no reconnect unless asked; a fresh boot;
  - no key in any status; B1's listen socket redacted;
  - a handshake that exits leaves the acceptor serving, and a dead acceptor stops its listener.
- `peer/network_wiring_test` (3):
  - the game host's motion subtree under a connect profile: every other listener of the VM on `127.0.0.1`, a share out and a course in;
  - the host refuses a listen profile;
  - a configured `socket_module` is never used.
- `peer/network_two_process_test` (2, two OS processes): the game host connecting out to a headless child; and **the L2 shape**, a headless child connecting out, one course each way, with exact accounting including the sender connections' drops.

**The verifier:** one agent, read only, on the frozen draft `160d4eb`. It found 0 blockers, 1 major (V1: scanner false negatives) and 7 minor findings (V2–V8), plus V9–V13 as minor or notes. All are fixed or dispositioned in `verifier\verifier-disposition.txt`, with its report and own artefacts beside it; B1's identical acceptor pattern (V3) is left as it is and disclosed. One gap I found myself (no certificate / TLS 1.2 under the profile) was added before the report arrived.

**The BEAM gate of record (`scripts/beam-gate.sh`): NOT MET.** Three attempts are kept, each with a NOTE:

| Attempt | Tree | Result |
|---|---|---|
| 1 | relay `866fbde4` (`2f8c172`) | FAIL, 3 of 13 steps: one **new** test (the wiring test asserted the sink's gap-free flag; the host's rate floor legitimately withholds a jittered sample, exactly as in M7-C's live sink: `complete=false, gaps=1, received = sent`) |
| 2 | relay `2aab0c04` (`f9d7f93`) | FAIL, 3 of 13: the same new test (a native sample arriving before the share activates is a counted gap, M7-B1 record 8.2), plus two **pre-existing** tests: M3 `endpoint_test:224` (run 1) and the M7-B1 share-deadline tests T1 ×2 (run 3) |
| 3 | relay **`5f63cde9`** (`aae5999`, the final relay tree) | FAIL, 1 of 13: the compiles, the scoped format check, the areas (212/0, 207/0, 21/0) and full suites 1, 3, 4, 5 passed (866/0; seeds 707925, 100315, 674764, 455102); suite 2 (seed 407757) failed **2 pre-existing** M7-B1 tests, `restore_result_test` "B" ×2, at a setup assertion that the fake had already moved. Every M7-L1 test passed in every run. |

The gate was not re-run to obtain a clean pass.

**A bounded diagnostic (not a gate).** Five full suites of the unchanged baseline tree `da39d5e4` (`baseline-suite-check-attempt1`, isolated build) were all clean today: 831 / 0, seeds 329636, 929503, 241449, 805697, 732835, about 2:09 per run against about 2:45 with M7-L1's tests.
- The three pre-existing failures are timing-tight by design: trace writes held at a bound − 60 ms, a connection suspended 80 ms against a 100 ms stale limit, and assertions against the fake's own clock. They are the same class as the M7-B1 correction's own gate attempt 1 (H-A5).
- They failed in 3 of 10 runs with M7-L1's tests present and in 0 of 5 without them today. That sample does not separate chance from a perturbation by the new tests. No M7-L1 process or port outlived any run (the leftover checks: beam 0, ports 0).
- The added duration matches the new tests' own time.

**The kit rehearsal of record** (`scripts/kit-rehearsal.sh`, `kit-rehearsal-attempt2`): **PASS, 95 checks, 0 failures**.
- **Inputs:** HEAD `dba921b`, a bundle of 98 files (manifest `d0369e3f…`, archive `0794c0fa…`), run from its evidence copy.
- **Exchanges:** two successful exchanges, the second a fresh restart: 57 = 57 = 57 each way, one connection, generation 1, the listener's only listener `127.0.0.1:<port>`, the connector listening on nothing.
- **Failure cases:** wrong pin (exit 3 on both sides, no data); wrong hello label (exit 4 on both sides, one connection, no reconnection); no peer (exit 3 at 10 s); disconnect (the connector exit 4, never reconnected; the stopped listener exit 6 with its summary); early stop (exit 6); port taken (exit 7, `eaddrinuse` recorded).
- **Refusals:** 24 argument refusals, each exit 2 before any socket with ssl not started and no output directory:
  - addresses: wildcard, a privileged port, a hostname, IPv6, a public address, a role mismatch, a loopback default;
  - pins: the configuration's sha256, the bundle pin, a bundle pin that is not an object, the runtime;
  - the bundle: a modified file, an extra file;
  - the output directory, an unknown key, the key mode, an undecodable key;
  - approvals: not standalone, a word inside a longer reply, "Ready" for a "Go ahead" gate, too old, naming another configuration, naming another bundle, presented after recording.
- **Afterwards:** the scanner self-test PASS; the attempt-wide scan with all three rehearsal keys known, 0 material hits over 163 files; no peer process left; the credentials then removed (a logical deletion).
- **Attempt 1** (HEAD `aae5999`) FAILED and is kept with a NOTE. The drvfs evidence root ignores case, so two of the scanner self-test's control names were one file. The self-test crashed in its cleanup and left its planted throwaway key and controls, which are the 4 PEM hits the attempt-wide scan found. Those planted files were removed from the failed attempt (logical deletion), each listed with size and sha256. macOS APFS ignores case by default, so the Mac would have failed alike. Fixed in `dba921b`.
- `compat-check.sh` on **this** host (the build host, not the Mac) found no missing prerequisite.

**Findings reproducers** (`scripts/findings/`, `findings-attempt2`): the OTP `transport_accept` close, the B1 listen-socket key, the Hub abandon crash, and the SIGTERM trap. Attempt 1's Hub reproducer matched the wrong form of the exit term; it is kept with a NOTE.

## 7. Performed, reused, not executed

| Item | Status |
|---|---|
| Frozen inputs, the M7-C seal re-hash, the video hash | performed (`checkpoint-attempt2`, 33 / 33) |
| The video inspection | performed once (stills; `media-review\`) |
| The boundary amendment before code | performed (`47c2147`) |
| Implementation, tests, kit | performed (section 4) |
| One verifier | performed (`verifier\`) |
| Strict compiles (dev, test), scoped format, the areas | performed, passed (gate attempt 3) |
| Five full suites on the final relay tree | performed, **NOT MET** (4 of 5 clean; 2 pre-existing failures in 1 run) |
| The baseline diagnostic | performed (5 / 5 clean) |
| The kit rehearsal (loopback, two OS processes) | performed, PASS (attempt 2) |
| `compat-check.sh` | performed on the WSL build host only; **not run on the Mac** |
| native6 / native5, the placement content, prior game qualification | **reused by identity**, not rebuilt or re-run |
| Native loops, content rehearsals, the DLL | not executed (not needed: nothing native changed) |
| Any LAN socket, Mac contact, firewall / WSL / router / epmd change, HITMAN, real credential | **not executed** (not authorized) |

## 8. Findings

1. **B1's listen socket carried the private key into status and crash reports.** OTP's TLS listen-socket term embeds the TLS options, the key included, and B1's `format_status` redacted only `creds`. `:sys.get_status` therefore held the key's DER. **Fixed** for both paths: the listen socket is redacted, and a test fails without the fix.
2. **OTP 28 `:ssl.close/1` on a `transport_accept` socket does nothing** (`{:error, :notsup_on_transport_accept_socket}`), so the client stays connected. B1's "second connection refused before its handshake" therefore never closes that TCP connection. The profile listener accepts TCP itself and closes with `:gen_tcp.close/1`. **B1's path is left unchanged** (legacy unchanged) and disclosed for review.
3. **B1's `Motion.Hub` crashes on a refused share issue.** `Hub.abandon/1` evaluates `(state.session && …) and …` with no session, so `nil and …` raises `BadBooleanError` and the Hub restarts instead of answering the refusal. The reproducer is `f-hub-abandon.exs`. **Not fixed** (motion code is outside this stage).
4. **B1's accept loop has the acceptor-exit pattern of V3**, and `TLS.credentials` does not DER-decode the key. Fixed on the profile path only; **B1's path is unchanged** and disclosed.
5. **`System.trap_signal(:sigterm, …)` does not replace the VM's own SIGTERM stop.** The stop runs after the user traps return and exits 0 about 1 s later. The kit's trap therefore blocks, bounded. The reproducer is `f-sigterm-trap.exs`: plain exit 0 with no summary, blocking exit 6 with a summary.
6. **Case-insensitive file systems** (drvfs, APFS) merge names that differ only by case: kit rehearsal attempt 1.
7. **The sink's `complete` flag means gap-free**, not transport-complete. A source's or host's own legitimate withholding (rate floor, spacing, pre-activation) leaves a counted gap with nothing lost; M7-C's live sink shows `complete=false` that way. The kit judges transport completeness instead.
8. **The five-suite gate is not met.** Three pre-existing timing-tight tests failed in 3 of 10 runs alongside M7-L1's tests, and in 0 of 5 baseline runs (section 6).

## 9. Deviations and disclosures

1. Checkpoint attempt 1 was refused by `readiness.py` (my generator omitted its checks); kept.
2. Development bundles and rehearsals ran in the session's scratch directory, from dangling commits (a temporary index; no ref, index or working tree changed). They are not evidence: the qualifications of record are in the root.
3. The section 9 wording of the M7-C record was corrected in place, with its acceptance appended (section 11).
4. The verifier's scratch directory also held earlier sessions' verifier files; only this review's artefacts were copied, never its planted keys, key hex or crash dump.
5. While diagnosing gate attempt 1, a CPU-load probe's `pkill -f` matched its own shell and ended it before it restored a temporarily edited test file. The file was restored immediately afterwards, and no process was left.
6. The gate of record is not met (sections 6 and 8). I report it and do not retry around it.
7. The kit rehearsal's attempt-1 planted throwaway keys were removed from the failed attempt, each listed (NOTE). Nothing else in a kept attempt was changed.

## 10. Preserved

- native5 and native6 unchanged, not rebuilt; the placement content; the game at M0 (26 / 26).
- Every tag on both repositories, and the sealed roots: `m7c-run1` re-hashed in full, no other sealed root written.
- The shared epmd untouched.
- The sealed M7-C kit scripts are untouched (the new kit is separate).

## 11. The MacBook: compatibility check, start and stop (prepared; **not executed** there)

The full procedure is in `tools/peer-transport/README.md`. In short, all paths absolute:
- **Read-only check:** `sh <B>/kit/compat-check.sh <B> 4760`, then read MISSING PREREQUISITES.
  - It names the OS and architecture, the runtime as resolved (a shim reported, not executed), TLS 1.3, P-256 and ECDSA, the bundle's loadability, the port, the IPv4 addresses, the firewall state, and any Erlang boot file.
  - Required: OTP 28 and Elixir 1.19.x (or `GLACIER_PEER_ELIXIR` naming them). Nothing is installed.
- **Credentials:** `elixir -pa <B>/ebin/glacier_relay <B>/kit/creds.exs generate <S> mac`, then the same `import`. Only the public files cross, and the pins are compared over a second channel.
- **Start:** `sh <B>/kit/start.sh <B> <config.json> <sha256>`, in the foreground: one printed command, a non-distributed peer.
- **Stop:** `sh <B>/kit/stop.sh <O>`, or it ends by itself.
- **After the run:** `elixir <B>/kit/scan.exs <O> --known-key <S>/creds-mac/own-key.pem`, then remove `<S>/creds-mac`.

Unverified: the Mac's actual OS, runtime, ssl, addresses, firewall and port.
## 12. Proposed M7-L2: one transport-only exchange between the Windows host and the MacBook (proposed, not granted)

**Goal.** Qualify the existing peer protocol across the LAN with no game. The checks:
- the connection under the `lan_ipv4` profile;
- the per-run credentials and pins;
- one bounded synthetic exchange each way;
- the counters, the reconciliation and the teardown on both machines.

It cannot establish:
- real-game LAN following, collision or native frame cost;
- anything about a game on the Mac;
- the M7 exit.

**Roles.**
- The MacBook **listens**: one headless peer, `listen: {<MAC_IP>, 4760}`, `initiator: <WIN_IP>`, `prefix_length: <P>`.
- The Windows/WSL host **connects out**: one headless peer, `connect: {<MAC_IP>, 4760}`.

Both are non-distributed BEAM processes started from the same bundle, and nothing else listens.

**Steps.** Each step's output is kept; a failure stops the run with no automatic repeat.
1. **Mac, read only:** `compat-check.sh <bundle> 4760`. Stop if MISSING PREREQUISITES lists anything; a runtime mismatch is a decision for the operator, not an installation.
2. **Windows:** `bundle.sh` from the accepted commit; record the manifest and archive digests.
3. **Transfer** the archive by the approved channel; on the Mac, verify `shasum -a 256` before unpacking into the owned directory.
4. **Credentials, each machine for itself** (`creds.exs generate`). Exchange only `own-ca.pem` and `own-identity.json`, import them, and compare the CA digests and leaf pins over a second channel.
5. **Configurations.**
   - One out-and-back course each way: 1.0 m at 0.5 m/s, a 2 s prefix and 2 s holds (the C course's shape, labelled synthetic, around a synthetic origin), 241 samples over 12 s.
   - Lifetimes 120 s; the connector's connect window 60 s.
   - Present them with their sha256, the addresses, the port and the pins.
6. **The operator's approval**, recorded verbatim as a standalone reply (the Windows configuration names it), then a Windows readiness record (`readiness.py`):
   - the repository clean, the bundle digest, no HITMAN or relay process, ports free;
   - the shared epmd reported unchanged, and the WSL networking mode reported read only.
7. **Start.** The Mac's `start.sh` (foreground) first. While it runs, a read-only `lsof -nP -iTCP:4760 -sTCP:LISTEN` on the Mac must show exactly `<MAC_IP>:4760`, owned by that process. Then the Windows `start.sh`.
8. **Both end by themselves** (exit 0 expected). Keep their console, `summary.json`, `events.ndjson` and `trace/`.
9. **Both sides:** `scan.exs` with the side's key known must report 0 material hits; then remove the credentials (a logical deletion). Mac outputs come back to the Windows evidence root by the approved channel, and the owned Mac directory is kept or removed as decided.
10. **Seal** the evidence root, its temporary manifest outside the root.

**Success.**
- Both exit 0, with outcome `complete`.
- Each sink's reconciliation is complete and received equals the other side's sent.
- One connection, generation 1 on both sides; `refused_address` 0 and `handshake_failures` 0.
- The listener's only listener is the declared socket; the connector listens on nothing.
- The scans are clean.

**Permission needed.** The local-network permission this needs, and nothing broader:
- **Inbound, on the MacBook:** one TCP listener at `<MAC_IP>:4760`, bound by a `beam.smp` that the operator starts from a terminal in the owned directory, for at most 120 s. It accepts only `<WIN_IP>`, and no other port, interface or service is opened.
  - If the macOS application firewall is on, it may need the operator's consent at its prompt to allow incoming connections for that `beam.smp`, for this run.
  - If macOS asks, it may need Local Network access for that terminal.
  - Never a firewall disablement, a global rule, a router change or a change to the unrelated Mac project.
- **Outbound, from the Windows/WSL host:** one TCP connection to `<MAC_IP>:4760`, expected to work through WSL2 NAT with no Windows-firewall, WSL-mode or router change. That is expected, not established. If any change turns out to be needed: stop and ask.
- **Transfer:** one channel the operator chooses for the bundle archive, the public credential files and the returned Mac outputs. No remote shell or remote execution.
- **Not included:** exposing epmd, Erlang distribution, the command / motion / dashboard listeners, or any game.

**To be named by that authorization** (blank or unverified here):

| Item | Value | Status |
|---|---|---|
| Mac OS / architecture | — | unverified |
| Mac OTP / Elixir as resolved on PATH | — | unverified (Elixir is installed for another project; exact compatibility unknown) |
| Mac ssl / crypto (TLS 1.3, P-256) | — | unverified |
| Mac application firewall state | — | unverified |
| `<MAC_IP>` and `<P>` | — | unverified |
| `<WIN_IP>` (as the Mac will see it) | — | unverified |
| Port 4760 free on the Mac | — | unverified |
| Transfer channel; owned Mac directory; retention | — | to be chosen |

## 13. What M7-L1 establishes, and what it does not

**Established offline, on the Windows/WSL host, on owned loopback sockets:**
- the peer endpoint's explicit `lan_ipv4` profile and its refusals, with B1's default loopback behaviour unchanged;
- the profile's wiring in the game host's motion subtree and in the headless peer;
- authentication unchanged under the profile;
- a headless-to-headless exchange in two non-distributed OS processes, with exact sequence, drop and close accounting and bounded teardown on success, refusal, timeout and disconnect;
- the kit's refusals before any socket;
- a material-based scan with positive controls.

**Not established:** anything on the MacBook, or on any LAN; macOS firewall or Local Network behaviour; the Mac's runtime compatibility; WSL2 NAT outbound to the LAN; real-game LAN following; collision; native frame cost; a second game; the M7 exit. A loopback test is no proof of Mac or LAN compatibility. **The five-suite gate is not met** (section 6).

**Next:** review. Nothing further is granted, and no Mac or LAN action follows from this record.

## 14. M7-L1 correction: the default listener, `Hub.abandon` and the gate's three test families (2026-10-20)

**Authorization:** "Glacier Relay — M7-L1 focused listener, abandonment and gate correction". It accepted M7-L1's demonstrated progress (the explicit profile, loopback-only execution, the two-process kit, the scanner improvements, the M7-C acceptance) but **not** full M7-L1 acceptance or M7-L2. It authorized one BEAM / test / tooling pass, confined to:
- the default peer listener's refusal and acceptor lifecycle;
- `Motion.Hub.abandon`;
- diagnosing and correcting the three named failing test families.

No native change or rebuild, HITMAN, content, Mac, LAN socket, real credential, firewall / WSL / router / epmd change, packaging, frontend, media inspection or tag. **Sections 1–13 above are unchanged: the original gate stays NOT MET as recorded.**

**Evidence:** `%TEMP%\glacier-m0\hitmen\m7l1-correction\`, sealed, 495 entries, manifest `f7bf96bbda757c10405c152bd6ae16d0d27188ffdd167dd30a2ed2630963ea69` (verifies; its temporary file was written outside the root; 0 unlisted files). State root `~/.local/state/glacier-relay-m7l1c` (ext4: isolated copies and builds, the kit's disposable credentials, removed after their scan).

### 14.1 Basis

`checkpoint-attempt1`, `readiness.py`, 32 / 32 ok, read only:
- glacier-relay `main` `5436a7bb` = origin, clean; the L1 relay tree `5f63cde9` (= gate commit `aae5999`'s), kit `4f473706`; `dba921b` an ancestor;
- ZHMModSDK `relay/m2` `8129d721` = origin, clean; the tags unchanged (`6ee99b44…`);
- the runtime by file hash; native6 (`91a7098f…`, its manifest's bytes) and native5 (`f271d129…`); the placement content;
- the L1 seal re-hashed in full (732 / 732, `4cf04a32…`); the M7-C seal by its manifest's bytes (`5da4a64a…`);
- the game at M0 (26 / 26); no BEAM or game process; the project ports free; the shared epmd (pid 45286) present and untouched.

The claim record `.evidence-root` has an empty `guard_sha256` (the guard was sourced from zsh; `claim-NOTE.txt`); the guard's identity is pinned by the checkpoint.

### 14.2 Diagnosis (on the frozen tree, in isolated copies)

**Leak probe.** One run per file, with a diagnostic `test_helper` that snapshots the VM before any test and after the suite (+0.2 s, +6 s): M7-L1's four test files, the three failing families' files, and B1's TLS and two-process tests as controls.
- Before (`diagnosis-frozen-attempt1`, then `diagnosis-frozen-v2-attempt1` with every temporary entry listed): no new port, OS child, busy process or environment change after any file; the only new processes are ExUnit's runner and the logger handler, as for the controls. **One leftover:** `network_wiring_test` leaves an `m7l1-wiring-*` trace directory (version 1 of the probe listed only `glacier-relay*` names and missed it; the verifier found it). 38 such directories (40 synthetic motion traces, no key text) from M7-L1-era runs were removed from `/tmp`.
- After (`diagnosis-final-attempt1`, the final commit, plus the two new test files): nothing left by any file.
- No resource or environment leakage that could slow the named tests was found. That does not prove M7-L1's added load is irrelevant; it removes leakage as a cause.

**The three families, each reproduced on purpose:**

| Test | Gate failure | Mechanism (reproduced) | Classification |
|---|---|---|---|
| web `endpoint_test.exs:224` (M3-A) | `ArgumentError` from `:ets.lookup` in `server_info/1` | The restarted endpoint's name is registered before its `init/1` runs, and `server_info/1` reads a table its first child creates (R1: raising samples after 20 / 20 kills). After a `:kill` the **first** restart attempt also fails to start its LiveView socket child (`:already_started`, the killed endpoint's still terminating; R1c 8 / 10), so even `projection_test`'s predicate (`1f7c2fc`) exits on it (R1b). | test predicate |
| `deadline_share_hub_test` T1, held write | no `{:held, …}` within 1 s | A hold armed after the last sample decided before the bound holds nothing (R2: armed at bound − 1 ms). | test timing |
| T1, suspended connection | `last_seq_received` 17 ≠ k − 1 (k = 19) | Handed 17 = received 16 + expired 1, so nothing was stale: sample 18 was never handed — the share's 45 ms **rate guard** withheld it (R3: a native burst reproduces it exactly). Attempt 2's NOTE called it a stale drop; these counts exclude that. | test assumption |
| `restore_result_test` B ×2 | `world != pre` failed at :43 | The fixture's 600 ms course moved before the session was admitted late: 0 targets applied, a clean confirmed close at the stream's end — restorable by definition — at the preimage (R4b: the fake's answers 210–240 ms late give exactly this; ≤ 200 ms, displaced). | test fixture |

None demonstrated a production defect in the code under test. The killed endpoint's failing restart attempts are recorded as a finding (14.7), not changed.

### 14.3 The production corrections

| Commit | Change |
|---|---|
| `42eb31b` | **The default listener** takes the profile's qualified path: `gen_tcp` listen with socket options only, accept, close a second connection (`refused_busy`) before any TLS byte, upgrade with `:ssl.handshake/3` (raise and exit caught). A lost acceptor stops the endpoint (`{:acceptor_exited, reason}`) for both plans. Teardown kills the acceptor first, so a handshake in progress no longer outlives the endpoint, then closes the listen socket and the connection. |
| `5668d10` | **`Hub.abandon/1`** pattern-matches: only a share or session with this id AND status `:pending` is forgotten; anything else leaves the state as it was. No rescue. |

Unchanged: `Peer.Network` (no `:network` option = `127.0.0.1` only, port 0 allowed; the profile's concrete address, initiator and headless-only rules), the TLS policy, pins and credentials, the wire messages, `Peer.Connection`, reconnect behaviour, the log lines, the `format_status` redaction, the authority. `TLS`: documentation only.

**Before / after** (`before-after-attempt2`, on the final commit: the new tests against the frozen `relay/lib`, then the corrected one; attempt 1, on `914c7f0`, agrees but for the barrier-dependent case of 14.10 item 3):

| Behaviour | Before (frozen code) | After |
|---|---|---|
| a second connection while the peer is up (loopback default) | the client's read times out (3 s): the connection stayed open | closed at once, no byte received; the peer unaffected |
| a handshake that exits (loopback default) | the exit escapes: no failure is counted and the next attempt is never served | the socket closed, the failure counted; the acceptor survives and serves the next |
| a killed acceptor (loopback default) | the endpoint stays up, bound, serving no one | the endpoint stops; under `HeadlessPeer` only it restarts and serves |
| a normal stop during a handshake (both plans) | the profile's handshake waits out its 5 s deadline | ended at once |
| a refused share issue with no session | `BadBooleanError`, the hub crashes | the refusal answered; the share forgotten; nothing sent |
| back-to-back clients (race probe, 30 rounds, two runs) | 3 and 1 busy refusals, each a 3 s client timeout | 15 and 15, each closed within 2 ms |

### 14.4 The tests

Commits `82eb1ac`, `d51284e` (new tests and the updates the listener change needs), `c398a3f`, `ebf2c7b`, `914c7f0`, `02052fb` (the three families, test-only), and after the verifier `83c4853`, `0333466`, `6fe6ee3` (tests) and `9541c02` (documentation):
- `peer/listener_lifecycle_test` (new, 14 = 7 cases × both listeners): the busy refusal (raw and TLS clients, within 1 s, no byte; the peer keeps its process, generation and data), both handshake-failure paths, the lost acceptor (alone and under `HeadlessPeer`), both teardowns (no TCP socket left on the listener's port), and the key's absence from `:sys.get_status/1`, `Endpoint.status/1`, the exit reason after an acceptor loss (`{:acceptor_exited, :killed}`) and the formatted log text captured in each case at `:debug` with SASL reports let through (the endpoint's info lines and the crash report's `State:` asserted present) — **only those channels**; raw report terms are not checked (finding 4).
- `motion/hub_abandon_test` (new, 8): the share and session refusals through `Motion` (the hub the same process on the same links, no open at the fake, a legitimate open afterwards), and on the hub: nothing prepared, a pending share alone, a pending session alone, foreign ids, active and done operations.
- Updated for the corrected listener: `network_test` (the loopback listen call carries TCP options only), `network_endpoint_test` (the default listen socket no longer embeds the key), `tls_test` (two back-to-back raw-client tests wait for the previous connection to end: a client arriving earlier is refused at once now, where it used to wait out its 3 s timeout).
- web `endpoint_test`: `projection_test`'s predicate plus "a failed restart attempt that is gone is not yet" (its `failed_to_start_child` exit, or `:noproc` when its name is no longer registered to it); any other exit propagates.
- T1: explicit fake-source control (`FakeMotionNative.hold_motion_out/1`, `release_motion_out/2`): the fake's output is held 300 ms before the bound, the hub is seen to have decided every written sample, and exactly one sample is released 120 ms before the bound; its decision before the bound is asserted. Delivery control kept; exact accounting `source_sent = received + the connection's stale + expired`. The old 150 ms hold bound is replaced by the conditions it stood for (the same motion link and identified peer connection). Production deadlines unchanged. **Remaining timing dependence:** the test process must release the one sample in time to precede the bound — a 120 ms lead, asserted with its own message (at least 40 ms before the bound) — where the old tests had an effective 10–60 ms window that also depended on the fake's cadence.
- restore B: the course holds at its displaced end; the fixture waits for an applied target at that end (the destination's confirmed reference and the fake's candidate there), then ends the stream, so the session closes as before.

**Negative controls** (`before-after-attempt2`). Six mutations, each failing exactly the tests that claim it: the share's send boundary, the connection's `not_after`, the busy close, the teardown kill, the acceptor-exit stop, and `format_status` returning the unredacted state (the status checks and, through the crash report's `State:`, both lost-acceptor cases). The corrected web predicate survives 20 tight kills and stays false without a restart. The corrected B fixture is displaced and restorable with the fake's answers 0 / 230 / 400 ms late, and refuses an at-baseline course (that control first showed `914c7f0`'s wait trivially true for a course that never leaves P; fixed in `02052fb`).

### 14.5 The verifier

One agent, read only, on the frozen draft `02052fb` (brief, report and disposition in `verifier\`; the report preserved as delivered). It found 1 major, 3 minor and 6 notes; no key leak on any path the endpoint controls.

| Id | Finding | Disposition |
|---|---|---|
| W1 major | `network_endpoint_test.exs` not formatter-clean: the gate's format step would fail | fixed (`83c4853`) |
| W2 minor | the log channel was narrower than claimed: `with_log` keeps the `:warning` level, so the endpoint's info lines and a crash report's `State:` were never checked (an unredacted `format_status` passed the lost-acceptor cases) | fixed (`83c4853`): `:debug` with SASL reports let through, the channel asserted present, byte forms only in log text; mutation m6 now fails those cases |
| W3 note | OTP's ssl keeps the TLS options, the key included, in raw SASL report terms; formatted text has none | recorded (14.7); no configuration enables SASL reports |
| W4 minor | the VM-wide socket count could be flaky | fixed (`83c4853`): sockets on the test's listener port only |
| W5 minor | the web predicate's `:noproc` window; a dead branch; the restart budget at 3 of 3 | (a), (b) fixed (`0333466`); (d) recorded (14.7), not asserted |
| W6 note | the endpoint's own closes after a failed upgrade and at teardown are not discriminated (ssl and port ownership close them on the tested paths) | recorded (14.7) |
| W7, W8 | a trivially true conjunct; a barrier that can match just before the handshake | acknowledged; the assertions hold either way |
| W9 note | a stale seam comment; a long docstring line | fixed (`9541c02`) |
| W10 note | six SessionTest failures in its one full suite (command-link welcome timeouts after a trace-append timeout); `network_wiring_test`'s temporary directory; the accept loop's immediate retry | recorded (14.7); the directory fixed (`6fe6ee3`) |

### 14.6 Qualification

**The final inputs:** glacier-relay `9541c02` (relay tree `90d40033`; kit `tools/peer-transport` `4f473706`, unchanged; `tools/content-deployment` unchanged). Twelve commits after `5436a7b`: 2 production, 1 documentation-only in `relay/lib`, 9 test (`relay/test`, `test/support`).

**The BEAM gate of record** (`scripts/beam-gate.sh`, `beam-gate-attempt1`): **PASS, the first and only attempt.**

| Step | Result |
|---|---|
| `mix compile --warnings-as-errors --force` (dev, test) | exit 0, exit 0 |
| scoped format check (explicit globs: peer, motion, headless, command lib and tests, test support, the boundary, headless and web endpoint tests, config) | exit 0 |
| whole-tree format check (information only) | exit 1, the same 12 pre-existing M2-era files as M7-L1's |
| areas: peer + motion; command; headless + boundary; web endpoint | 234 / 0; 207 / 0; 21 / 0; 11 / 0 |
| five full suites, `--warnings-as-errors`, seeds declared in the script before any run: 118004, 529371, 760243, 342815, 905562 | **888 / 0 each, exit 0 each**, no warning |
| leftovers after the gate | beam 0, project ports 0 |

The suite grew from 866 to 888 (+14 lifecycle, +8 abandon). The known failing seeds of M7-L1 were used only as diagnostic inputs, never in the gate. One clean gate on these inputs is evidence that the three families no longer depend on the timing they did; it is not a statistical claim, and the stalls of finding 6 can still fail a future run.

**The kit rehearsal** (`scripts/kit-rehearsal.sh`, M7-L1's wrapper unchanged but for its header; `kit-rehearsal-attempt1`): **PASS, 95 checks, 0 failures, the first and only attempt.** The corrected endpoint invalidated every two-process result, so the whole rehearsal ran again; nothing of M7-L1's rehearsal is reused.
- **Inputs:** a bundle of the final commit `9541c02`: 98 files, manifest `20987b6c8748924211ca24de050a0a0772e8691c4b10f3de06892366e260f7b7`, archive `61720a82bc6cd7451af53b42c521fc9b49147e1a2dff5d5c12033c07f8d85d8b`; the evidence copy verifies against its manifest.
- **Exchanges:** two, the second a fresh restart: 57 = 57 = 57 each way (total = sent + 0 skipped; received = sent − 0 connection drops), one connection, generation 1; the listener's only listening socket `127.0.0.1:<port>`, the connector listening on nothing; both OS processes ended.
- **Failure cases:** wrong pin (exit 3 on both sides, every handshake refused); wrong hello label (exit 4 on both, one connection never identified, no reconnection, no data); no peer (exit 3 at its 10 s lifetime); disconnect (the connector exit 4; the listener, stopped by `stop.sh` through its recorded pid, exit 6 with its summary); early stop (exit 6); port taken (exit 7, `eaddrinuse`).
- **Refusals:** the same 24 as M7-L1's, each exit 2 before any socket with ssl not started.
- **Afterwards:** the scanner self-test PASS; the attempt-wide scan with the three rehearsal keys known: MATERIAL HITS 0 over 270 files (2 armour-like texts without material and 10 suggestive names, information only); no peer process left; the credentials then removed (logical deletion, not secure erasure).
- `compat-check.sh` on **this** build host: no missing prerequisite. **Not run on the Mac.**

### 14.7 Findings (for review; none changed beyond its row)

1. **The default listener's three defects: fixed** (14.3): the busy refusal that left the TCP connection open, the escaping handshake exit, and the ignored acceptor exit.
2. **`Hub.abandon`'s `BadBooleanError`: fixed** (14.3).
3. **A brutally killed web endpoint escalates to a whole web-subtree restart.** After `Process.exit(endpoint, :kill)` the endpoint's restart attempts fail while its LiveView socket child is still terminating (`:already_started`), and they exhaust the web supervisor's default intensity (3 in 5 s): over 30 fresh subtrees of `endpoint_test`'s sequence, the web supervisor itself ended in 22 to 25 (two runs; `probe-web-intensity-attempt2`, `before-after-attempt2`). Under `start_supervised` the test supervisor restarts the subtree, so the test passes; in the application the web subtree is a `one_for_one` child of `GlacierRelay.Supervisor`, which would restart it alone. The ingestion processes are untouched either way, which is what the test asserts. Not changed (web supervision is outside this pass). **Decision for review:** accept it as recorded, or authorize a web-only change (the endpoint's restart tolerance, or a test that kills with the supervisor's own semantics).
4. **OTP's ssl keeps the TLS options, the private key included, in raw SASL report terms** (the receiver child's start arguments on every upgraded connection; the bad-key `child_terminated` report). Elixir's formatted text holds none of it, and no configuration enables SASL reports. Pre-existing for every TLS listener here, B1's included. **M7-L2 must keep SASL reports off.**
5. **The endpoint's own socket closes are not discriminated by the tests** (verifier W6): after a failed upgrade the TLS connection process closes the socket, and the listen port dies with its owner. The behaviour holds; the endpoint's close matters only on the raise path, which no test reaches.
6. **SessionTest stalls in the verifier's one full suite** (seed 424242): six consecutive `MotionStack.start` timeouts on the command link's welcome (1 s), right after a 200 ms trace-append timeout; the file passes alone with that seed. Outside this pass's code and named families; watched in the gate (14.6).
7. **The accept loop retries an accept error other than `:closed` at once** (a busy loop on `:emfile`), in both listeners, as before. Not changed.

### 14.8 Performed, reused, not executed

| Item | Status |
|---|---|
| The frozen-basis checkpoint (heads, trees, tags, runtime, native6 / native5, content, the L1 seal re-hashed, the M7-C seal's manifest, M0) | performed (`checkpoint-attempt1`, 32 / 32) |
| Leak probe before and after; the four reproductions; R1b / R1c / R4b; the race and web-intensity probes | performed (`diagnosis-*`, `probe-*`) |
| The two production corrections and the test corrections | performed (14.3, 14.4) |
| Before / after and six mutations | performed (`before-after-attempt2` of record; attempt 1 kept with a NOTE) |
| One verifier | performed (`verifier\`) |
| Strict compiles, scoped format, four areas, five full suites | performed, **PASS** (`beam-gate-attempt1`) |
| The kit rehearsal from a bundle of the final tree | performed, **PASS** (`kit-rehearsal-attempt1`) |
| `compat-check.sh` | performed on the WSL build host only; **not run on the Mac** |
| M7-L1's scanner unit / pure-policy results | not re-run separately: the rehearsal re-ran the scanner self-test and the policy refusals with everything else |
| native6 / native5, the placement content, M7-C's runtime qualification, earlier sealed evidence | **reused by identity** (the checkpoint and the final checks); nothing native or content rebuilt or re-run |
| Native loops, content rehearsal, media review, HITMAN | not executed (not authorized; nothing native changed) |
| Any LAN socket, Mac contact or check, firewall / WSL / router / epmd change, real credential | **not executed** (not authorized) |

### 14.9 Preserved

- M7-L1's sections 1–13 and its sealed root `m7l1-offline` (re-hashed, 732 / 732): **its gate stays NOT MET as recorded**; this section adds a gate on corrected inputs, it does not rewrite that one.
- native5 and native6, the placement content, the M7-C root and video, every tag on both repositories, the M6 tags; the game at M0 (26 / 26); the shared epmd untouched.
- Every failed or superseded attempt of this pass is kept: `probe-r1c-frozen-attempt1`, `before-after-attempt1` (NOTE), `probe-web-intensity-attempt1`; the superseded probe sources are reconstructed byte for byte in `scripts\diag\superseded\` (each matching the sha256 its attempt recorded).

### 14.10 Deviations and disclosures

1. The claim record's `guard_sha256` is empty: the guard was sourced from zsh (`claim-NOTE.txt`). The guard's identity is pinned by the checkpoint and the final checks.
2. Six probe sources were edited after a first run and not saved first; each earlier version was reconstructed by reversing the edit and kept only because its sha256 matched the one recorded (`scripts\diag\superseded\README.txt`). `diag-run.sh` and `before-after.sh` gained steps between attempts; the README says which, and how the earlier runs are unaffected.
3. The before / after's loopback teardown-during-handshake case on the **old** code passed in attempt 1 and failed in attempt 2 (its barrier can match just before the handshake, verifier W8). The profile's case failed on the old code both times; the corrected code passes both in every run.
4. 38 stray `m7l1-wiring-*` directories in `/tmp` (40 synthetic motion traces, no key text) from M7-L1-era runs of `network_wiring_test` were removed (not evidence).
5. The verifier's report is saved as delivered, without the hand-back's two-space indentation.
6. The state root's isolated copies and builds (no key file; scanned, `final-scan.txt`) were removed after the seal's scan; the kit's disposable credentials were removed after their scan (logical deletion, not secure erasure).
7. **The verifier's own run outputs were not retained.** Its working directory (copies, builds, probes, its mutation script and run logs) sat in the state root and was removed with it, before I copied its run logs into the evidence root as M7-L1 did. Its report, preserved verbatim, lists every run with its command and exit status; the raw logs behind those rows are gone. I read part of its full-suite log (the SessionTest failures) before the removal; finding 6 quotes it from that reading.

### 14.11 What this establishes, and what it does not

**Establishes (offline, on this host, on owned loopback sockets):**
- The default listener now closes a refused connection with no TLS byte, survives handshake failures, stops when its acceptor is lost, and tears down completely; its address contract is unchanged.
- `Hub.abandon` answers an authority refusal without crashing the hub and forgets only the matching pending preparation.
- The three test families no longer depend on the timing that failed them; each mechanism was reproduced and its protection shown by a mutation or a negative control.
- The five-suite gate passes on the corrected inputs; the kit passes its loopback rehearsal from a bundle of them.

**Does not establish:** anything on the MacBook, a LAN, macOS's firewall, another OTP build or a case-insensitive APFS volume beyond what the drvfs evidence root shows; anything about HITMAN, the native or a game; that every possible dump or report is free of key material (14.4 names the channels checked; finding 4); that the gate cannot fail on a future run (finding 6); full M7-L1 acceptance or M7-L2, which remain for review.

### 14.12 M7-L2 (unchanged, not granted)

Section 12's procedure stands, with one addition from finding 4: **SASL reports stay off** on both machines (no `handle_sasl_reports`, no handler serialising raw report terms). A transport-only stage asks for no game recording and no HITMAN "Ready". Its own authorization still has to name the Mac's actual runtime, addresses, the permission to listen, the transfer channel and the owned directories.

## 15. M7-L1 accepted for its demonstrated offline scope (2026-10-20)

**Authorization:** "Glacier Relay — M7-L1 acceptance and M7-L2 transport-only authorization". It accepts M7-L1 and its correction (section 14) for the demonstrated offline scope. The review inspected the pushed code and records. The Windows test executions, the local seals and anything about the Mac remain **recorded evidence**, to be verified where they are relied on. Sections 1–14 are unchanged. **The original gate (section 6) stays NOT MET** in its historical record; the acceptance rests on the corrected code, its retained gate of record (`beam-gate-attempt1`) and the rehearsal from the rebuilt bundle (`kit-rehearsal-attempt1`), both in `m7l1-correction\` (`f7bf96bb…`). Five clean suites are evidence on those inputs, not a statistical guarantee.

**Accepted:**
- the corrected default listener's actual behaviour: the busy refusal closed before any TLS byte; handshake failures handled; an acceptor's loss stopping the endpoint; and teardown ending the acceptor and its sockets;
- `Hub.abandon/1` forgetting only a matching pending preparation;
- the diagnosed corrections of the three test families;
- the five strict suites, 888 / 0 each, with seeds declared before any run;
- the 95 / 0 rehearsal from the corrected bundle (`20987b6c…`, archive `61720a82…`), with exact accounting in both directions.

**Qualifications kept with the acceptance:**
- T1 still requires the test process to release one controlled sample within a stated 120 ms lead before the bound. It is improved and qualified, not scheduling-independent.
- The verifier's six SessionTest startup timeouts (finding 6) in its separate full suite stand as reported. They did not recur in the gate, and they are not rerun to chase a statistical conclusion.
- The verifier's report survives; its raw run and mutation outputs were deleted (14.10 item 7). Claims that rest only on that report are **report-supported**, not independently replayable raw evidence. The author's retained gate, rehearsal and before / after evidence are separate. No verifier campaign is recreated to repair the account.
- The reconstructed diagnostic sources stay marked as reconstructed, each with its matching pre-recorded sha256 (14.10 item 2).
- The claim record's guard hash is empty; the independently pinned checkpoint identity is the disclosed substitute (14.10 item 1).

**The web decision (finding 3):** accepted as a **documented, deferred M3 reliability limitation**, not a blocker for the headless transport experiment. A `:kill`ed web endpoint can escalate to a web-subtree restart. Nothing here claims endpoint-only recovery or immunity to repeated crashes. The web supervisor, its restart budget and the kill test are not changed. The transport kit starts no dashboard and no ingestion or command application.

**Residuals retained:** the unexercised ownership / close distinctions (finding 5), the accept loop's immediate retry on other errors (finding 7), and the report and dump limitations (finding 4: raw SASL terms, tracing, memory inspection and OS / core dumps are outside the tested confidentiality claim). M7-L2 includes no exhaustion, crash or fault-injection experiment.

**Unchanged:** M6 and M7-C stay accepted for their scopes. M7 stays open. No milestone tag is created or moved.

**M7-L2** is authorized: its preparation, and then, only after a separate approval of its exact configuration, one bounded transport-only exchange between the Windows/WSL host and the MacBook. That is not a game experiment. Its record is `docs/design/M7L2_LAN_TRANSPORT_RECORD.md`.

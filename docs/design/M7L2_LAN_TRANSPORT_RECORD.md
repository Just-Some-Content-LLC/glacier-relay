# M7-L2 — one transport-only exchange between the Windows/WSL host and the MacBook (record)

**Authorization:** "Glacier Relay — M7-L1 acceptance and M7-L2 transport-only authorization" (2026-10-20). It accepts M7-L1 for its demonstrated offline scope (`M7L1_PEER_NETWORK_RECORD.md` section 15) and authorizes two things:
- the preparation of M7-L2;
- after a **separate, configuration-specific operator approval**, one bounded transport-only exchange between the Windows/WSL host and the MacBook.

This is not a game experiment: no HITMAN, no "Ready" and no screen recording. The procedure is the M7-L1 record's section 12, with SASL reports kept off (14.12). It uses the committed kit `tools/peer-transport/` and its schemas, and no second launch, approval, credential or evidence system.

**Status: run 1 DONE (2026-10-20); awaiting review.** One bounded, transport-only exchange ran between the Windows/WSL host and the MacBook, after one combined approval ("Go ahead").
- Both peers ended by themselves, exit 0, outcome complete.
- 201 of 201 synthetic samples were received in each direction, in order, with identical content, no gaps and no connection drops.
- There was one mutually authenticated TLS 1.3 connection, from 192.168.1.11 (WSL through NAT) to 192.168.1.17:4760, with exact per-run pins, generation 1, no refused address and no failed handshake.
- Both scans were clean, the disposable credentials were removed on both machines, and no OS permission was introduced.

**One reconciliation check failed and stays failed:** the Windows connector's kit record lists one "listening socket". It is diagnosed as its own outbound socket caught mid-connect (section 13).

**History:** the preparation first stopped at a missing Mac prerequisite (sections 4–8, kept as written); it resumed under the operator's option B (section 9). M7 stays open; no tag.

**Evidence:** `%TEMP%\glacier-m0\hitmen\m7l2-run1\`, **sealed**: 242 entries, manifest `ecc8d118287246625c4738a5f8c89d92fe9b5ffa975873db128e5caa2131d6d8`. It verifies, has 0 unlisted files, its temporary manifest was written outside the root, and the guard refuses the root. State root: `~/.local/state/glacier-relay-m7l2` (ext4). It holds no key.

**Not authorized:**
- a game run, M7-D, a native build, another course or a second transport attempt;
- any application or library change, or new transport behaviour;
- a remote shell, SSH server, network share or transfer-service installation;
- a firewall disablement, or a router, WSL-mode or epmd change;
- Erlang distribution between the hosts.

## 1. Basis

`checkpoint-attempt2`, `readiness.py`, **36 / 36 ok**, read only:
- glacier-relay `main` `b8ec0ae`: the acceptance documentation, on top of the frozen `7c926894`, which `origin/main` was as last fetched;
- only `docs/` differs from the qualification source `9541c02`, whose trees are relay `90d40033` and kit `4f473706`; `tools/content-deployment` is unchanged;
- ZHMModSDK `relay/m2` `8129d721` = origin, clean; the tags unchanged (`6ee99b44…`);
- the WSL runtime by file hash (OTP 28.4.2, Elixir 1.19.6), resolved on the login PATH;
- native6 `91a7098f…` and native5 `f271d129…`, and the placement content, by identity: preserved, not used;
- both M7-L1 seals re-hashed in full: `m7l1-correction` 495 / 495 (`f7bf96bb…`), `m7l1-offline` 732 / 732 (`4cf04a32…`); the M7-C seal by its manifest's bytes (`5da4a64a…`);
- the qualified bundle: archive `61720a82…` (1,424,732 bytes); the sealed extracted copy against its `MANIFEST.sha256` `20987b6c…` (98 / 98, its file set exact, BUNDLE.txt = commit `9541c02`, OTP 28.4.2 / Elixir 1.19.6);
- no BEAM or game process; the project ports and 4760 free; the shared epmd (pid 45286) reported, untouched; WSL networking mode `nat`; no Erlang boot file.

The claim record holds the guard's hash (`426347f2…`): this time it was claimed from bash.

`checkpoint-attempt1` (35 ok, 1 FAIL) is kept with a NOTE. Its one failing check was my own miscount: 98 / 97 expected where the bundle holds 98 listed files plus the manifest, 99. The set comparison itself passed.

## 2. Agreements and coordination

**Operator agreements** (`agreements.txt`, recorded before use):
- the transfer channel: a USB stick carried by hand, with this conversation as the second channel for digests and pins;
- the Mac directory: `~/glacier-relay-peer-l2`;
- retention: remove the Mac directory once its outputs are back and verified.

**Two sessions** (`coordination-NOTE.txt`, `coordination-NOTE-2.txt`, the operator's messages verbatim):
- The Mac has its own companion operator session. This Windows session is the coordinator.
- Neither session reads the other's conversation; everything crosses as files on the stick or as values the operator relays.
- The operator's clarifications:
  - 201 samples / 10 s is a planned total, not a sent or received count.
  - The initiator `192.168.1.11` stays provisional until a route lookup confirms it.
  - A returned Mac configuration is PREPARED, NOT APPROVED.
  - The Mac checks the checksum file's pin first.
  - The Mac runs a known-key scan before anything returns.
  - Staging opens no socket and never creates the run's output or connector attempt.
  - The logger check runs through the actual launch path.
  - Any edit re-pins its hashes.

## 3. Windows preparation (performed)

| Step | Result |
|---|---|
| Bundle reuse (`bundle-verify-attempt1`) | the archive copied once to `to-mac\` and extracted into the state root; both copies `61720a82…`; 103 entries (99 files, 4 directories; nothing absolute, `..` or a link); manifest `20987b6c…`, 98 / 98 OK, file set exact; byte-identical to the sealed copy. **Not rebuilt.** |
| `compat-check.sh` on the WSL host with port 4760 (`win-checks-attempt1`) | no missing prerequisite |
| The logger check (`logger-check.sh`, sha256 `9c15e3f3…`; new, read only, beside the bundle) | PASS. SASL reports off: `handle_sasl_reports` false, `sasl` not started, the primary translator filter `sasl: false`. Exactly two handlers: `:default` (`Logger.Formatter`) and OTP ssl's stock `:ssl_handler` (`filter_default` stop, only `[otp, ssl]`, formatter `ssl_logger`). A `[otp, sasl]` marker dropped and an ordinary marker printed. Its two negative controls each FAIL as intended: an extra handler, and the translator letting SASL through, where the marker then appeared twice. |
| Address and permission state, read only | WSL `nat`, 172.23.229.225/20. Windows' only LAN interface with a default route is Wi-Fi, 192.168.1.11/24, gateway 192.168.1.1. The Windows firewall is ON in all profiles; the Hyper-V firewall's WSL policy allows outbound. Nothing was changed. |
| The course | the bundle's own generator: **201 planned samples over 10 s**. Section 12 of the M7-L1 record estimated 241 over 12 s; this record uses the generator's number. |
| Windows disposable credentials (`creds-win-generate-attempt1`) | generated in the state root (directory 0700, key 0600; the CA key never written): leaf pin `da85e708…c45468`, CA `26bcd393…3feb06`, valid 2026-10-19 13:00Z to 10-27 13:00Z. Only the public CA and identity were copied out. **Removed unused** after the Mac result, scanned first (section 6). |
| The staging tools, prepared, not used for the run | `validate-configs.exs`, `make-win-config.py`, `route-check.sh`, `write-approval.py`, `run-connector.sh` (`prestage` / `stage` / `start`), `arrival.sh`. They were dry-run on hypothetical values (`tooling-dryrun-attempt1`). A consistent pair passes; four single-field changes each fail for their own reason; a standalone "Go ahead" is accepted and "Looks good, go ahead" refused. |

## 4. Packet 1 and the Mac's result

**Packet 1** went to the stick (`D:`, "Thumbdrive", exFAT), in `m7l2-run1-to-mac\`:
- the archive and `logger-check.sh`;
- `creds-win-public\` (public only);
- `M7L2-PACKET-1.txt` (`7ee99905…`): a self-contained brief with the run ID, labels, port, hashes, a fixed Mac configuration template, the steps and what to return;
- `SHA256SUMS` (`82b0eaee…`).

Beside the folder, outside it, went `M7L2-CLARIFICATIONS-1.txt` (`1e81339c…`). It holds the clarifications, plus copying back with `cp -X` so that macOS adds no `._` sidecar files on exFAT.

Everything sent passed a scan with the Windows key known (0 hits). Every file was read back from the stick and matched, 7 / 7 (`usb-out-packet1-attempt2`; see section 7 for attempt 1).

**The Mac's result,** as the operator relayed it (`mac-compatibility-1-relayed.txt`; the Mac's own files are still on the Mac):
- The checksum file matched its pin first. All payloads, the packet, the archive and the clarifications matched.
- The archive listing was clean. The bundle verified (manifest pin, 98 / 98, exact 99-file set) and was unchanged after the check.
- `elixir` and `erl` resolve to Homebrew: no shim, no boot file and no flag variable.
- The runtime is **Elixir 1.20.3 on OTP 29.0.5** (ERTS 17.0.5, ssl 11.7.4), and there is no other runtime on the Mac. TLS 1.3, P-256, ECDSA, JSON and the bundle's modules all work on it.
- **MISSING PREREQUISITES:** OTP release 29 (28 needed) and Elixir 1.20.3 (1.19.x needed).
- en0 is 192.168.1.17/24, and 192.168.1.11 routes directly on en0 (still only a proposal). Port 4760 is free.
- The macOS application firewall is **off**. The Local Network privacy state is unknown.
- Not done, because of the blocker: the Mac's logger check, its credentials, the pin comparison, its configuration and the return packet.

## 5. The blocker and the decision (for the operator / review)

The kit pins the runtime on purpose. The bundle, its 888 / 0 ×5 qualification, its 95 / 0 rehearsal, finding 4 and this run's logger-check expectations were all established on OTP 28 / Elixir 1.19. Installing or switching a runtime is outside M7-L2. The options:

| Option | What it keeps | What it needs |
|---|---|---|
| **A. Stop M7-L2 here** | everything as is | the close-out (section 8) |
| **B. A separate OTP 28 + Elixir 1.19 runtime on the Mac**, leaving Homebrew's default untouched, named by `GLACIER_PEER_ELIXIR` and removed afterwards | the qualified bundle, its pins and every qualification identity, unchanged | a new authorization naming the exact runtime source, prefix, installation and removal; then a fresh packet (new Windows credentials) and the Mac checks again |
| C. Rebuild and requalify the bundle for OTP 29 / Elixir 1.20 | — | that runtime on the build host as well, and a new qualification cycle (both excluded by the operator for this stage) |
| D. Run the qualified bundle on OTP 29 / Elixir 1.20 by changing the run configuration's runtime pin | the bundle bytes | an unqualified runtime pairing: the qualification, finding 4's channel analysis and the logger check's stock-handler expectation were not established on OTP 29 / ssl 11.7.4 |

**Recommendation:** B if M7-L2 is to continue, because it is the only option that runs exactly the qualified artefact under its own pins. Otherwise A. D is not recommended without review.

## 6. Performed, reused, not executed

| Item | Status |
|---|---|
| The M7-L1 acceptance (record section 15, design section 23, HANDOFF, ROADMAP) | committed `b8ec0ae` |
| The checkpoint; bundle reuse; the Windows checks; the logger check and its controls | performed (sections 1, 3) |
| Packet 1 to the stick, read back 7 / 7 | performed |
| The Mac's packet verification, bundle verification and `compat-check.sh` | performed by the Mac session (relayed) |
| The Mac's logger check, credentials, configuration; the route confirmation; the Windows configuration; the permission table; the approval; staging; both peers; reconciliation | **not executed** (stopped at the prerequisite) |
| The Windows credentials | generated, never used. Before removal, a scan of every owned output with the key known (`scan-owned-before-creds-removal-attempt1`): 210 files, **0 material hits** (one armour-like text, the scanner's own pattern text in `scan.exs`; five suggestive names, information only). Then removed (`creds-win-removal-attempt1`); 0 `.pem` files remain in the state root. A logical deletion, not secure erasure. |
| The bundle, the 888 / 0 suites, the 95 / 0 rehearsal, the scanner's self-test, native and content identities | **reused by identity**; nothing rebuilt, re-qualified or re-run |
| HITMAN, game hashes, native loops, media | not executed (not part of L2) |

## 7. Deviations and disclosures

1. Checkpoint attempt 1 failed on my own count expectation (section 1). It is kept with a NOTE, and the generator as it ran is in `scripts\superseded\`.
2. **The logger check's first version** required `:default` as the only handler. Its first dry run on the WSL host showed OTP ssl's own `:ssl_handler`, which `ssl_app` adds on every ssl start (ssl-11.5.4 `ssl_app.erl`). Version 2 requires exactly the stock two, each specified exactly. Version 1 (`4eeca724…`) is in `scripts\superseded\`. Its dry run was console-only, not an evidence attempt.
3. **The Windows credentials were generated before the Mac's prerequisites were known**, so that the Mac could import them and hash its configuration in one USB trip (`coordination-NOTE.txt` says so). They were removed unused when the Mac failed.
4. **`usb-out-packet1-attempt1` reported PASS wrongly.** The first `powershell.exe` call inside its comparison loop consumed the rest of the file list from standard input, so only 2 of 7 files were hash-compared (both ok). The script was fixed (`/dev/null` as stdin, and the PASS requires every file compared); version 1 is in `scripts\superseded\`. Attempt 2 re-read every file from the stick without copying again: 7 / 7. Attempt 1 is kept with a NOTE.
5. The first form of the credential removal (inside a `bash -c` script) was refused by the coordinator tool's safety check and did not run. A plain `rm -r` of the literal path followed.
6. A syntax check (`py_compile`) wrote a `__pycache__` into `scripts\`. It was removed; it was not evidence.
7. **The Mac session works in `/Users/justsomedude/dev/glacier-relay/runs/m7l2-run1/`**, not the agreed `~/glacier-relay-peer-l2`. It also flagged that packet 1's `out_dir` template sits directly under the run directory while its handoff uses an outputs subfolder; nothing was written. The operator should confirm that this is a new directory, used only for this run and not inside the other project, before any retention step there.
8. The Mac's raw files (its `MAC-COMPATIBILITY-1.txt` and the compat-check output) are on the Mac only. This record relies on the operator's relay of them.
9. The M7-L1 record's section 12 estimate of 241 samples / 12 s is not the generator's figure (201 / 10 s); section 12 is unchanged.

## 8. State at the stop, and the close-out then proposed (superseded by sections 9–16)

- **Windows:** the evidence root, writers stopped, not sealed. The state root holds the extracted bundle, the hypothetical dry-run files and the logger-control copies; no key.
- **The stick:** packet 1 and the clarifications.
- **Mac** (relayed): the run directory with packet 1, the extracted bundle and logs. No Mac credential was ever generated. No permission changed.

Closing out option A would take three steps:
1. The Mac session returns its logs (the compatibility report and the raw check outputs, with a `SHA256SUMS`) by stick, to be verified here (`arrival.sh`).
2. The operator then removes the Mac run directory by its exact path, as agreed.
3. This root is sealed, its manifest written last with the temporary file outside the root.

Option B would start from a new authorization and a fresh packet, reusing this record's verified identities.

## 9. Option B: a separate runtime on the Mac (packet 2 and amendment 1)

**The decision** (`decision-B.txt`, verbatim): "I choose B. I confirm number 2 for you. I want to continue  provide what information I must handoff to the mac and I will do so."
- Option B is a separate Erlang/OTP 28 + Elixir 1.19 runtime inside the Mac run directory, removed with it. Homebrew's runtime stays untouched. The qualified bundle and its pins are unchanged.
- "Number 2" confirmed `/Users/justsomedude/dev/glacier-relay/runs/m7l2-run1/` as a new directory, used only for this run and not inside the other project. It replaces `agreements.txt` item 2.

**The runtime files** were fetched and verified on the PC and carried by the stick; the Mac downloaded nothing (`fetch-mac-runtime-attempt1`).
- **Erlang/OTP 28.4.2** for macOS, the build host's release, from the community `erlef/otp_builds` (git ref `73c4b0e0…`, OpenSSL 3.5.5 linked statically):
  - aarch64 `2d59451e…` (71,569,063 bytes);
  - x86_64 `d2268e54…` (64,584,104 bytes).

  Each hash equals both GitHub's release-asset digest and the project's builds CSV. The trees hold no absolute or `..` path; the only link is `bin/epmd`.
- **Elixir 1.19.6** for OTP 28 (`v1.19.6-otp-28.zip`, `d69db875…`): the build host's own download, matching `builds.hex.pm`'s `builds.txt`. Its 721 files are identical to the build host's installed Elixir.

**Packet 2** (`to-mac-2\`: `SHA256SUMS` `29e35a80…`, text `5bd2e3de…`; on the stick 8 / 8 verified):
- the runtime files;
- **new** Windows disposable credentials (leaf `d53f3905…6bc3ed3`, CA `72c6e8ca…ba0dd216`); packet 1's were withdrawn, never imported, and removed unused;
- the layout under the confirmed run directory;
- **the Mac configuration itself**, fully determined (`672a6dac…7a04`): listen `192.168.1.17:4760/24`, initiator `192.168.1.11`. Its plan was accepted by the bundle's own `Peer.Network`.

**The initiator, route-derived** (`route-check-attempt1`, read only, no packet sent): for 192.168.1.17, Windows selects source 192.168.1.11 on Wi-Fi, 192.168.1.0/24 on-link; WSL leaves through its NAT gateway.

**Amendment 1** (`packet-2-amendment-1.txt`, `63133d8d…`). The Mac's logger check (step 7) **failed** for one defined reason, "the sasl application is started"; its SASL marker was still 0 and its control 1.
- The cause, confirmed on the PC: the erlef tree's `bin/start.boot` / `bin/start.script` are the SASL variants (`58745822…` / `322c04c5…`).
- The build host's runtime boots `start_clean` (`b21d8b75…` / `c3558d5c…`). The clean files in the erlef tree are byte-identical to those.
- **My error:** packet 2 said no Install step was needed. That is true of the root, but OTP's `Install -minimal` also selects the clean boot.
- The approved fix was exactly `Install -minimal`'s two copies, inside `RUN/runtime/otp-28.4.2/bin` only. Before and after hashes matched, and the other 3,411 runtime files were unchanged.
- The logger check was **not waived**: attempt 2 passed outright. Attempt 1 is kept.

## 10. The Mac's preparation, the pins and the combined approval

**The Mac's return 1** (`from-mac-1\`, pin `e23a4eb4…`, 39 files, `arrival-from-mac-1-attempt1` PASS):
- macOS 26.2 (25C56), arm64 (not Rosetta), with the aarch64 tarball. `erl` and `elixir` came from the run-local runtime: OTP 28 (erts 16.3.1), Elixir 1.19.6, ssl 11.5.4, crypto 5.8.3, OpenSSL 3.5.5.
- compat-check: none missing. Logger check attempt 2: PASS. The bundle was re-verified.
- en0 192.168.1.17/24, the route to 192.168.1.11 on-link, 4760 free.
- The application firewall was off (block-all off, stealth off, no beam entries). The operator read Local Network access for WezTerm (the launch terminal) as **already on**.
- The Mac credentials (leaf `04c8edbb…a3ea2b6d5`, CA `bd37263f…c381d115`). The configuration copied unedited.
- **Deviation:** the Mac session's own tool policy did not let it run the transferred runtime. The runtime-dependent steps ran in the operator's `!` shell, through scripts the Mac session wrote (returned in `from-mac-1\operator\`).

**The second channel** (`second-channel-1.txt`, `-2.txt`): the Mac's import read the Windows CA and pin, and the PC's import (`creds-win-import-attempt1`) read the Mac's. Both directions match the values the operator relayed.

**The Windows configuration** (`m7l2-run1-win.json`, `07c3dc5e…49c04ef`; the Mac pin taken from the import's `peer.json`). `validate-configs-attempt1`: **CONFIGS PASS**. Both plans went through the bundle's `Peer.Network`, and the sockets, prefix, initiator, crossed pins, labels, course, limits and pins all agree.

**Staging and approval:**
- `prestage` (staging-attempt1) passed. It opened no socket and created no output directory or connector attempt; the approval was pending.
- The combined table `permission-table-m7l2-run1.txt` (`6ae1b947…`) was presented at 18:42:26Z.
- The operator's first reply described readiness. It was **not** taken as consent; a standalone reply was asked for.
- The standalone reply "Go ahead" was recorded verbatim at 18:49:37Z (`approval-m7l2-run1.json`; its gate names the table's sha256).
- `stage` (staging-attempt2): every check passed, including the logger check through the launch path.

## 11. The run (2026-10-20; each host's own clock)

| | Mac listener | Windows/WSL connector |
|---|---|---|
| Start | 18:49:55Z, after its logger check PASS at 18:49:54Z in the same `!` input | 18:50:20.968Z (`connector-attempt1`, its only attempt), after its staging checks again |
| Listening socket | operator's `lsof` in a second tab: `beam.smp 61051 … TCP 192.168.1.17:4760 (LISTEN)` (`mac-listener-lsof-relayed.txt`); the kit record: `["192.168.1.17:4760"]` | none at endpoint start (console `[]`); see section 13 |
| Peer identified | `m7l2-win`, pin `d53f3905…`, headless, generation 1, at 18:50:21.870Z | `m7l2-mac`, pin `04c8edbb…`, headless, generation 1, at 18:50:21.867Z (+153 ms after its endpoint started) |
| Course | 201 samples at 50 ms, sent 201 | 201 samples at 50 ms, sent 201 |
| End | `peer_bye` (the connector's `exchange_complete`); FINISHED complete, **exit 0** at 18:50:34.021Z (38.3 s of 120 s); kit-recorded exit status | closed `{:local, :exchange_complete}`; FINISHED complete, **exit 0** at 18:50:34.110Z; no reconnection |
| After | PID 61051 gone, nothing on 4760, no dump | no BEAM; the one socket (WSL `172.23.229.225:57294` → `192.168.1.17:4760`) went from ESTAB (24 samples) to TIME-WAIT, then disappeared |

The two clocks are not compared, and no one-way delay is derived from them.

## 12. Reconciliation from both ends' records (`reconcile-attempt1`)

| | Windows → Mac (stream `53376288…`) | Mac → Windows (stream `12eb81ab…`) |
|---|---|---|
| Generated (planned 201) | 201 | 201 |
| Sent / spaced (skipped) / dropped | 201 / 0 / 0 | 201 / 0 / 0 |
| Received (recorded, qualified) | 201 | 201 |
| Transport completeness: received set = sent set | yes, 0 connection drops | yes, 0 connection drops |
| Duplicates / out of order | 0 / 0 | 0 / 0 |
| Gap-free numbering 1..201 | yes | yes |
| Content: positions and the source's stamp, per sequence | 201 / 201 identical | 201 / 201 identical |
| Summaries vs traces, both ends | agree | agree |

Both directions also pass these checks:
- **Endpoints:** connections 1, refused_address 0, refused_busy 0, handshake_failures 0 on both.
- **Connection counters,** crossed: samples 201 / 201 and lines 226 / 226 each way; 0 stale and 0 expired.
- **Identities:** pins and boot IDs crossed; generation 1; labels and kinds as configured.
- **The Mac VM's only listener** was `192.168.1.17:4760`.

**Round-trip probes,** each on its own node's clock and not one-way delays: Windows 12 probes, 7 / 11 / 22 ms (min / median / max); Mac 12 probes, 9 / 11 / 23 ms.

## 13. The one failed check

**RECONCILIATION: FAIL on one check,** kept as written (`reconcile-attempt1-NOTE.txt`): "the Windows VM listened on nothing: `['172.23.229.225:57294']`".
- The connector's `events.ndjson` endpoint record (18:50:21.714292Z) and its console line (18:50:21.713238Z, `[]`) come from the same kit function, `PeerKit.listeners()`, called back to back.
- That function counts any TCP port with no peer as a listener, and a client socket that is still connecting has none.
- `172.23.229.225:57294` is the connector's own outbound socket. The sampler shows no 4760 socket at 18:50:21.463Z, then that socket ESTAB to `192.168.1.17:4760` from 18:50:21.967Z. Nothing ever listened on 4760 on Windows.
- **Assessment:** "the connector listens on nothing" is supported (the console snapshot, the socket identity, a connect-only endpoint) but **not established** by the kit's record. There was no independent all-port listener snapshot during the run.
- **Kit finding, for review:** `PeerKit.listeners()` also reports a connecting client socket. Not changed.

## 14. Close-out, and the state now

- **Windows:**
  - the outputs scanned with the key known (`scan-post-run-win-attempt1`: 224 files, 0 material hits);
  - copied into `win-outputs\` and verified (4 / 4);
  - the credentials removed (`creds-win-removal-attempt2`); 0 `.pem` files in the state root;
  - no BEAM, no 4760 socket; the shared epmd 45286 untouched; the Windows firewall and WSL unchanged.
- **Mac** (relayed; `mac-finished-relayed.txt`, `mac-end-state-relayed.txt`):
  - the outputs and its return folder scanned with the Mac key known (11 files, 0 hits);
  - the credentials removed after the scan;
  - `from-mac-2\` returned (pin `0e16f016…`; 11 macOS `._` sidecars removed with `dot_clean` on the stick only); arrival PASS at 18:58:02Z;
  - **only then** the operator removed the run directory by its exact path, which took the runtime, bundle, logs and state with it. Homebrew (OTP 29.0.5 / Elixir 1.20.3) untouched. No permission added, so nothing to revoke; WezTerm's Local Network grant stays as it was. Two empty parent folders remain, the operator's.
- **Final checks** (`final-checks-attempt2`), **36 / 36**:
  - both M7-L1 seals re-hashed in full (495 / 495, 732 / 732); the M7-C seal by its manifest;
  - the tags `6ee99b44…`; native6 / native5 and the content; the runtime;
  - the bundle (archive and sealed copy).

  Attempt 1 is kept with a NOTE: its origin check still expected the pre-push head.
- **Final scan** (`scan-final-attempt1`, no key left to know): 386 files in the root and the state root, 0 material hits. The one armour-like text is the scanner's own pattern text. The only `.pem` files in the root are the three public CA certificates that crossed. No dumps.
- **Seal:** `ecc8d118…`, 242 entries.
- **Kept outside the root,** no secret:
  - the state root: the Windows bundle copy, the dry-run and logger-control files, the output originals;
  - `%TEMP%\glacier-m0\hitmen\m7l2-inbox\`: the arrival copies;
  - the stick: packets 1 and 2, the clarifications, `from-mac`, `from-mac-2`.

## 15. Performed, reused, not executed; disclosures (continuing section 7)

**Performed:**
- option B's runtime, fetched and verified on the PC, installed on the Mac inside the run directory, with amendment 1;
- packet 2; the Mac preparation; the second-channel comparison both ways; both configurations and their validation;
- staging; the combined approval; **one** exchange; the two-way reconciliation; the scans and credential removal on both machines;
- the Mac retention; the final checks; the seal.

**Reused by identity:** the bundle, its 888 / 0 ×5 qualification and 95 / 0 rehearsal, and every native, content and tag identity.

**Not executed:** a second exchange or any retry; HITMAN; any game hash; native work; a firewall, WSL, router or epmd change; any OS permission.

**Disclosures:**
10. Packet 2's "no Install step" was wrong (section 9). Amendment 1 corrected it, and the logger check was not waived.
11. The permission system refused my first write of `decision-B.txt` (a shell write, flagged as unauthorized persistence). The same text was then written with the editor tool.
12. The Mac session's tool policy routed its runtime-dependent steps through the operator's shell and its own scripts (section 10).
13. The Mac record lists "no second-terminal lsof". The operator did run it, and its line is in the PC record (`mac-listener-lsof-relayed.txt`).
14. The Mac listener's exit status 0 is the kit's record (its summary and console FINISHED). The shell's own exit code was not shown.
15. My tooling changed between uses, each previous version kept in `scripts\superseded\`, and each used version dry-run before its use:
    - `logger-check` v2; `usb-out` v2 (the stdin bug);
    - `creds-win` v2 (the outbound folder, with an explicit refusal instead of `cp --no-clobber`);
    - `validate-configs` / `tooling-dryrun` v2 (the packet-2 layout; dry run attempt 2: 5 negative controls);
    - `scan-win` v2: a no-known-key mode, used only for the Mac's returned files after the Windows key was removed, since their known-key scan is the Mac's own;
    - `make-checkpoint-manifest` v3 (the final-mode origin check).
16. Windows credentials were generated twice. Generation 1 was unused and removed. Generation 2 was used, then scanned and removed.

## 16. What M7-L2 run 1 establishes, and what it does not

**Establishes:**
- The qualified bundle (9541c02, unchanged) ran across the LAN, on the actual Windows/WSL host (OTP 28.4.2) and the actual MacBook (arm64, a separate OTP 28.4.2 / Elixir 1.19.6 with the clean boot).
- It ran under section 20's `lan_ipv4` profile: one mutually authenticated TLS 1.3 connection with exact per-run pins, from the route-derived initiator 192.168.1.11 (WSL through NAT, no Windows or WSL change) to the Mac's one declared socket.
- One bounded synthetic exchange each way, with exact two-way accounting and identical content.
- Bounded teardown on both machines, with no reconnection.
- Clean key scans on both sides, credentials removed, and no OS permission introduced.

**Does not establish:**
- native motion latency, one-way delay, game following, a real player or a second game client, multiplayer, or M7 completion;
- behaviour under loss, congestion, a firewall that is on, or another network;
- that the Windows connector had no listener on any port: supported, not independently established (section 13);
- that memory, tracing or OS dumps hold no key material (finding 4 of M7-L1 stands).

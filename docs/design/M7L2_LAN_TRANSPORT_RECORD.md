# M7-L2 — one transport-only exchange between the Windows/WSL host and the MacBook (record)

**Authorization:** "Glacier Relay — M7-L1 acceptance and M7-L2 transport-only authorization" (2026-10-20). It accepts M7-L1 for its demonstrated offline scope (`M7L1_PEER_NETWORK_RECORD.md` section 15) and authorizes two things:
- the preparation of M7-L2;
- after a **separate, configuration-specific operator approval**, one bounded transport-only exchange between the Windows/WSL host and the MacBook.

This is not a game experiment: no HITMAN, no "Ready" and no screen recording. The procedure is the M7-L1 record's section 12, with SASL reports kept off (14.12). It uses the committed kit `tools/peer-transport/` and its schemas, and no second launch, approval, credential or evidence system.

**Status: preparation STOPPED at a missing Mac prerequisite (2026-10-20).** The Mac's only runtime is Homebrew's: Erlang/OTP 29.0.5 and Elixir 1.20.3. The qualified bundle is built and qualified on OTP 28 / Elixir 1.19.x, and the kit's own compatibility check lists that as MISSING. As the authorization requires, the preparation stopped there for a decision (section 5).
- No peer was started on either machine, and no LAN socket was opened.
- No permission table was presented and no approval was asked.
- No Mac credential, Mac configuration or Windows configuration exists.
- Nothing was installed, upgraded or changed on either machine.

**Evidence:** `%TEMP%\glacier-m0\hitmen\m7l2-run1\`, **not sealed yet** (section 8). Its writers are stopped. State root: `~/.local/state/glacier-relay-m7l2` (ext4). It holds no key now.

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

## 8. State now, and the close-out

- **Windows:** the evidence root, writers stopped, not sealed. The state root holds the extracted bundle, the hypothetical dry-run files and the logger-control copies; no key.
- **The stick:** packet 1 and the clarifications.
- **Mac** (relayed): the run directory with packet 1, the extracted bundle and logs. No Mac credential was ever generated. No permission changed.

Closing out option A would take three steps:
1. The Mac session returns its logs (the compatibility report and the raw check outputs, with a `SHA256SUMS`) by stick, to be verified here (`arrival.sh`).
2. The operator then removes the Mac run directory by its exact path, as agreed.
3. This root is sealed, its manifest written last with the temporary file outside the root.

Option B would start from a new authorization and a fresh packet, reusing this record's verified identities.

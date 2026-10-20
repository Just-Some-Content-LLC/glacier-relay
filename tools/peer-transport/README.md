# Peer transport kit (M7-L1)

Operator tooling for **one transport-only test of the peer link between two machines**, with no game. Two headless peers, each one non-distributed BEAM process: one **listens** (the MacBook in M7-L2), the other **connects out** (the Windows/WSL host). Once identified over mutual TLS 1.3 with pinned leaves, each sends **one finite synthetic course** and records the other's. Nothing received is ever sent on, and the run ends by itself.

- Boundary: `docs/design/M7_NETWORK_GHOST.md` section 20 (the opt-in `lan_ipv4` profile).
- Record: `docs/design/M7L1_PEER_NETWORK_RECORD.md`; its first LAN use, `docs/design/M7L2_LAN_TRANSPORT_RECORD.md`.
- **M7-L3** (`docs/design/M7L3_LAN_GAME_PREPARATION.md`) added two things, prepared and qualified on loopback only:
  - the socket observation (`sockets.exs`), which replaces M7-L1's listener heuristic;
  - the game-facing peer (`game-peer.exs`, `go.sh`): the MacBook's side of a later one-game LAN experiment.

**Status.** Prepared and qualified in M7-L1 on the Windows/WSL host only, on owned loopback sockets. M7-L2 then ran the transport-only peer once between the Windows/WSL host and the MacBook, under its own authorization. The M7-L3 additions have run on loopback only, never on a Mac or a LAN. Each such use needs its own authorization. A loopback rehearsal is not proof of Mac or LAN compatibility.

**What it never does:**
- start the relay application, the command authority, a motion link, the dashboard or any game-facing listener;
- use Erlang distribution or epmd;
- listen anywhere but the one declared address, or accept anyone but the declared initiator;
- install, download or upgrade anything;
- touch a shell profile, a firewall, WSL or a router;
- read another project's files, or kill anything but its own recorded process.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `bundle.sh <commit> <new-dir>` | Windows/WSL | builds the bundle from one exact commit: the relay's compiled modules plus this kit, `BUNDLE.txt`, `MANIFEST.sha256`, a `.tar.gz` and its sha256 |
| `compat-check.sh [<bundle>] [<port>]` | either | **read-only** compatibility report; ends with MISSING PREREQUISITES |
| `creds.exs generate` / `import` | either | per-machine, per-run credentials; only public files cross between machines |
| `rebundle.sh <qualified-bundle> <its-manifest-sha256> <commit> <new-dir>` | Windows/WSL | M7-L3: a kit-only bundle, the qualified bundle's compiled modules byte for byte with one commit's kit; refuses unless that commit's relay tree is the qualified one; compiles nothing |
| `peer.exs <config> <sha256>` | either | the transport-only peer: checks everything before any socket, then one bounded exchange |
| `game-peer.exs <config> <sha256>` | the Mac | M7-L3: the headless peer facing one game host (below) |
| `sockets.exs` | either | M7-L3: `PeerKit.Sockets`, one observation of the VM's own TCP sockets (below); loaded by both peers after the bundle check |
| `start.sh <bundle> <config> <sha256> [peer.exs\|game-peer.exs]` | either | prints and runs the one launch command (foreground) |
| `stop.sh <out_dir>` | either | stops that run's own recorded process only |
| `go.sh <out_dir>` | the Mac | M7-L3: the operator's one go for the game-facing peer's course |
| `scan.exs <dir>... --known-key <key.pem>` / `--selftest <dir>` | either | material-based secret scan, with planted positive controls |
| `tests/rehearsal.sh` | Windows/WSL | the loopback qualification of the transport kit (M7-L1; M7-L3 added the socket-record checks and the M7-L2 race) |
| `tests/sockets_test.exs` | Windows/WSL | M7-L3: the socket observation's focused controls |
| `tests/game-peer-test.sh`, `tests/fake-host.exs` | Windows/WSL | M7-L3: the game-facing peer's focused tests, against a stand-in game host (not the relay's) |

## Prerequisites (to be checked on the Mac under the L2 authorization, not assumed)

- **The runtime:** Erlang/OTP **28** and Elixir **1.19.x**: on the PATH, or named by absolute path in `GLACIER_PEER_ELIXIR`. The bundle is BEAM bytecode built and qualified with OTP 28.4.2 / Elixir 1.19.6, and every start refuses a different OTP release or Elixir minor.
  - `elixir` existing on the Mac does **not** establish this. `compat-check.sh` reports the runtime it would use.
  - A version manager's shim (asdf, mise) is reported and **not executed**, since it may read version files above the kit or install a runtime; `start.sh` refuses one. Name the real `elixir` in `GLACIER_PEER_ELIXIR` instead.
  - A user Erlang boot file (`~/.erlang`, or `.erlang` in the user configuration directory) would run before the peer's checks: `compat-check.sh` names it and `start.sh` refuses to run while it exists.
  - A missing or different runtime is listed for a decision. The kit does not install, upgrade or switch anything.
- **TLS:** ssl with TLS 1.3; crypto with P-256 and ECDSA.
- **The shell:** a POSIX `sh`, plus `ps`, `kill`, `tar` and `shasum` (macOS base system), and `lsof` / `ifconfig` for the report.
- **No** Python, Mix, Hex, Homebrew or compiler.
- **One owned project directory**, for example `~/glacier-relay-peer-l2/`, holding only the unpacked bundle, the state directory (credentials, 0700) and the run outputs. Nothing else on the Mac is read or written.

## Procedure (one run)

All paths are absolute. `<B>` is the unpacked bundle directory, `<S>` the owned state directory and `<O>` a run's output directory.

1. **Windows: build.** `tools/peer-transport/bundle.sh <commit> <new-dir>` prints the `MANIFEST.sha256` digest (the run configurations pin it) and the archive digest.
2. **Transfer.** Copy the archive to the Mac's owned directory. On the Mac, run `shasum -a 256 <archive>`, compare it with the printed archive digest, then `tar -xzf`. The transfer channel is part of the L2 authorization.
3. **Mac: read-only check.** Run `sh <B>/kit/compat-check.sh <B> <port>` and read MISSING PREREQUISITES. Stop if anything is listed.
4. **Credentials, each machine for itself:**
   - generate: `elixir -pa <B>/ebin/glacier_relay <B>/kit/creds.exs generate <S> <side>`;
   - exchange only `creds-<side>/own-ca.pem` and `own-identity.json` with the other machine;
   - import: `... creds.exs import <S> <side> <peer-ca.pem> <peer-identity.json>`;
   - compare the printed peer CA digest and leaf pin over a second channel.

   The certificates are short-lived test certificates: generate them shortly before the run.
5. **The run configuration**, one per side (schema below). Its sha256 is computed and presented with the exact addresses, port and pins. The Windows side's configuration names an approval record (below).
6. **Start the listener first**, on the Mac in a terminal: `sh <B>/kit/start.sh <B> <config> <sha256>`. Then start the connector on Windows.
   - Each prints its checks, the endpoint, the listening sockets of its own VM, the identification and the two courses, then FINISHED with its outcome.
   - `start.sh` removes `ERL_AFLAGS`, `ERL_FLAGS`, `ERL_ZFLAGS`, `ELIXIR_ERL_OPTIONS` and `ERL_LIBS` for the peer, and turns crash dumps off (`ERL_CRASH_DUMP_BYTES=0`), because a dump would hold the private key.
   - Exit status:

     | Status | Meaning | Summary written |
     |---|---|---|
     | 0 | complete: every inbound stream ended with all its source sent received, in order, nothing twice (gaps are the source's own skips, `spaced` / `dropped` in the other summary) | yes |
     | 2 | refused before any socket | no; the output directory is not created |
     | 3 | no peer, or the lifetime ended | yes |
     | 4 | the connection ended before completion or before identification; never reconnected | yes |
     | 5 | ended, but some inbound stream is not transport-complete | yes |
     | 6 | stopped by `stop.sh` (SIGTERM) | yes |
     | 7 | the endpoint could not start (the declared address not this machine's, or the port taken) | yes |
     | 124 | the hard backstop, lifetime + 15 s | no |
7. **Stop early, if needed:** `sh <B>/kit/stop.sh <O>`, from another terminal. It acts only on the process recorded in `<O>/peer.pid` whose command line is that run's peer, and it checks that again before any KILL.
8. **Scan, then clean up:**
   - `elixir <B>/kit/scan.exs <O> --known-key <S>/creds-<side>/own-key.pem` must report MATERIAL HITS: 0;
   - then remove `<S>/creds-<side>`. This is a logical deletion, not secure erasure.

## The run configuration (`glacier-relay.peer-transport-run/1`)

```json
{"schema": "glacier-relay.peer-transport-run/1", "run_id": "m7l2-run1", "side": "mac", "role": "listen",
 "network": {"profile": "lan_ipv4", "prefix_length": 24, "listen": ["192.168.1.20", 4760], "initiator": "192.168.1.10"},
 "label": "m7l2-mac", "expected_label": "m7l2-win",
 "credentials": {"cert_file": "<S>/creds-mac/own-cert.pem", "key_file": "<S>/creds-mac/own-key.pem",
                 "peer_ca_file": "<S>/creds-mac/peer-ca.pem", "peer_pin": "<the Windows leaf pin>"},
 "course": {"profile": "out_and_back", "prefix_ms": 2000, "distance_m": 1.0, "speed_mps": 0.5, "hold_ms": 2000, "interval_ms": 50},
 "limits": {"lifetime_s": 120, "connect_window_s": 0, "start_after_up_ms": 1000, "drain_ms": 1000},
 "out_dir": "<O>", "bundle": {"manifest_sha256": "<the MANIFEST.sha256 digest>"},
 "runtime": {"otp_release": "28", "elixir_version_prefix": "1.19."}}
```

**The connector's configuration differs:**
- `"role": "connect"`;
- `"network": {"profile": "lan_ipv4", "prefix_length": 24, "connect": ["192.168.1.20", 4760]}`;
- a `connect_window_s` of up to its lifetime;
- an `approval` entry: `{"file": "<approval.json>", "max_age_s": 1800, "accepted_replies": ["Go ahead"]}`.

**The address rules** (`GlacierRelay.Peer.Network`):
- IPv4 only, as strict dotted quads: `127.0.0.1` or RFC 1918 private unicast. No hostname, wildcard, multicast, broadcast, link-local, public address or IPv6.
- A declared prefix of 8–30, never discovered. The network and broadcast addresses of the prefix are refused, and the initiator must be inside the listener's prefix.
- Ports 1024–65535.
- Only a headless peer listens under the profile.

The addresses above are **placeholders**: the real ones are named by the L2 authorization.

**The bundle** is checked before anything else, even before the configuration is decoded. The files under it must be exactly those listed in its `MANIFEST.sha256`, each with its sha256. So keep the configuration, credentials and outputs **outside** the bundle directory.

## The approval record (`glacier-relay.peer-transport-approval/1`)

A JSON file written by the coordinator holding:
- the gate, the presentation time, and the sha256 of the configuration and of the bundle manifest it presented;
- **the operator's reply exactly as given** (`operator_reply_verbatim`), and when it was recorded.

`peer.exs` accepts it only if:
- the **whole** reply, trimmed (case-insensitive, with at most one trailing `.` or `!`), equals one of the configuration's `accepted_replies`;
- it names this configuration and this bundle;
- it is younger than `max_age_s`.

A longer message that merely contains an approval word is **not** consent. The coordinator then asks for a standalone reply and never composes one from another message. A no-game transport stage asks for no game recording and no HITMAN "Ready".

A configuration without an `approval` entry needs none. By convention only the side the coordinator starts (the Windows connector) names one, because the operator starting the Mac listener in their own terminal is that side's act. The L2 authorization can require it on both.

## Outputs (`<O>`, created exclusively, 0700)

- `peer.pid`: the OS process id and the configuration path, for `stop.sh`;
- `events.ndjson`: the checks, the endpoint (with its socket observation), peer up and down, the course, the further socket observations, the finish;
- `trace/`: the headless motion trace of every sample sent and received;
- `summary.json`: the outcome, both identities and pins (public), the endpoint counts, the source and sink reconciliation, and each socket observation's verdict.

None of them holds a private key or a token.

**The scan** (`scan.exs`) counts as material:
- a decodable PEM private key, including one inside a JSON string;
- each known key's DER as raw bytes, base64, hex, or the decimal byte list the BEAM prints (inspect, `~p`, `~w`);
- an EC key's private scalar in each of those forms.

It walks directories without glob expansion and refuses a directory with nothing to scan. Its `--selftest` plants positive controls for every form, each of which must be found by its own class, plus negative controls (pattern text, a certificate, suggestive file names, random numbers). It then removes the planted key and the positives.

## Socket observation (`sockets.exs`, M7-L3)

M7-L1's `PeerKit.listeners()` counted every TCP socket without a peer as a listener. A client socket that is still connecting has no peer either, so M7-L2's connector record listed its own outbound socket as one (`M7L2_LAN_TRANSPORT_RECORD.md` section 13). `PeerKit.Sockets.observe/0` replaces it, and having no peer no longer means anything.

**One observation** is taken at each reporting point: the endpoint start, the identification, the finish (and the game-facing peer's go). It is printed and written from the same result. It holds two views, each with its own time; they are two queries, never presented as one atomic result:
- **the VM's view:** every `tcp_inet` port of this VM, classified by its explicit inet-driver state (`:inet.info/1`: `listen`, `connecting`, `connected`), with its addresses and owning Erlang process. A socket that closes during the observation is counted, not classified.
- **the kernel's view of this OS process:** on Linux `ss -tanpH` (this pid's lines only); on macOS `lsof -nP -a -p <pid> -iTCP -F pnT`. The macOS branch was tested through its parser only, never executed on a Mac; there, the operator's second-terminal `lsof` stays the runtime check.

**The verdict:**
- `observed`: the VM listing is complete, and the kernel's listening set (when available) is the same;
- `ambiguous`: an entry is unclassified, or the kernel disagrees;
- `unavailable`: the VM listing failed. A failed query is never an empty successful result.

"Listens on nothing" (`no_listener?/1`) and "listens only on the declared socket" (`only_listener?/2`) are true only for an `observed` result. This is an operator measurement at those points, not continuous proof and not a monitor.

## The game-facing peer (`game-peer.exs`, M7-L3)

The MacBook's side of the later one-game LAN experiment (design section 26; the M7-L3 record). It runs M7-C's two sequential phases against the Windows game host. It is **not** the transport-only peer: it sends no course by itself.
- **It listens only:** one declared private socket, for one declared game host (`client_kind` game). The game host connects out.
- **Phase 1, the share:** it records the game host's real-player share stream in its sink, and sends nothing back. Nothing received ever reaches its source.
- **Phase 2, the course:** only on the operator's `go.sh <out_dir>`, once, it sends M7-C's one synthetic course. That is `Motion.Course.out_and_back` from P's exact words (`c2b2fae1,416d47ae`): 1.0 m along negative world x at 0.5 m/s, a 4,000 ms stationary prefix, 2,000 ms holds and a 50 ms interval, so 241 samples over 12,000 ms.
  - The course is compiled into the script; the configuration names the profile and the anchor, and both must equal the compiled ones.
  - The generated course is checked against its own facts before any socket. Its digest is printed, so the operator can compare it with the game host's course plan.
- **The go is one-shot.** It is refused before identification, while an inbound stream (the share) is open, or after a course has run. A refused go is final.
- **The end:** the game host closes the connection, or the lifetime ends (60–900 s). It never reconnects.
- **Exit status:**
  - 0: ended by the host after identification, every inbound stream transport-complete, and the course (if any) ended `course_complete`;
  - 3: the lifetime ended;
  - 4: the connection ended before identification, or during the course;
  - 5: the host ended it with a share open or incomplete;
  - 2, 6, 7 and 124: as for `peer.exs`.

The configuration (`glacier-relay.peer-game-run/1`) has the transport configuration's keys, with these differences:
- `"role": "listen"` only;
- `"course": {"profile": "m7c_out_and_back", "anchor_words": ["c2b2fae1", "416d47ae"]}`;
- `"limits": {"lifetime_s": N}`.

It holds no run token, no authority API and no game state.

# Peer transport kit (M7-L1)

Operator tooling for **one transport-only test of the peer link between two machines**, with no game. Two headless peers, each one non-distributed BEAM process: one **listens** (the MacBook in M7-L2), the other **connects out** (the Windows/WSL host). Once identified over mutual TLS 1.3 with pinned leaves, each sends **one finite synthetic course** and records the other's. Nothing received is ever sent on, and the run ends by itself.

- Boundary: `docs/design/M7_NETWORK_GHOST.md` section 20 (the opt-in `lan_ipv4` profile).
- Record: `docs/design/M7L1_PEER_NETWORK_RECORD.md`.

**Status.** Prepared and qualified in M7-L1 on the Windows/WSL host only, on owned loopback sockets. **Nothing here has been run on the MacBook, and no LAN socket has been opened.** Doing either needs its own authorization. A loopback rehearsal is not proof of Mac or LAN compatibility.

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
| `peer.exs <config> <sha256>` | either | the peer: checks everything before any socket, then one bounded exchange |
| `start.sh <bundle> <config> <sha256>` | either | prints and runs the one launch command (foreground) |
| `stop.sh <out_dir>` | either | stops that run's own recorded process only |
| `scan.exs <dir>... --known-key <key.pem>` / `--selftest <dir>` | either | material-based secret scan, with planted positive controls |
| `tests/rehearsal.sh` | Windows/WSL | the M7-L1 loopback qualification of all of the above |

## Prerequisites (to be checked on the Mac under the L2 authorization, not assumed)

- **The runtime:** Erlang/OTP **28** and Elixir **1.19.x** on the PATH. The bundle is BEAM bytecode built and qualified with OTP 28.4.2 / Elixir 1.19.6, and every start refuses a different OTP release or Elixir minor.
  - `elixir` existing on the Mac does **not** establish this. `compat-check.sh` reports the version the PATH actually resolves, including through a version manager's shim.
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
   - Exit status: 0 = complete and reconciled; 3 = no peer, or the lifetime ended; 4 = the connection ended first; 5 = complete but not reconciled; 2 = refused before any socket.
7. **Stop early, if needed:** `sh <B>/kit/stop.sh <O>`, from another terminal.
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

## The approval record (`glacier-relay.peer-transport-approval/1`)

A JSON file written by the coordinator holding:
- the gate, the presentation time, and the sha256 of the configuration and of the bundle manifest it presented;
- **the operator's reply exactly as given** (`operator_reply_verbatim`), and when it was recorded.

`peer.exs` accepts it only if:
- the **whole** reply, trimmed (case-insensitive, with at most one trailing `.` or `!`), equals one of the configuration's `accepted_replies`;
- it names this configuration and this bundle;
- it is younger than `max_age_s`.

A longer message that merely contains an approval word is **not** consent. The coordinator then asks for a standalone reply and never composes one from another message. A no-game transport stage asks for no game recording and no HITMAN "Ready".

## Outputs (`<O>`, created exclusively, 0700)

- `peer.pid`: the OS process id and the configuration path, for `stop.sh`;
- `events.ndjson`: the checks, the endpoint, the listeners, peer up and down, the course, the finish;
- `trace/`: the headless motion trace of every sample sent and received;
- `summary.json`: the outcome, both identities and pins (public), the endpoint counts, the source and sink reconciliation.

None of them holds a private key or a token.

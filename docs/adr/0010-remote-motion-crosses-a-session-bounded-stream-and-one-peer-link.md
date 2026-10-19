# ADR 0010 — Remote motion crosses a session-bounded stream; inter-host exchange is BEAM-to-BEAM over one explicit peer link

**Status:** Proposed (2026-10-19, with the M7-A design `docs/design/M7_NETWORK_GHOST.md`). Scope: **M7 — Network ghost only.** Nothing here authorizes implementation, a socket, a network, firewall or WSL change, a second machine or a runtime experiment.

**It amends ADR 0009 rule 3:** engine writes would no longer come only from individual commands; they could also come from samples inside a session that a command opened.

## Context

The M6 checkpoint has two loopback, native-initiated links:
- **telemetry** (`4747`): one-way and best-effort; it drops the oldest envelope when full;
- **commands** (`4749`): duplex, journaled, armed, one in flight, one per frame (ADR 0009).

M6 applied one compiled transform write on a content-placed candidate. M7 needs a continuous, superseding flow of one player's sampled pose, from one machine to another and back, applied to the other machine's candidate. Neither link fits it:
- through telemetry, samples would evict semantic events and enter recordings;
- through the command path, every sample would be a journaled request / response command.

The 2023 Hitmen transport (GameNetworkingSockets, all interfaces, unauthenticated, raw memory) is rejected (ADR 0005). Erlang distribution grants a connected node full code execution.

Only one Windows game host is available. Early development therefore needs a peer without a game.

## Decision

1. **Control and data planes are separate.**
   - **Open and reverse:** only journaled, armed commands on the existing command link (`player.pose.share/1`, `candidate.motion.session/1`). The M6 v1 / v2 contracts are unchanged, except that their forwards are refused while a session is open.
   - **Close:** by command, or natively on any fail-closed condition. A close never needs arming, and it is journaled when known.
   - **Samples:** they travel outside the journal — on a third native-initiated loopback link (proposed `4750`, behind native settings that default to false), and between hosts on the peer link. Sessions record their bounds, outcome and counts in the journal. The samples go to a separate, bounded motion trace.
2. **The native adapter stays local.** It never listens and never speaks to another host. Inter-host exchange is BEAM-to-BEAM over one explicit peer link:
   - off by default;
   - mutually authenticated with pinned per-experiment certificates;
   - one allowlisted peer;
   - towards a headless peer, the **game host only connects out**: its BEAM never listens on the LAN, and no port proxy is used. Where the listener sits for two game hosts is decided with M7-D's environment, under the same rules.

   Ports 4747 / 4748 / 4749 / 4750 stay loopback, each with a start-time refusal of non-loopback binds. Erlang distribution is never an inter-host channel, and it is pinned to loopback before any networking change.
3. **A network message is data, never authorization.**
   - Each game host alone originates its local player's samples, and alone opens its own destination session after local operator arming. That arming names the expected peer and its declared source kind.
   - A peer message cannot open, extend or arm anything.
   - Streams are directional, and nothing received from the peer is forwarded back.
4. **A headless protocol peer is a first-class but labelled peer.** It has no game, no adapter, no authority and no token. Its samples declare `source_kind: synthetic`, and a session armed for another kind refuses them. A result obtained with a headless peer is never reported as equivalent to two real game instances and never satisfies the M7 exit.
5. **Destination application is bounded and latest-wins.**
   - At most one apply per frame, through the existing single setter site, after fresh resolution of the compiled candidate.
   - Peer-derived x / y are accepted only if finite and inside the session's spatial and step bounds.
   - When samples stop the candidate holds; it never extrapolates.
   - Mission, generation or link changes close the session natively.
   - There is no automatic reversal: a return is a separately approved `restore`.
6. **The observer path stays separate.** `Wire.*`, `MissionSession`, `Session.Fold`, the recorder, the reader, the replay, the dashboard, the fixture player, the test-support modules and the HTTP endpoint do not reference `Motion.*` or `Peer.*`. The compile-time boundary test and the supervision-tree invariance test with the flags off are extended accordingly.

## Consequences

- Loss and ordering are handled by sequence numbers and the receiver's own hold timers, not by delivery guarantees. Exactly-once application is not claimed.
- Cross-machine monotonic clocks are not compared; one-way latency is only estimated.
- A UDP / DTLS transport, interpolation, rotation and z-following are later, separately evidenced decisions.

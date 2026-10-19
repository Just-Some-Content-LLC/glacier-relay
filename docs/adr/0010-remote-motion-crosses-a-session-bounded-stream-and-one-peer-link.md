# ADR 0010 — Remote motion crosses a session-bounded stream; inter-host exchange is BEAM-to-BEAM over one explicit peer link

**Status:** **Accepted (2026-10-19), as amended below, for the amended boundary and the M7-B1 scope; clarified the same day by the M7-B1 correction (amendments 10–13; design section 17)** (offline, BEAM and tooling, fake native endpoints and owned loopback peers). Proposed earlier the same day with the M7-A design `docs/design/M7_NETWORK_GHOST.md`; the reviewed contract is that design's section 15. Acceptance is **not** evidence of native or runtime enforcement: the DLL implements none of this until M7-B2, and nothing has run against the game. Scope: **M7 — Network ghost only.** Nothing here authorizes a native change, a game run, a LAN socket, a network, firewall or WSL change, or a second machine.

The Context and Decision sections below are the proposal as reviewed. They are kept as written; the **Amendments on acceptance** section changes them and governs where they conflict.

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

## Amendments on acceptance (2026-10-19; design section 15)

These are amendments. The proposal above did not contain them.

1. **Close is not a command.** `candidate.motion.session/1` carries `open` and `restore` only. Close is a `ghost.close` on the bound motion link — or, when that line cannot be written within its deadline, the dropping of the link, on which the native closes. The command link's one-in-flight rule therefore cannot block it. It needs no arming, works with full buffers or a degraded audit, and is journaled when known as `requested`, `transmitted`, `confirmed` or `unknown`. A peer ends only its own bound stream.
2. **The local data link is bound, not merely loopback.** The `4750` link is accepted only for the current token-verified command link's adapter and generation. It is then attested by an HMAC of the run token over a fresh nonce and both link generations, verified inside `TokenHolder`. The token never leaves the host. A share or session names its motion link generation.
3. **The local approval fixes the session.** It fixes the peer pin, boot, connection, stream and `source_kind`, the starting exact inspection, the identity mapping, and the numeric limits and expiry (section 15.3), all before application is possible. There is no acquisition exemption: the first target, and any target after a pause, is bounded against the opening snapshot or the last **confirmed-applied** postimage. The displacement credit is capped, so a pause earns nothing extra.
4. **First uncertainty ends application.** The first uncertain post-call result ends application, as does any native refusal, critical identity, generation, parent, registry or control failure, report disagreement, or trace or audit loss. A declared stall or lag growth closes the session. There is no resumption, and no automatic recovery or re-arming.
5. **Exclusivity covers restores.** `candidate.transform.set` v1 / v2 forwards **and restores** are refused while a motion session is not restored. A motion open is refused while an M6 forward is unrestored. There is one session per authority process by default, and a new session never replaces an unrestored one's preimage. A motion restore needs a native-confirmed clean close, the retained preimage, a fresh later exact inspection and new arming; lost or uncertain history is ineligible.
6. **Peer authentication.** TLS 1.3 only, mutual. Each side has a per-experiment private CA and a pinned leaf. The verification callback only narrows, and the pin is checked again after the handshake. There is no trust on first use, no resumption, no early data and no Erlang distribution between peers. B1's 4750 / 4760 refuse any non-loopback bind, and B1's test peers are non-distributed.
7. **Freshness claims are limited** to order, receipt silence and bounded delay growth (receiver interval minus source interval). Every queue, frame, deadline and control capacity is bounded; control overflow closes the connection.
8. **Evidence.** There is a separate, bounded motion trace with explicit incompleteness. Per-apply postimages travel in `ghost.applied`. F2 (engine frames +1 … +4) is unmeasured unless B2 adds the bounded instrument. RTT / 2 is not a latency.
9. **Corrections.** The epmd "harmless under NAT" and "would be exposed" claims are retracted (wildcard listener observed; reachability and firewall not established). "No collision" means collision is unvalidated.

## Amendments of the M7-B1 correction (2026-10-19; design section 17)

10. **Deadlines hold at event and effect boundaries.** A timer is a wakeup, not a deadline. Every event is judged at its processing time, after the deadlines that have passed by then. Eligibility is checked again immediately before the bytes, after any blocking pre-send work. A target cancelled there is never uncertain, and a late acknowledgement or a late confirmation is evidence only: it never resolves, confirms, releases or reopens anything. B2's native enforces the same on its own clock.
11. **A restoration result proves the restoration.** A motion restore releases the candidate only with the whole restoration-result contract (design 17.2), journaled before it takes effect. Anything less is non-releasing and terminal for the session. This changes no M5 path and no accepted M6 operation semantics.
12. **The peer sender's queue** is the implemented one, accepted for the first bounded headless-peer scope: drop-newest at 8, with stale (100 ms) and share-bound drops, the per-stream rate enforced by the producers (design 17.3). It is not a proof of absolute freshness.
13. **The TLS observation is scoped** to the tested OTP 28 / ssl 11.5.4 configuration (design 15.7). No TLS redesign follows from it.

# M7 — Network ghost: architecture and capability-gap investigation (M7-A)

**Status:** design only (2026-10-19). Nothing implemented, built, installed or launched; no socket opened, no network change, no other machine contacted, no token, no engine command. Nothing here implies that multiplayer works. Every stage below needs its own authorization.

**Reviewed (2026-10-19):** section 15 is the reviewed contract that M7-B1 implements against fakes. It amends, and where they conflict governs, sections 1–14. ADR 0010 is accepted for that amended boundary and the B1 scope only.

This revision includes the operator's **hardware and ownership constraint** (section 9). There is one Windows HITMAN development host (the Steam copy), an Xbox copy and a MacBook. A second compatible Windows game installation is not assumed.

**Authorization:** "Glacier Relay — Proposed M7-A architecture investigation", with the amendment "M7-A hardware and ownership constraint".

**Evidence:** `%TEMP%\glacier-m0\hitmen\m7a-design\` (guarded; sealed after this record): `checkpoint-checks.txt` (PASS), `environment-facts.txt`, `source-facts.txt` (cited files with git blobs), `verifier-report.txt` (the one read-only verifier's report on the pre-amendment draft) and `verifier-disposition.txt` (how each of its 25 findings is handled in this text).

**Roadmap, as written.** Goal: "Two PCs, same mission. Each instance renders the other player's externally driven Hitman." Exit: "bidirectional movement/input representation survives a bounded test session." This is not shared-world synchronization (section 7). The exit is preserved: only two real game instances can meet it (section 9).

**Classes:** **S** source-established; **R** runtime-demonstrated; **I** inference; **P** proposal; **U** unknown.

## 1. Starting point

The accepted checkpoint resolves exactly from Git and the preserved artefacts (`checkpoint-checks.txt`):
- glacier-relay `148dd5bb`, the tag object `4a05ddaa` → `4ee9dd39`, `relay/` and `tools/` unchanged since `874d404c`;
- ZHMModSDK `76c407f3` on `06a2c48c`, the tag object `7cfed869`;
- native5 `f271d129…`, the content `5ac64848…` / `58e9a10f…` / `9433888b…`;
- the M6-G1 / G2 / closure manifests and the video `b959fc53…`.

No discrepancy. M6's limits carry forward (`M6_SECOND_HITMAN.md` 20.4–20.5):
- M6 demonstrated one world-y step and one restoration, not ongoing control, pose streaming, locomotion or cross-machine operation;
- the M6-F2b lift returned within ≤ 6 frames (M6-F1b's return time was not established) while the y step held, and no causal rule follows.

**Finding (recorded, not changed):** epmd listens on `0.0.0.0:4369` / `[::]:4369`. That is most likely (I) the daemon left by the tooling's `--sname` nodes; the process was not identified. WSL2 is in NAT mode, inferred (I) from the absent `.wslconfig`. A later networking change would expose epmd unless distribution is first pinned to loopback (4.3).

## 2. Reused capabilities, and the smallest missing ones

| Capability | State | Class |
|---|---|---|
| Local player = registry slot 0, read on the frame; the generation = its `ContractSessionId` at the rise | basis of M2–M6 | S, R |
| Local-hero pose | slot 0's stored `m_mTransform` and dirty flag, inside `relay.inspect.candidate_transform/1` — a **one-off, journaled command result** (≈ 56–60 ms round trip), read only on a stationary hero; moving-hero reads exist only via the 2023 module's refreshing getter (experiment 4, 213 reads) | S; R |
| Telemetry | no position (`RoomId`, a number, only) | S |
| Candidate identity: brick `007c57a6ea581f8c` / entity `feede715906f747f`, re-resolved per frame, distinct, in no registry slot | M6-C3 … G2 | R |
| One setter site, `SetObjectToWorldMatrixFromEditor`, exact on its frame for **single** writes | z twice (returned), y once (held) | R |
| Repeated writes, x, rotation, rendering at rate, frame cost | untested | U |
| Authority, journal, arming, `token_verified`, attestation, ownership evidence, the 60 s inspection binding, the fault latch | fail-closed single issuer | S, R |
| The M6 one-forward budget per process | wrong for motion by design; unchanged | S |
| Telemetry `127.0.0.1:4747` (one-way, 256 entries, drops the **oldest**); command `127.0.0.1:4749` (native-initiated, queue 8, 64-id dedup ring, one per frame) | loopback only | S, R |
| Inter-host exchange | none; Hitmen's GNS (port 6969, unauthenticated, raw memory) is rejected (ADR 0005) | S |

**Missing (P):**
- a read-only **pose sampler** for slot 0 (native);
- a session-bounded **motion applier** (native) on the one setter site;
- a local **motion link** (the data plane);
- a **motion-session contract** on the authority (the control plane);
- a BEAM-to-BEAM **peer link**;
- a reusable **headless protocol peer** (section 9);
- a **motion trace** (evidence).

**Not needed:** input injection, animation, pathfinding, registry changes, activation.

## 3. Decision: replicate observed spatial state

| | **Observed spatial state** | Input intent |
|---|---|---|
| Source | a pose read on the frame (S; R via the historical getter) | the raw 0x148-byte block is rejected; the per-controller input path is unexplored (U) |
| Destination | the accepted setter (R for single writes; repeated writes U) | Agent48 is outside the registry (R, M6-D1b) and, by the supported-not-proven hypothesis H1, an unspawned hero (I; M6-D2). Whether any of its controllers consumes input is U, and testing that needs activation / registry / controller changes, which are not authorized. |
| Drift | none accumulates; each sample is absolute (I) | the same input diverges in two independently simulated worlds (I) |
| Visual | slides without gait (I) | possibly animated (U) |
| Testable with one game instance and a headless peer | yes, per direction (section 9) | no: a synthetic input stream says nothing about a real controller |

**Decision (P): observed spatial-state replication.** Input intent is blocked by one missing fact: whether the candidate, unspawned by hypothesis, runs a controller that consumes input.

**Proposed exit interpretation (for review):** each real instance's candidate follows the other real instance's sampled local-player horizontal position within stated bounds and statistics. Input representation, gait, turning (in v1), collision and world synchronization are not claimed.

## 4. Architecture

```text
game host (Windows)                                            peer (real game host, or headless)
HITMAN + native ──4747──► BEAM ══ peer link (NEW; the game host connects out) ══► BEAM peer
               ◄═4749 control═►
               ◄═4750 data (NEW)═►
```

A game host is the **source** for its own hero and the **destination** for the peer's samples on its own candidate. A headless peer has no game: it is a labelled synthetic source and a recording sink (section 9).

### 4.1 Why the adapter stays local

- The native side never listens (ADR 0005, proposed; ADR 0009).
- Networking belongs to BEAM (ADR 0002).
- The frame thread never waits on remote I/O, and a game crash stays separate from a network fault.

Rejected for samples:
- **telemetry**, which evicts the oldest entry and would put samples into recordings (ADR 0008; ADR 0009 rule 7);
- **the command path**, which is journaled, one-in-flight and request / response (`M6_SECOND_HITMAN.md` 6);
- **Erlang distribution**, where a connected node can run any code on the other.

### 4.2 Two planes

**Control (command link; journaled, armed; P).**
- `player.pose.share/1` `open | close`: inert, but samples leave the machine. It needs inert arming, an operator share statement and a bounded duration.
- `candidate.motion.session/1` `open | close | restore`: effectful, with the M5 / M6 prerequisites plus a new **session arming**:
  - one-shot, valid at most 120 s (the existing effectful-arming maximum) until one `open` consumes it;
  - it names the expected peer and its declared source kind (`game` | `synthetic`);
  - the session it opens has its own duration bound (section 6).

  `restore` returns the candidate to the session's opening preimage. It is the named reversal, separately approved, never automatic. **A close never needs arming:** it happens by command, or natively on any fail-closed condition, and is journaled when known.
- **Local enabling:** native `[motion] enabled | share | apply` settings in `glacierrelay.ini`, all false by default, beside the BEAM flags (P).
- Motion is a separate contract. It never re-arms or re-issues the one-shot M6 command.
- **The M6 contracts:** v1 / v2 are unchanged in their contracts. While a session is open, both the authority and the native scheduler refuse their forwards; that refusal is the only addition. A native `open` refuses while the M6 ledger is `ForwardInvoked` or `Invalidated`.
- **Within a frame:** the command tick runs first, and there is no motion apply on a frame where a command invoked a setter.

**Data (not journaled per sample; P; lines ≤ 1 KiB).**
- native → BEAM (4750): `hero.sample {share_id, seq, frame, native_mono_ms, words[12], dirty}`.
- peer: `pose.sample {session_id, origin_peer, source_kind, seq, src_frame | null, src_mono_ms, words[12], dirty}`, `pose.end {reason}`, and `ping` / `pong` with the sender's own clock echoed.
- BEAM → native: `ghost.target {session, seq, x, y}`, latest wins. In v1, z and the rotation stay at the session-open preimage.
- native → BEAM, every 250 ms: `ghost.report` (counts by outcome, the last applied seq / frame, that frame's exact postimage) and `ghost.closed {reason}`.

**Applying frame (native).** A target is applied only if all of these hold:
- the session is open;
- the mission is playing;
- the generation, scene and both link generations are as at `open`;
- the latch is clear;
- the seq is newer than the last accepted;
- x and y are finite;
- the target is inside the box;
- the target passes the step rule.

**Step rule:** the reference is the last **accepted** target, sample to sample. **Acquisition** is the session's first target, and the first target after a hold of at least 250 ms; it needs only finiteness and the box, and is counted. Any other step over 1.0 m is refused.

The target is the preimage with `Trans.x` / `Trans.y` replaced. Observe → one Invoke → ReadBack run through the existing `ITransformApplier`, so there is still one setter site. Otherwise the candidate holds.

Peer-derived x / y are thereby **parameters of an engine write**. That is a departure from M6's compiled displacement, bounded only by the checks above.

### 4.3 Peer transport

**TCP with mutual TLS 1.3** (OTP `ssl` loads here), using per-experiment self-signed certificates whose fingerprints the operators exchange out of band (P). The reasons:
- one ordered connection carries the control messages and both streams;
- standard integrity and authentication;
- about 300 B at 20 Hz is trivial.

Loss stalls are bounded at the receiver: latest wins, an older or duplicate seq is dropped, and no backlog is replayed. "Stale" means only that, plus the receiver's own hold timer; no cross-clock age exists. **UDP / DTLS is deferred** until a measured LAN shows stalls exceeding the hold bound. The sender's drop-oldest bound applies to samples only: handshake, `pose.end`, `ping` / `pong` and close messages are never dropped.

**Direction:** with a headless peer, the game host only **connects out**. Its BEAM never listens on the LAN, and no port proxy is used, because a proxy would become the real listener and escape the one-peer rule.

Two game hosts (M7-D) need one of them to listen. In WSL2 NAT mode BEAM cannot bind a LAN address, so that choice — for example mirrored networking with distribution pinned first, or BEAM outside WSL — is deferred to M7-D's environment preparation, under the same rules. A listener runs on the peer side only:
- off by default;
- one configured address, never `0.0.0.0`; `127.0.0.1` for a local peer;
- natively on macOS for the MacBook peer;
- a proposed port of 4760;
- one allowlisted peer.

The game host therefore needs no inbound rule and no WSL2 networking change: outbound connections from NAT are expected to work (I, untested). 4747 / 4748 / 4749 / 4750 stay loopback. Each gets a start-time refusal of non-loopback binds, with a test; today only 4749 has one. If a networking change is ever proposed, epmd and distribution are pinned to loopback first.

## 5. Identities, authority, routing

| Identity | Definition | Class |
|---|---|---|
| Peer | UUID per BEAM boot, an operator label and a declared **client kind** (`game` | `headless`); authenticated by its pinned certificate | P |
| M7 session | UUID offered and accepted; one per bounded test session | P |
| Game instance | `adapter_instance_id` | S, R |
| Mission generation | each machine's own `ContractSessionId`, never compared across machines; recorded at `open`; a change ends the session | R; P |
| Source entity | a role: slot 0's hero on the sampling frame; for a headless peer, a named synthetic generator | R; P |
| Destination candidate | the compiled pair, re-resolved on each apply frame | R |
| Content fingerprint | build, SDK, scene, the loaded brick set, package and DLL hashes; must match between two game peers (`HITMEN_ENTITY_IDENTITY.md` requirement 3); a headless peer declares none | P |

Authored ids (the hero's `69bdf7f855ea15e0`, `feede715906f747f`) are expected to repeat across instances (I) and are never cross-machine identity. Pointers never leave the frame.

**Lifecycle, in order:**
1. peer handshake (certificates, kinds, fingerprint);
2. local `share open`;
3. local session arming;
4. a fresh exact candidate inspection;
5. session `open`;
6. stream;
7. `close` (any cause);
8. optionally, a separately approved `restore`.

The session summary is journaled.

**Authority.** Each game host alone originates its hero's samples and alone opens and validates its own destination, after **local** operator arming. A peer message carries data only. It cannot open, extend or arm anything, and it does not prove target validity. A headless peer never holds a token, never reaches 4749 / 4750 and never issues a command. The ADR 0009 boundary test extends to `Motion.*` and `Peer.*`, so the browser, replay, recorder and fixtures cannot issue operations.

**No feedback:**
1. The sampler reads only slot 0, and refuses a frame where that entity is the candidate or not distinct from it.
2. The applier writes only the candidate.
3. Outbound samples come only from the local sampler (origin = self). Inbound samples go only to the local destination and are never forwarded. An inbound origin equal to self is dropped and counted.
4. The candidate is never a sample source.

Engine-level coupling (a ghost pushing a hero) is U.

## 6. Bounds and failures (bounds proposed, not measured)

**Bounds:**
- 20 Hz sampling (≥ 50 ms; about 5 frames at M6-F2b's ≈ 9.8 ms frame interval);
- at most one apply per frame;
- 120 s per session (300 s maximum);
- a box of ±8 m in x / y around P (−89.49, 14.83), which includes Agent 47's start, 5.75 m away; z not written;
- at most 1.0 m per step;
- native outbound queue 8 (drops the oldest); native inbound one superseding slot; the peer sender drops the oldest **sample** above 8 unsent and never blocks the source.

No synchronized wall clocks are assumed, and exactly-once application is not promised: samples are idempotent absolute poses, ordered by seq.

| Event | Destination behaviour |
|---|---|
| no new target for 250 ms (local clock) | **hold**; never extrapolate |
| 2 s | stalled: stop applying |
| 10 s, peer-link loss, or `pose.end` | close (native closes on its own timer even if BEAM is silent) |
| duplicate / older seq; origin = self | drop, count |
| `source_kind` or peer ≠ the armed session's | refuse, count; close |
| non-finite; outside the box; a non-acquisition step over 1.0 m | refuse, hold, count; close after 3 consecutive |
| predicate fall, generation or scene change | native closes on that frame |
| candidate unresolved, not distinct, in the registry, or dirty | refuse the frame; close after 10 consecutive |
| postimage ≠ request | uncertain; close after 3 consecutive (F1 counts all) |
| setter fault | the existing latch; effectful path off for the process |
| motion- or command-link loss; authority restart | native closes and holds; not persisted; after an authority restart, no inspection-bound open until a new journal (M6-F 12.5; inheritance P) |
| game restart | session invalid (new adapter id); the candidate is at P on a fresh launch (M6-E3, M6-G2), and after a mission restart I (shown only for pre-P content, M6-C3) |
| fingerprint mismatch between game peers | the handshake is refused |
| either operator cancels | local `close`; a peer `close` also closes the local destination |

**After a session the candidate stays where it was last applied.** A return to P is the approved `restore`; a mission exit also resets it.

## 7. Evidence, clocks, falsification

**Evidence layers, kept separate:**
- **requested** — the source sample;
- **received** — the destination BEAM's receipt;
- **applied** — the destination native frame and exact postimage;
- **later observations** — the existing read-only `relay.inspect.candidate_transform/1`;
- **visual** — testimony and recordings.

A per-node **motion trace** (`glacier-relay.motion-trace/1`, P) holds the samples and reports, each with its `source_kind`. It is separate from the journal (sessions only, with their source kind) and from mission recordings (unchanged).

**Clocks:** each native and each BEAM node has its own monotonic clock. They are not comparable — not between machines, and not even between native (Windows) and BEAM (the WSL2 VM) on one host (I).
- **Measurable:** per-domain intervals, the peer round-trip time on the sender's clock, loss / drop / stale counts, and inter-arrival jitter.
- **Not measurable:** one-way latency. It can only be estimated (segments + RTT / 2, labelled).

**World state is not synchronized.** NPCs, doors and items are simulated separately in each instance. Nothing attributes NPC behaviour to the ghost.

**Falsifiers** (thresholds P):
- **F1** the postimage ≠ the request on more than 1 % of applies;
- **F2** reads at +1 … +4 frames return toward the preimage — an x / y counterpart of the z return;
- **F3** no visible following, or flicker;
- **F4** a fault or crash, or the median frame interval worse by more than 20 %;
- **F5** the hero's stored transform dirty in more than 10 % of samples, or frozen while the operator moves. The refreshing getter would then be a separate change.
- **F6** (coupling) the local hero's sampled position changes while the operator reports no input and the ghost is within 2 m. No software path runs from the candidate to the hero; physical coupling is U.

F1–F4 and F6 need one game instance driven by a peer. F5 needs one game instance sampled.

## 8. Locomotion and geometric courses

The operator's interest in circles in both directions, concentric circles, squares and triangles is **future capability and test-course interest**, not unfinished M6 work and not an M7 prerequisite. Two distinct uses:
1. **Synthetic trajectories** of those shapes, generated by the headless peer with their parameters recorded and every sample labelled `synthetic`. They qualify the pipeline and drive the destination, and are never evidence of locomotion or of local-player sampling.
2. **A real course:** the operator walks Agent 47 around a shape inside the box, and that real motion is sampled. A ghost reproduces position only — it slides, with no gait, no turning in v1 and no collision.

Walking a path with gait, stopping and collision is separate locomotion work. The preferred route does not need it, and none is started.

## 9. Test resources, the headless peer, and the claims that need two real instances

**Resources (operator, 2026-10-19):**
- one established Windows HITMAN host (Steam);
- an Xbox copy — not a test resource here: no console adaptation;
- a MacBook — a candidate host for the headless peer only.

No second compatible Windows installation is assumed. Split-screen, simultaneous instances on one host, and hardware or licence purchases are **not prerequisites** of any stage below.

**The headless protocol peer (P).** One reusable BEAM application:
- `Peer.*` plus a driver, with no native adapter, no `Command.Authority`, no token and no destination applier;
- declares `client_kind: headless`;
- as a **source**, it emits only labelled synthetic courses;
- as a **sink**, it records what it receives in its motion trace and verifies sequence, bounds and freshness.

It runs first on the game host, as a second local node over loopback. Later, optionally, it runs on the MacBook across the LAN, with the game host connecting out (installation and the MacBook's inbound rule are each separately authorized). On the game host, its samples reach the candidate only inside a session the local operator armed for that peer and `source_kind: synthetic`.

| Claim | One game host + headless peer | Needs two real game instances |
|---|---|---|
| Protocol, lifecycle, failure table, bounds, labelling, both directions concurrently on one link | **yes** (offline, then live) | — |
| Real local-hero sampling (F5) and transport of real samples, locally then across the LAN | **yes** (real samples, a recording sink) | — |
| Destination application on the real engine: F1–F4, visual following of a labelled synthetic course, frame cost, coupling near the local hero | **yes** (synthetic input, labelled) | — |
| One instance's **real** player motion represented on **another real instance's** candidate | no | **yes** (deferred) |
| "Each instance renders the other player's externally driven Hitman" (the goal) | no | **yes** (deferred) |
| Bidirectional real-to-real representation surviving one bounded session (**the exit**) | no | **yes** (deferred) |
| Content / build fingerprint agreement and mission-generation pairing between two installations; one side's mission transition closing the other's real destination | no | **yes** (deferred) |
| Game-to-game latency and visual evidence, two operators' testimony, observed NPC / world divergence between instances | no | **yes** (deferred) |

A test with one game host and a headless peer is **never reported as equivalent** to two real clients, and it never satisfies the M7 exit. Its acceptance text names its `source_kind`, its peer kind and its single instance. The deferred claims wait until a second compatible Windows game installation and its operator are arranged; this design neither assumes nor requires one before then.

## 10. Stages

- **M7-B1 (offline, BEAM only):**
  - the `Motion.*` / `Peer.*` subtrees, off by default;
  - the control-plane entries;
  - the headless peer;
  - two local nodes over loopback with throwaway certificates;
  - fake native endpoints; the synthetic courses;
  - the failure table as tests, plus the boundary and invariance tests.
- **M7-B2 (offline, native):**
  - the sampler, the applier, the motion link and the probe's FAKE worlds;
  - a native6 build of record, not installed;
  - probe ⇄ host node ⇄ headless peer on one machine.
- **M7-C (attended, the one game host, a local headless peer; ONE run, two one-way phases):**
  - C1: share only (real samples out to the recording sink; no engine write);
  - C2: one armed synthetic session (a course at most 120 s) on the candidate, then close, restore, exit;
  - each phase is its own session and arming, with no idle destination session;
  - it tests F1–F6.
  - **C3** — both directions concurrently with one real end — only after the review of C1 / C2, under its own authorization.
- **M7-L (optional, attended or offline):** the same headless peer on the MacBook across the LAN — real transport, the round-trip time, loss and stalls. Its prerequisites (an Erlang / Elixir installation on the MacBook, its firewall rule, the LAN) are each separately authorized.
- **M7-D (deferred; the exit):** two real game instances, only once that resource is arranged:
  - A → B, then B → A — each its own session and arming, at most 120 s;
  - a review;
  - then one bidirectional session — two sessions, one per machine, concurrent.

## 11. Qualification and invalidation

**Reused unchanged:**
- the content set and its install / rollback / verify scripts and rehearsals;
- the evidence guard and the `readiness.py` reuse;
- the sealed M6 roots, native5 and the tags.

The headless peer is qualified once, and its results are reused while its code, `mix.lock` and runtime identities are unchanged.

**Invalidated by each change:**
- **M7-B1** (`relay/lib`, `relay/config`): the BEAM suites (5 × 618), every matrix group and readiness record keyed to those trees, and the pre-flight gates. v1 / v2 are re-proven by re-running the existing lift / step FAKE groups. The M6-G1 test-warning exception is **not** inherited. Native evidence is unaffected.
- **M7-B2** (`Src` → native6): native 25 / 25, the import / export comparison (no new import expected), the one-setter-site scan (must stay 1), the FAKE matrix, the installer's DLL identity and every record (a). Content is unaffected.
- **M7-L:** the MacBook's OS, OTP / Elixir and certificate identities are recorded at its checkpoint.
- **M7-D:** the second installation's identities are checked there, and none is inherited.

No full historical audit without a trigger (M6-F 14.6).

## 12. Next authorization and open questions

**Proposed (not granted): M7-B1, offline, BEAM only, including the local headless peer** (section 10), with ADR 0010 (proposed) as its boundary. It excludes native code, the game, any LAN socket, network / firewall / WSL configuration, the MacBook and a live token.

**Open:**
1. Is the MacBook on the same LAN as the game host (wired or wireless)? Would a later Erlang / Elixir installation and one inbound rule on it be acceptable, each separately authorized?
2. Is the exit interpretation (section 3) acceptable, and is the section 9 split of claims accepted as written?
3. Which course and shapes for C2, inside the box around P? Which real course for C1?
4. Can the operator record the game host's screen for C2 (Game Bar, as in M6-G2)?
5. How the two-instance test resource might later be arranged is outside this design, and not a prerequisite.

## 14. Operator review answers (2026-10-19; recorded after commit `4c01fb76`; sections 1–13 kept as written)

The operator's answers to section 12, verbatim:
- "Yes the Mac is on the same LAN as the PC. Elixir is already on the MacBook, as I have been developing a separate unrelated project on it."
- "Yes I accept it." (the exit interpretation of section 3 and the section 9 split of claims)
- "Figure eights around the planters would make a could synthetic course. Walking around the circular fountain would be a good idea. Making a square or rectangle around the planters would be decent as well.  Bidirectional walking back and forth between planters is another idea."
- "I can record the screen using the game bar again."

**What changes, and what does not:**
- **The MacBook.** M7-L's LAN prerequisite is now operator-reported, and Elixir is present (operator-reported). Its Elixir / OTP versions, its `ssl` support and its firewall were **not inspected**: no machine was contacted. They are recorded at M7-L's checkpoint, together with its one inbound rule, which still needs its own authorization. The MacBook's unrelated project is not touched. The headless peer runs as a separate application with its own directory, node name and port.
- **Acceptance.** The section 3 exit interpretation and the section 9 claims split are accepted by the operator as written. The M7 exit itself is unchanged, and the two-instance claims stay deferred.
- **Courses** (P; built from the planter centres of `M6E_VISUAL_PLACEMENT.md` section 11 — rows y 11.99359 / 17.67185, columns x −80.477 / −84.044 / −87.670 / −91.318; the extents of the planters are unmeasured; collision and physical coupling are unvalidated: this stage neither disables collision nor provides collision avoidance, and a path inside the coordinate box is not proven clear or safe, even when it looks plausible — corrected in section 15.1):

  | Course | Kind | Proposed geometry | In the ±8 m box |
  |---|---|---|---|
  | S1 figure-eight around two planters of the +y row | synthetic (C2), both senses | lobes centred on (−87.670, 17.672) and (−91.318, 17.672), radius 1.824 m, crossing at (−89.494, 17.672) | yes |
  | S2 rectangle around the four planters at P (a square variant around one planter) | synthetic (C2), both senses | x −92.82 … −86.17, y 10.49 … 19.17 (a 1.5 m margin), 30.65 m perimeter | yes |
  | S3 shuttle, back and forth between planter pairs | synthetic (C2); also walkable for real | the avenue centreline y 14.833, x −91.318 … −84.044 (7.27 m) | yes |
  | R1 around the circular fountain | **real** (C1 sampling; later M7-D) | the operator walks it; the fountain's position and radius are **not recorded** (U) | not known |
  | R2–R4 the operator walking S1–S3 | **real** | as walked | to be checked |

  Proposed synthetic speeds are 1.0–1.5 m/s, that is 0.05–0.075 m per 20 Hz sample, far inside the 1.0 m step bound; the game's own walking speed is U. The planter column at x −80.477 lies outside the box (box x ≤ −81.49), so no course uses it.
- **Effect on the box.** C1 sends real samples to a recording sink and writes nothing to the engine, so R1 needs no box. Any **destination** use of R1 (M7-D) needs the fountain's geometry first: the box is fitted to it, or the session refuses it. That geometry is to come from an offline read of the preserved Paris content in a later stage's preparation, not from screenshots.
- **Recording.** Game Bar is confirmed for C1 and C2; no frame synchronization is claimed (as in M6-G2).

**Unchanged:** nothing is authorized by these answers. M7-B1 remains the proposed next authorization.

## 15. Reviewed contract (M7-A review; normative for M7-B1)

**Status:** reviewed amendments recorded on 2026-10-19 under the authorization "Glacier Relay — M7-B1 offline implementation authorization" (with "M7-A review and M7-B1 bounded offline implementation"), **before** any M7 code. Sections 1–14 remain the proposal as reviewed; where they conflict with this section, this section governs. The original proposal did **not** contain the protections below; they are amendments. B1 makes them executable against fake native endpoints and owned loopback peers only. Native enforcement (B2) and every runtime claim remain unvalidated.

**Review basis:** the design at `4c01fb76` (sections 1–13) and `2a66d0e3` (section 14), and ADR 0010 as proposed; the design seal `m7a-design\` manifest `cc73bfb4b515f0d9986c9e4c1afa684a6c813dc2a276a1aeb97fbdcc2e615c87`. The M7-A verifier inspected a pre-amendment draft that was **not retained**. Its line references cannot be re-resolved, and its report is not independently repeatable; it stays as historical evidence with that qualification.

### 15.1 Corrections to earlier text

- **epmd (section 1; HANDOFF).** Retracted: "harmless under the default WSL2 NAT mode" and "a later networking change would expose epmd". Observed: `epmd -daemon` (pid 45286, started 2026-10-12, this user's OTP 28.4.2) listens on `0.0.0.0:4369` and `[::]:4369`. The project's tooling starts `--sname` nodes, which makes it the likely starter; that is not proven. Which interfaces can reach it, and the firewall state, were not established. epmd and distribution are separate listeners. B1 uses no named node. The daemon is reported, not stopped or rebound.
- **Collision (section 14; also section 8's "no collision").** Read as: collision and physical coupling are unvalidated. This stage neither disables collision nor provides collision avoidance. A path inside the coordinate box is not proven clear or safe, even when it looks plausible.
- **Acquisition exemption (section 4.2).** Removed. No target, first or after a pause, bypasses the displacement bound (15.3).
- **"Close after 3 consecutive" (section 6).** Replaced. The first uncertain post-call result, or the first critical identity, generation, parent, registry or control failure, ends application.
- **Evidence claims (sections 6–7, 10).** A 250 ms report is not a trace of every apply. A 20 Hz stream says nothing about engine frames +1 … +4. F2 is **unmeasured** unless B2 adds the bounded instrument named in 15.8. RTT / 2 is never reported as a one-way latency. "It tests F1–F6" in M7-C is withdrawn.
- **"Never dropped" control messages (section 4.3).** Replaced by bounded control capacity (15.6).

### 15.2 Identities and bindings

| Identity | Scope | Use |
|---|---|---|
| Peer | the pinned leaf certificate (SHA-256 of its DER) and the configured label and client kind (`game` / `headless`) | authentication; the declared client kind must equal the configured one |
| Boot | a random UUID per BEAM boot, in `hello` | rejects data from a previous boot |
| Connection generation | a local counter per peer connection | a session is bound to one |
| Stream | a UUID per source attempt (`stream.open`), with `source_kind` | a session is bound to one stream, so a restarted source opens a new stream, which the session refuses |
| Share, session | local UUIDs | journaled, never authority on the wire |
| Adapter, command link generation, motion link generation | local only | never sent to a peer |
| Mission generation | each machine's own | a local precondition only, never compared across machines |

A headless peer may declare only `source_kind: synthetic`; a headless peer declaring `game` is a protocol violation that closes the connection. `source_kind` is authenticated-peer **provenance**, not proof that a game produced truthful values. A sink never forwards or relabels what it receives: there is no API path from a sink to a source.

**Mapping:** identity only (source world x / y = destination target x / y). With absolute identity mapping, two real players starting at the same place would put the ghost on the receiving local hero. Before any real-to-real runtime (M7-D), non-overlapping starts or an explicitly armed fixed mapping must be chosen; there is no implicit dynamic recentering. B1 refuses any mapping other than `identity`.

### 15.3 Destination application (BEAM rules; the native rules are 15.5)

The **local approval** fixes all of the following before application is possible:
- the peer (pin, label, kind), boot, connection generation and stream, with `source_kind`;
- the scope (the compiled candidate) and the mapping;
- the starting evidence: one fresh exact inspection, through `TransformBinding.qualify/2`;
- the limits below and the expiry.

No peer message can open, extend or widen any of it. A session that does not exist ignores every sample.

| Limit | Default | Compiled bound | Boundary |
|---|---|---|---|
| Area: the anchor (the opening snapshot's x / y) ± `half_extent_m` | 8.0 | 0.1 … 8.0 | inclusive; a sample outside it closes the session (`outside_area`) |
| Forward rate: at most one `ghost.target` per `min_forward_interval_ms` (receiver BEAM clock) | 50 | 50 … 1,000 | one target in flight: the next is sent only after the previous one's `ghost.applied` |
| Displacement from the **reference** | `max_speed_mps` × min(Δr, `credit_ms`) / 1,000 | speed 0.1 … 3.0 (default 2.0); credit 50 … 200 (default 100) | ≤ passes. Δr is the receiver-clock time since the reference was sent. The credit cap means a pause never earns more than `credit_ms` of movement (0.2 m at the defaults). A refused target is withheld (`refused_displacement`) and never clamped. |
| Stall: no target forwarded for `stall_ms` | 250 | 100 … 1,000 | ≥ closes (`stall`) |
| Lag growth (15.6) | 100 | 20 … 250 | > closes (`late`) |
| Duration | 120,000 | 1,000 … 300,000 | BEAM closes at the end; the native closes on its own clock |
| Acknowledgement of the target in flight | 200 | fixed | a timeout is **uncertain**, which closes |

**Reference:** the last target that `ghost.applied` confirmed applied, with its exact postimage; before that, the opening snapshot. Acquisition is the first target against the opening snapshot, under the same displacement rule, with no exemption. An old or delayed target inside the box does not acquire anything. Received, validated, superseded, forwarded and confirmed sequence numbers are kept distinct. Supersession in the pending slot never advances the reference.

**Sequence:**
- a duplicate or older sequence number is refused and counted, and is never re-applied;
- a target is never re-sent because it is still available;
- a source-clock value that does not increase closes the session (`protocol`);
- a sample with `qualified: false` (dirty or unqualified at the source) is withheld (`unqualified`), and a receiver never promotes it.

**Ends application (BEAM side):**
- `ghost.applied` reporting `uncertain`, a postimage that differs from the request, any native refusal, or an acknowledgement timeout;
- a report whose counts disagree with the acknowledgements received before it, or a report-sequence gap;
- loss of the trace or the audit trail;
- `stream.end` or peer-link loss;
- the operator.

There is **no resumption**. A declared stall or loss of stream context ends the session; a new session needs new local approval and new arming. No automatic recovery or re-arming happens in the first attended experiment.

### 15.4 Lifecycle and close

**Order:**
1. peer connection (TLS, then `hello`);
2. for the source: local inert arming and a `player.pose.share/1` `open`, whose operator statement fixes the peer, the stream, the duration (≤ 300 s) and the interval (≥ 50 ms). For the destination:
   1. a fresh exact inspection;
   2. effectful arming (the existing one-shot arming, with its telemetry attestation and ownership evidence);
   3. `Motion` approval (15.3);
   4. `candidate.motion.session/1` `open`;
3. native confirmation (the result's opening snapshot equals the inspection's words);
4. application;
5. close;
6. optionally, a separately approved `restore`.

The command entries carry **`open` and `restore` only**.

**Close** is never a command, so the command link's one-in-flight rule cannot block it. It is a `ghost.close` on the bound motion link. If that line cannot be written within its send deadline, the motion link is dropped, and the native closes on link loss. Close needs no arming. It works with no sample flowing, with a command in flight, with full buffers and with a degraded audit (a failed journal entry is recorded as a gap and never forces continued application). It is journaled when known, with one of four states:
- `requested`: BEAM has stopped sending targets;
- `transmitted`: the line was written;
- `confirmed`: `ghost.closed` was received;
- `unknown`: no confirmation within 1,000 ms, or the link was lost first. BEAM then drops the motion link, and the native's own timers are the remaining, unconfirmed stop.

A peer ends only its own bound stream. A `stream.end` naming another stream or boot is refused and counted.

**Hold and closed** mean that Relay stops invoking the setter. They do not mean the engine keeps the entity motionless, and absolute targets do not prove that the engine call is idempotent.

**Mutual exclusion** (authority; mirrored natively in B2):
- `candidate.transform.set` v1 / v2 — forward **and** restore — is refused while a motion session exists that is not restored, or while a motion `open` / `restore` is in flight;
- a motion `open` is refused while any command is in flight, or while an M6 forward has consumed its budget without a confirmed restoration;
- the read-only `relay.inspect.candidate_transform/1` stays issuable.

**Budget:** at most `max_sessions` destination sessions per authority process (default **1**). A new session is refused while an earlier one is not restored, so a session never replaces another's retained preimage. The M6 one-forward budget is unchanged, and nothing resets either budget. An authority restart ends the attended run's commands (M6-F 12.5).

**Restore** (`candidate.motion.session/1` `restore`) is issuable only when all of these hold:
- the session closed `confirmed` and clean (native-reported, with no uncertain outcome);
- the session's journaled opening preimage is retained;
- a fresh exact inspection, later than the close, finds the candidate's words equal to the native-confirmed final words, on the session's adapter, the current token-verified link and the same mission generation;
- new effectful arming is held.

If the inspection finds the words already equal to the preimage, the result is `already_at_baseline`, and nothing is submitted. An `unknown` close, lost history, a different adapter or a mismatching inspection is ineligible. There is no automatic inverse and one restore per session.

### 15.5 The local data link (`127.0.0.1:4750`) and the native rules (B2 contract, modelled in B1)

**Binding:**
- The native connects and sends `motion.hello {adapter_instance_id, command_link_generation}`. It is accepted only if it equals the **current, token-verified** command link.
- BEAM answers with `motion.welcome {motion_link_generation, nonce}`.
- The native returns, within 2 s, `motion.attest` = HMAC-SHA256(run token, `motion|nonce|motion_link_generation|command_link_generation|adapter_instance_id`), verified inside `TokenHolder`. The run token never leaves the host.
- The binding lives only as long as that command link, that motion link and that authority process. A command-link loss drops the motion link.
- A share or session names its motion link generation, and every data line names its share or session. Loopback access, or a UUID alone, binds nothing.

**Native rules** (one pending slot; at most one apply per frame, and at least `min_apply_interval_ms` = 40 apart on the native clock):
- Before each call, on that frame:
  - the session is open;
  - the mission is playing;
  - the generation, the scene and both link generations are as at open;
  - the latch is clear;
  - the candidate is resolved, distinct and not in the registry, and its cache is clean;
  - its parent is unchanged;
  - **every word except Trans.x / Trans.y equals the opening snapshot's**: an unexplained change is refused, never forced back, and closes the session;
  - the sequence number is greater than the last applied one;
  - the target is finite and in the area;
  - its distance from the last applied postimage (or the opening snapshot) is at most `max_speed` × `credit`.
- A target whose x / y words equal the last applied ones is `skipped_identical`: no call.
- A pre-call failure means **no invocation**.
- After the call, a postimage that differs from the request, or a read-back that is unavailable, is **uncertain**: never reported as unapplied, and it closes the session (a fault sets the existing latch).
- `ghost.applied` is sent for every target; `ghost.report` every 250 ms, with a report sequence number.
- **Autonomous closes**, with no BEAM needed:
  - duration;
  - target silence of `silence_close_ms` (default 1,000);
  - motion- or command-link loss;
  - a generation or scene change;
  - a predicate fall;
  - any refusal or uncertainty.
- `ghost.closed` carries its reason, `clean`, the final words and the counts.

The B1 fake models these timers in a separate process, so they keep running while BEAM's motion process is suspended. That shows the BEAM contract, **not** that the DLL enforces any of it.

### 15.6 Freshness and bounded transport

**What is established:**
- order and the refusal of duplicates within one stream;
- receipt silence on the receiver's clock;
- the **growth** of one-way delay relative to the epoch's least-delayed validated sample. It is computed as the receiver interval minus the source interval, each subtraction within one clock domain, and its error is the two clocks' rate difference (an assumption, labelled).

**Not established:**
- absolute delay or sample age;
- a constant delay present from the first sample;
- the source clock's truthfulness.

**Bounds:**

| Part | Bound |
|---|---|
| Frames | lines of at most 1,024 bytes on the peer link and the motion link, with at most 1,024 buffered partial bytes |
| Parsing | strict: an unknown kind or field is a violation and closes the connection |
| Receive | one read at a time (`active: :once`); each sample is handed to the destination by a call with a 200 ms deadline |
| Peer sender | samples: at most 8 queued and one per 45 ms per stream, the oldest dropped and counted; control: at most 16 queued, and an overflow closes the connection, so stop stays possible |
| Send deadlines | 500 ms (peer) and 200 ms (motion link), closing on timeout. Measured: OTP 28 `ssl` with `send_timeout` returned `{:error, :timeout}` after about 209 KB had been buffered (`m7b1-offline\tls-probe\`) |
| Liveness | `ping` each second; three seconds without input closes the connection. RTT is recorded on the sender's clock only |

Delayed traffic can sit in kernel, TLS and application buffers well beyond the visible queues (209 KB is roughly 70 s of samples). It never plays out as a catch-up trajectory, for three reasons:
- a stall closes the session first;
- lag growth closes it;
- forward pacing and the displacement bound limit any burst.

### 15.7 Peer authentication and network isolation

**TLS:**
- **TLS 1.3 only, mutual.** Each side has a per-experiment private CA (ECDSA P-256, SHA-256) and a leaf certificate. Each side trusts exactly the other side's CA, `fail_if_no_peer_cert` is set, and the other side's **leaf SHA-256 is pinned**.
- The verification callback only narrows: it accepts `valid_peer` on an exact pin and never overrides a `bad_cert`. The pin is checked again after the handshake.
- There is no trust on first use, no session resumption and no early data. The hostname check is off, because the pin is the identity.
- OTP 28 refuses a self-signed leaf even when that leaf is in `cacerts` (`selfsigned_peer`; `tls-probe\t1`). That is why the CA-and-leaf form is used, rather than an accepting callback.

**One allowlisted peer and one connection.** A second connection is refused.

**Refused:** a missing or wrong certificate, a wrong pin, TLS 1.2, a malformed handshake, a `hello` whose identity or kind differs from the configuration, and an oversized or malformed line.

**Credentials** are throwaway and live in test-owned temporary directories. Private keys never enter a report.

**Isolation:**
- No Erlang distribution between peers. B1's test peers are **non-distributed** (`nonode@nohost`); the second BEAM process is controlled over its standard input and output.
- 4747 / 4748 / 4749 keep their loopback configuration; 4749's refusal of a non-loopback bind is preserved. 4750 and 4760 refuse any non-loopback bind at start in B1, including `0.0.0.0` and `::`.
- No LAN exposure, no firewall, WSL or Mac change, and nothing is done to the shared epmd. Any later stage that uses a named node restricts epmd and distribution itself (both, IPv6 included) and verifies the sockets. A new environment setting does not rebind a daemon that is already running.

### 15.8 Evidence

**Trace.** A per-node `glacier-relay.motion-trace/1`, separate from the journal and from recordings:
- **Bounds:** 200,000 records or 32 MiB; a datasync every 100 ms and at close.
- **Markers:** a footer `trace.closed`; `trace.truncated` at the bound, after which the health is `full`; an I/O error makes it `failed`.
- **Required for a destination session or a share:** health other than `ok` stops further effects and closes, without blocking stop.
- **Incompleteness:** a trace without its footer may lack the records since the last sync.
- **Clock domains:** every record carries the writer's clock. Foreign-domain values are labelled (`src_mono_ms`, `native_mono_ms`) and never subtracted across domains.

**Accounting** for each destination session:
- received, by verdict;
- superseded, forwarded, and acknowledgements by outcome;
- uncertain;
- report gaps;
- the close reason and state;
- sequence reconciliation against the source's `stream.end` `last_seq`.

**Verdicts:**
- **F1:** every applied target's postimage on its own frame (`ghost.applied`). The first mismatch ends the session, so there is no percentage threshold.
- **F2:** unmeasured. The smallest instrument is a B2 native read of the candidate's words on the next ≤ 4 frames after each apply, during sessions only.
- **F3:** testimony and recording only.
- **F4:** native and runtime.
- **F5:** the unqualified fraction, from the trace.
- **F6:** a sampled-hero change with a stationary operator report is a finding, not proof of pushing.

Software no-feedback means no re-forwarding and never the candidate as a source. It does not exclude engine coupling.

### 15.9 Courses

**One deterministic generator** (`Motion.Course`), with no pathfinding:
- **Segments:** `hold`, `line` and `arc`.
- **Profiles:** out-and-back, shuttle, rectangle (or square), figure-eight (tangent lobes, opposite senses, a smooth crossing) and circle.
- **Parameters recorded:** origin, scale, orientation, direction, speed policy (constant speed per segment), sample interval and seed-free timing (sample *k* is the path position at *k* × interval).
- **Bounds:** every profile **starts with a stationary sample at the anchor P**. It reaches its start by an explicit `line` and returns by one. Transitions and closing segments are inside the area, rate and displacement checks.
- **Sources and labels:** courses are offline fixtures (section 14's geometry) and are never real-player samples or a locomotion demonstration. The 1.0–1.5 m/s preference stays a proposal under the enforced limits.

**First destination course (a recommendation, not permission):** a short, slow out-and-back from P along the avenue centreline (y 14.833). It goes 1.0 m out at 0.5 m/s, with holds, in a corridor reviewed for that run. The full shuttle, the rectangle and the figure-eight stay options for separately approved runs, after their real geometry and exposure have been reviewed.

**Fountain walk:** source-only. It needs no destination box, but it does need bounded duration, rate and output, and a share approval. Its geometry is deferred until a destination course needs it. A captured walk is not proof that the path is safe to assign to another character.

**Future onboarding** (a requirement only, not a deliverable now): a participant with a second game installation would need, at the least:
- a reproducible installation check against the content fingerprint;
- generation of per-experiment credentials and an exchange of pins;
- a one-command peer start that opens nothing but the agreed port;
- the same evidence guard.

There is no installer, GUI, embedded runtime or updater in B1.

### 15.10 Remaining untested (unchanged by B1)

- native sampling of a moving hero, and its dirty fraction;
- native enforcement of 15.5;
- repeated setter writes, x writes and frame cost;
- collision and coupling;
- every TLS path other than loopback;
- MacBook compatibility (OTP, `ssl`, firewall);
- any LAN or two-game behaviour.

M7-C, L and D each need their own authorization and fresh readiness.

## 13. Sources

| Claim area | Source (blobs in `source-facts.txt`) |
|---|---|
| Frame order, one command per frame | `Mods/GlacierRelay/Src/GlacierRelay.cpp` (`ObserveFrame`, `ScheduleCommand`) |
| Links, queues, limits | `CommandLink.h`, `CommandQueue.h`, `CommandProtocol.h`, `TcpRelaySink.h`; `relay/config/config.exs`; `command/listener.ex` |
| Hero and candidate snapshots, ledger, setter site | `TransformObservation.h`, `TransformApply.h`, `ITransformApplier.h`, `TransformApplier.cpp` |
| No position telemetry | `TelemetryNormalizer.cpp` |
| Authority, arming, journal, token | `command/authority.ex`, `journal.ex`, `token_holder.ex`, `supervisor.ex` |
| Observer path, recordings | `mission_session.ex`, `session/fold.ex`, `recording/recorder.ex`; ADR 0008 |
| Boundaries | ADR 0002, 0005, 0009; `docs/ARCHITECTURE.md` (continuous vs semantic state) |
| Runtime outcomes | `M6F_TRANSFORM_CONTROL.md` 16.3–16.4; `M6G_VISIBLE_CONTROL.md` 9.4–9.7, 10.3–10.5; `M6_SECOND_HITMAN.md` 2.5–2.9, 6, 11, 20 |
| Prior art (not runtime proof) | `Mods/Hitmen/Src/Hitmen.cpp`; `HITMEN_GNS_CONTRACT.md`; `HITMEN_ENTITY_IDENTITY.md` |
| Reuse mechanism | `tools/content-deployment/readiness.py`; `M6F_TRANSFORM_CONTROL.md` 14.4–14.6, 15.4 |

# M1 Design — First Semantic Event

Date: 2026-10-06. Status: **proposal, awaiting decisions** (listed at the end). No code described here exists yet. A real transport is a standing-constraint reversal and is not started without explicit approval.

Inputs: `ARCHITECTURE.md`, ADR 0001 to 0004, `protocol/README.md`, and the runtime evidence in `research/HITMEN_COMPILE_ARCHAEOLOGY.md` experiment 4. Reviewer guidance (2026-10-06): one event, one direction, predicate separate from edge, no dependence on graceful shutdown, no reliance on the player registry, and examine `IHitmenTransport` before building on it.

## 1. Is `IHitmenTransport` a transport-neutral boundary?

No. It is a GNS-shaped compatibility seam, and it should stay one.

`Mods/Hitmen/Src/HitmenTransport.h` (S1, `04329728`) was written so that the 2023 message code could keep compiling after GameNetworkingSockets was removed. Every method is a renamed GNS call, and each one carries an assumption Glacier Relay has already rejected:

| Method | Assumption carried over from GNS | Relay position |
|---|---|---|
| `StartServer(port)` | The game process hosts a listening socket | The game never listens. Networking authority is BEAM's (ADR 0002). |
| `Connect(addr, port)` + `PollConnected()` → `HitmenConnection` | Symmetric peers, connection handles, one client | Native is an outbound client of one service. |
| `SendUnreliable(conn, bytes, size)` | Unreliable datagrams of opaque bytes | Semantic events need ordering and typed, versioned content (ADR 0003). |
| `ReceiveMessages()` → `vector<HitmenMessage{bytes}>` | Polled inbound opaque bytes, dispatched by a wire enum | No inbound in M1; later commands must be typed and validated, never raw bytes into engine memory. |
| `HitmenMessage` | A buffer the 2023 code memcpy'd into engine objects | Explicitly out. |

The seam's value is archaeological: it documents what the 2023 transport did, and it keeps the compiled-out `#if 0` code attached to its original contract. Repurposing it would let the old protocol's shape leak into the new architecture through the interface, which is exactly how a temporary seam becomes permanent.

**Decision proposed:** `IHitmenTransport` and `NullHitmenTransport` stay as they are, frozen with the historical Hitmen code. Glacier Relay gets its own boundary, designed from the relay side.

## 2. Layering

```
Glacier (engine memory, hooks, SDK types)
        |
        |  reads only; SDK types stop here
        v
Observation            ObserveSceneState: scene resource, scene type, loading stage, loaded flag
        |
        |  plain values (strings, ints, bools)
        v
Semantic layer         MissionObserver: holds the MissionPlaying predicate, detects false -> true
        |
        |  RelayEvent (engine-independent struct)
        v
RelayAdapter           assigns adapter_instance_id, sequence, timestamp; builds Envelope; serializes
        |
        |  serialized Envelope (bytes + type tag), nothing else
        v
IRelaySink             Publish(serialized envelope)
        |             implementations: LogRelaySink (durable log), TcpRelaySink (loopback client)
        v
wire  ──────────────────────────────────────────────►  BEAM: Listener -> Decoder -> Validator -> MissionSession
```

Rule established by this first event: **nothing below `IRelaySink` ever sees a pointer, an SDK struct, an offset or a raw memory image**, and nothing above the observation layer ever includes an SDK header. The compiler enforces the second half if the semantic layer, adapter and sink live in files that do not include `Glacier/*.h`.

## 3. The event

### Predicate (state), not emission

```
MissionPlaying := scene_type == "mission"
               && loading_stage == 8          (ESceneLoadingStage::eLoading_ScenePlaying)
               && scene_loaded == true
```

All three inputs are read directly from engine state each frame, the way the probe already does (`ZEntitySceneContext::m_SceneInitParameters.m_Type`, `m_LoadingStage`, `ZApplicationEngineWin32::m_bSceneLoaded`). **No hook is involved**, so the predicate is unaffected by the finding that a mission restart never calls `LoadScene`. The hooks stay registered for logging only.

Why these inputs and not others:

- `scene_type` distinguishes a mission from the main menu, where a local player also exists (experiment 4, F5). It was `"mission"` for Paris and empty for the menu.
- Stage 8 plus the loaded flag is the point at which the probe observed the local player resolving on the same frame, on every mission load and restart (F6).
- The player registry is not an input. Its SDK model is wrong on this build (F1) and the event does not need it.

### Edge

Emit exactly one `mission.playing` event when the predicate changes from false to true. Nothing is emitted while it stays true, and nothing is emitted on false (a `mission.ended` event is a later addition, not M1).

Observed consequences on the experiment-4 timeline: one event at the Paris load (stage 7 → 8), one at the restart (stage 7 → 8 again, because the predicate dropped to false at stage 0), none at the menu. That matches what a MissionSession would want.

### Name

`mission.playing`, not `mission.started`: it names what was observed (the engine reports the scene as playing), without claiming to know the engine's definition of a mission start. `ARCHITECTURE.md`'s illustrative `mission.started` should be read as superseded by this for M1.

### Payload (schema version 1)

```json
{
  "scene_resource": "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity",
  "scene_type": "mission",
  "codename_hint": "Peacock",
  "game_session_id": "2516109819408417528-6f46ac15-6033-4821-9d65-5ed7659392bb"
}
```

`game_session_id` is **observation, not identity**: it is copied from player slot 0 when available and omitted when not, and no correctness, deduplication or keying on the BEAM side depends on it. It is the one registry read in the event path; it is optional and read through the inline slot (whose layout held in experiment 4), never through the mis-modelled array.

## 4. Envelope (protocol version 1)

```json
{
  "protocol_version": 1,
  "adapter_instance_id": "c2f9b0d0-3f0c-4a9a-9d2b-5c1e0f6a7b11",
  "sequence": 1,
  "timestamp": "2026-10-06T20:34:34.787Z",
  "event_type": "mission.playing",
  "schema_version": 1,
  "payload": { ... }
}
```

- `adapter_instance_id`: a GUID generated once per adapter instance (per game process). It is the source identity from `protocol/README.md`.
- `sequence`: starts at 1, increments per published envelope, never reused within an instance. Gaps tell BEAM something was dropped; a new instance id tells it the game restarted.
- `timestamp`: UTC, from the adapter's clock at observation time.
- `event_type` and `schema_version` version the payload independently of the envelope.

## 5. Delivery semantics

Experiment 4 showed the game ends by terminating its own process: no destructor, no DLL detach (F9). The design therefore makes **no correctness claim that depends on shutdown**.

- Ordered, best-effort delivery during the process lifetime.
- Each event is published as soon as it is observed; nothing is batched for later.
- If the sink is not connected, the event is logged and dropped. The sequence number still advances, so the gap is visible on reconnect.
- There is no final `disconnect` event. BEAM treats the native peer as ephemeral: a closed socket, a silent peer, or a new `adapter_instance_id` are all ordinary conditions.
- Liveness (heartbeat and BEAM-side timeout) is deferred; M1 has one event and a socket close is enough signal.
- Stronger semantics (acknowledged, replayable events) are a later layer, chosen when a use case needs them, per ADR 0003's "separate reliability policy" requirement.

## 6. Wire

`protocol/README.md` defers the choice to M1. Proposal for M1, with the envelope's version fields making it replaceable:

| Option | Assessment |
|---|---|
| **TCP to loopback, newline-delimited JSON (one envelope per line)** | Simplest on both sides. Elixir: `:gen_tcp` or Thousand Island, `Jason`. Native: Winsock, no third-party dependency. Inspectable with any TCP tool. Ordering comes from the stream. **Recommended for M1.** |
| WebSocket | The SDK tree has uWebSockets, but as a server (Editor mod); native would need a client implementation. No benefit for one outbound stream. |
| UDP | Unordered, lossy; wrong for semantic events (ADR 0003 separates these). |
| Named pipe | Windows-only, awkward from Elixir. |
| Binary encodings (MessagePack, protobuf, ETF) | Premature with one event; nothing to measure yet. Revisit when continuous state is added. |

Native side constraints:

- Outbound connect only, to `127.0.0.1:<port>` by default (port configurable through the mod's settings file). The game process never listens.
- The socket never touches the game thread: a bounded queue is filled on the frame thread and drained by one adapter-owned sender thread with non-blocking I/O and reconnect with backoff. Queue overflow drops the oldest event and logs it.
- Nothing is read from the socket in M1 beyond detecting close. No command path exists.

## 7. BEAM side (minimum)

A new Elixir/OTP application, in a `relay/` directory of this repository unless decided otherwise:

```
GlacierRelay.Application
  GlacierRelay.Wire.Listener      TCP acceptor on the configured port, one process per connection
  GlacierRelay.Wire.Decoder       line -> JSON -> Envelope struct; rejects unknown protocol_version
  GlacierRelay.Wire.Validator     per event_type/schema_version payload validation
  GlacierRelay.MissionSession     GenServer: receives validated events, keeps {adapter_instance_id, last_sequence, playing?, last_event}
```

M1 success is visible as a log line and as `GlacierRelay.MissionSession.state/0` in IEx showing the Paris event with its sequence number.

Not in M1: Phoenix, LiveView, persistence, more than one event type, commands, authentication.

Environment note: neither Elixir nor Erlang is currently installed on this machine (checked WSL and Windows on 2026-10-06). BEAM can run in WSL2 (Windows reaches WSL2 listeners via localhost forwarding by default) or natively on Windows. This is a setup decision.

## 8. Where the native code lives

Two options:

| Option | Pros | Cons |
|---|---|---|
| **A. New mod `Mods/GlacierRelay`** (recommended) | Clean start on Glacier Relay's architecture; Hitmen stays frozen as the archaeology vehicle; the relay DLL contains no `#if 0` 2023 code, no transport seam, no second-Hitman scan; its inertness gate is trivial to state | Copies the few validated reads (`ObserveSceneState`, the durable logger) out of Hitmen; two DLLs during the transition |
| B. Add the relay layers inside `Mods/Hitmen` | No duplication; one DLL | The relay's first real component is born inside a mod named after a dead multiplayer experiment, next to its compiled-out protocol; "Hitmen is the only variable" stops being true the moment it networks |

Option A follows the reviewer's framing: the old mod got us through the wall and does not need to define what is built on the other side. Under A, Hitmen's branch stays as it is (research record), and `GlacierRelay` is built on a new branch from the same baseline, reusing `HitmenLog` (renamed) and the scene reads verbatim.

## 9. Staging and the M1 gate

Two stages, each a separate approved runtime experiment:

**Stage 1 — semantic layer with `LogRelaySink`.** Everything in sections 2 to 4 exists; the sink writes each serialized envelope to the durable log. No socket, no new imports, same inertness gate as the probe. Run: menu → Paris → restart → second mission → quit. Pass: exactly one envelope per mission entry, sequences 1, 2, 3, none at the menu, no faults.

**Stage 2 — `TcpRelaySink` and the BEAM listener.** Same run with BEAM up, then once with BEAM down and restarted mid-session to see the drop-and-reconnect behavior. Pass (M1 exit): BEAM receives and validates every envelope that was published while connected, in order; `MissionSession` reflects them; the game is stable; the only new network activity from the game is the loopback connect.

Multi-mission validation is part of the Stage 2 gate rather than a prerequisite for building, as the reviewer suggested.

## 10. Explicitly out of scope for M1

Commands, player transform streaming, registry serialization, generic RPC, authentication, persistence, LiveView, heartbeats, binary encodings, any second-Hitman or multiplayer work, any SDK-core change (the registry defect stays documented, not fixed).

## 11. Decisions needed

1. **Boundary:** freeze `IHitmenTransport` as historical and introduce `IRelaySink` as proposed (section 1 to 2)?
2. **Event:** `mission.playing` with the predicate, edge and payload in section 3?
3. **Wire:** TCP loopback with newline-delimited JSON for M1 (section 6)?
4. **Code location:** new `Mods/GlacierRelay` (option A) or inside Hitmen (option B)?
5. **BEAM environment:** Elixir in WSL2 or on Windows, and `relay/` in this repository?
6. **Staging:** approve building Stage 1 now (no network), with Stage 2 as a separate authorization?

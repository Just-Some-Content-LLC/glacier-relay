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

---

## 12. Stage 1 implementation record (2026-10-06)

Decisions 1 to 6 were approved as written, with two refinements: Stage 2's wire is an approved *direction*, not yet an implementation; and BEAM will run in WSL2, with Windows-native → WSL2 loopback connectivity to be verified explicitly in Stage 2, not assumed.

**Built, not deployed.** `GlacierRelay.dll` has never been loaded by the game. The Stage 1 runtime experiment needs its own authorization.

### Branch and commits

`Just-Some-Content-LLC/ZHMModSDK` branch `relay/m1`, created from the M0 baseline `5cc7f1b1` (not from the Hitmen branch; Hitmen stays commented out of the build and untouched). Head `0640cc89`.

| Commit | Change |
|---|---|
| `0ab5a0c5` R1 | `Mods/GlacierRelay` skeleton, wired into `MODS`; `RelayLog` (durable log derived from the probe's, fmt + Win32 only) |
| `d6656164` R2 | `SceneState` (plain values); `SceneObservation` (the Glacier-facing reads); per-frame observation with change logging |
| `39a015a7` R3 | `MissionObserver` (predicate + edge), `RelayEvent.h`; `GlacierRelayTests` target without the SDK |
| `46803c99` R4 | `RelayEnvelope` + JSON quoting, `IRelaySink`, `LogRelaySink`, `RelayAdapter`; tests |
| `0640cc89` R5 | Plugin publishes `mission.playing` from the frame update |

### Architecture as built

```
Mods/GlacierRelay/Src
  Glacier-facing (include SDK headers):      GlacierRelay.cpp/.h, SceneObservation.cpp/.h
  Engine-independent (no SDK header):        SceneState.h, MissionObserver.cpp/.h, RelayEvent.h,
                                             RelayEnvelope.cpp/.h, Json.cpp/.h, IRelaySink.h,
                                             LogRelaySink.cpp/.h, RelayAdapter.cpp/.h, RelayLog.cpp/.h
Mods/GlacierRelay/Tests                      MissionObserverTests.cpp, RelayAdapterTests.cpp
```

The split is enforced, not just documented: `GlacierRelayTests` compiles every engine-independent file with only `Mods/GlacierRelay/Src` and the vcpkg include directory on its path and links fmt only, so an SDK include in any of them fails the build.

Per frame: `SceneObservation::ObserveScene()` → `SceneState` → `MissionObserver::Update()` → optional `MissionPlayingEvent` → `RelayAdapter::Publish()` → `PublishedEnvelope` → `LogRelaySink::Publish()` → durable log. Everything runs on the frame thread inside the probe's log-only fault guard. No hooks are registered at all.

### Event, predicate, edge, envelope

- `MissionObserver::IsMissionPlaying(scene)` = `available && scene_type == "mission" && loading_stage == 8 && scene_loaded`. Inputs are read from the scene context and application engine each frame (`m_SceneInitParameters.m_Type`, `m_LoadingStage`, `m_pScene`, `m_bSceneLoaded`); no hook, so restarts are covered.
- `Update()` returns an event only on false → true. Unobservable state counts as false.
- `MissionPlayingEvent { scene_resource, scene_type, codename_hint, optional game_session_id }`. The session id is read from inline player slot 0 on the edge frame only, never through the SDK's array model, and nothing keys on it.
- Envelope v1 as in section 4; payload schema version 1. Produced text, from the standalone replay:

```json
{"protocol_version":1,"adapter_instance_id":"430c0943-ba88-4795-aa88-e9f09c4ae47c","sequence":1,"timestamp":"2026-10-06T21:44:35.419Z","event_type":"mission.playing","schema_version":1,"payload":{"scene_resource":"assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity","scene_type":"mission","codename_hint":"Peacock","game_session_id":"2516109819408417528-6f46ac15-6033-4821-9d65-5ed7659392bb"}}
```

### `IRelaySink` contract

`void Publish(const PublishedEnvelope&)`, called on the frame thread, must not block. `PublishedEnvelope` is `{ event_type, sequence, json }`, owned strings and an integer; the JSON is one object without a trailing newline. The header states that the interface must not grow toward `IHitmenTransport` (no listen, no connection handles, no inbound bytes). `LogRelaySink` writes `published <type> #<seq>: <json>` to the durable log and does nothing else.

### Tests performed

1. `GlacierRelayTests` (unit, SDK-free): predicate cases; edge detection replaying experiment 4's sequence (boot, menu, Paris, restart without `LoadScene`, return to menu) with exactly one event per mission entry and none for the menu; event without session id; observability loss and regain; JSON quoting; payload with and without session id; exact envelope text; sequence numbering; sink receives owned values and no newline; UUID v4 shape and distinctness; timestamp shape. All pass.
2. Standalone end-to-end replay (`%TEMP%\glacier-m0\hitmen\relaytest\`, not committed): the same scene sequence through `MissionObserver` → `RelayAdapter` → the real `LogRelaySink` → `RelayLog`. Exactly two envelopes, sequences 1 and 2, both parse as JSON with the expected keys.

### Clean build and inertness

Clean configure, build and tests from a deleted build tree at `0640cc89`: pass, no warnings from relay sources. `GlacierRelay.dll` SHA-256 `01adc65857468e9b42b4a812ec649f380f8fa18d0c0cfae1700ead2eb671548d`.

| Check | Result |
|---|---|
| Imports | `ZHMModSDK.dll`, `KERNEL32`, `USER32`, `SHELL32`, `IMM32` only; no socket or HTTP API |
| Exports | the three SDK plugin exports only |
| Hooks | none registered (`AddDetour` absent from the source) |
| Engine writes | none: no assignment through any `Globals::` pointer, no `SetProperty`, no transform setter, no actor access, no `Functions::` calls |
| UI | none (no ImGui) |
| Threads | none created by the adapter; everything runs on the frame thread |
| SDK core | unchanged; `CMakeLists.txt` differs from baseline only by the `GlacierRelay` entry |
| Hitmen | untouched and not built on this branch |

### Proposed Stage 1 runtime experiment (awaiting authorization)

Same discipline as the probe run (`research/HITMEN_RUNTIME_PROBE.md`), with `GlacierRelay.dll` as the single variable against M0:

1. Pre-flight: game version unchanged; M0 hashes; `Retail\mods\GlacierRelay.dll` absent; no Hitmen DLL present; backups of `mods.ini` and a `Retail` hash list.
2. Install: copy `_build\relay-x64-Debug\Mods\GlacierRelay\GlacierRelay.dll` to `Retail\mods\`; add `[glacierrelay]` to `mods.ini`. M0 mod set otherwise.
3. Run: launch via Steam → menu → attach Visual Studio (native) → Paris → walk → restart → exit to menu → **a second mission** → walk → exit to menu → quit.
4. Pass: envelopes `#1` (Paris), `#2` (restart), `#3` (second mission) in the durable log, none at the menu, each valid JSON with the expected scene resource; `mission playing` transitions coherent; no `ERROR`/`FAULT`; game stable; exit code 0.
5. Rollback and verify by hash, as before.

Stage 2 (TCP sink, BEAM listener in WSL2, explicit loopback connectivity check) is not started.

---

## 13. Stage 1 runtime result (2026-10-06, 21:55Z to 22:05Z)

Authorized explicitly, with Sapienza as the second mission. `GlacierRelay.dll` from `relay/m1` `0640cc89` (SHA-256 `01adc658…1548d`) was the single variable against the M0 mod set. Two game-directory changes (the DLL and a `[glacierrelay]` section); both reverted afterwards and all 107 `Retail` files verified against pre-flight hashes. Operator attached Visual Studio after the main menu.

**Result: pass.** 51 log lines, 0 `ERROR`, 0 `WARN`, 0 `FAULT`, one thread throughout, process stable, normal exit. `ZHMModLoader.log`: "Mod glacierrelay successfully loaded."

| Expectation | Observed |
|---|---|
| No event at the main menu (boot, after Paris, after Sapienza) | None. Menu reached stage 8 loaded three times with type empty. |
| `#1` on Paris load | 22:01:05.881, same frame as stage 8 + loaded |
| `#2` on Paris restart, without `LoadScene` | 22:02:18.755, after the 8 → 0 → 5 → 6 → 7 → 8 restart sequence |
| `#3` on Sapienza load | 22:03:39.406 (`CoastalTown/Mission01.entity`, hint `Octopus`) |
| Sequence numbers contiguous, one instance id | 1, 2, 3; `9c8f3a75-7054-457c-919d-ee87e77f57d9` |
| Each envelope valid JSON, schema version 1, expected keys | Yes, all three |
| Predicate transitions coherent | false → true three times, true → false three times, each pair bracketing one mission entry |

Evidence (local only): `%TEMP%\glacier-m0\hitmen\relay-run1\` (relay log SHA-256 `4f23707a…ce7f9`, SDK log, `mods.ini` before/after, `Retail` listings and hashes).

### Findings

1. **The predicate's two conditions are both necessary.** On the Sapienza load the loaded flag went true at stage 7, 164 ms before stage 8; on both Paris loads it went true only at stage 8. A predicate on the loaded flag alone would have fired early in Sapienza; one on stage 8 alone would have fired before the flag in Paris. Requiring both gave the same semantics on all three entries.
2. **Scene type is readable from the context on restart.** `m_SceneInitParameters.m_Type` stayed `"mission"` through the restart, so the predicate needed no hook. This closes the restart gap identified in experiment 4 (F2).
3. **Game session id changed on every mission entry**, including the restart, and the three values were distinct (`2516109767498002969-…`, `2516109766730159341-…`, `2516109765960127603-…`). The leading decimal part decreases over time by roughly the elapsed ticks, which is the shape of a "max ticks minus now" reverse timestamp; the suffix is a GUID. Observation only; nothing keys on it.
4. **The engine-independent layers ran unchanged from their tests.** The three in-game envelopes have exactly the shape the unit tests and the standalone replay produced.
5. As in experiment 4, there was no destructor or detach line at quit; the last line is the menu reaching stage 8.

### Status

Stage 1 is empirically validated: `Glacier observation → semantic state → edge → versioned event → IRelaySink → log`. Stage 2 (TCP loopback sink, BEAM listener in WSL2, explicit Windows → WSL2 loopback verification) is **not** started and needs its own authorization. The game installation is in its M0 file state.

---

## 14. Stage 2 implementation record (2026-10-06)

Stage 1 was accepted as the validated baseline. Stage 2 starts at `IRelaySink`; the predicate, edge, payload, schema version, instance id and sequence semantics are unchanged (the engine-independent sources above the sink were not modified except for the log-directory override in `RelayLog`).

**Built and integration-tested without the game. `GlacierRelay.dll` has not been deployed since the Stage 1 run.** The M1 final runtime experiment needs its own authorization.

### BEAM environment

| Item | Value |
|---|---|
| Host | WSL2 2.0.14.0, Ubuntu 20.04.6 LTS, kernel 5.15.133.1, default NAT networking (no `.wslconfig`, no `/etc/wsl.conf`), eth0 `172.23.229.225/20` |
| Erlang/OTP | 28.4.2 (erts 16.3.1), precompiled from `builds.hex.pm`, installed with `./Install -minimal` to `~/.local/opt/otp-28.4.2` (no root; checksum verified) |
| Elixir | 1.19.6 compiled for OTP 28, precompiled from `builds.hex.pm` to `~/.local/opt/elixir-1.19.6` |
| PATH | `~/.local/opt/beam-env.sh`, sourced from `~/.zshrc` |
| Dependencies | none (OTP 28's built-in `JSON` module) |

### Windows → WSL2 connectivity (measured, not assumed)

| Question | Observed |
|---|---|
| Bind address | `127.0.0.1:4747` inside WSL2 (`:gen_tcp.listen` with `ip: {127,0,0,1}`) |
| Destination from Windows | `127.0.0.1:4747` (also `localhost`); connect took 2 to 6 ms |
| Mechanism | WSL2 localhost forwarding: `wslrelay.exe` opens `127.0.0.1:4747` on the Windows side the moment the WSL2 listener binds (`netstat -ano` shows it LISTENING), and relays. Inside WSL2 the peer appears as `127.0.0.1:<port>`. |
| LAN exposure | None. The WSL2 eth0 address refused the connection (the listener is bound to loopback only), and the Windows-side forwarder is bound to `127.0.0.1`. |
| Firewall | No prompt and no rule needed (outbound loopback on Windows; the forwarder is a loopback listener). |
| Listener down | Windows gets "actively refused" immediately; the forwarder's Windows listener disappears. |
| Listener restart | Reachable again at once; the forwarder re-registers. |
| Forwarder lag | After the BEAM process is killed, the Windows forwarder accepted connections for about 1 s and then closed them. The native sink logged three connect/"peer closed" pairs in that second before backing off. Benign, but a connection "succeeding" at the forwarder does not prove BEAM is up. |

### BEAM application (`relay/`, commits `ff56c38`, `716621e`, `4138d6b`)

```
GlacierRelay.Application                    one_for_one
  GlacierRelay.MissionSession               GenServer: per instance id {last_sequence, playing?, last_event, received, gaps}; logs each event; notifies subscribers
  GlacierRelay.Wire.ConnectionSupervisor    DynamicSupervisor, one Wire.Connection per accepted socket
  GlacierRelay.Wire.Listener                GenServer owning the listen socket (127.0.0.1:4747, backlog 8); a linked acceptor loops accept/start_child/controlling_process
GlacierRelay.Wire.Connection                per socket, active: :once; Framing -> Envelope.decode -> MissionSession.handle_event
GlacierRelay.Wire.Framing                   pure NDJSON splitter with max_line_bytes (64 KiB; 4 KiB in tests)
GlacierRelay.Wire.Envelope, GlacierRelay.Events   envelope v1 and mission.playing v1 validation
```

TCP ownership: the Listener process owns the listen socket; each accepted socket is transferred to its Connection process (`controlling_process`) and dies with it. A Listener crash rebinds the port; accepted connections keep running; a connection still in the backlog at that instant is lost and the native client reconnects.

Validation: `protocol_version` must be 1; `adapter_instance_id`, `timestamp`, `event_type` non-empty strings; `sequence`, `schema_version` positive integers; `payload` an object; then per event type: `mission.playing` v1 requires `scene_resource` (non-empty), `scene_type`, `codename_hint` (strings) and accepts an optional string `game_session_id`; unknown payload keys are ignored; unknown event types and schema versions are rejected. Failure policy: an invalid line is logged and dropped, the connection continues; a line over the limit closes the connection; nothing is ever written to the socket.

Gaps: `MissionSession` records `{expected, got}` when a sequence is not `last + 1` and logs a warning; the first event from an instance is never a gap. A new instance id is a new game process.

### Native TCP sink (`relay/m1`, commits `3713468d`, `a28840e6`)

`TcpRelaySink : IRelaySink`. Native is the outbound client to `127.0.0.1:<port>`; the host is not configurable, the port is (`Retail\mods\glacierrelay.ini`, `[relay] port = 4747`, `sink = tcp|log`, default `tcp`).

- `Publish()` (frame thread) appends to a bounded queue (256) and returns; measured under 20 ms in tests, typically microseconds. It never touches the socket.
- One sender thread: non-blocking `connect` with a 2 s timeout; backoff 1, 2, 4, 8, 16, 30 s while the backend is absent, logging the first failure and each doubling; `send` with a 2 s timeout; a 500 ms wake to notice a closed peer.
- While disconnected, `Publish` drops the envelope immediately with a warning. A disconnect discards whatever is queued. No retransmission.
- No inbound protocol: whatever the peer sends is `recv`'d and discarded, counted, and logged once. `ws2_32` imports are client calls only; there is no `listen`, `accept` or `bind` in the source.
- Failure with BEAM absent: the mod initializes normally, the game thread is never blocked, log lines are the only effect.
- Known limit: if the peer closes within the 500 ms detection window, an envelope sent in that window is counted as sent but lost. Best-effort, as specified.

### Tests and results

| Layer | Tests | Result |
|---|---|---|
| Elixir framing | split across chunks, multiple lines per chunk, CRLF, empty lines, limit on terminated and unterminated lines | 5 pass |
| Elixir envelope | the three real Stage 1 envelopes decode; optional/mistyped session id; malformed JSON, non-objects; every missing and mistyped field; other protocol versions; unknown event; unknown schema version; missing payload fields; unknown payload keys ignored | 7 pass |
| Elixir listener | loopback bind; in-order delivery of the Stage 1 envelopes; arbitrary chunking; malformed line between valid ones; line over limit closes; gap recording; reconnect with a new instance id; listener never writes; listener restart with a live connection | 9 pass (21 total, run 5× to check for flakiness) |
| Native unit (`GlacierRelayTests`) | backend absent: Publish under 20 ms, 3 drops, bounded attempts; backend appears later: connects, 2 lines in order; inbound bytes discarded and counted, connection still works; backend disappears: detected, drop counted; backend returns: reconnect, delivery; prompt destruction | all pass, plus the Stage 1 tests |
| Integration A (Windows probe → WSL2 BEAM) | `GlacierRelayWireProbe 4747 sleep:1000,stage1` | BEAM logged `mission.playing #1, #2, #3` from instance `8c26a3f2…` at the probe's timestamps; native log shows `sent #1..#3`; disconnected "after 3 line(s), 0 rejected" |
| Integration B (BEAM absent → starts → killed → restarts) | `publish,sleep:6000,publish,sleep:10000,publish,sleep:12000,publish` | #1 dropped (not connected); connected 1 s after BEAM started; #2 delivered; peer-closed detected; backoff 1, 2, 4 s; #3 dropped; reconnected after restart; #4 delivered. BEAM: first instance saw #2, second saw #4. |
| Malformed BEAM input cannot affect native | by construction (no parser; `recv` discards) and by the inbound-bytes test | pass |

Evidence (local): `%TEMP%\glacier-m0\hitmen\wire-probe\` (probe logs, BEAM logs) and `relaytest\testlogs\`.

### Clean native build

Deleted build tree, configured, built `GlacierRelay`, `GlacierRelayTests`, `GlacierRelayWireProbe`, ran the tests: pass, no warnings from relay sources. `GlacierRelay.dll` SHA-256 `5ab6e64ca40f835e1cf233e2e8aec86d39c5bd7bd72217eee1c89597f1160f25`. Imports: `ZHMModSDK.dll`, `KERNEL32`, `USER32`, `SHELL32`, `IMM32` and now `WS2_32` (14 client-side functions). Still no hooks, no engine writes, no UI, SDK core unchanged, Hitmen untouched.

### Commit sequence

glacier-relay `main`: `ff56c38` bootstrap, `716621e` framing/envelope/events, `4138d6b` listener/connection/session. ZHMModSDK `relay/m1`: `3713468d` R6 TcpRelaySink, `a28840e6` R7 wire probe and sent-sequence logging.

### Proposed M1 final runtime experiment (awaiting authorization)

Same discipline as the Stage 1 run, with the Stage 2 DLL and BEAM up:

1. In WSL2: `cd relay && mix run --no-halt`, output captured to a file; confirm `relay: listening on 127.0.0.1:4747` and the Windows-side forwarder (`netstat -ano | findstr :4747`).
2. Pre-flight as before (game version, M0 hashes, no relay/Hitmen files, backups). Install `GlacierRelay.dll` (SHA above) to `Retail\mods\` and add `[glacierrelay]` to `mods.ini`. No `glacierrelay.ini` is needed (defaults: `tcp`, 4747).
3. Launch via Steam → menu. Check the native log for `tcp sink: connected` and the BEAM log for `accepted`. Then attach VS, Paris → walk → restart → menu → Sapienza → menu → quit.
4. Pass: BEAM logs `mission.playing #1` (Paris), `#2` (restart), `#3` (Sapienza) with the native log's instance id, sequence numbers, timestamps, scene resources and session ids matching line for line; `MissionSession` state shows that instance with `last_sequence: 3`, `gaps: []`; nothing at the menu; the native log shows `sent #1..#3` and no drops; no `ERROR`/`FAULT`; game stable; exit code 0; BEAM logs the disconnect when the process ends.
5. Optionally, while in Sapienza: stop and restart BEAM once to see the reconnect in the game (no event is expected during that window). Only if approved.
6. Rollback and verify by hash. Stop BEAM.

# Hitmen — Historical Transport and Wire Contract (GameNetworkingSockets)

Date: 2026-10-06

Source: upstream ZHMModSDK `Mods/Hitmen` at `5cc7f1b1`, before revival commit `04329728` ("S1 replace GameNetworkingSockets with a null transport seam") on `Just-Some-Content-LLC/ZHMModSDK` `research/hitmen-revival`.

Purpose: Glacier Relay is **not** reviving GameNetworkingSockets (GNS). This document preserves what the original Hitmen transport and messages actually were, so that knowledge survives the removal and can inform the native-adapter → BEAM protocol (see ADR 0001, 0002 and 0003).

## Transport

| Aspect | Original behavior |
|---|---|
| Library | Valve GameNetworkingSockets `1.4.1`, statically linked (`GameNetworkingSockets::static`, via CPM) |
| Lifecycle | `GameNetworkingSockets_Init` in `OnEngineInitialized`; `GameNetworkingSockets_Kill` in the plugin destructor |
| Topology | One host, one client. `// TODO: Multiple clients.` A later connection overwrites `m_ClientConnection`. |
| Host | `CreateListenSocketIP` on all interfaces, port **6969** (hard-coded in the UI), plus one poll group |
| Client | `ConnectByIPAddress("<addr>:6969")`; the address is typed into an ImGui window |
| Connection handling | Status-changed callbacks. Host: on `Connecting`, `AcceptConnection` + `SetConnectionPollGroup`. Client: on `Connected`, set connected. No disconnect handling. |
| Receive | Polled each frame: `ReceiveMessagesOnPollGroup` (host) / `ReceiveMessagesOnConnection` (client), at most 100 messages per frame |
| Send | `SendMessageToConnection(..., k_nSteamNetworkingSend_UnreliableNoNagle)` for **all** traffic |
| Callbacks | `RunCallbacks()` each frame |
| Security | GNS's own encrypted connection; no application-level authentication, handshake or version check |

At upstream `5cc7f1b1` **the entire per-frame networking path is commented out** (`OnFrameUpdate`). That includes receive, callbacks and both send timers. In its last state Hitmen ran only the scene-detection half: finding the local and the second Hitman.

## Framing

One GNS message carries exactly one application message, written with `BinaryStreamWriter` as raw host-order (x64 little-endian) bytes:

```
[MessageId : int32] [payload ...]
```

`MessageId` is an unscoped C++ `enum` (underlying `int`, 4 bytes):

| Value | Name |
|---|---|
| 0 | `InputsAndPositions` |
| 1 | `NpcPositions` |

There is no version field, length prefix, sequence number, timestamp or checksum.

## Messages

### `InputsAndPositions` (0): each peer → the other peer

Intended rate: 30 Hz (`1/30 s` timer; commented out).

| Offset | Size | Field | Source |
|---|---|---|---|
| 0 | 4 | `MessageId` = 0 | |
| 4 | 64 | `SMatrix` world transform of the local Hitman | `ZSpatialEntity::GetWorldMatrix()` (now `GetObjectToWorldMatrix`, H3) |
| 68 | 0x148 (328) | Raw bytes of the local character input state | `ZHitman5::m_pCharacterInputProcessor->m_pInput + 8` (presumably skipping the vtable pointer) |

Total **396 bytes**.

On receive (if the second Hitman exists):

1. Set property `m_eRoomBehaviour = ROOM_DYNAMIC` on the second Hitman.
2. `SetWorldMatrix(transform)` on the second Hitman (now only `SetObjectToWorldMatrixFromEditor` exists, H3).
3. If the second Hitman has an input processor and input object, **memcpy the 328 bytes directly over its input state** (at the same +8 offset).

A commented-out variant only snapped the position when the error was 0.3 or more (world units, presumably metres).

### `NpcPositions` (1): host → client only

Intended rate: 10 Hz (`1/10 s` timer; commented out).

| Field | Size |
|---|---|
| `MessageId` = 1 | 4 |
| `aliveCount` (`uint32`) | 4 |
| then `aliveCount` × { actor index (`int32`), `SMatrix` world transform } | 4 + 64 each |

The actor index is the position in `ZActorManager::m_aActiveActors[0 .. *Globals::NextActorId)` on the host. On receive, the client applies `SetWorldMatrix` to the actor at the **same index** if it is alive and the index is within its own `NextActorId`.

That layout no longer exists in the SDK (H8): `ZActorManager` was reinterpreted in `c2e1cc3d` (2025-12-08), and the field at that offset is now `TMaxArray<TEntityRef<ZActor>, 500> m_activatedActors`.

## Implicit authority model

- Each peer is authoritative for **its own Hitman**: transform and raw input.
- The host is authoritative for **NPC transforms only**. AI, state, life/death, items, doors and objectives are not replicated; each instance simulates them locally.
- No ownership negotiation, reconciliation, interpolation or lag compensation; the last message received wins.

## Hazards (why "extremely incredibly unsafe")

1. **Untrusted bytes written into engine memory.** 328 network bytes are copied over a live engine input object, with an assumed size of `0x148` and an assumed 8-byte (vtable?) skip.
2. **No real bounds checking.** `BinaryStreamReader` validates reads only with `assert`, which is compiled out of Release builds. A short or malformed message reads past the buffer.
3. **Cross-instance identity by array index.** NPC identity assumes both games populate the actor array in the same order. This is not guaranteed, and the array itself has since been reinterpreted (H8).
4. **No protocol versioning.** Layout changes (for example of `SMatrix` or the input block) are silently misinterpreted.
5. **Unscoped enum on the wire.** The message ID width depends on the compiler's enum representation.

## What Glacier Relay should keep vs replace

| Keep (knowledge) | Replace (mechanism) |
|---|---|
| The second-Hitman discovery path (`hitmen.brick`, sub-entity `0xfeede715906f747f`) | GNS, IP:6969, single-client topology |
| Which engine surfaces are needed: Hitman transform, character input processor, actor transforms | Raw memory blobs on the wire. Use semantic, versioned messages (ADR 0003). |
| The split between per-player state (high rate, unreliable) and world state (lower rate, host-authoritative) | Array-index entity identity. Use stable cross-instance identities (Hitmen research question 4). |
| The `m_eRoomBehaviour = ROOM_DYNAMIC` requirement for an externally moved Hitman | Native-side networking. Networking belongs to BEAM (ADR 0002). |

## Revival seam

`Mods/Hitmen/Src/HitmenTransport.h` (`research/hitmen-revival`) defines `IHitmenTransport`. Each method is annotated with the GNS calls it replaces: `StartServer`, `Connect`, `PollConnected`, `ReceiveMessages` and `SendUnreliable`. The only implementation, `NullHitmenTransport`, never opens a socket and logs a warning if the UI tries to host or connect. The message encode/decode code above is unchanged and still drives through the seam. A future implementation of the seam is the natural attachment point for the native-adapter → BEAM boundary.

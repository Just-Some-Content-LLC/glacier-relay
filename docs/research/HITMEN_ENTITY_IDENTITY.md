# Hitmen — NPC Identity Archaeology (H8)

Date: 2026-10-06

Sources: upstream ZHMModSDK history up to `5cc7f1b1`; `Just-Some-Content-LLC/ZHMModSDK` `research/hitmen-revival` commit `b8c66ead` ("H8 exclude NPC position sync from the dormant build").

Question: **how did the 2023 Hitmen protocol identify an NPC across two machines, and what does the current engine model offer instead?**

This is protocol archaeology, not a compile fix. Nothing here was ported. The NPC sync code is compiled out of the dormant build (`#if 0`) and kept verbatim as evidence.

Everything below is derived from source and upstream history. **None of it has been observed at runtime on game `3.280.0.0`.** Claims that depend on runtime behavior are marked *unverified*.

## What the 2023 protocol did

`NpcPositions` (message 1, host → client, intended 10 Hz; see `HITMEN_GNS_CONTRACT.md`):

```cpp
// host
for (int i = 0; i < *Globals::NextActorId; ++i)
    if (ActorManager->m_aActiveActors[i].m_pInterfaceRef->IsAlive())
        write(i), write(worldMatrix(m_aActiveActors[i]));

// client
if (index < *Globals::NextActorId && ActorManager->m_aActiveActors[index].m_pInterfaceRef->IsAlive())
    m_aActiveActors[index].SetWorldMatrix(matrix);
```

The integer on the wire is the loop index. So the protocol's NPC identity was:

```
distributed NPC identity == index into this process's actor array
```

That only holds if both game instances fill the array with the same actors in the same order and never diverge. Nothing in the protocol checks this.

## What the old array was

SDK model from 2023 until 2025-12-08:

```cpp
class ZActorManager {
    PAD(0x1F60);
    TEntityRef<ZActor> m_aActiveActors[1000]; // 0x1F68, ZActorManager destructor, last if
};
```

- The name and the count of 1000 were guesses. The only stated evidence was "ZActorManager destructor, last if".
- Everything before `0x1F68` was unknown padding.
- The loop bound was the separate global `Globals::NextActorId` (`uint16_t*`, found by pattern `FF 05 ?? ?? ?? ?? 48 83 C1`, an `inc` of a global).

## What the current SDK models

`c2e1cc3d` (2025-12-08, "Add new fields to ZActorManager and refactor GetActorByName and GetActorById") replaced the padding with a detailed layout. The relevant part:

| Offset | Field | Meaning in the SDK model |
|---|---|---|
| `0x8` | `TEntityRef<ZActor> m_aActors[500]` | Fixed slot table |
| `0x1F48` | `TArray<int> m_aFreeActorRuntimeIds` | Free list of slot ids, so slots are recycled |
| `0x1F60` | `bool m_bLockActorLists` | |
| `0x1F68` | `TMaxArray<TEntityRef<ZActor>, 500> m_activatedActors` | Dense list plus count, at the old array's offset |
| `0x3EB0` | `TMaxArray<int, 500> m_aActivatedActorIds` | Parallel list of runtime ids |
| `0x4688` | `m_enabledActors`, then `m_disabledActors`, `m_aEnabledActorIds` | |
| `0x8D08` | `TMaxArray<TEntityRef<ZActor>, 400> m_aliveActors` (+ ids, grid nodes) | |
| `0xCD30` | `TMaxArray<TEntityRef<ZActor>, 400> m_aliveHm5Characters` (+ ids) | |
| `0xED28` | `m_aliveActorsByDistanceToHM` | Sorted by distance to the player |
| `0x10630` | `TArray<TEntityRef<ZActor>> m_SpawnedActors` | Actors created at runtime |

`ZActor::m_nActorRuntimeId` (`0x119C`) was named in `c4366323` (2026-01-14); it had previously been called `m_nCurrentBehaviorIndex`.

Consequences for the old code:

1. **The old array was 500 entries, not 1000.** A `TMaxArray<TEntityRef<ZActor>, 500>` is 500 × 16 bytes of storage followed by a count. The 2023 model's entries 500 to 999 overlapped the count, `m_aActivatedActorIds` (plain integers) and part of `m_enabledActors`. The 2023 code never read them only because `NextActorId` bounded the loop.
2. **The array is a dense list, not a slot table.** `m_activatedActors` is a count-prefixed list of currently activated actors. The slot table is the separate `m_aActors[500]`, whose ids are recycled through a free list.
3. **Position in the list is not an identity.** It depends on activation order, and (*unverified*) on how the engine removes entries when an actor is deactivated. It is a property of one process at one moment.
4. Current upstream mods still loop `m_activatedActors` up to `*Globals::NextActorId` rather than `m_activatedActors.size()`. Whether those two are always equal is *unverified*.

So `m_activatedActors` is the same memory the 2023 code read, but adapting the NPC sync to it would preserve the accident (index as identity) under a name that now makes the problem obvious. It was not adapted.

## Identifiers that exist in the engine model

| Identifier | Where | Stable across machines? | Notes |
|---|---|---|---|
| Index in `m_activatedActors` | `ZActorManager` | **No** | Activation-order dependent |
| `ZActor::m_nActorRuntimeId` | `ZActor` `0x119C` | **No** | Slot id, recycled via `m_aFreeActorRuntimeIds` |
| `ZEntityType::m_nEntityID` | `ZEntityType` `0x58` (64-bit) | **Yes, for authored entities** | The id authored in the scene/brick data. Same game data gives the same id. |
| Entity id + brick/blueprint resource | Game data | **Yes, for authored entities** | How the game's own data refers across bricks (below) |
| `ZActor::m_sActorName` | `ZActor` `0x498` | Yes, but not unique | Human-readable label only |
| `ZActor::m_OutfitRepositoryID` | `ZActor` `0x430` | Yes, but not unique | Shared by every NPC wearing the outfit |

### Evidence that entity id is the engine's own stable handle

1. **Hitmen already uses it, for the second Hitman.** The mod finds the second player with `GetSubEntityIndex(0xfeede715906f747f)` inside `hitmen.brick`. In `Mods/Hitmen/Smf/hitmen/chunk0/_sdk/hitmen.entity.json` that id is the authored entity `Agent48` (factory `agent47_default.entitytemplate`), next to `Agent48Spawn` (`herospawn.entitytemplate`). The 2023 code used a stable authored id for the Hitman and an array index for NPCs.
2. **The game's own data addresses entities this way.** Property overrides in `multiplayer_hitmen.entity.json` reference entities in other bricks as `{ "ref": "<entity id>", "externalScene": "<brick resource>" }`.
3. **The SDK resolves actors by it.** `ZActorManager::GetActorById(uint64_t)` compares `GetType()->m_nEntityID`.
4. **The Editor mod's external protocol uses it.** `EntitySelector { uint64_t EntityId; optional<ZRuntimeResourceID> TbluHash; ... }` (`Mods/Editor/Src/EditorServer.h`) is how an out-of-process tool names a live entity.

### Known limits of entity id (all *unverified* at runtime)

- **Not globally unique on its own.** An id is authored per blueprint. The same template instantiated twice yields the same sub-entity ids under different owners, which is why the Editor selector carries an optional blueprint hash. A full identity is the id qualified by where it was instantiated (owning brick, and for nested templates the chain of owning entities).
- **Runtime-spawned actors have no authored id shared between machines.** `m_SpawnedActors`, crowd characters and anything created by game logic at runtime need an identity assigned by whoever is authoritative for the spawn.
- **Both instances must run the same content.** Same scene, same bricks, same game version, same content mods. Ids from different data are not comparable.

## What a stable cross-machine identity scheme would need

Requirements only. No design is proposed here and nothing is implemented.

1. **Authored entities:** identify by entity id qualified by its instantiation context (at minimum the brick's runtime resource id; for nested templates, a path of ids). Never by list position or runtime slot.
2. **Runtime-spawned entities:** an id allocated by the session authority (BEAM, per ADR 0002) and mapped to a local entity on each machine when the spawn is replicated.
3. **A content fingerprint in the session handshake:** scene resource, loaded brick set and game version, so that two instances whose ids are not comparable refuse to pair instead of silently mis-addressing entities. The 2023 protocol had no handshake at all.
4. **Resolution, not indexing, on receive:** look the entity up by identity and treat "not found" and "not alive" as normal outcomes.
5. **A native-side mapping** from stable identity to the local `ZEntityRef`, rebuilt on every scene load and cleared on scene clear.

## Open questions for a later runtime experiment

Observation only; these can be answered by reading, without mutation:

- Is `m_nEntityID` unique among all activated actors in a real mission? How many collisions, and from which templates?
- Do two launches of the same mission produce the same set of (entity id, brick) pairs for NPCs? Does the order of `m_activatedActors` differ between launches?
- Does `*Globals::NextActorId` equal `m_activatedActors.size()`?
- What do `m_SpawnedActors` and crowd characters report for `m_nEntityID`?

None of these are part of the first runtime load, which reads no actor data at all (see `HITMEN_RUNTIME_PROBE.md`).

# ZHMModSDK Hitmen — Initial Analysis

Source examined: upstream `Mods/Hitmen/Src/Hitmen.cpp` as available during project formation (2026-10-03).

## PROVEN in source

- The module initializes Valve GameNetworkingSockets.
- It contains host/listen and connect-by-IP paths.
- Message IDs include `InputsAndPositions` and `NpcPositions`.
- Player transmission serializes a world matrix and a raw block associated with the local character input processor.
- Received player state can set the second Hitman's world matrix and write remote input bytes into its character input structure.
- NPC transmission iterates active actors, sending actor index plus world matrix for living actors.
- Received NPC state can set corresponding actor world matrices.
- The module searches loaded bricks for an SDK `hitmen.brick` and obtains an `m_OtherHitman` entity that it queries as `ZHitman5`.
- Debugging code iterates four entries in `ZPlayerRegistry::m_aPlayerData` and inspects fields associated with player/network state.
- The implementation contains an explicit `TODO: Multiple clients.`
- Significant networking/update code in `OnFrameUpdate` is currently commented out.
- Multiple raw-memory operations are explicitly marked by the author as extremely unsafe.

## What this proves

The source establishes important primitives and prior experimentation. It does **not** establish a production co-op implementation.

Strong evidence exists for:
1. multiple Hitman-like entities in a scene,
2. runtime transform manipulation,
3. access to character input state,
4. access to active actor transforms,
5. an attempted network transport between instances.

## What it does not prove

- Correct remote animation across all actions.
- Shared inventory semantics.
- Combat/projectile authority.
- NPC AI convergence.
- Ragdoll/physics convergence.
- Mission-script convergence.
- Disguise, suspicion, witness, trespass or enforcer convergence.
- Save/load behavior.
- Freelancer compatibility.
- More than one remote client.
- Stability on current WOA builds.

## Research questions

1. Does the current SDK still load the Hitmen brick successfully?
2. Can the second Hitman participate in interaction/animation systems without corrupting local-player assumptions?
3. Which player registry/network remnants derive from historical Glacier multiplayer/Ghost Mode?
4. Which world entities have stable cross-instance identities?
5. Can semantic events be intercepted directly, or must some be inferred from state transitions?
6. Which simulation should own NPC AI during co-op?
7. Can non-authoritative clients suppress local AI decisions safely?
8. What minimum state slice yields a convincing two-player proof of concept?

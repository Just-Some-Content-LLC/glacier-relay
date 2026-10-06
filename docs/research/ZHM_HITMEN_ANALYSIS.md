# ZHMModSDK Hitmen — Initial Analysis

Source examined: upstream `Mods/Hitmen/Src/Hitmen.cpp` as available during project formation (2026-10-03).

## Status at M0 baseline (2026-10-06)

**Characterization: dormant experimental source. Its current compilability and runtime compatibility are unknown.**

M0 (see `M0_BASELINE.md`) found that at ZHMModSDK `5cc7f1b1`:

- `Hitmen` is commented out of the top-level `MODS` list in `CMakeLists.txt`, and is therefore **not built, installed or shipped**.
- Its networking dependency is also disabled: `#CPMAddPackage("gh:ValveSoftware/GameNetworkingSockets@1.4.1")` at the top level, and `#GameNetworkingSockets::static` in `Mods/Hitmen/CMakeLists.txt`.
- Both were disabled in upstream commit `40d86dc7` (2024-12-22, "Update dependencies").
- Since then, `Mods/Hitmen` has received only cross-cutting mechanical edits made alongside SDK-wide refactors (for example `13ae7b83` 2025-10-22, `6fdbdfa1` 2026-08-12, `e10ddf81` 2026-08-12). **None of these edits have been compile-validated by the upstream build.**
- The README still lists Hitmen as a sample mod.

This replaces the earlier description of Hitmen as an "unfinished experimental implementation". Everything below about what the source shows still holds as a statement about the source text. None of it is evidence that the code compiles, or behaves as described, against the current SDK or game.

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
- That it compiles against the current SDK (not built upstream since 2024-12-22).

## Research questions

0. Does the dormant Hitmen source still compile against current ZHMModSDK? If not, what is the catalogue of API and structure drift?
1. Does the current SDK still load the Hitmen brick successfully?
2. Can the second Hitman participate in interaction/animation systems without corrupting local-player assumptions?
3. Which player registry/network remnants derive from historical Glacier multiplayer/Ghost Mode?
4. Which world entities have stable cross-instance identities?
5. Can semantic events be intercepted directly, or must some be inferred from state transitions?
6. Which simulation should own NPC AI during co-op?
7. Can non-authoritative clients suppress local AI decisions safely?
8. What minimum state slice yields a convincing two-player proof of concept?

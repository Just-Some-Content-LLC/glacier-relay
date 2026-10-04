# Glacier Relay

> Experimental semantic runtime, telemetry, and multiplayer coordination infrastructure for HITMAN: World of Assassination and Glacier 2.

**Status:** research / pre-alpha. No multiplayer release exists today.

Glacier Relay is an independent open-source research project exploring a stable semantic boundary between the proprietary Glacier 2 runtime and higher-level tooling. The immediate goal is not to rewrite Glacier, Peacock, or ZHMModSDK. It is to translate observable runtime behavior into a versioned event/command protocol that can support instrumentation, analytics, mission recording, development tools, and—if the engine research continues to validate the required primitives—cooperative multiplayer.

## Thesis

Keep reverse-engineered engine details at a narrow native boundary. Above that boundary, reason in domain concepts: players, actors, items, doors, cameras, objectives, mission events, authority, replication, and telemetry.

```text
HITMAN WOA / Glacier 2
        |
        | native hooks / runtime state
        v
Glacier Adapter (ZHMModSDK-derived)
        |
        | versioned semantic protocol
        v
Glacier Relay (Elixir/OTP)
   |       |       |       |
telemetry replay  tools  multiplayer
```

## Evidence standard

Project documents label important technical claims as:

- **PROVEN** — demonstrated by current source/tooling or reproduced by this project.
- **OBSERVED** — supported by reverse-engineering evidence but not yet established as a stable contract.
- **HYPOTHESIS** — plausible architectural proposition requiring experimentation.
- **RESEARCH REQUIRED** — an explicit unknown.
- **LONG-TERM** — intentionally outside current implementation scope.

## Initial milestones

0. Establish a reproducible research baseline against current WOA and ZHMModSDK.
1. Emit one semantic Glacier event into BEAM.
2. Build useful live mission telemetry.
3. Add a Phoenix/LiveView observability console.
4. Persist mission event streams and derived analytics.
5. Establish a safe command path from BEAM back into Glacier.
6. Reproduce and stabilize the experimental second-Hitman primitive.
7. Demonstrate a network-controlled remote Hitman between two PCs.
8. Synchronize a deliberately bounded set of shared-world events.
9. Complete one constrained mission cooperatively.

Each milestone must produce useful evidence even if later multiplayer research fails.

## Non-goals

- Distributing IO Interactive assets or proprietary code.
- Circumventing ownership requirements.
- Claiming affiliation with or endorsement by IO Interactive.
- Replacing ZHMModSDK before there is evidence that doing so creates value.
- Promising production-quality co-op before the synchronization problem has been experimentally characterized.
- Making higher-level systems depend on raw Glacier pointers or memory layouts.

## Upstream and related work

Glacier Relay builds on community reverse engineering, especially ZHMModSDK. The organization maintains a downstream fork for experiments that require Glacier-facing changes. Peacock is important prior art for WOA service emulation, but is not currently a dependency or translation target.

See `docs/VISION.md`, `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`, and `docs/research/ZHM_HITMEN_ANALYSIS.md`.

## Legal / trademark

This is an unofficial fan/community research project and is not affiliated with, endorsed by, or sponsored by IO Interactive. HITMAN, World of Assassination, Glacier, and related names and marks belong to their respective owners. Users are expected to own legitimate copies of the game and required content.

## License

Licensing for original Glacier Relay components is being finalized before substantive implementation is accepted. Upstream-derived code remains subject to its upstream license. Do not copy code across repository boundaries without verifying license obligations.

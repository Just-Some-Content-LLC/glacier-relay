# Vision

Glacier Relay exists to turn reverse-engineered Glacier runtime observations into a stable, useful semantic platform.

## Why

World of Assassination contains an unusually rich systemic simulation. Community tooling already demonstrates runtime access far beyond asset replacement, while ZHMModSDK's experimental `Hitmen` module provides evidence that a second Hitman entity, remote transform/input application, and NPC transform synchronization have all been explored.

The opportunity is broader than co-op: create a semantic event and command layer that supports observability, personal analytics, mission recording, developer tooling, extensibility, and eventually shared-world synchronization.

## Product ladder

1. **Observer** — understand what happens in a running mission.
2. **Recorder** — persist what happened and derive statistics.
3. **Controller** — safely apply semantic commands to Glacier.
4. **Relay** — coordinate multiple game instances.
5. **Co-op** — synchronize enough of a mission to create a convincing shared experience.

Every rung must be useful independently.

## Design principles

- Preserve and credit upstream community work.
- Prefer semantic events over leaking engine memory structures.
- Separate high-frequency replication from durable world facts.
- Make authority explicit.
- Treat crashes and desynchronization as expected research conditions.
- Instrument everything.
- Version the wire protocol from the first successful event.
- Keep the native Glacier adapter narrow.
- Keep the BEAM alive when a game client crashes.
- Do not make language uniformity a goal; make boundaries coherent.

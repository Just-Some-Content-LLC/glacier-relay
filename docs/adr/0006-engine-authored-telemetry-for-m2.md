# ADR 0006 — Prefer Glacier's engine-authored telemetry stream for M2 telemetry

**Status:** Proposed (2026-10-07). Scope: **M2 telemetry only.** This ADR does not make the stream the source of truth for mission-attempt lifecycle (ADR 0005 and the M1/M2 Stage A predicate stand), for commands (M5), for replication (M7+), or for any future Glacier Relay architecture.

## Context

The B0 probe (`docs/research/ACTOR_OUTCOME_ARCHAEOLOGY.md`, section 15) showed that HITMAN WOA `3.280.0.0` passes every event of its contract-session telemetry through `ZAchievementManagerSimple::OnEventSent` before transmission, as a `ZDynamicObject` with a `Name`, a `Value` and session metadata. One 22-minute Paris session yielded 204 events of 43 names across mission/contract lifecycle, kills and pacifications, disguise, inventory, objectives and challenges, detection and body state, and combat statistics, with zero serialization failures and no measurable frame cost. The controlled `Kill`/`Pacify` payloads matched the 33-field schema documented by Peacock exactly, and carried the engine's own classification of type (`EDeathType`), context (`EDeathContext`), class, method, item, target flag and actor type.

The alternative established by static archaeology, per-frame state observation of `ZActor`, was run alongside as a correlation instrument and showed:

- **state names mislead**: `IsDead()` went true on every pacification (it means "down"), returned to false when a body was bagged, and `IsAlive()` false mostly meant "not yet enabled";
- **polling has no causality**: nothing in actor state says who or what caused a transition, whether it was an accident, or which item was used;
- **polling has no classification**: guard versus civilian is not a modelled actor field;
- **state observation is still necessary**: one pacified NPC recovered thirteen minutes later with no telemetry event at all; the only evidence was `IsPacified()` falling.

## Decision

For M2 telemetry, **prefer Glacier's engine-authored semantic telemetry stream when it directly represents the fact Relay needs.** Use **direct state observation** for validation, correlation (resolving a telemetry event to a live entity), persistent or current state, and facts the stream does not carry. Treat **entity pins** as archaeology and correlation tooling, not as a Relay event source, unless a later need is demonstrated.

Evidence hierarchy for M2:

| Rank | Evidence | Answers | Examples |
|---|---|---|---|
| 1 | Engine-authored semantic occurrence (`OnEventSent`) | *What semantic occurrence did Glacier record?* | `Kill`, `Pacify`, `ContractStart`, `ContractFailed`, `ObjectiveCompleted`, `Disguise`, `ItemPickedUp` |
| 2 | Engine state observation | *What state is the runtime in now?* and anything the stream lacks | the scene predicate (`mission.playing/stopped`), `IsPacified()`, actor identity and `RepositoryId` reads |
| 3 | Engine pin / internal transition | ordering and archaeology | `Dead`, `PacifiedData`, `OnPacified` |

The native adapter remains an anti-corruption layer (ADR 0001): it recognizes a bounded set of stream events, validates them, and translates them into Relay-owned, versioned, engine-independent events (ADR 0003) through `IRelaySink` (ADR 0005). **It does not forward arbitrary stream JSON to BEAM**, and the stream's shape is not the Relay protocol.

## Consequences

- M2 is organized around normalizing a bounded subset of one stream, with state observation added per demonstrated need, instead of one native observer per roadmap vocabulary.
- The first hook enters `GlacierRelay` (`OnEventSent`, log-and-continue). The M1 "no hooks" property was a choice, not a rule; it is replaced by "one read-only hook on an engine-authored surface, documented here".
- Relay's mission attempt stays bounded by the scene predicate; the stream's `ContractStart`/`ContractFailed` and `ContractSessionId` become evidence attached to attempts, not a second lifecycle (section 5 of the design).
- Events the engine marks `_DONTSEND` are not normalized by default (design, section 4).
- The decision is conditioned on `3.280.0.0` evidence. A game update that changes the hook's pattern, the event names or the payloads is detected on the BEAM side as unknown names or failed validation and on the native side as a failed hook install; nothing in Relay assumes the stream is permanent. State observation is the instrument for re-validating a new build.
- Peacock remains prior art under ADR 0004: its schema was corroborated, not adopted; Relay's schemas are written from the captured corpus.

## Alternatives rejected

- **Per-vocabulary state polling** (actor state for kills, inventory archaeology for items, disguise state, objective archaeology): no causality, misleading names, one reverse-engineering project per vocabulary, and the kill case alone would have needed hit-info structures the SDK does not model.
- **Transparent forwarding of the raw stream to BEAM**: couples the Relay protocol to IOI's backend contract, leaks user and platform identifiers, and moves validation out of the anti-corruption layer.
- **Pins as the primary surface**: emitted by logic entities, not actors; no identity without payload decoding; one hook on a very hot path for ordering information only.

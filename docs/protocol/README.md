# Glacier Relay Protocol

M1 (2026-10-06) fixed the **envelope** (version 1), the first event `mission.playing` (schema 1) and the wire (NDJSON over an outbound TCP client to a loopback BEAM listener); see `docs/design/M1_FIRST_SEMANTIC_EVENT.md`. M2 Stage A added `mission.stopped` (schema 1, same payload shape), the falling edge of the same predicate. M2 B1 added `actor.died` and `actor.pacified` (schema 1), normalized from Glacier's engine-authored telemetry stream through a bounded, table-driven boundary (ADR 0006); the stream's own shape is never the Relay protocol. M2 B2 added `contract.started` and `contract.ended` (schema 1): Glacier's own account of its contract sessions, published whenever the engine emits them (they occur on both sides of the mission predicate's edges), with `contract.ended` carrying the engine's reason verbatim beside `reason_kind` (`restart` | `exit_to_menu` | `other`). `mission.*` is observed runtime state; `contract.*` is engine-authored session semantics; BEAM correlates the two by stream order and says so. B2 is built and validated without the game; its runtime experiment is pending. See `docs/design/M2_TELEMETRY.md` for what each event does and does not claim.

## Logical envelope

A future message should minimally communicate:

```text
protocol_version
message_type
session_id
source_id
sequence/tick (where applicable)
timestamp (where applicable)
payload
```

## Channels

The design distinguishes:

1. **Events** — facts observed in Glacier.
2. **Commands** — requested changes applied through the adapter.
3. **Continuous replication** — high-frequency ephemeral state.
4. **Snapshots** — state used to initialize/recover a client.

Do not choose JSON, MessagePack, Protobuf, Erlang External Term Format, QUIC, TCP or UDP by preference alone. M1 should establish payload shapes and performance requirements first.

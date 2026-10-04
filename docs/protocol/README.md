# Glacier Relay Protocol

The wire protocol is intentionally unspecified until M1.

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

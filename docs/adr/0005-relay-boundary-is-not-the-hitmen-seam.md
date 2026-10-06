# ADR 0005 — The relay boundary is not the Hitmen transport seam

**Status:** Proposed (2026-10-06).

`IHitmenTransport` was created to keep the dormant 2023 Hitmen networking code compiling after GameNetworkingSockets was removed. Its shape is GNS's: a listening host, connection handles, unreliable opaque-byte messages, polled receive. Those are assumptions Glacier Relay rejects (ADR 0001, 0002, 0003).

Glacier Relay's native boundary is a separate, relay-designed interface (`IRelaySink`) that accepts only serialized, versioned, engine-independent envelopes. `IHitmenTransport` stays frozen with the historical Hitmen code as documentation of what the 2023 protocol was.

Consequences: no Glacier type, pointer, offset or memory image crosses the sink; the native side is an outbound client and never listens; the first event (`docs/design/M1_FIRST_SEMANTIC_EVENT.md`) establishes the rule.

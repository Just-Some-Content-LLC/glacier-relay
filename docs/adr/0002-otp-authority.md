# ADR 0002 — Use OTP for semantic coordination, not frame simulation

**Status:** Accepted for initial research.

Glacier remains responsible for local rendering, physics, AI and game simulation. OTP coordinates mission/session lifecycle, semantic world facts, telemetry, persistence and multiplayer authority.

High-frequency transform replication may pass through Relay, but BEAM will not attempt to reproduce Glacier's frame simulation.

# ADR 0003 — Establish a versioned semantic event/command protocol

**Status:** Accepted for initial research.

The protocol is the project's primary abstraction. Engine-specific observations are normalized into semantic events; commands travel in the opposite direction.

Requirements:
- explicit protocol version,
- stable entity identity strategy,
- timestamps/ticks where meaningful,
- source/client identity,
- schema validation,
- forward-compatible extension strategy,
- separate reliability policy for continuous versus semantic state.

Serialization and transport are intentionally undecided until M1 measurements.

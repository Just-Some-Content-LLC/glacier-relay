# ADR 0001 — Keep Glacier access behind a native adapter

**Status:** Accepted for initial research.

Glacier runtime manipulation requires native, version-sensitive, unsafe operations. Glacier Relay will keep those concerns in a narrow adapter derived from/compatible with ZHMModSDK and communicate with BEAM out of process.

Raw pointers, vtables, memory addresses and reconstructed engine layouts must not become protocol fields.

Consequences: some C++ remains initially; a future Rust adapter is possible, but rewriting proven upstream machinery is not an early objective.

# Security

This project experiments with native hooks and reverse-engineered runtime structures. Expect crashes and data loss during development.

- Develop against legitimate local game installations.
- Do not expose experimental Relay listeners directly to the public internet.
- Treat all native-adapter messages as untrusted until validated.
- Never deserialize raw pointers or arbitrary memory addresses supplied over the network.
- Keep experimental multiplayer isolated from production/personal infrastructure.
- Report security-sensitive findings privately to the maintainers before public disclosure when appropriate.

The project is not intended to bypass platform security, anti-cheat systems, licensing, or account protections.

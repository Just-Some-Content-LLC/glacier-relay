# Glacier Relay — BEAM side

The Elixir/OTP backend of Glacier Relay. M1 scope: receive one semantic event (`mission.playing`) from the native adapter over TCP loopback and surface it inside BEAM. Design: `../docs/design/M1_FIRST_SEMANTIC_EVENT.md`.

Deliberately small: OTP primitives only. No Phoenix, no Ecto, no database, no distributed Erlang.

## Toolchain

Runs in WSL2 (Ubuntu 20.04.6). Windows owns the game and the native adapter; WSL2 owns this application.

| Component | Version | Source |
|---|---|---|
| Erlang/OTP | 28.4.2 (erts 16.3.1) | precompiled `builds.hex.pm/builds/otp/ubuntu-20.04/OTP-28.4.2.tar.gz`, installed with `./Install -minimal` to `~/.local/opt/otp-28.4.2` |
| Elixir | 1.19.6 (compiled with OTP 28) | precompiled `builds.hex.pm/builds/elixir/v1.19.6-otp-28.zip` to `~/.local/opt/elixir-1.19.6` |

No root was needed. `~/.local/opt/beam-env.sh` prepends both to `PATH`; it is sourced from `~/.zshrc`. Checksums were verified against `builds.txt` before installation.

```sh
source ~/.local/opt/beam-env.sh
cd relay
mix test
iex -S mix
```

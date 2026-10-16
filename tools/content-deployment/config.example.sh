# Local configuration for the content-deployment tooling (copy, edit, `source` it; never commit a copy with real paths
# if they identify a machine or a user). Every script also takes its target directories as explicit arguments; these
# variables cover only the fixed local installations the scripts cannot derive.
#
# The HITMAN installation root (the directory holding Runtime/ and Retail/). Passed as an argument to every script
# that reads or changes it; kept here for convenience only.
export GLACIER_GAME_DIR="/mnt/c/Program Files (x86)/Steam/steamapps/common/HITMAN 3"
# The relay application (the directory holding mix.exs). Default: ../../relay relative to this tooling directory.
#export GLACIER_RELAY_DIR=/path/to/glacier-relay/relay
# The relay node name (the node is started with --sname relay). Default: relay@<this host's short name>.
#export GLACIER_RELAY_NODE=relay@HOST
# The BEAM toolchain environment file, sourced when present (PATH to OTP and Elixir).
#export GLACIER_BEAM_ENV=$HOME/.local/opt/beam-env.sh
# The directory holding the frozen native probe and test executables (GlacierRelayCommandProbe.exe,
# GlacierRelayTests.exe) for the tooling dry run; required by dry-run-m6c3.sh.
#export GLACIER_NATIVE_DIR=/path/to/preserved/native

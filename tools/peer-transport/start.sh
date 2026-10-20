#!/bin/sh
# M7-L1 — start ONE transport-only peer in the foreground (operator tooling; README.md). POSIX sh (macOS /bin/sh, bash 3.2, WSL).
#   start.sh <bundle-dir> <run-config.json> <run-config-sha256>
# Prints the exact command, then runs it from the bundle's own directory with the user's Erlang/Elixir flag and library variables
# removed (ERL_AFLAGS, ERL_FLAGS, ERL_ZFLAGS, ELIXIR_ERL_OPTIONS, ERL_LIBS: none can add a node name, an emulator flag or a module
# path) and crash dumps off (ERL_CRASH_DUMP_BYTES=0: a dump would hold the private key), so the peer is never distributed and
# leaves no dump. It refuses a user Erlang boot file (~/.erlang, or .erlang in the user config directory: it would run before
# peer.exs's checks) and a version manager's shim (set GLACIER_PEER_ELIXIR to the real elixir instead). Every other check happens
# inside peer.exs before any socket; the run ends by itself (its exit status is this script's). Stop it early with
# stop.sh <out_dir> (from another terminal) — never with a pattern kill.
set -eu
[ "$#" -eq 3 ] || { echo "usage: start.sh <bundle-dir> <run-config.json> <run-config-sha256>" >&2; exit 2; }
B=$1; CFG=$2; SHA=$3
case "$B" in /*) ;; *) echo "start.sh: the bundle directory must be absolute" >&2; exit 2;; esac
case "$CFG" in /*) ;; *) echo "start.sh: the run configuration path must be absolute" >&2; exit 2;; esac
[ -f "$B/kit/peer.exs" ] && [ -d "$B/ebin/glacier_relay" ] || { echo "start.sh: $B is not a peer-transport bundle" >&2; exit 2; }
ELIXIR=${GLACIER_PEER_ELIXIR:-$(command -v elixir)} || { echo "start.sh: elixir not found on PATH" >&2; exit 2; }
case "$ELIXIR" in /*) ;; *) echo "start.sh: the elixir path must be absolute: $ELIXIR" >&2; exit 2;; esac
case "$ELIXIR" in *asdf*|*mise*|*rtx*|*/shims/*) echo "start.sh: REFUSED: $ELIXIR looks like a version manager's shim; set GLACIER_PEER_ELIXIR to the real elixir (see compat-check.sh)" >&2; exit 2;; esac
for rc in "$HOME/.erlang" "${XDG_CONFIG_HOME:-$HOME/.config}/erlang/.erlang" "$HOME/Library/Application Support/erlang/.erlang"; do
  [ -e "$rc" ] && { echo "start.sh: REFUSED: an Erlang boot file exists ($rc); it would run before the peer's checks" >&2; exit 2; }
done
cd "$B"
echo "start.sh: $(date -u +%Y-%m-%dT%H:%M:%SZ) running from $B:"
echo "  env -u ERL_AFLAGS -u ERL_FLAGS -u ERL_ZFLAGS -u ELIXIR_ERL_OPTIONS -u ERL_LIBS ERL_CRASH_DUMP_BYTES=0 $ELIXIR -pa $B/ebin/glacier_relay $B/kit/peer.exs $CFG $SHA"
exec env -u ERL_AFLAGS -u ERL_FLAGS -u ERL_ZFLAGS -u ELIXIR_ERL_OPTIONS -u ERL_LIBS ERL_CRASH_DUMP_BYTES=0 \
  "$ELIXIR" -pa "$B/ebin/glacier_relay" "$B/kit/peer.exs" "$CFG" "$SHA"

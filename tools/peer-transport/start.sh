#!/bin/sh
# M7-L1 — start ONE transport-only peer in the foreground (operator tooling; README.md). POSIX sh (macOS /bin/sh, bash 3.2, WSL).
#   start.sh <bundle-dir> <run-config.json> <run-config-sha256>
# Prints the exact command, then runs it from the bundle's own directory with the user's Erlang/Elixir flag variables removed
# (ERL_AFLAGS, ERL_FLAGS, ERL_ZFLAGS, ELIXIR_ERL_OPTIONS: none of them can add a node name or other emulator flag), so the peer is
# never distributed. Every check happens inside peer.exs before any socket; the run ends by itself (its exit status is this
# script's). Stop it early with stop.sh <out_dir> (from another terminal) — never with a pattern kill.
set -eu
[ "$#" -eq 3 ] || { echo "usage: start.sh <bundle-dir> <run-config.json> <run-config-sha256>" >&2; exit 2; }
B=$1; CFG=$2; SHA=$3
case "$B" in /*) ;; *) echo "start.sh: the bundle directory must be absolute" >&2; exit 2;; esac
case "$CFG" in /*) ;; *) echo "start.sh: the run configuration path must be absolute" >&2; exit 2;; esac
[ -f "$B/kit/peer.exs" ] && [ -d "$B/ebin/glacier_relay" ] || { echo "start.sh: $B is not a peer-transport bundle" >&2; exit 2; }
ELIXIR=$(command -v elixir) || { echo "start.sh: elixir not found on PATH" >&2; exit 2; }
cd "$B"
echo "start.sh: $(date -u +%Y-%m-%dT%H:%M:%SZ) running from $B:"
echo "  env -u ERL_AFLAGS -u ERL_FLAGS -u ERL_ZFLAGS -u ELIXIR_ERL_OPTIONS $ELIXIR -pa $B/ebin/glacier_relay $B/kit/peer.exs $CFG $SHA"
exec env -u ERL_AFLAGS -u ERL_FLAGS -u ERL_ZFLAGS -u ELIXIR_ERL_OPTIONS "$ELIXIR" -pa "$B/ebin/glacier_relay" "$B/kit/peer.exs" "$CFG" "$SHA"

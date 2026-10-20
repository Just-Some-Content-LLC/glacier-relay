#!/bin/sh
# M7-L3 — the operator's ONE go for the game-facing peer's course (operator tooling; README.md). POSIX sh (macOS /bin/sh, WSL).
#   go.sh <out_dir>
# Checks that <out_dir>/peer.pid names a running game-facing peer of that configuration (as stop.sh does: its command line names
# kit/game-peer.exs and the configuration), then creates <out_dir>/go.request exclusively. The peer takes it within about 50 ms,
# judges it (refused before identification, while the share's stream is open, or after a course: one go per run, a refused go is
# final) and prints its decision in its own terminal; go.taken records it. A second go.sh is refused here while go.request or
# go.taken exists. This script sends nothing over the network and signals no process.
set -eu
[ "$#" -eq 1 ] || { echo "usage: go.sh <out_dir>" >&2; exit 2; }
O=$1
F=$O/peer.pid
[ -f "$F" ] || { echo "go.sh: no $F" >&2; exit 2; }
PID=$(sed -n 1p "$F"); CFG=$(sed -n 2p "$F")
case "$PID" in ''|*[!0-9]*) echo "go.sh: $F does not hold a process id" >&2; exit 2;; esac
[ -n "$CFG" ] || { echo "go.sh: REFUSED: $F names no run configuration (line 2)" >&2; exit 2; }
CMD=$(ps -p "$PID" -o command= 2>/dev/null || true)
case "$CMD" in
  *kit/game-peer.exs*"$CFG"*) ;;
  '') echo "go.sh: REFUSED: process $PID is not running" >&2; exit 2;;
  *) echo "go.sh: REFUSED: process $PID is not this game-facing peer (command: $(printf '%s' "$CMD" | cut -c1-160))" >&2; exit 2;;
esac
[ -e "$O/go.taken" ] && { echo "go.sh: REFUSED: a go was already taken ($(cat "$O/go.taken")); one go per run" >&2; exit 2; }
[ -e "$O/go.request" ] && { echo "go.sh: REFUSED: a go request is already waiting ($O/go.request)" >&2; exit 2; }
( set -C; printf '%s go requested by the operator for %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CFG" > "$O/go.request" ) \
  || { echo "go.sh: REFUSED: could not create $O/go.request exclusively" >&2; exit 2; }
echo "go.sh: $(date -u +%Y-%m-%dT%H:%M:%SZ) go requested for process $PID (the peer prints its decision in its own terminal)"
i=0; while [ "$i" -lt 30 ] && [ ! -e "$O/go.taken" ]; do sleep 0.1; i=$((i + 1)); done
if [ -e "$O/go.taken" ]; then echo "go.sh: the peer's decision: $(cat "$O/go.taken")"; else echo "go.sh: the peer has not taken the request within 3 s (see its terminal)"; fi

#!/bin/sh
# M7-L1 — stop ONE transport-only peer by its own recorded process id (operator tooling; README.md). POSIX sh.
#   stop.sh <out_dir>
# Reads <out_dir>/peer.pid (written by peer.exs: the BEAM's OS process id, then the run configuration path), checks that this
# process's command line is exactly that peer (it names kit/peer.exs and that configuration), sends TERM, waits up to 10 s, and
# only then KILLs that one process id. Never a pattern kill, never another process; an absent process is reported, not an error.
set -eu
[ "$#" -eq 1 ] || { echo "usage: stop.sh <out_dir>" >&2; exit 2; }
F=$1/peer.pid
[ -f "$F" ] || { echo "stop.sh: no $F" >&2; exit 2; }
PID=$(sed -n 1p "$F"); CFG=$(sed -n 2p "$F")
case "$PID" in ''|*[!0-9]*) echo "stop.sh: $F does not hold a process id" >&2; exit 2;; esac
# verifier V7: without the configuration path the identity check would match any kit peer
[ -n "$CFG" ] || { echo "stop.sh: REFUSED: $F names no run configuration (line 2)" >&2; exit 2; }
is_peer() { c=$(ps -p "$PID" -o command= 2>/dev/null || true); case "$c" in *kit/peer.exs*"$CFG"*) return 0;; *) return 1;; esac; }
CMD=$(ps -p "$PID" -o command= 2>/dev/null || true)
if [ -z "$CMD" ]; then echo "stop.sh: process $PID is not running (already ended)"; exit 0; fi
case "$CMD" in
  *kit/peer.exs*"$CFG"*) ;;
  *) echo "stop.sh: REFUSED: process $PID is not this peer (command: $(printf '%s' "$CMD" | cut -c1-160))" >&2; exit 2;;
esac
echo "stop.sh: $(date -u +%Y-%m-%dT%H:%M:%SZ) TERM to $PID (the peer of $CFG)"
kill -TERM "$PID" 2>/dev/null || true
i=0
while [ "$i" -lt 100 ] && ps -p "$PID" >/dev/null 2>&1; do sleep 0.1; i=$((i + 1)); done
if ps -p "$PID" >/dev/null 2>&1; then
  # the identity again, right before the KILL: a reused process id is never killed
  if is_peer; then
    echo "stop.sh: still running after 10 s: KILL to $PID"
    kill -KILL "$PID" 2>/dev/null || true
  else
    echo "stop.sh: process $PID is no longer that peer; not killed" >&2; exit 1
  fi
fi
ps -p "$PID" >/dev/null 2>&1 && { echo "stop.sh: process $PID did not end" >&2; exit 1; }
echo "stop.sh: process $PID ended"

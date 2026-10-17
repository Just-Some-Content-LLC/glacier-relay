#!/bin/bash
# Starts the relay node for the M6-B2 controlled READ-ONLY run (and for its tooling dry run): recorder on
# (M4, unchanged), command subtree on (GLACIER_RELAY_COMMAND=1), EFFECTFUL AUTHORITY OFF (the variable
# unset; the authority reports effectful enabled false and player.outfit.set/2 is never issuable), the run
# token read from <state-root>/token (GLACIER_RELAY_COMMAND_TOKEN_FILE; read once by the authority for the
# protocol-v2 attestation, never logged), dashboard off, the in-node watcher loaded. Waits for the wire
# listener (4747) and the command listener (4749), checks 4748 stays unbound, and checks the authority
# reports the token as configured from the file with the effectful authority disabled.
#   start-beam.sh <evidence-dir> <state-root> [effectful]
# M6-F: the optional third argument "effectful" starts the node with the EFFECTFUL AUTHORITY ON
# (GLACIER_RELAY_COMMAND_EFFECTFUL=1; the C-3 shape) for the M6-F tooling dry run and, under its own
# authorization, the M6-F1b run; absent, the authority stays off exactly as before.
set -u
E="$1"; S="$2"; MODE="${3:-inert}"
T="$(cd "$(dirname "$0")" && pwd)"
RELAY=${GLACIER_RELAY_DIR:-$(cd "$T/../.." && pwd)/relay}
BEAM_ENV=${GLACIER_BEAM_ENV:-$HOME/.local/opt/beam-env.sh}; [ -f "$BEAM_ENV" ] && source "$BEAM_ENV"
cd "$RELAY" || exit 1
pgrep -a beam.smp > /dev/null && { echo "ABORT: beam.smp already running"; exit 1; }
ss -ltn | grep -qE ':4747 |:4748 |:4749 ' && { echo "ABORT: a run port is bound"; exit 1; }
[ -f "$S/token" ] && grep -qE '^[0-9a-f]{64}$' "$S/token" || { echo "ABORT: no valid token file at $S/token"; exit 1; }
[ "$(stat -c %a "$S/token")" = "600" ] || { echo "ABORT: token file mode is $(stat -c %a "$S/token"), expected 600"; exit 1; }
if [ "$MODE" = effectful ]; then
  env -u GLACIER_RELAY_DASHBOARD GLACIER_RELAY_RECORD=1 GLACIER_RELAY_RECORD_DIR="$S/rec" GLACIER_RELAY_COMMAND=1 GLACIER_RELAY_COMMAND_JOURNAL_DIR="$S/commands" \
    GLACIER_RELAY_COMMAND_EFFECTFUL=1 GLACIER_RELAY_COMMAND_TOKEN_FILE="$S/token" \
    nohup elixir --sname relay -S mix run --no-halt "$T/m5b_watch.exs" > "$E/beam.log" 2>&1 &
else
  env -u GLACIER_RELAY_DASHBOARD -u GLACIER_RELAY_COMMAND_EFFECTFUL GLACIER_RELAY_RECORD=1 GLACIER_RELAY_RECORD_DIR="$S/rec" GLACIER_RELAY_COMMAND=1 GLACIER_RELAY_COMMAND_JOURNAL_DIR="$S/commands" \
    GLACIER_RELAY_COMMAND_TOKEN_FILE="$S/token" \
    nohup elixir --sname relay -S mix run --no-halt "$T/m5b_watch.exs" > "$E/beam.log" 2>&1 &
fi
echo $! > "$E/beam.pid"
echo "beam launcher pid $(cat "$E/beam.pid") started $(date -u +%FT%TZ) (effectful authority $([ "$MODE" = effectful ] && echo ON || echo OFF); token from file; dashboard off)"
for _ in $(seq 1 300); do ss -ltn | grep -q ':4747 ' && ss -ltn | grep -q ':4749 ' && break; sleep 0.1; done
echo "listening (WSL): $(ss -ltn | grep -E ':4747 |:4748 |:4749 ' | awk '{print $4}' | tr '\n' ' ')"
ss -ltn | grep -q ':4748 ' && echo "WARNING: 4748 is bound (dashboard?)" || echo "4748 not bound (dashboard disabled)"
sleep 1; grep -E 'listening|recorder:|command journal:|watch:' "$E/beam.log" | cut -c1-300
grep -q 'token_source: :file' "$E/beam.log" && grep -q 'token_configured: true' "$E/beam.log" && echo "authority: token configured from the file" || echo "WARNING: the authority does not report token_source :file / token_configured true"
grep -o 'effectful: %{[^}]*}' "$E/beam.log" | head -1
if [ "$MODE" = effectful ]; then
  grep -q 'effectful: %{enabled: true' "$E/beam.log" && echo "authority: effectful enabled true" || echo "WARNING: the authority does not report effectful enabled true"
else
  grep -q 'effectful: %{enabled: false' "$E/beam.log" && echo "authority: effectful enabled false" || echo "WARNING: the authority does not report effectful enabled false"
fi
grep -qiE 'token file|not 64 lowercase' "$E/beam.log" && echo "WARNING: token file error logged" || echo "no token file error logged"

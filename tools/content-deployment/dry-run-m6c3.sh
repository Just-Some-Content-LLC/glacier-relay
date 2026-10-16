#!/bin/bash
# M6-C2: dry run of the M6-C3 operator tooling against the FROZEN M6-B1 hardening command probe (no DLL, no game,
# no real token, no content). The BEAM node as the run starts it (recorder, command subtree, EFFECTFUL OFF, token
# from a file) in a throwaway state root with an EPHEMERAL token. Phases: (1) the probe's "restart" mission world
# with the FAKE candidate present — the R4/R5/R6 sequence: arm, players (slots recorded), entity (candidate
# expected PRESENT: lookup facts as EVIDENCE), outfit, the cross-check; then after the scripted restart (a new
# fake generation) the same pair again and the cross-check against the previous one (the same authored
# candidate under a NEW generation; the local hero unchanged); (2) the menu world: the candidate absent as
# expected (the R3/R7 shape); (3) "extra-slot": slot 1 occupied — recorded as a FINDING, not a stop;
# (4) the candidate present where absence is expected: the M6-B2 stop detection still fires; (5) 70 + the
# candidate: the scan bound with the candidate found inside the prefix. Then the journal (0 effectful), the
# native probe logs (0 FAULT/ERROR; WARN = the benign shutdown notices only), token scans, the frozen native
# tests once, teardown. Every expectation is a check; exit code zero never counts as a pass.
#   dry-run-m6c3.sh <dry-run-evidence-dir> <throwaway-state-root>
#   GLACIER_NATIVE_DIR (required): the directory holding the frozen GlacierRelayCommandProbe.exe and GlacierRelayTests.exe
#   GLACIER_RELAY_DIR (default ../../relay from this script), GLACIER_RELAY_NODE (default relay@<this host>),
#   GLACIER_BEAM_ENV (default ~/.local/opt/beam-env.sh, sourced when present). WSL: cmd.exe, tasklist.exe, wslpath.
set -u
T="$(cd "$(dirname "$0")" && pwd)"
D=${1:?dry-run evidence dir}; SD=${2:?throwaway state root}
NATIVE=${GLACIER_NATIVE_DIR:?set GLACIER_NATIVE_DIR to the directory holding the frozen probe and test executables}
RELAY=${GLACIER_RELAY_DIR:-$(cd "$T/../.." && pwd)/relay}
NODE=${GLACIER_RELAY_NODE:-relay@$(hostname -s)}
BEAM_ENV=${GLACIER_BEAM_ENV:-$HOME/.local/opt/beam-env.sh}; [ -f "$BEAM_ENV" ] && source "$BEAM_ENV"
mkdir -p "$D"; out=$D/dry-run.txt; [ -e "$out" ] && { echo "ABORT: $out exists (retain the previous pass first)"; exit 1; }; : > "$out"; fail=0
TW=$(wslpath -w "$T"); DW=$(wslpath -w "$D"); NW=$(wslpath -w "$NATIVE")
say() { echo "$(date -u +%H:%M:%S.%3NZ) $*" | tee -a "$out"; }
bad() { say "FAIL: $*"; fail=$((fail + 1)); }
op() { local l=$1; shift; (cd "$RELAY" && elixir --sname "op-$l" -S mix run --no-start "$T/cmd.exs" "$D" "$l" "$@") > "$D/op-$l.out" 2>&1; echo "op $l rc=$?: $(grep -E 'EVIDENCE|refused|issued|-> ' "$D/op-$l.out" | sed -E 's/^[0-9T:.-]+Z [^ ]+ //' | cut -c1-160 | tr '\n' '|' | cut -c1-1600)" | tee -a "$out"; }
xc() { local l=$1; shift; python3 -I "$T/xcheck.py" "$D" "$l" "$@" > "$D/xc-$l.out" 2>&1; echo "xcheck $l rc=$?: $(tail -1 "$D/xc-$l.out"); NOT: $(grep -o 'EVIDENCE [^:]*: NOT' "$D/xc-$l.out" | sed 's/EVIDENCE //; s/: NOT//' | tr '\n' ' ')" | tee -a "$out"; }
rpcwait() { local i; for i in $(seq 1 "$2"); do r=$(elixir --sname "dr-w$RANDOM" -e "true = :net_kernel.connect_node(:\"$NODE\"); s = :rpc.call(:\"$NODE\", GlacierRelay.Command, :status, []); IO.puts(if $1, do: \"yes\", else: \"no\")" 2>/dev/null | tail -1); [ "$r" = yes ] && return 0; sleep 1; done; return 1; }
linkgone() { rpcwait 's.link == nil' 120; }
stop_beam() { elixir --sname "dr-stop$RANDOM" -e "case :net_kernel.connect_node(:\"$NODE\") do true -> :rpc.call(:\"$NODE\", :init, :stop, []); IO.puts(\"init.stop sent\"); _ -> IO.puts(\"relay node not reachable\") end" 2>/dev/null | tail -1; for _ in $(seq 1 60); do pgrep -q beam.smp || break; sleep 0.5; done; }
rval() { python3 -c "import json,sys; o=json.load(open(sys.argv[1])); v=o.get(sys.argv[2]); print('' if v is None else v)" "$1" "$2"; }
jval() { python3 -c "import json,sys; o=json.load(open(sys.argv[1])); f=o.get(sys.argv[2]); print(f.get('value','') if isinstance(f,dict) else ('' if f is None else f))" "$1" "$2"; }
nots() { grep -c 'EVIDENCE .*: NOT' "$1"; }
notnames() { grep -o 'EVIDENCE [^:]*: NOT' "$1" | sed 's/EVIDENCE //; s/: NOT//' | tr '\n' ' '; }
export WSLENV="${WSLENV:+$WSLENV:}GLACIER_PROBE_TOKEN"
probe() { PSTART=$(date +%s); GLACIER_PROBE_TOKEN="$6" cmd.exe /c "$TW\\run-probe-m6c3.cmd $DW\\nativelogs $NW\\GlacierRelayCommandProbe.exe 4749 $3 $4 $2 inert ok $5" > "$D/probe-$1.txt" 2>&1 & PROBE=$!; }
probe_done() { wait $PROBE; say "probe $1 exit $?: $(tr -d '\r' < "$D/probe-$1.txt" | grep -E '^command probe: (done|link|queue|result|players-mode|fake relay transition)' | cut -c1-200 | tr '\n' '|' | cut -c1-1200)"; linkgone && say "link gone after probe $1" || bad "link still present after probe $1"; }
waitlink() { rpcwait 's.trust.peer == :identified and s.trust.token_verified == true' 40 && say "$1: probe identified and token_verified" || bad "$1: no token-verified link within 40 s"; }

say "dry run start; relay $(git -C "$RELAY" rev-parse HEAD) ($(git -C "$RELAY" status --porcelain | wc -l) uncommitted); probe $(sha256sum "$NATIVE/GlacierRelayCommandProbe.exe" | cut -c1-16)… (frozen); cmd.exs $(sha256sum "$T/cmd.exs" | cut -c1-16)… xcheck.py $(sha256sum "$T/xcheck.py" | cut -c1-16)…"
ss -ltn | grep -qE ':4747 |:4748 |:4749 ' && { bad "ports bound before start"; exit 1; }
pgrep -a beam.smp > /dev/null && { bad "beam.smp running before start"; exit 1; }
tasklist.exe 2>/dev/null | grep -qi 'HITMAN3.exe' && { bad "HITMAN running"; exit 1; }
(cd "$RELAY" && mix compile --warnings-as-errors > "$D/compile.txt" 2>&1) && say "compile ok" || bad "compile failed"
mkdir -p "$D/nativelogs" "$D/nativelogs-tests"
rm -rf "$SD"; mkdir -p "$SD/rec" "$SD/commands"; chmod 700 "$SD" "$SD/rec" "$SD/commands"
"$T/provision-secret.sh" "$SD" | tee -a "$out"
"$T/start-beam.sh" "$D" "$SD" | tee -a "$out"
grep -q 'authority: token configured from the file' "$out" && grep -q 'authority: effectful enabled false' "$out" && say "BEAM: the file token with the effectful authority OFF" || bad "BEAM did not report the file token with the effectful authority off"
op d-pre status
grep -q 'effectful %{enabled: false' "$D/op-d-pre.out" && grep -q 'token_source: :file' "$D/op-d-pre.out" && grep -q '; link nil;' "$D/op-d-pre.out" && say "pre-launch status: effectful disabled, token from file, no link" || bad "pre-launch status unexpected"
TOK="$(tr -d '\n' < "$SD/token")"

# ---- phase 1: Paris with the FAKE candidate present, then the scripted restart (one probe process, 6 s fake frames) ----
probe p1 restart 6000 170000 candidate-present "$TOK"
waitlink p1
op r1-arm arm
op r1-players players 9000 recorded
op r1-entity entity - - 9000 present
op r1-outfit outfit - - 9000
GEN1=$(rval "$D/r1-players-result.json" mission_generation); say "phase 1 generation before the restart: $GEN1 (ops ended $(( $(date +%s) - PSTART )) s after the probe start; must be < 48 s = fake frame 8)"
[ $(( $(date +%s) - PSTART )) -lt 48 ] || bad "the first pair did not finish before the scripted restart (timing)"
xc r1-x --players r1-players --entity r1-entity --outfit r1-outfit --expected-gen "$GEN1" --candidate-expect present
while [ $(( $(date +%s) - PSTART )) -lt 100 ]; do sleep 1; done; say "waited for the scripted restart (fake frame 16 = 96 s)"
op r2-players players 9000 recorded
op r2-entity entity - - 9000 present
op r2-outfit outfit - - 9000
GEN2=$(rval "$D/r2-players-result.json" mission_generation); say "phase 1 generation after the restart: $GEN2"
[ -n "$GEN1" ] && [ -n "$GEN2" ] && [ "$GEN1" != "$GEN2" ] && say "a new generation after the restart" || bad "no new generation after the scripted restart"
xc r2-x --players r2-players --entity r2-entity --outfit r2-outfit --expected-gen "$GEN2" --prev-players r1-players --prev-entity r1-entity --session-expect different --candidate-expect present
op r1-disarm disarm
probe_done p1
J=$D/r1-entity-observed.json
[ "$(jval "$J" cand_brick_present)" = True ] && [ "$(jval "$J" cand_resolved)" = True ] && [ "$(jval "$J" cand_hitman5)" = True ] && [ "$(jval "$J" cand_distinct_from_local)" = True ] && [ "$(jval "$J" cand_index_check)" = in_range ] && [ "$(jval "$J" brick_count)" = 24 ] && say "phase 1: the FAKE candidate present (24 bricks), resolved, hitman5, distinct, in range — the M6-C3 R4/R5 fields" || bad "phase 1: candidate fields not as scripted"
[ "$(nots "$D/op-r1-entity.out")" = 0 ] && [ "$(nots "$D/op-r2-entity.out")" = 0 ] && [ "$(jval "$J" cand_character_id)" = "787c1ff2-467c-421d-98f4-6bbb92e5fc99" ] && say "phase 1: 0 NOT on both entity reads (the frozen probe scripts the candidate with the AUTHORED character guid and transform, so every candidate EVIDENCE line is ok)" || bad "phase 1: unexpected entity NOT set: $(notnames "$D/op-r1-entity.out")/ $(notnames "$D/op-r2-entity.out")"
[ "$(nots "$D/xc-r1-x.out")" = 0 ] && [ "$(nots "$D/xc-r2-x.out")" = 0 ] && say "phase 1: both cross-checks 0 NOT (candidate distinct on the same frame; the same authored candidate under the new generation; slot 0 unchanged)" || bad "phase 1: cross-check NOT lines: $(notnames "$D/xc-r1-x.out") / $(notnames "$D/xc-r2-x.out")"

# ---- phase 2: the menu world, candidate absent as expected (the R3 / R7 shape) --------------------------------------
probe p2 menu 1000 60000 default "$TOK"
waitlink p2
op m-link linkcheck
op m-arm arm
op m-players players 9000 recorded
op m-entity entity - - 9000 absent
xc m-x --players m-players --entity m-entity --candidate-expect absent
op m-disarm disarm
probe_done p2
[ "$(nots "$D/op-m-entity.out")" = 0 ] && [ "$(nots "$D/op-m-players.out")" = 0 ] && [ "$(nots "$D/xc-m-x.out")" = 0 ] && say "phase 2: the candidate absent as expected at the menu (0 NOT)" || bad "phase 2: unexpected NOT lines"

# ---- phases 3-5: one probe each -------------------------------------------------------------------------------------------
scenario() { # <label> <players-mode> <entity-expect>
  probe "$1" mission 1000 50000 "$2" "$TOK"; waitlink "$1"
  op "$1-arm" arm; op "$1-players" players 9000 recorded; op "$1-entity" entity - - 9000 "$3"; op "$1-disarm" disarm; probe_done "$1"
}
scenario x1 extra-slot absent
[ "$(notnames "$D/op-x1-players.out")" = "players.slots-1-3-as-experiment-4 " ] && grep -q 'players.slots-1-3-recorded: ok' "$D/op-x1-players.out" && grep -q 'populated \[1\]' "$D/op-x1-players.out" && say "phase 3: slot 1 occupied is RECORDED as a finding (presence is not identity), not a stop" || bad "phase 3: slot recording not as expected: $(notnames "$D/op-x1-players.out")"
scenario s1 candidate-present absent
[ "$(notnames "$D/op-s1-entity.out")" = "entity.candidate-not-present entity.candidate-lookup-not-performed " ] && say "phase 4: a present candidate where absence is expected still trips exactly the two M6-B2 stop conditions" || bad "phase 4: stop detection changed: $(notnames "$D/op-s1-entity.out")"
scenario c1 bricks-oversized-candidate present
[ "$(jval "$D/c1-entity-observed.json" brick_count)" = 71 ] && [ "$(jval "$D/c1-entity-observed.json" bricks_scanned)" = 64 ] && [ "$(jval "$D/c1-entity-observed.json" cand_brick_present)" = True ] && [ "$(notnames "$D/op-c1-entity.out")" = "entity.scan-complete " ] && say "phase 5: 71 bricks scanned 64, the candidate found inside the prefix: presence positive, the scan bound the one FINDING" || bad "phase 5: not as expected: $(notnames "$D/op-c1-entity.out")"

# ---- journal, native logs, tests, token scans, teardown -------------------------------------------------------------------
op d-final status
stop_beam | tee -a "$out"
cp "$(ls -t "$SD"/commands/commands-*.ndjson | head -1)" "$D/journal-dryrun.ndjson"
say "journal: $(wc -l < "$D/journal-dryrun.ndjson") entries; events $(python3 -c "import json,sys,collections; c=collections.Counter(json.loads(l)['event'] for l in open(sys.argv[1]) if l.strip()); print(dict(sorted(c.items())))" "$D/journal-dryrun.ndjson")"
[ "$(grep -c 'player.outfit.set' "$D/journal-dryrun.ndjson")" = 0 ] && [ "$(grep -c '"authority.effectful' "$D/journal-dryrun.ndjson")" = 0 ] && say "journal: 0 effectful entries" || bad "journal: an effectful entry"
say "EVIDENCE NOT lines across the operator actions: $(nots "$D/operator-actions.log") — $(notnames "$D/operator-actions.log")(expected exactly 4: x1 slots-1-3-as-experiment-4; s1 candidate-not-present + candidate-lookup-not-performed; c1 scan-complete)"
[ "$(nots "$D/operator-actions.log")" = 4 ] && [ "$(notnames "$D/operator-actions.log")" = "players.slots-1-3-as-experiment-4 entity.candidate-not-present entity.candidate-lookup-not-performed entity.scan-complete " ] || bad "unexpected EVIDENCE NOT set: $(notnames "$D/operator-actions.log")"
cmd.exe /c "$TW\\tests-once-m6c3.cmd $DW\\nativelogs-tests $NW\\GlacierRelayTests.exe $DW\\native-tests-once.txt" > "$D/native-tests-once-exit.txt" 2>&1
say "frozen native tests once: $(tr -d '\r' < "$D/native-tests-once-exit.txt" | tr '\n' ' '); last line: $(tr -d '\r' < "$D/native-tests-once.txt" | tail -1 | cut -c1-120)"
grep -q 'EXIT=0' "$D/native-tests-once-exit.txt" && grep -q 'GlacierRelayTests: all checks passed' "$D/native-tests-once.txt" && say "frozen native tests: exit 0, all checks passed" || bad "frozen native tests did not pass"
say "files containing the ephemeral token value: evidence $(grep -rlF -- "$TOK" "$D" 2>/dev/null | wc -l), state root $(grep -rlF -- "$TOK" "$SD/rec" "$SD/commands" 2>/dev/null | wc -l)"
[ "$(grep -rlF -- "$TOK" "$D" 2>/dev/null | wc -l)" = 0 ] || bad "the ephemeral token leaked into the evidence tree"
unset TOK
say "native probe logs: $(ls "$D/nativelogs" | wc -l) files; FAULT/ERROR $(cat "$D"/nativelogs/*.log 2>/dev/null | grep -cE 'FAULT|ERROR'); WARN $(cat "$D"/nativelogs/*.log 2>/dev/null | grep -c 'WARN') (benign shutdown $(cat "$D"/nativelogs/*.log 2>/dev/null | grep -c 'link shutting down')); 'exceeded the result line bound' $(cat "$D"/nativelogs/*.log 2>/dev/null | grep -c 'exceeded the result line bound')"
[ "$(cat "$D"/nativelogs/*.log 2>/dev/null | grep -cE 'FAULT|ERROR')" = 0 ] || bad "a FAULT/ERROR line in a probe log"
[ "$(cat "$D"/nativelogs/*.log 2>/dev/null | grep 'WARN' | grep -vc 'link shutting down')" = 0 ] || bad "a WARN line other than the benign shutdown notice"
rm -rf "$SD"; say "throwaway state root removed: $([ -e "$SD" ] && echo NO || echo yes)"
say "leftovers: beam.smp $(pgrep -c beam.smp); ports $(ss -ltn | grep -cE ':474[789] '); probe exe $(tasklist.exe 2>/dev/null | grep -ci GlacierRelayCommandProbe)"
[ "$(pgrep -c beam.smp)" = 0 ] || bad "beam.smp still running"
if [ "$fail" = 0 ]; then say "DRY RUN RESULT: PASS (0 failures)"; else say "DRY RUN RESULT: FAIL ($fail failure(s))"; fi
exit $fail

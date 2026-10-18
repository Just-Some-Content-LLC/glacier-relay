#!/bin/bash
# follow-matrix.sh — M6-F2a: the focused OFFLINE matrix of the bounded follow-up sampler (cmd-m6f.exs lift-follow + m6f_follow.exs)
# against the FROZEN M6-F1a command probe (m6f1a-offline/native4, 4cb8cc0e…: FAKE frames, FAKE exact-transform world, FAKE
# transform applier — never Glacier's setter, never HITMAN) and the reviewed BEAM application started as a run starts it
# (start-beam.sh … effectful: the effectful authority ON and disarmed, an EPHEMERAL token from a file in a throwaway ext4 directory
# under the stage's state root, removed at the end — also on an abort, by the EXIT trap). Only the probe's existing modes and the
# existing public Command API are used. Every phase has its own node and probe (one lift per authority process is by design), may
# start only when no node and no probe is alive, and ENDS AS SOON AS ITS OUTCOME IS KNOWN (probe-phase.sh: only the phase's own
# processes are stopped — by RPC, by own pid, by the probe's Windows PID found by ancestry — within a deadline; a failed teardown
# is a FAIL; the probe's duration argument is a failsafe). Every expectation is a check written to the report; an exit code is
# never the evidence. The harness's own bytes and every tool's are recorded (tooling.tsv) and copied (harness/) per attempt.
#
#   follow-matrix.sh <active-evidence-root> <state-root> <group> <phase>...
# Phases (the probe's frame interval M6F2A_FRAME_MS, default 10 ms — the run measured ≈ 10.7 ms per frame — except slow):
#   old-path          the M6-F1b tooling as it ran (kit-m6f1b: op.sh / seq-lift.sh / seq-later.sh, byte-identical copies of the
#                     sealed m6f1b-run1 scripts) on the same stack: the measured first later observation of the OLD path
#   kit-held          the next-run kit (kit/: op.sh + seq-lift.sh with lift-follow) end to end: held at every slot; before the
#                     lift a reused output label and a sealed destination are refused without changing their sentinels; after it
#                     a second lift-follow / lift is refused by op.sh and, bypassing op.sh, by the local guard (budget consumed);
#                     with old-path in the same group: the kit's first later observation is compared with the old path's
#   returned | drifted | dirty | near    the probe's transform-later modes (the first read after the fake lift and every later one)
#   slow              700 ms fake frames: late results, missed / delayed slots recorded, no catch-up; the observation target missed
#   fault             the fake setter reports a fault: the original is failed — no read, no retry
#   exit-after-call   the probe terminates right after the fake setter: the original is unknown — no read, no retry
#   disconnect        the probe is terminated (by its PID) after slot 2: the sequence stops before slot 3
#   authority-restart the Authority process is killed after slot 2 (its supervisor restarts it): the sequence stops before slot 3
#   operator-stop     the run's stop marker is written after slot 1: the sequence stops before slot 2
#   no-link           the probe carries a WRONG token: its link never verifies; the phase ends on that outcome after 10 s and its
#                     probe is stopped by the PID found by ancestry — far below its failsafe lifetime; nothing is issued
#   lift-refused      the local guard passes but the AUTHORITY refuses the lift (its binding inspection is older than the
#                     authority's 60 s inspection window, which the local guard does not judge): no follow-up read, the budget 1
# M6-F2b preparation (authorization "M6-F2a Review and Conditional M6-F2b Authorization", items A and D):
#   issue-timeout     the phase's own command Link process is SUSPENDED (sys:suspend, through the authority's state) before
#                     lift-follow starts — none of its pre-lift RPCs touch the link — so the lift's issuance blocks inside the
#                     authority's send beyond the tool's 3 s issuance bound; the tool must report the issuance UNCERTAIN (never
#                     "nothing transmitted"), read nothing and retry nothing; the link is resumed (inside the authority's own 5 s
#                     call bound) and the journal then shows the lift accepted, transmitted and applied: a timeout is not a refusal
#   restore-held      the run kit end to end (op.sh, seq-lift.sh with lift-follow, seq-restore.sh): held at every slot; the
#                     LAST lift-follow sample (r4-lift-s5, through the existing file / result convention) feeds the restoration
#                     after a separate simulated operator approval and a fresh arming: eligibility, the planner and the
#                     authority's binding (a just-in-time inspection iff the sample is over 35 s old), ONE restoration, its later
#                     read-back and the separate restoration facts
#   restore-aged      as restore-held, but the sample is first left to age past the authority's 60 s inspection window: a
#                     DIRECT restoration bound to it (bypassing the wrapper) is refused before transmission (inspection_stale);
#                     the wrapper then takes ONE just-in-time inspection, revalidates it (held, bit-equal) and restores bound to it
#   restore-returned  the samples return to baseline: the wrapper refuses before arming (not held); a DIRECT restoration is not
#                     submitted (already_at_baseline, the authority-side evidence); no restoration in the journal
#   restore-drifted   the samples drift: the wrapper refuses before arming; a DIRECT restoration is refused before transmission
#                     by the authority's own evidence check; no restoration in the journal
# M6-F2b preparation (authorization "M6-F2a Review and Conditional M6-F2b Authorization", item C): tooling.tsv records, besides every
# tool and kit file the phases run: the relay/lib and relay/config TREES at HEAD (the group refuses to start if either, mix.exs or
# mix.lock has an uncommitted change — so the recorded trees are the code that ran), mix.exs and mix.lock, and the runtime files
# (OTP_VERSION, the erts beam.smp, Elixir's VERSION and elixir.app, the python3 binary); runtime.txt the versions as printed.
set -u
E=${1:?active evidence root}; S=${2:?state root}; G=${3:?group}; shift 3; PHASES="$*"
T=/mnt/c/Users/steve/dev/glacier-relay/glacier-relay/tools/content-deployment
H=/mnt/c/Users/steve/AppData/Local/Temp/glacier-m0/hitmen
NATIVE=$H/m6f1a-offline/native4; PROBE=$NATIVE/GlacierRelayCommandProbe.exe; IMG=GlacierRelayCommandProbe.exe
RELAY=/mnt/c/Users/steve/dev/glacier-relay/glacier-relay/relay; KIT=$E/kit; OLD=$E/kit-m6f1b
FRAME_MS=${M6F2A_FRAME_MS:-10}
source "$HOME/.local/opt/beam-env.sh"
. "$T/evidence-guard.sh"; evg_attach "$E" "$S" || exit 3
. "$T/probe-phase.sh"
A=$(evg_attempt "matrix-$G") || exit 3; out=$(evg_out "$A/matrix.txt") || exit 3; tsv=$(evg_out "$A/timing.tsv") || exit 3
fail=0; PD=""; PD_OPEN=0; SD=""; OLD_OBS=""; KIT_OBS=""
say() { echo "$(date -u +%H:%M:%S.%3NZ) $*" | tee -a "$out"; }
bad() { say "FAIL: $*"; fail=$((fail + 1)); }
okc() { if eval "$2"; then say "ok: $1"; else bad "$1"; fi; }
ms() { date +%s%3N; }
NODE=$PP_NODE

# on any exit (an abort, a signal, a set -u stop): this phase's own processes are stopped and the throwaway token removed
cleanup() {
  if [ "$PD_OPEN" = 1 ] && [ -n "$PD" ]; then pp_probe_end "$PD" main 15 > /dev/null; pp_beam_end "$PD" 25 > /dev/null; PD_OPEN=0; say "trap: the open phase's own processes stopped ($(basename "$PD"))"; fi
  if [ -n "$SD" ] && [ -e "$SD" ]; then find "$SD" -name token -type f -exec shred -u {} \; 2>/dev/null; rm -rf "$SD"; fi
}
trap cleanup EXIT
trap 'say "interrupted"; exit 130' INT TERM

harness=$(evg_dir "$A/harness") || exit 3
for f in follow-matrix.sh probe-phase.sh tests/follow_check.py; do cp "$T/$f" "$(evg_out "$harness/$(basename "$f")")"; done
tt=$(evg_out "$A/tooling.tsv") || exit 3
REPO=$(git -C "$RELAY" rev-parse --show-toplevel)
dirty=$(git -C "$REPO" status --porcelain -- relay/lib relay/config relay/mix.exs relay/mix.lock | wc -l)
[ "$dirty" = 0 ] || { echo "ABORT: relay/lib, relay/config, mix.exs or mix.lock has $dirty uncommitted change(s): the tree identities would not be the code that runs"; exit 1; }
ERTS=$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().'); OTPREL=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')
EXDIR=$(dirname "$(dirname "$(readlink -f "$(command -v elixir)")")")
for f in "$T/cmd-m6f.exs" "$T/m6f_follow.exs" "$T/cmd_m6f_args.exs" "$T/cmd.exs" "$T/xcheck.py" "$T/probe-phase.sh" "$T/follow-matrix.sh" "$T/tests/follow_check.py" \
         "$T/run-probe-m6f.cmd" "$T/start-beam.sh" "$T/provision-secret.sh" "$T/evidence-guard.sh" "$KIT/op.sh" "$KIT/seq-lift.sh" "$KIT/ident.exs" \
         "$KIT/seq-restore.sh" "$KIT/restore-eligibility.py" "$KIT/restore-compare.py" "$KIT/decode-transform.exs" \
         "$OLD/op.sh" "$OLD/seq-lift.sh" "$OLD/seq-later.sh" "$OLD/ident.exs" "$OLD/decode-transform.exs" "$OLD/restore-compare.py" "$PROBE" "$RELAY/mix.exs" "$RELAY/mix.lock" \
         "$ERTS/releases/$OTPREL/OTP_VERSION" "$(ls "$ERTS"/erts-*/bin/beam.smp | head -1)" "$EXDIR/VERSION" "$EXDIR/lib/elixir/ebin/elixir.app" "$(readlink -f "$(command -v python3)")"; do
  printf '%s\t%s\t%s\n' "$f" "$(sha256sum "$f" | cut -c1-64)" "$(stat -c %s "$f")" >> "$tt"; done
for d in relay/lib relay/config; do printf 'tree:%s\t%s\ttree\n' "$d" "$(git -C "$REPO" rev-parse "HEAD:$d")" >> "$tt"; done
{ echo "glacier-relay HEAD $(git -C "$REPO" rev-parse HEAD) (uncommitted elsewhere: $(git -C "$REPO" status --porcelain | wc -l) path(s); relay/lib, relay/config, mix.exs, mix.lock: clean)"; elixir --version 2>&1 | grep -E 'Erlang|Elixir'; echo "OTP $(cat "$ERTS/releases/$OTPREL/OTP_VERSION")"; python3 --version; } > "$(evg_out "$A/runtime.txt")"
say "M6-F2a follow-up matrix group $G (attempt $(basename "$A")): phases $PHASES; relay $(git -C "$RELAY" rev-parse --short HEAD) (+$(git -C "$RELAY" status --porcelain | wc -l) uncommitted paths); cmd-m6f.exs $(sha256sum "$T/cmd-m6f.exs" | cut -c1-16)… m6f_follow.exs $(sha256sum "$T/m6f_follow.exs" | cut -c1-16)… follow-matrix.sh $(sha256sum "$T/follow-matrix.sh" | cut -c1-16)… follow_check.py $(sha256sum "$T/tests/follow_check.py" | cut -c1-16)… probe-phase.sh $(sha256sum "$T/probe-phase.sh" | cut -c1-16)… kit seq-lift.sh $(sha256sum "$KIT/seq-lift.sh" | cut -c1-16)… (all in tooling.tsv; the harness copied to harness/); frame interval $FRAME_MS ms"
[ "$(sha256sum "$PROBE" | cut -c1-64)" = 4cb8cc0e435f79e5af1e9a018f8e4218cf5bfc0ee094929e4b7754be063b5a3b ] || { bad "the probe is not the frozen native4 build"; exit 1; }
(cd "$OLD" && sha256sum -c --quiet SOURCE.sha256) || { bad "kit-m6f1b is not byte-identical to the sealed m6f1b-run1 scripts"; exit 1; }
ss -ltn | grep -qE ':4747 |:4748 |:4749 ' && { bad "ports bound before start"; exit 1; }
pgrep -x beam.smp > /dev/null && { bad "beam.smp running before start"; exit 1; }
tasklist.exe 2>/dev/null | grep -qiE 'HITMAN3.exe|GlacierRelayCommandProbe' && { bad "HITMAN or a probe running"; exit 1; }
SD=$S/$(basename "$A"); [ -e "$SD" ] && { bad "throwaway state dir exists: $SD"; SD=""; exit 1; }
mkdir -m 700 "$SD"; bash "$T/provision-secret.sh" "$SD" | tee -a "$out"
TOK=$(tr -d '\n' < "$SD/token")   # the probe's token travels in its environment (WSLENV), never in argv or a file under the evidence root
export GLACIER_PROBE_TOKEN="$TOK" WSLENV="${WSLENV:+$WSLENV:}GLACIER_PROBE_TOKEN"
printf 'phase\tframe_ms\tsetup_ms\tprep_ms\tvm_age_at_send_ms\tlift_call_ms\tterminal_wait_ms\tfirst_request_ms\tfirst_obs_frames\tfirst_obs_native_ms\tslots(outcome:timing:late_ms:class)\trequests\tmissed\tstop\tframe_period_ms\tteardown_probe_ms\tteardown_beam_ms\ttotal_ms\n' > "$tsv"

tool() {   # <phase-dir> <label> <cmd.exs|cmd-m6f.exs> <action> [args] -> op-<label>.out (first line: the start time, ms)
  local pd=$1 l=$2 t=$3 a=$4; shift 4
  local o; o=$(evg_out "$pd/op-$l.out") || return 2
  echo "$(date -u +%FT%T.%3NZ) $l $a $*" > "$o"
  (cd "$RELAY" && elixir --sname "mx-$l-$RANDOM" -S mix run --no-start "$T/$t" "$pd" "$l" "$a" "$@") >> "$o" 2>&1
}
jget() { python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {'d': d}))" "$@" 2>/dev/null; }

phase_start() {   # <name> <frame_ms> <transform-apply-mode> <transform-later> <failsafe_ms> [link: yes|no] -> 0 = the phase is up
  local link=${6:-yes} wrong
  PH=$1; PF=$2; PD=$(evg_dir "$A/$1") || exit 3; NL=$(evg_dir "$PD/nativelogs") || exit 3
  T0=$(ms); T1=$T0; T2=$T0; say "== phase $1: probe frame interval $2 ms, transform-apply-mode $3, transform-later $4 (failsafe lifetime $5 ms; link expected: $link)"
  if pgrep -x beam.smp > /dev/null || tasklist.exe 2>/dev/null | grep -qi "$IMG"; then bad "$1: a node or a probe is still alive before the phase: not started"; return 1; fi
  ST=$SD/$1; mkdir -m 700 "$ST" "$ST/rec" "$ST/commands"; cp "$SD/token" "$ST/token"; chmod 600 "$ST/token"
  PD_OPEN=1
  pp_beam_start "$PD" "$ST" effectful > /dev/null || { bad "$1: BEAM start ($(cut -f2,3 "$PD/lifecycle.tsv" | tail -1))"; return 1; }
  if [ "$link" = no ]; then
    wrong=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')   # a token the node does not hold: never the real one
    GLACIER_PROBE_TOKEN="$wrong" pp_probe_start "$PD" main "$NL" "$PROBE" 4749 "$2" "$5" mission effectful ok candidate-present candidate-present present "$3" "$4" > /dev/null || { bad "$1: probe start ($(cut -f2,3 "$PD/lifecycle.tsv" | tail -1))"; return 1; }
    if pp_wait 10 's = :rpc.call(:"'"$NODE"'", GlacierRelay.Command, :status, []); IO.puts(if is_map(s) and s.trust.token_verified == true, do: "yes", else: "no")'; then bad "$1: a link with the wrong token verified"; return 1; fi
    T1=$(ms); say "$1: the link never verified within 10 s (the expected outcome); probe PID ${PP_PROBE_PID:-unknown} found by ancestry"; return 0
  fi
  pp_probe_start "$PD" main "$NL" "$PROBE" 4749 "$2" "$5" mission effectful ok candidate-present candidate-present present "$3" "$4" > /dev/null || { bad "$1: probe start ($(cut -f2,3 "$PD/lifecycle.tsv" | tail -1))"; return 1; }
  pp_wait 40 's = :rpc.call(:"'"$NODE"'", GlacierRelay.Command, :status, []); IO.puts(if is_map(s) and s.trust.peer == :identified and s.trust.token_verified == true, do: "yes", else: "no")' || { bad "$1: no token-verified link within 40 s"; return 1; }
  pp_probe_link_pid "$PD" main > /dev/null || bad "$1: the link's owner is not the probe PID found by ancestry"
  T1=$(ms); say "$1: node and probe up, link token-verified ($((T1 - T0)) ms); probe PID $PP_PROBE_PID (by ancestry; = the link's owner)"
}

prep() {   # <prefix> [sleep-before-attest-s]: inert arming, the binding inspection, the telemetry stand-in attestation, ONE effectful arming
  local p=$1 wait=${2:-0}
  tool "$PD" "$p-arm" cmd.exs arm
  tool "$PD" "$p-ct" cmd.exs ctransform 9000 present
  INS=$(tr -d '\n' < "$PD/$p-ct-command-id.txt" 2>/dev/null); GEN=$(jget "$PD/$p-ct-result.json" "d['mission_generation']"); AD=$(jget "$PD/$p-ct-result.json" "d['adapter_instance_id']")
  [ "$wait" -gt 0 ] && { say "$PH: waiting ${wait} s so that the binding inspection is older than the authority's 60 s window"; sleep "$wait"; }
  tool "$PD" "$p-attest" cmd-m6f.exs attest "$AD" "matrix: the probe has no telemetry connection; the command result's adapter id stands in ($p-ct-result.json)"
  tool "$PD" "$p-arme" cmd-m6f.exs arm-effectful "$IMG"
  grep -q 'arm_effectful (ttl 30000 ms) -> :ok' "$PD/op-$p-arme.out" && say "$PH: armed ONE effectful operation with the owner-only form 'arm-effectful $IMG' (the default 30000 ms supplied; the M6-F1b finding)" || bad "$PH: owner-only arm-effectful: $(grep -o 'arm.effectful.*' "$PD/op-$p-arme.out" | tail -1 | cut -c1-200)"
  T2=$(ms)
}

journal_check() {   # <phase-dir> <lift label> <lifts> <armings> <consumed> [<inspections after the lift>, default: the follow-up requests] [<restorations>]
  local r
  r=$(python3 -I - "$1" "$2" "$3" "$4" "$5" "${6:-}" "${7:-0}" <<'PY'
import json, sys, glob, os
pd, label, w_lifts, w_arm, w_cons, w_ins, w_res = sys.argv[1:8]
fr = os.path.join(pd, label + "-follow-result.json")
req = int(w_ins) if w_ins else (json.load(open(fr))["requests"] if os.path.exists(fr) else 0)
idf = os.path.join(pd, label + "-command-id.txt")
lid = open(idf).read().strip() if os.path.exists(idf) else None
ents = []
for f in sorted(glob.glob(os.path.join(pd, "journal-*.ndjson"))):
    ents += [json.loads(l) for l in open(f) if l.strip()]
acc = [e for e in ents if e.get("event") == "command.accepted"]
lifts = [e for e in acc if e.get("name") == "candidate.transform.set" and (e.get("params") or {}).get("mode") == "lift"]
restores = [e for e in acc if e.get("name") == "candidate.transform.set" and (e.get("params") or {}).get("mode") == "restore"]
outfit = [e for e in acc if e.get("name") == "player.outfit.set"]
after = []
if lid:
    idx = [i for i, e in enumerate(acc) if e.get("command_id") == lid]
    after = acc[idx[0] + 1:] if idx else []
ins_after = [e for e in after if e.get("name") == "relay.inspect.candidate_transform"]
arm = sum(1 for e in ents if e.get("event") == "authority.armed_effectful")
cons = sum(1 for e in ents if e.get("event") == "authority.effectful_consumed")
res_after = [e for e in after if e in restores]
facts = "lifts=%d inspections_after=%d restores_after=%d other_after=%d restores=%d outfit=%d effectful_armings=%d consumed=%d (expected inspections after the lift %d, restorations %s)" % (len(lifts), len(ins_after), len(res_after), len(after) - len(ins_after) - len(res_after), len(restores), len(outfit), arm, cons, req, w_res)
ok = len(lifts) == int(w_lifts) and len(restores) == len(res_after) == int(w_res) and not outfit and len(after) == len(ins_after) + len(res_after) and len(ins_after) == req and arm == int(w_arm) and cons == int(w_cons)
print(("ok" if ok else "FAIL") + " " + facts)
PY
)
  case "$r" in ok*) say "ok: $PH: the journal (independent of the tool's report): ${r#ok }";; *) bad "$PH: the journal: ${r#FAIL }";; esac
}

phase_end() {   # stop the phase's own processes now; a failed teardown is a FAIL; keep the journal; the teardown times
  local tp tb an
  pp_probe_end "$PD" main 15 > /dev/null || bad "$PH: probe teardown ($(grep -E 'probe\.' "$PD/lifecycle.tsv" | tail -1 | cut -f2,3))"
  pp_beam_end "$PD" 25 > /dev/null || bad "$PH: node teardown ($(grep -E 'beam\.|ports\.' "$PD/lifecycle.tsv" | tail -1 | cut -f2,3))"
  PD_OPEN=0
  an=$(cut -f2 "$PD/lifecycle.tsv" | grep -E 'FAILED|UNKNOWN|TIMEOUT|STILL-BOUND|NOT-OWNED|REFUSED|MISMATCH' | sort -u | tr '\n' ' ')
  [ -z "$an" ] || bad "$PH: lifecycle anomalies: $an"
  pgrep -x beam.smp > /dev/null && bad "$PH: a beam.smp is still alive after the teardown"
  tasklist.exe 2>/dev/null | grep -qi "$IMG" && bad "$PH: a probe is still alive after the teardown"
  for j in "$ST"/commands/commands-*.ndjson; do [ -f "$j" ] && cp "$j" "$(evg_out "$PD/journal-$(basename "$j" .ndjson | sed 's/^commands-//').ndjson")"; done
  tp=$(grep -E '	probe\.(gone|exited)' "$PD/lifecycle.tsv" | grep -oE 'teardown [0-9]+' | grep -oE '[0-9]+' | tail -1)
  tb=$(grep -E '	beam\.(stopped|terminated)' "$PD/lifecycle.tsv" | grep -oE 'teardown [0-9]+' | grep -oE '[0-9]+' | tail -1)
  say "$PH: teardown: $(cut -f2,3 "$PD/lifecycle.tsv" | grep -E '^(probe\.(gone|exited|terminated|killed)|beam\.(stopped|terminated)|ports)' | tr '\t' ' ' | cut -c1-120 | tr '\n' '|')"
  ROW_TEARDOWN="${tp:--}	${tb:--}	$(( $(ms) - T0 ))"
}

timing_row() {   # <follow-result.json>
  python3 -I - "$1" "$PH" "$PF" "$((T1 - T0))" "$((T2 - T1))" "$ROW_TEARDOWN" >> "$tsv" <<'PY'
import json, sys
fr, ph, pf, setup, prep, tear = sys.argv[1:7]
d = json.load(open(fr))
sl = d.get("slots", [])
s0 = sl[0] if sl else {}
c = d.get("clock") or {}
vm = round(c["vm_age_ms_at_plan"] + (c["t_send_us"] - c["t_plan_us"]) / 1000) if c.get("vm_age_ms_at_plan") is not None else "-"
row = lambda s: "%s:%s:%s:%s" % (s.get("outcome"), s.get("timing"), s.get("lateness_ms", "-"), s.get("class"))
fr_ms = [s["native_ms_after_lift"] / s["frames_after_lift"] for s in sl if isinstance(s.get("native_ms_after_lift"), int) and s.get("frames_after_lift")]
period = round(sum(fr_ms) / len(fr_ms), 2) if fr_ms else "-"
print("\t".join(map(str, [ph, pf, setup, prep, vm, d.get("lift_call_ms"), d.get("terminal_wait_ms"), s0.get("request_ms", "-"), s0.get("frames_after_lift", "-"), s0.get("native_ms_after_lift", "-"),
  " ".join(row(s) for s in sl), d.get("requests"), d.get("missed"), d.get("stop"), period] + tear.split("\t"))))
PY
}

follow_checks() {   # <label> <stop expression> <requests expression> <class|-> <fast|slow|none>
  local l=$1 fr=$PD/$1-follow-result.json r rc
  [ -s "$fr" ] || { bad "$PH: no follow result $fr ($(grep -E 'REFUSED|refused|rror' "$PD/op-$l.out" | head -3 | cut -c1-200 | tr '\n' ' '))"; return; }
  r=$(python3 -I "$T/tests/follow_check.py" "$fr" "$PD/op-$l.out" "$PH" "$2" "$3" "$4" "$5" 2>&1); rc=$?
  printf '%s\n' "$r" | while IFS= read -r x; do say "$x"; done
  fail=$((fail + $(printf '%s\n' "$r" | grep -c '^FAIL')))
  [ "$rc" = 0 ] || [ "$(printf '%s\n' "$r" | grep -c '^FAIL')" != 0 ] || bad "$PH: the checker exited $rc without a FAIL line (crash or missing lines)"
  say "$PH: follow EVIDENCE: $(grep -o 'EVIDENCE follow[^:]*: [a-zA-Z]*' "$PD/op-$l.out" | sed 's/EVIDENCE follow\.//' | tr '\n' ' ')"
  grep -E '^[0-9T:.-]+Z [^ ]+ follow slot ' "$PD/op-$l.out" | sed -E 's/^[0-9T:.-]+Z [^ ]+ //' | cut -c1-260 | while IFS= read -r x; do say "  $x"; done
}

direct_phase() {   # <name> <apply> <later> <class|-> <stop expression> <requests expression> <fast|slow|none> [hook] [frame_ms]
  local name=$1 apply=$2 later=$3 want=$4 stop=$5 nreq=$6 tim=$7 hook=${8:-} fms=${9:-$FRAME_MS} pid lifts=1 cons=1
  if phase_start "$name" "$fms" "$apply" "$later" 240000; then
    prep p
    if [ -n "$hook" ]; then
      tool "$PD" p-lift cmd-m6f.exs lift-follow "$INS" "$GEN" & pid=$!
      "$hook"; wait "$pid"
    else
      tool "$PD" p-lift cmd-m6f.exs lift-follow "$INS" "$GEN"
    fi
    follow_checks p-lift "$stop" "$nreq" "$want" "$tim"
  fi
  phase_end
  journal_check "$PD" p-lift "$lifts" 1 "$cons"
  [ -s "$PD/p-lift-follow-result.json" ] && timing_row "$PD/p-lift-follow-result.json"
}

wait_slot() {   # <slot index>: waits (bounded 30 s) until the follow file holds that slot's line
  local i; for i in $(seq 1 600); do grep -q "\"slot\":$1[,}]" "$PD/p-lift-follow.ndjson" 2>/dev/null && return 0; sleep 0.05; done; return 1
}
hook_disconnect() { wait_slot 2 && { pp_probe_killed "$PD" main "the disconnect scenario, after slot 2's line" > /dev/null && say "disconnect: the probe (PID $PP_PROBE_PID) terminated after slot 2's line"; } || bad "disconnect: slot 2 never written"; }
hook_restart() { wait_slot 2 && { r=$(pp_rpc 'IO.puts(inspect(:rpc.call(:"'"$NODE"'", Process, :exit, [:rpc.call(:"'"$NODE"'", Process, :whereis, [GlacierRelay.Command.Authority]), :kill])))'); say "authority-restart: Process.exit(Authority, :kill) after slot 2's line -> $r"; } || bad "authority-restart: slot 2 never written"; }
hook_stop() { wait_slot 1 && { echo "$(date -u +%FT%TZ) HARD STOP: matrix operator-stop scenario (after slot 1)" > "$(evg_out "$PD/stop.marker")"; say "operator-stop: stop.marker written after slot 1's line"; } || bad "operator-stop: slot 1 never written"; }

no_link_phase() {
  if phase_start no-link "$FRAME_MS" ok held 240000 no; then
    okc "no-link: the probe's Windows PID is known although the link never verified (found by ancestry, not from the link)" "[ -n '${PP_PROBE_PID:-}' ]"
  fi
  phase_end
  okc "no-link: the probe was stopped by its PID when the outcome was known (probe.terminated), not left to its 240 s failsafe" "grep -q '	probe.terminated	' '$PD/lifecycle.tsv' && [ $(( $(ms) - T0 )) -lt 60000 ]"
  okc "no-link: the journal holds no token-verified peer and no accepted command" "! cat '$PD'/journal-*.ndjson 2>/dev/null | grep -qE '\"event\":\"(peer.token_verified|command.accepted)\"'"
  say "no-link: phase total $(( $(ms) - T0 )) ms (failsafe lifetime 240000 ms)"
  printf 'no-link\t%s\t%s\t-\t-\t-\t-\t-\t-\t-\t(the link never verified; nothing issued)\t0\t-\t-\t-\t%s\n' "$FRAME_MS" "$((T1 - T0))" "$ROW_TEARDOWN" >> "$tsv"
}

lift_refused_phase() {
  local rc bud
  if phase_start lift-refused "$FRAME_MS" ok held 240000; then
    prep p 62
    tool "$PD" p-lift cmd-m6f.exs lift-follow "$INS" "$GEN"; rc=$?
    okc "lift-refused: the local guard passed and the AUTHORITY refused the lift (lift_candidate returned an error); no follow-up read" \
      "! grep -q 'LOCAL GUARD REFUSED' '$PD/op-p-lift.out' && grep -q 'lift refused locally: :inspection_stale (refused before transmission: nothing transmitted' '$PD/op-p-lift.out' && grep -q '\"stop\":\"lift_not_issued\"' '$PD/p-lift-follow.ndjson' && grep -q 'EVIDENCE follow.lift-not-issued-no-read: ok' '$PD/op-p-lift.out' && [ ! -e '$PD/p-lift-command-id.txt' ]"
    say "lift-refused: $(grep -o 'lift refused locally: .*' "$PD/op-p-lift.out" | cut -c1-220) (rc $rc)"
    bud=$(pp_rpc 's = :rpc.call(:"'"$NODE"'", GlacierRelay.Command, :status, []); IO.puts("#{s.effectful.transform_lift_budget} #{s.trust.effectful_armed}")')
    okc "lift-refused: the lift budget is still 1 (nothing issued; the arming is not consumed: '$bud')" "[ '${bud%% *}' = 1 ]"
  fi
  phase_end
  journal_check "$PD" p-lift 0 1 0
  printf 'lift-refused\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\t(the authority refused the lift; no follow-up read)\t0\t-\tlift_not_issued\t-\t%s\n' "$FRAME_MS" "$((T1 - T0))" "$((T2 - T1))" "$ROW_TEARDOWN" >> "$tsv"
}

issue_timeout_phase() {
  local hold hout rc lid st apid0
  if phase_start issue-timeout "$FRAME_MS" ok held 240000; then
    prep p
    apid0=$(pp_rpc 'IO.puts(inspect(:rpc.call(:"'"$NODE"'", Process, :whereis, [GlacierRelay.Command.Authority])))')
    # the hold: ONE VM that suspends the phase's own Link (found through the authority's state; this node and probe are the phase's
    # own), reports it, waits (bounded 8 s) until lift-follow's output says the issuance is UNCERTAIN, then resumes the link
    hout=$(evg_out "$PD/link-hold.txt") || exit 3
    (cd "$RELAY" && elixir --sname "mx-hold-$RANDOM" -e '
      [node, opout, ready] = System.argv() |> then(fn [n | r] -> [String.to_atom(n) | r] end)
      true = :net_kernel.connect_node(node)
      link = :rpc.call(node, :sys, :get_state, [GlacierRelay.Command.Authority]).link.pid
      :ok = :rpc.call(node, :sys, :suspend, [link])
      File.write!(ready, "suspended #{inspect(link)} #{DateTime.utc_now() |> DateTime.to_iso8601()}\n")
      t0 = System.monotonic_time(:millisecond)
      seen = Enum.find_value(Stream.repeatedly(fn -> Process.sleep(20); File.read(opout) end), fn
        {:ok, t} -> if(String.contains?(t, "LIFT ISSUANCE UNCERTAIN"), do: :uncertain_seen, else: (System.monotonic_time(:millisecond) - t0 > 8_000) && :bound_reached)
        _ -> (System.monotonic_time(:millisecond) - t0 > 8_000) && :bound_reached
      end)
      r = :rpc.call(node, :sys, :resume, [link])
      IO.puts("resumed #{inspect(link)} -> #{inspect(r)} after #{System.monotonic_time(:millisecond) - t0} ms (#{seen})")
    ' "$NODE" "$PD/op-p-lift.out" "$PD/link-hold.ready") > "$hout" 2>&1 & hold=$!
    for _ in $(seq 1 300); do [ -s "$PD/link-hold.ready" ] && break; sleep 0.05; done
    okc "issue-timeout: the phase's own Link process suspended before lift-follow started ($(cat "$PD/link-hold.ready" 2>/dev/null | cut -c1-80))" "[ -s '$PD/link-hold.ready' ]"
    tool "$PD" p-lift cmd-m6f.exs lift-follow "$INS" "$GEN"; rc=$?
    wait "$hold"
    say "issue-timeout: $(grep -oE 'LIFT ISSUANCE UNCERTAIN.{0,200}' "$PD/op-p-lift.out" | head -1) | hold: $(tail -1 "$hout" | cut -c1-160)"
    okc "issue-timeout: lift-follow reports the issuance UNCERTAIN after its 3 s bound ({:badrpc, :timeout}) — not a refusal, never 'nothing transmitted'" \
      "grep -q 'LIFT ISSUANCE UNCERTAIN: .*returned {:badrpc, :timeout}' '$PD/op-p-lift.out' && ! grep -q 'nothing transmitted' '$PD/op-p-lift.out' && grep -q 'EVIDENCE follow.lift-issuance-determined: NOT' '$PD/op-p-lift.out' && grep -q 'EVIDENCE follow.no-read-after-uncertain-issuance: ok' '$PD/op-p-lift.out'"
    okc "issue-timeout: the follow file holds the plan and the uncertain end, no issuance record and no slot; no command-id file" \
      "grep -q '\"event\":\"follow.plan\"' '$PD/p-lift-follow.ndjson' && grep -q '\"stop\":\"lift_issuance_uncertain\"' '$PD/p-lift-follow.ndjson' && ! grep -qE '\"event\":\"follow.(issued|slot)\"' '$PD/p-lift-follow.ndjson' && [ ! -e '$PD/p-lift-command-id.txt' ]"
    okc "issue-timeout: the link was resumed only after the uncertain report (inside the authority's own 5 s bound)" "grep -q 'resumed .*uncertain_seen' '$hout'"
    # what the authority did meanwhile (read now, after the tool ended — never by the tool): the lift accepted, transmitted, applied
    lid=$(python3 -I -c "import json,glob,sys; e=[json.loads(l) for f in glob.glob(sys.argv[1]+'/commands/commands-*.ndjson') for l in open(f) if l.strip()]; a=[x for x in e if x.get('event')=='command.accepted' and x.get('name')=='candidate.transform.set']; print(a[0]['command_id'] if len(a)==1 else 'none:%d' % len(a))" "$ST")
    for _ in $(seq 1 100); do st=$(pp_rpc 'c = :rpc.call(:"'"$NODE"'", GlacierRelay.Command, :command, ["'"$lid"'"]); IO.puts(if is_map(c), do: c.status, else: inspect(c))'); case "$st" in applied|failed|unknown|expired|precondition_failed|unavailable) break;; esac; sleep 0.1; done
    say "issue-timeout: the journal's one lift $lid: authority status $st"
    okc "issue-timeout: the authority accepted, transmitted and APPLIED the lift after the tool's timeout (the timeout was not a refusal)" "[ '$st' = applied ]"
    st=$(pp_rpc 'IO.puts(inspect(:rpc.call(:"'"$NODE"'", Process, :whereis, [GlacierRelay.Command.Authority])))')
    okc "issue-timeout: the authority was not restarted by the hold (the same pid $apid0 before and after: its own 5 s call bound not reached)" "[ -n '$apid0' ] && [ '$st' = '$apid0' ]"
  fi
  phase_end
  journal_check "$PD" p-lift 1 1 1 0
  printf 'issue-timeout\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\t(the issuance RPC timed out: UNCERTAIN; no follow-up read; the lift applied meanwhile)\t0\t-\tlift_issuance_uncertain\t-\t%s\n' "$FRAME_MS" "$((T1 - T0))" "$((T2 - T1))" "$ROW_TEARDOWN" >> "$tsv"
}

direct() {   # <phase-dir> <label> <action> [args]: cmd-m6f.exs called DIRECTLY (bypassing op.sh and the wrapper); its output is NOT an op-*.out file (op.sh's per-run counts are untouched)
  local pd=$1 l=$2 a=$3; shift 3
  local o; o=$(evg_out "$pd/direct-$l.out") || return 2
  echo "$(date -u +%FT%T.%3NZ) $l $a $* (direct, bypassing the wrapper)" > "$o"
  (cd "$RELAY" && elixir --sname "mx-$l-$RANDOM" -S mix run --no-start "$T/cmd-m6f.exs" "$pd" "$l" "$a" "$@") >> "$o" 2>&1
}

restore_phase() {   # <name> <transform-later> <held|returned|drifted> [aged]
  local name=$1 later=$2 kind=$3 aged=${4:-} run=$KIT rc LS LSID age jit ins_after nres arm cons
  if ! phase_start "$name" "$FRAME_MS" ok "$later" 400000; then phase_end; return; fi
  OPX() { M6F1B_MODE=dry-run M6F1B_OWNER=$IMG M6F1B_GUARD_ROOT=$E M6F1B_RUN_DIR=$run bash "$run/op.sh" "$PD" "$S" "$@"; }
  OPX ident r2-id baseline >> "$out"
  OPX op r3-arm arm > /dev/null; OPX op r3-players players 9000 recorded > /dev/null; OPX op r3-entity entity - - 9000 present > /dev/null
  OPX op r3-ct ctransform 9000 present > /dev/null
  OPX xcheck r3-x --players r3-players --entity r3-entity --transform r3-ct --candidate-expect present --slots-expect recorded > /dev/null
  T2=$(ms)
  OPX note "MATRIX: simulated operator go-ahead for the lift" > /dev/null
  M6F1B_MODE=dry-run M6F1B_OWNER=$IMG M6F1B_GUARD_ROOT=$E M6F1B_RUN_DIR=$run bash "$run/seq-lift.sh" "$PD" "$S" r4 r3-players r3-entity r3-ct > "$(evg_out "$PD/seq-lift.console")" 2>&1; rc=$?
  okc "$name: seq-lift completed (R4 done, rc $rc)" "[ $rc = 0 ] && grep -q 'R4 done' '$PD/r4-sequence.txt'"
  follow_checks r4-lift "d['stop'] is None" "d['requests'] == 6" "$( [ "$kind" = held ] && echo held || ([ "$kind" = returned ] && echo returned_to_baseline || echo drifted))" fast
  LS=$(python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); r=[s for s in d['slots'] if s['outcome']=='requested']; print('r4-lift-s%d' % r[-1]['slot'])" "$PD/r4-lift-follow-result.json")
  LSID=$(tr -d '\n' < "$PD/$LS-command-id.txt" 2>/dev/null)
  okc "$name: the last lift-follow sample $LS is returned through the existing file / result convention (command id, result, observed)" "[ -n '$LSID' ] && [ -s '$PD/$LS-result.json' ] && [ -s '$PD/$LS-observed.json' ]"
  if [ "$aged" = aged ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$PD/r4-lift-follow-result.json") ))
    say "$name: waiting $(( 62 - age > 0 ? 62 - age : 0 )) s more so that the last sample ($LS) is older than the authority's 60 s inspection window"
    [ "$age" -lt 62 ] && sleep $(( 62 - age ))
    direct "$PD" x-stale restore "$(tr -d '\n' < "$PD/r4-lift-command-id.txt")" "$LSID" "$(jget "$PD/$LS-result.json" "d['mission_generation']")"
    okc "$name: a DIRECT restoration bound to the stale sample is refused before transmission (inspection_stale; nothing transmitted)" "grep -q 'restore refused locally: :inspection_stale (refused before transmission' '$PD/direct-x-stale.out' && ! grep -q 'restoration issued' '$PD/direct-x-stale.out'"
  fi
  if [ "$kind" != held ]; then
    # the wrapper's eligibility refuses before arming; a direct call then meets the authority-side evidence
    OPX note 'restoration go-ahead (verbatim): "MATRIX: a simulated operator approval, separate from the lift'"'"'s"' > /dev/null
    M6F1B_MODE=dry-run M6F1B_OWNER=$IMG M6F1B_GUARD_ROOT=$E M6F1B_RUN_DIR=$run bash "$run/seq-restore.sh" "$PD" "$S" r6 r4-lift "$LS" r4-ct r3-players r3-entity > "$(evg_out "$PD/seq-restore.console")" 2>&1; rc=$?
    say "$name: seq-restore rc $rc: $(grep -E 'NOT ELIGIBLE|eligibility' "$PD/r6-sequence.txt" | sed -E 's/^[^ ]+ //' | cut -c1-240)"
    okc "$name: the wrapper refuses before any identity check or arming (exit 10: the last sample is not held)" "[ $rc = 10 ] && grep -q 'NOT ELIGIBLE: .*not held' '$PD/r6-sequence.txt' && [ ! -e '$PD/op-r6-arm.out' ] && [ ! -e '$PD/id-r6-id.out' ]"
    direct "$PD" x-direct restore "$(tr -d '\n' < "$PD/r4-lift-command-id.txt")" "$LSID" "$(jget "$PD/$LS-result.json" "d['mission_generation']")"
    if [ "$kind" = returned ]; then
      okc "$name: a DIRECT restoration is not submitted — the authority-side check finds the preimage (already_at_baseline)" "grep -q 'restore NOT submitted' '$PD/direct-x-direct.out' && ! grep -q 'restoration issued' '$PD/direct-x-direct.out'"
    else
      okc "$name: a DIRECT restoration is refused before transmission by the authority-side evidence check" "grep -q 'restore refused locally: .*(refused before transmission' '$PD/direct-x-direct.out' && ! grep -q 'restoration issued' '$PD/direct-x-direct.out'"
    fi
    say "$name: direct: $(grep -oE 'restore (NOT submitted|refused locally)[^(]*' "$PD/direct-x-direct.out" | head -1 | cut -c1-200)"
    nres=0; arm=1; cons=1
  else
    # a line that mentions a restoration but is NOT an approval in the exact form: the eligibility refuses (exit 10, nothing armed)
    OPX note "MATRIX: no restoration yet (a line mentioning a restoration that is not an approval)" > /dev/null
    M6F1B_MODE=dry-run M6F1B_OWNER=$IMG M6F1B_GUARD_ROOT=$E M6F1B_RUN_DIR=$run bash "$run/seq-restore.sh" "$PD" "$S" r6x r4-lift "$LS" r4-ct r3-players r3-entity > "$(evg_out "$PD/seq-restore-x.console")" 2>&1; rc=$?
    okc "$name: a line mentioning a restoration that is not an approval in the exact form is refused (exit 10, nothing armed)" "[ $rc = 10 ] && grep -q 'NOT ELIGIBLE: .*no operator restoration approval' '$PD/r6x-sequence.txt' && [ ! -e '$PD/op-r6x-arm.out' ]"
    OPX note 'restoration go-ahead (verbatim): "MATRIX: a simulated operator approval, separate from the lift'"'"'s, after the follow result"' > /dev/null
    M6F1B_MODE=dry-run M6F1B_OWNER=$IMG M6F1B_GUARD_ROOT=$E M6F1B_RUN_DIR=$run bash "$run/seq-restore.sh" "$PD" "$S" r6 r4-lift "$LS" r4-ct r3-players r3-entity > "$(evg_out "$PD/seq-restore.console")" 2>&1; rc=$?
    sed -E 's/^[^ ]+ r6: //' "$PD/r6-sequence.txt" | grep -E 'eligibility|sample .* old|plan:|restoration issued|after the restoration|later class|R6 done|HARD|NOT' | cut -c1-300 | while IFS= read -r x; do say "  $x"; done
    okc "$name: seq-restore completed (R6 done, rc $rc): eligibility, ONE restoration, its later read-back" "[ $rc = 0 ] && grep -q 'R6 done' '$PD/r6-sequence.txt' && grep -q 'eligibility: the last of 6 samples' '$PD/r6-sequence.txt'"
    okc "$name: every restoration EVIDENCE line ok (19)" "[ \$(grep -c 'EVIDENCE restore' '$PD/op-r6-restore.out') = 19 ] && ! grep -q 'EVIDENCE restore[^:]*: NOT' '$PD/op-r6-restore.out'"
    jit=0; [ -e "$PD/r6-jit-ct-command-id.txt" ] && jit=1
    age=$(grep -oE 'sample .* is [0-9]+ s old' "$PD/r6-sequence.txt" | grep -oE '[0-9]+ s old' | grep -oE '[0-9]+')
    okc "$name: a just-in-time inspection was taken iff the sample was over 35 s old (age ${age:-?} s, just-in-time $jit)" "[ -n '$age' ] && { { [ '$age' -gt 35 ] && [ $jit = 1 ]; } || { [ '$age' -le 35 ] && [ $jit = 0 ]; }; }"
    if [ "$jit" = 1 ]; then okc "$name: the just-in-time inspection held and was bit-equal to the sample before the restoration was bound to it" "grep -q 'conclusion \"held\"' '$PD/op-r6-jit-later.out' && grep -q 'EVIDENCE xcheck.transform-candidate-words-vs-previous: ok .*candidate world words bit-equal' '$PD/xc-r6-jit-x.out' && grep -q \"restore .* bound to the later exact inspection \$(tr -d '\\n' < '$PD/r6-jit-ct-command-id.txt')\" '$PD/op-r6-restore.out'"; fi
    [ "$aged" = aged ] && okc "$name: the aged sample took the just-in-time path" "[ $jit = 1 ]"
    okc "$name: the restoration facts are reported separately (restore_facts; world / local / parent / dirty vs the pre-lift inspection)" "grep -q 'EVIDENCE restore.world-restored-exact-observed: ok' '$PD/op-r6-restore.out' && grep -q 'EVIDENCE restore.snapshot-facts-recorded: ok' '$PD/op-r6-restore.out' && grep -qE '^world' '$PD/r6-post-compare.txt'"
    say "$name: after the restoration vs the pre-lift inspection: $(grep -E '^(world|local|parent|dirty|snapshot)' "$PD/r6-post-compare.txt" | cut -c1-70 | tr '\n' ';')"
    M6F1B_MODE=dry-run M6F1B_OWNER=$IMG M6F1B_GUARD_ROOT=$E M6F1B_RUN_DIR=$run bash "$run/op.sh" "$PD" "$S" opf r7-restore2 restore x y z > "$(evg_out "$PD/r7-restore2.txt")" 2>&1
    okc "$name: op.sh refuses a second restoration" "grep -q 'REFUSED' '$PD/r7-restore2.txt' && [ ! -e '$PD/op-r7-restore2.out' ]"
    nres=1; arm=2; cons=2
  fi
  phase_end
  ins_after=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['requests'])" "$PD/r4-lift-follow-result.json")
  for f in r6-jit-ct r6-post-ct; do [ -e "$PD/$f-command-id.txt" ] && ins_after=$((ins_after + 1)); done
  journal_check "$PD" r4-lift 1 "$arm" "$cons" "$ins_after" "$nres"
  timing_row "$PD/r4-lift-follow-result.json"
}

old_or_kit() {   # <old-path|kit-held>
  local name=$1 run s rc
  if [ "$name" = old-path ]; then run=$OLD; else run=$KIT; fi
  if ! phase_start "$name" "$FRAME_MS" ok held 300000; then phase_end; return; fi
  OPX() { M6F1B_MODE=dry-run M6F1B_OWNER=$IMG M6F1B_GUARD_ROOT=$E M6F1B_RUN_DIR=$run bash "$run/op.sh" "$PD" "$S" "$@"; }
  OPX ident r2-id baseline >> "$out"
  OPX op r3-arm arm > /dev/null; OPX op r3-players players 9000 recorded > /dev/null; OPX op r3-entity entity - - 9000 present > /dev/null
  OPX op r3-ct ctransform 9000 present > /dev/null
  OPX xcheck r3-x --players r3-players --entity r3-entity --transform r3-ct --candidate-expect present --slots-expect recorded > /dev/null
  okc "$name: the R3 qualification snapshot qualifies (xcheck)" "grep -q 'EVIDENCE xcheck.transform-candidate-qualified: ok' '$PD/xc-r3-x.out'"
  T2=$(ms)
  if [ "$name" = kit-held ]; then
    INS=$(tr -d '\n' < "$PD/r3-ct-command-id.txt"); GEN=$(jget "$PD/r3-ct-result.json" "d['mission_generation']")
    # a reused output label: a NON-follow capture of that label exists (a sentinel) -> refused by op.sh and by cmd-m6f.exs itself
    printf 'sentinel: an earlier capture under this label\n' > "$(evg_out "$PD/rx-lift-command-id.txt")"; s=$(sha256sum "$PD/rx-lift-command-id.txt" | cut -c1-64)
    OPX opf rx-lift lift-follow "$INS" "$GEN" > "$(evg_out "$PD/rx-opsh.txt")" 2>&1
    okc "kit-held: op.sh refuses the reused label rx-lift before invoking anything" "grep -q \"label 'rx-lift'\" '$PD/rx-opsh.txt' && [ ! -e '$PD/op-rx-lift.out' ]"
    (cd "$RELAY" && elixir --sname "mx-rx$RANDOM" -S mix run --no-start "$T/cmd-m6f.exs" "$PD" rx-lift lift-follow "$INS" "$GEN") > "$(evg_out "$PD/rx-cmd.txt")" 2>&1; rc=$?
    okc "kit-held: cmd-m6f.exs lift-follow itself refuses the reused label (any <label>-* capture; rc 2, nothing issued, nothing written) and the sentinel is unchanged" "[ $rc = 2 ] && grep -q \"label 'rx-lift' already has 1 capture(s) this action writes\" '$PD/rx-cmd.txt' && [ \"\$(sha256sum '$PD/rx-lift-command-id.txt' | cut -c1-64)\" = '$s' ] && [ \$(ls '$PD' | grep -c '^rx-lift-') = 1 ]"
    # a sealed destination: a scratch "historical" directory UNDER a directory holding the manifest (a sealed root's subdirectory)
    SR=$(evg_dir "$PD/sealed-scratch"); SRS=$(evg_dir "$SR/attempt1"); printf 'sealed sentinel\n' > "$SR/sentinel.txt"; (cd "$SR" && sha256sum sentinel.txt > sha256.txt); ss0=$( (cd "$SR" && find . -type f | sort | xargs sha256sum) )
    (cd "$RELAY" && elixir --sname "mx-sr$RANDOM" -S mix run --no-start "$T/cmd-m6f.exs" "$SRS" sx lift-follow "$INS" "$GEN") > "$(evg_out "$PD/sx-cmd.txt")" 2>&1; rc=$?
    okc "kit-held: cmd-m6f.exs lift-follow refuses a subdirectory of a sealed root (an ancestor holds sha256.txt; rc 2, nothing issued, the sealed tree unchanged)" "[ $rc = 2 ] && grep -q 'sealed evidence root is never written' '$PD/sx-cmd.txt' && [ \"\$( (cd '$SR' && find . -type f | sort | xargs sha256sum) )\" = \"\$ss0\" ]"
    # op.sh pointed at a SEALED claimed root (a scratch claim inside this phase, its manifest written): the guard refuses to attach
    SC="$PD/sealed-root"; ( evg_claim "$SC" > /dev/null ) && printf 'sealed sentinel\n' > "$SC/sentinel.txt" && (cd "$SC" && sha256sum sentinel.txt .evidence-root > sha256.txt)
    sc0=$( (cd "$SC" && find . -type f | sort | xargs sha256sum) )
    M6F1B_MODE=dry-run M6F1B_OWNER=$IMG M6F1B_RUN_DIR=$run bash "$run/op.sh" "$SC" "$S" opf sy lift-follow "$INS" "$GEN" > "$(evg_out "$PD/sy-opsh.txt")" 2>&1; rc=$?
    sc1=$( (cd "$SC" && find . -type f | sort | xargs sha256sum) )
    okc "kit-held: op.sh pointed at a sealed claimed root is refused by the guard (rc $rc) and that root is unchanged" "[ $rc != 0 ] && grep -q 'sealed' '$PD/sy-opsh.txt' && [ \"\$sc1\" = \"\$sc0\" ]"
    bud=$(pp_rpc 's = :rpc.call(:"'"$NODE"'", GlacierRelay.Command, :status, []); IO.puts(s.effectful.transform_lift_budget)')
    okc "kit-held: the lift budget is still 1 after the four refusals (nothing was issued)" "[ '$bud' = 1 ]"
  fi
  OPX note "MATRIX: simulated operator go-ahead for the lift" > /dev/null
  M6F1B_MODE=dry-run M6F1B_OWNER=$IMG M6F1B_GUARD_ROOT=$E M6F1B_RUN_DIR=$run bash "$run/seq-lift.sh" "$PD" "$S" r4 r3-players r3-entity r3-ct > "$(evg_out "$PD/seq-lift.console")" 2>&1; rc=$?
  say "$name: seq-lift rc $rc: $(grep -E 'R4 done|STOPPED|HARD STOP|lift issued|NOT issued' "$PD/r4-sequence.txt" | sed -E 's/^[^ ]+ //' | cut -c1-200 | tr '\n' '|')"
  okc "$name: seq-lift completed (R4 done)" "[ $rc = 0 ] && grep -q 'R4 done' '$PD/r4-sequence.txt'"
  if [ "$name" = old-path ]; then
    M6F1B_MODE=dry-run M6F1B_OWNER=$IMG M6F1B_GUARD_ROOT=$E M6F1B_RUN_DIR=$run bash "$run/seq-later.sh" "$PD" "$S" r5 r4-lift r4-ct r3-players r3-entity > "$(evg_out "$PD/seq-later.console")" 2>&1
    say "old-path: seq-later: $(grep -E 'sample [ab] \(|classes:' "$PD/r5-sequence.txt" | sed -E 's/^[^ ]+ //' | cut -c1-200 | tr '\n' '|')"
    okc "old-path: both later samples held (the frozen fake's held mode)" "grep -q 'classes: sample A held (xcheck HELD); sample B held (xcheck HELD)' '$PD/r5-sequence.txt'"
    OLD_OBS=$(python3 -I -c "import json,datetime,sys; l=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2])); f=lambda t: datetime.datetime.fromisoformat(t.replace('Z','+00:00')); print(a['frame']-l['frame'], round((f(a['native_at'])-f(l['native_at'])).total_seconds()*1000))" "$PD/r4-lift-result.json" "$PD/r5a-ct-result.json")
    say "old-path: the FIRST later observation (sample A): +${OLD_OBS%% *} frames, +${OLD_OBS##* } ms on the native clock after the lift (by design >= 1 s, plus the fresh VMs before it)"
  else
    follow_checks r4-lift "d['stop'] is None" "d['requests'] == 6" held fast
    KIT_OBS="$(jget "$PD/r4-lift-follow-result.json" "d['slots'][0]['frames_after_lift']") $(jget "$PD/r4-lift-follow-result.json" "d['slots'][0]['native_ms_after_lift']")"
    say "kit-held: $(grep -E '^[^ ]+ r4:   deferred|the last sample' "$PD/r4-sequence.txt" | sed -E 's/^[^ ]+ r4: //' | cut -c1-200 | tr '\n' '|')"
    okc "kit-held: the deferred per-sample xcheck ran for all six samples after the schedule, each 0 NOT and HELD" "[ \$(ls '$PD'/xc-r4-lift-s*-x.out 2>/dev/null | wc -l) = 6 ] && [ \$(grep -l 'xcheck: 0 NOT line' '$PD'/xc-r4-lift-s*-x.out | wc -l) = 6 ] && [ \$(grep -l 'transform-later-vs-lift: ok .*: HELD' '$PD'/xc-r4-lift-s*-x.out | wc -l) = 6 ]"
    OPX opf r7-lift2 lift-follow "$INS" "$GEN" > "$(evg_out "$PD/r7-opsh.txt")" 2>&1
    okc "kit-held: op.sh refuses a second lift-follow (lift-follow counts as the run's one lift)" "grep -q 'REFUSED: a lift was already requested' '$PD/r7-opsh.txt' && [ ! -e '$PD/op-r7-lift2.out' ]"
    OPX opf r7-lift3 lift "$INS" "$GEN" > "$(evg_out "$PD/r7b-opsh.txt")" 2>&1
    okc "kit-held: op.sh refuses a plain lift after the lift-follow" "grep -q 'REFUSED: a lift was already requested' '$PD/r7b-opsh.txt' && [ ! -e '$PD/op-r7-lift3.out' ]"
    tool "$PD" r7-direct cmd-m6f.exs lift-follow "$INS" "$GEN"; rc=$?
    okc "kit-held: cmd-m6f.exs lift-follow called directly (bypassing op.sh) is refused by its local guard: the budget is consumed (rc $rc)" "[ $rc = 2 ] && grep -q 'lift guard lift-budget-available: FAILED' '$PD/op-r7-direct.out' && ! grep -q 'lift issued' '$PD/op-r7-direct.out'"
  fi
  phase_end
  if [ "$name" = old-path ]; then journal_check "$PD" r4-lift 1 1 1 2; else journal_check "$PD" r4-lift 1 1 1; fi
  if [ "$name" = old-path ]; then printf 'old-path\t%s\t%s\t%s\t-\t-\t-\t-\t%s\t%s\t(old path: two samples, A >= 1 s, B >= 10 s)\t2\t-\t-\t-\t%s\n' "$FRAME_MS" "$((T1 - T0))" "$((T2 - T1))" "${OLD_OBS%% *}" "${OLD_OBS##* }" "$ROW_TEARDOWN" >> "$tsv"
  else timing_row "$PD/r4-lift-follow-result.json"; fi
}

for ph in $PHASES; do
  case "$ph" in
    old-path|kit-held) old_or_kit "$ph";;
    returned) direct_phase returned ok returned returned_to_baseline "d['stop'] is None" "d['requests'] == 6" fast;;
    drifted) direct_phase drifted ok drifted drifted "d['stop'] is None" "d['requests'] == 6" fast;;
    dirty) direct_phase dirty ok dirty indeterminate "d['stop'] is None" "d['requests'] == 6" fast;;
    near) direct_phase near ok near near_target "d['stop'] is None" "d['requests'] == 6" fast;;
    slow) direct_phase slow ok held held "d['stop'] is None" "3 <= d['requests'] <= 6 and (d['missed'] >= 1 or any(s.get('timing') == 'delayed' for s in d['slots']))" slow "" 700;;
    fault) direct_phase fault fault held - "str(d['stop']).startswith('{:original_not_applied, :failed')" "d['requests'] == 0" none;;
    exit-after-call) direct_phase exit-after-call exit-after-call held - "str(d['stop']).startswith('{:original_not_applied, :unknown')" "d['requests'] == 0" none;;
    disconnect) direct_phase disconnect ok held held "str(d['stop']).startswith(('{:identity_changed', '{:request_refused', '{:inspection_not_applied'))" "d['requests'] == 3" fast hook_disconnect;;
    authority-restart) direct_phase authority-restart ok held held "str(d['stop']).startswith('{:identity_changed')" "d['requests'] == 3" fast hook_restart;;
    operator-stop) direct_phase operator-stop ok held held "d['stop'] == 'operator_stop'" "d['requests'] == 2" fast hook_stop;;
    no-link) no_link_phase;;
    lift-refused) lift_refused_phase;;
    issue-timeout) issue_timeout_phase;;
    restore-held) restore_phase restore-held held held;;
    restore-aged) restore_phase restore-aged held held aged;;
    restore-returned) restore_phase restore-returned returned returned;;
    restore-drifted) restore_phase restore-drifted drifted drifted;;
    *) bad "unknown phase $ph";;
  esac
  say "phase $ph done: $(tail -1 "$tsv" | cut -f1,12-18 | tr '\t' ' ')"
done

if [ -n "$OLD_OBS" ] && [ -n "$KIT_OBS" ]; then
  okc "the improvement, on the same stack: the kit's first later observation (+${KIT_OBS%% *} frames, +${KIT_OBS##* } ms native) is within the 150 ms target and earlier than the old path's (+${OLD_OBS%% *} frames, +${OLD_OBS##* } ms)" "[ '${KIT_OBS##* }' -le 150 ] && [ '${KIT_OBS##* }' -lt '${OLD_OBS##* }' ]"
fi

# ---- teardown of the group: token scans, throwaway state, processes -------------------------------------------------------------
n=$(grep -rlF -f "$SD/token" "$A" 2>/dev/null | wc -l); say "the ephemeral token value in this group's evidence: $n file(s) (expected 0; the pattern read through grep -f)"; [ "$n" = 0 ] || bad "the token leaked into the matrix evidence"
cleanup; trap - EXIT
say "throwaway state removed: $([ -e "$SD" ] && echo NO || echo yes); the stage state root entries: $(ls -A "$S" | wc -l)"
pgrep -x beam.smp > /dev/null && bad "beam.smp still running"; ss -ltn | grep -qE ':4747 |:4748 |:4749 ' && bad "a port is still bound"
tasklist.exe 2>/dev/null | grep -qi "$IMG" && bad "a probe is still running"
say "MATRIX GROUP $G RESULT: $([ "$fail" = 0 ] && echo "PASS (0 failures)" || echo "FAIL ($fail failures)")"
exit "$fail"

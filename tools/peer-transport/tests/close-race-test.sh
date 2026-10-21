#!/bin/bash
# M7-L3 (record section 15, correction B) — the game-facing peer's end-of-run report when the game host closes the connection
# between the endpoint's snapshot and the connection-status read (m7l3-admission dry-run-B-attempt1 / -2: the read exited the
# run, with no summary.json). Deterministic, never by waiting for chance: a TEST-ONLY seam is inserted into a SCRATCH COPY of the
# bundle (in <state-dir>; never shipped; its diff is kept in the attempt), immediately before the course-end status read:
#   hold  writes <out>/seam.reached, then holds until the connection's process has ended or <out>/seam.release exists (<= 20 s),
#         then writes <out>/seam.passed. The harness then closes the stand-in host (the race forced: the read meets an ended
#         connection) or releases the seam with the connection up (the live control);
#   fail  the read meets a stand-in process that exits abnormally on the call (an unexpected failure, never a success).
# The scratch copy gets its own MANIFEST.sha256 (the peer verifies it as any bundle) and its configuration pins it. Against the
# stand-in game host tests/fake-host.exs on loopback, as tests/game-peer-test.sh; nothing here is a Mac, a LAN or the relay's host.
#   close-race-test.sh <bundle-dir> <new-attempt-dir> <state-dir> <old|corrected>
# old        the bundle's game-peer.exs BEFORE correction B: the live control, then the forced race ONCE (the reproduction:
#            expected exit 1 and no summary.json)
# corrected  GamePeer.connection_counts/1's cases (the module taken from the bundle's own game-peer.exs, against stand-in
#            processes); the live control; the forced race; the forced unexpected failure; through the unmodified bundle: a
#            disconnect mid-course and an operator stop mid-course; the scanner; no process left
# <state-dir> (existing, empty, 0700, Linux filesystem) receives the disposable credentials and the scratch bundle copies; the
# caller removes it after the scan. Every check prints PASS / FAIL; the last line is the result.
set -uo pipefail
[ "$#" -eq 4 ] || { echo "usage: close-race-test.sh <bundle-dir> <new-attempt-dir> <state-dir> <old|corrected>" >&2; exit 2; }
B=$(cd "$1" && pwd -P); A=$2; S=$3; MODE=$4
case "$MODE" in old|corrected) ;; *) echo "close-race-test: the mode is old or corrected" >&2; exit 2;; esac
[ -e "$A" ] && { echo "close-race-test: REFUSED: $A exists" >&2; exit 2; }
[ -d "$S" ] && [ -z "$(ls -A "$S")" ] || { echo "close-race-test: REFUSED: $S must be an existing empty directory" >&2; exit 2; }
mkdir -p "$A"
T=$(cd "$(dirname "$0")" && pwd -P)
EX="elixir -pa $B/ebin/glacier_relay"
checks=0; fails=0
say() { echo "$(date -u +%FT%T.%3NZ) $*"; }
ok() { checks=$((checks + 1)); if [ "$1" = 0 ]; then say "PASS $2"; else fails=$((fails + 1)); say "FAIL $2"; fi; }
jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=(d[int(k)] if int(k) < len(d) else None) if isinstance(d,list) else (d or {}).get(k)
print(json.dumps(d) if isinstance(d,(dict,list)) else d)' "$1" "$2"; }
free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
sha() { sha256sum < "$1" | cut -c1-64; }
wait_grep() { local i=0; while ! grep -q "$2" "$1" 2>/dev/null && [ $i -lt "$3" ]; do sleep 0.1; i=$((i + 1)); done; grep -q "$2" "$1" 2>/dev/null; }
wait_file() { local i=0; while [ ! -e "$1" ] && [ $i -lt "$2" ]; do sleep 0.05; i=$((i + 1)); done; [ -e "$1" ]; }
pid_of() { sed -n 1p "$1/peer.pid" 2>/dev/null; }
evn() { grep -c "\"event\":\"$2\"" "$1/events.ndjson" 2>/dev/null; }

say "close-race-test ($MODE): bundle $B (MANIFEST.sha256 $(sha "$B/MANIFEST.sha256")); game-peer.exs $(sha "$B/kit/game-peer.exs"); attempt $A; state $S"
say "runtime: OTP $(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().'), Elixir $(elixir -e 'IO.write(System.version())')"

# ---- a scratch bundle copy with the test-only seam; its own manifest ------------------------------------------------------------
# variant <name> <hold|fail>: sets V (the copy) and VMS (its MANIFEST.sha256's sha256)
variant() {
  V=$S/bundle-$1; cp -pR "$B" "$V"
  python3 -I - "$V/kit/game-peer.exs" "$2" > "$A/seam-$1.txt" 2>&1 <<'PY'
import re, sys
p, kind = sys.argv[1], sys.argv[2]
lines = open(p).read().split("\n")
# the course-end status read: the corrected script's call, or the original's (game-peer.exs of aff8193, line 574)
at = [i for i, l in enumerate(lines) if re.match(r"^\s+(read = GamePeer\.connection_counts\(es\.connection\.pid\)|cc = Connection\.status\(es\.connection\.pid\)\.counts)", l)]
assert len(at) == 1, "the status read line must occur exactly once: %s" % at
ind = re.match(r"^(\s*)", lines[at[0]]).group(1)
seam = {
  "hold": ind + "# TEST-ONLY SEAM (close-race-test.sh; never shipped): hold before the status read until the connection has ended or the harness releases it\n"
        + ind + '(fn pid -> sp = Path.join(out, "seam"); File.write!(sp <> ".reached", PeerKit.now() <> "\\n"); Enum.find(1..400, fn _ -> not Process.alive?(pid) or File.exists?(sp <> ".release") or (Process.sleep(50) && false) end); File.write!(sp <> ".passed", "#{PeerKit.now()} connection alive #{Process.alive?(pid)}\\n") end).(es.connection.pid)',
  "fail": ind + "# TEST-ONLY SEAM (close-race-test.sh; never shipped): the status read meets a stand-in process that exits abnormally on the call\n"
        + ind + 'es = (fn es -> bad = spawn(fn -> receive do: ({:"$gen_call", _, _} -> exit(:seam_abnormal_exit)) end); File.write!(Path.join(out, "seam.reached"), PeerKit.now() <> "\\n"); %{es | connection: %{es.connection | pid: bad}} end).(es)',
}[kind]
lines.insert(at[0], seam)
open(p, "w").write("\n".join(lines))
print("seam %s inserted before line %d: %s" % (kind, at[0] + 1, lines[at[0] + 1].strip()[:120]))
PY
  local rc=$?
  diff -u "$B/kit/game-peer.exs" "$V/kit/game-peer.exs" > "$A/seam-$1.diff"
  # (the temporary manifest outside the copy, as rebundle.sh: inside, find would list it)
  ( cd "$V" && find . -type f ! -name MANIFEST.sha256 | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) > "$V.manifest.tmp" && mv "$V.manifest.tmp" "$V/MANIFEST.sha256"
  VMS=$(sha "$V/MANIFEST.sha256")
  return $rc
}

# ---- credentials: each side its own; only the public files cross ----------------------------------------------------------------
for side in mac host; do $EX "$B/kit/creds.exs" generate "$S" $side > "$A/creds-generate-$side.txt" 2>&1 || ok 1 "creds generate $side"; done
mkdir -p "$S/xfer"
for side in mac host; do cp "$S/creds-$side/own-ca.pem" "$S/xfer/$side-ca.pem"; cp "$S/creds-$side/own-identity.json" "$S/xfer/$side-identity.json"; done
$EX "$B/kit/creds.exs" import "$S" mac "$S/xfer/host-ca.pem" "$S/xfer/host-identity.json" > "$A/creds-import-mac.txt" 2>&1 || ok 1 "creds import into mac"
$EX "$B/kit/creds.exs" import "$S" host "$S/xfer/mac-ca.pem" "$S/xfer/mac-identity.json" > "$A/creds-import-host.txt" 2>&1 || ok 1 "creds import into host"
MPIN=$(jget "$S/creds-mac/own-identity.json" leaf_pin); HPIN=$(jget "$S/creds-host/own-identity.json" leaf_pin)

# gcfg <file> <port> <out> <bundle-manifest-sha256>
gcfg() {
  python3 -I - "$1" "$2" "$3" "$S" "$4" "$HPIN" <<'PY'
import json, sys
f, port, out, S, ms, hpin = sys.argv[1:7]
c = {"schema": "glacier-relay.peer-game-run/1", "run_id": "m7l3-race-test", "side": "mac", "role": "listen",
     "network": {"profile": "lan_ipv4", "prefix_length": 8, "listen": ["127.0.0.1", int(port)], "initiator": "127.0.0.1"},
     "label": "l3-mac", "expected_label": "l3-host",
     "credentials": {"cert_file": f"{S}/creds-mac/own-cert.pem", "key_file": f"{S}/creds-mac/own-key.pem",
                     "peer_ca_file": f"{S}/creds-mac/peer-ca.pem", "peer_pin": hpin},
     "course": {"profile": "m7c_out_and_back", "anchor_words": ["c2b2fae1", "416d47ae"]},
     "limits": {"lifetime_s": 60},
     "out_dir": out, "bundle": {"manifest_sha256": ms}, "runtime": {"otp_release": "28", "elixir_version_prefix": "1.19."}}
open(f, "x").write(json.dumps(c, indent=1) + "\n")
PY
}
# mac_start <case-dir> <bundle-dir> : the game-facing peer from start.sh, in the background (MBG = its pid)
mac_start() {
  sh "$2/kit/start.sh" "$2" "$1/mac.json" "$(sha "$1/mac.json")" game-peer.exs > "$1/console-mac.txt" 2>&1 &
  MBG=$!
  wait_grep "$1/console-mac.txt" "waiting for the game host" 150
}
# host_start <case-dir> <port> : the stand-in host, driven through a FIFO on fd 8 (in the state directory: drvfs has no FIFO)
host_start() {
  local fifo=$S/host-in-$(basename "$1")
  mkfifo -m 600 "$fifo" || { say "ABORT: no FIFO at $fifo"; exit 3; }
  $EX "$T/fake-host.exs" "$2" "$S/creds-host/own-cert.pem" "$S/creds-host/own-key.pem" "$S/creds-host/peer-ca.pem" "$MPIN" l3-host l3-mac < "$fifo" > "$1/host-out.txt" 2>&1 &
  HBG=$!
  exec 8> "$fifo"
  wait_grep "$1/host-out.txt" '"event":"ready"' 150
}
req() {
  local d=$1 rid; rid=$(( $(cat "$d/rid" 2>/dev/null || echo 0) + 1 )); echo "$rid" > "$d/rid"
  echo "${2%\}},\"id\":$rid}" >&8
  wait_grep "$d/host-out.txt" "\"id\":$rid[,}]" "$3" || { echo "{}"; return; }
  grep "\"id\":$rid[,}]" "$d/host-out.txt" | head -1 | sed 's/^@@//'
}
host_stop() { exec 8>&-; wait "$HBG" 2>/dev/null; }
jf() { python3 -I -c 'import json,sys; d=json.loads(sys.argv[1])
for k in sys.argv[2].split("."): d=d[int(k)] if isinstance(d,list) else (d or {}).get(k)
print(json.dumps(d) if isinstance(d,(dict,list)) else d)' "$1" "$2"; }
# up_and_go <case-dir> <bundle-dir> <manifest-sha256> : the Mac up, the host identified, the go taken
up_and_go() {
  local d=$1 port; port=$(free_port); mkdir -p "$d"; gcfg "$d/mac.json" "$port" "$d/out-mac" "$3"
  mac_start "$d" "$2" && host_start "$d" "$port" && [ "$(jf "$(req "$d" '{"op":"wait_up","ms":10000}' 120)" up)" = True ] \
    && sh "$2/kit/go.sh" "$d/out-mac" > "$d/go.txt" 2>&1 && wait_grep "$d/out-mac/go.taken" '"outcome":"started"' 50
}
# the summary's counters marker, as one line: available reason class
marker() { python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])).get("connection_counts_read") or {}; print(r.get("available"), r.get("reason"), r.get("class"))' "$1/out-mac/summary.json" 2>/dev/null || echo "no-summary"; }

if [ "$MODE" = corrected ]; then
  # ---- GamePeer.connection_counts/1, taken from the bundle's own game-peer.exs, against stand-in processes ------------------------
  cat > "$A/classify-cases.exs" <<'EXS'
[script] = System.argv()
src = File.read!(script)
a = :binary.match(src, "defmodule GamePeer do\n") |> elem(0)
{b, _} = :binary.match(src, "\nend\n", scope: {a, byte_size(src) - a})
# the script's own top-level aliases first (the module names Course, TransformWords, Connection through them)
aliases = src |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "alias ")) |> Enum.join("\n")
Code.eval_string(aliases <> "\n" <> binary_part(src, a, b + 5 - a), [], file: script)
# a stand-in connection: answers the status call as told
stand_in = fn how -> spawn(fn ->
  receive do
    {:"$gen_call", from, :status} ->
      case how do
        :reply -> GenServer.reply(from, %{counts: %{lines_out: 3, samples_out: 2}})
        :malformed -> GenServer.reply(from, %{status: :up})
        :silent -> Process.sleep(:infinity)
        {:exit, r} -> exit(r)
      end
  end
end) end
dead = spawn(fn -> :ok end); ref = Process.monitor(dead); receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
cases = [
  {"a live connection", stand_in.(:reply), {:ok, %{"lines_out" => 3, "samples_out" => 2}}},
  {"an ended connection (noproc)", dead, {:unavailable, "noproc"}},
  {"ended normally during the read", stand_in.({:exit, :normal}), {:unavailable, "ended_during"}},
  {"ended with shutdown during the read", stand_in.({:exit, :shutdown}), {:unavailable, "ended_during"}},
  {"ended with {:shutdown, _} during the read", stand_in.({:exit, {:shutdown, :closed}}), {:unavailable, "ended_during"}},
  {"an abnormal exit during the read", stand_in.({:exit, {:bad_state, :x}}), {:failed, "exit_abnormal"}},
  {"a reply without counters", stand_in.(:malformed), {:failed, "malformed_status"}},
  {"no reply within the call's 5,000 ms", stand_in.(:silent), {:failed, "timeout"}}
]
fails = for {what, pid, want} <- cases, reduce: 0 do
  n ->
    t0 = System.monotonic_time(:millisecond)
    got = GamePeer.connection_counts(pid)
    ms = System.monotonic_time(:millisecond) - t0
    IO.puts("#{if got == want, do: "PASS", else: "FAIL"} connection_counts: #{what} -> #{inspect(got)} (#{ms} ms)")
    if got == want, do: n, else: n + 1
end
IO.puts("CLASSIFY CASES: #{if fails == 0, do: "PASS", else: "FAIL"} (#{length(cases)} cases, #{fails} failed)")
EXS
  $EX "$A/classify-cases.exs" "$B/kit/game-peer.exs" > "$A/classify-cases.txt" 2>&1
  grep -q '^CLASSIFY CASES: PASS (8 cases, 0 failed)' "$A/classify-cases.txt"; ok $? "GamePeer.connection_counts/1 on stand-ins: $(grep -c '^PASS' "$A/classify-cases.txt") / 8 as specified ($(grep -o 'timeout.*' "$A/classify-cases.txt" | head -1))"
fi

# ---- the live control: the seam released while the connection is up; the counters read; then the host's close ----------------------
variant hold hold; ok $? "the scratch bundle copy with the hold seam ($(cat "$A/seam-hold.txt")); its manifest $VMS"
VHOLD=$V; VHOLDMS=$VMS
c=control; d=$A/$c
up_and_go "$d" "$VHOLD" "$VHOLDMS"; ok $? "$c: the Mac (scratch copy) up, the host identified, the go taken"
wait_file "$d/out-mac/seam.reached" 400; ok $? "$c: the course's stream ended; the seam reached (the read not yet made)"
touch "$d/out-mac/seam.release"; wait_file "$d/out-mac/seam.passed" 100
grep -q 'connection alive true' "$d/out-mac/seam.passed"; ok $? "$c: the seam released with the connection up ($(cat "$d/out-mac/seam.passed" 2>/dev/null))"
wait_grep "$d/out-mac/events.ndjson" '"event":"course_ended"' 50
r=$(req "$d" '{"op":"close"}' 50); wait $MBG; MRC=$?; host_stop
if [ "$MODE" = corrected ]; then
  [ "$MRC" = 0 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = ended_by_host ] && [ "$(marker "$d")" = "True None None" ] && [ "$(jget "$d/out-mac/summary.json" connection_counts.samples_out)" = 241 ] && [ "$(evn "$d/out-mac" finished)" = 1 ]
  ok $? "$c: exit $MRC, $(jget "$d/out-mac/summary.json" outcome); counters read: $(marker "$d"), samples_out $(jget "$d/out-mac/summary.json" connection_counts.samples_out); finished events $(evn "$d/out-mac" finished)"
else
  [ "$MRC" = 0 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = ended_by_host ] && [ "$(jget "$d/out-mac/summary.json" connection_counts.samples_out)" = 241 ]
  ok $? "$c (before the correction): exit $MRC, $(jget "$d/out-mac/summary.json" outcome); connection_counts.samples_out $(jget "$d/out-mac/summary.json" connection_counts.samples_out)"
fi

# ---- the forced race: the host closes while the seam holds; the read meets the ended connection ------------------------------------
c=race; d=$A/$c
up_and_go "$d" "$VHOLD" "$VHOLDMS"; ok $? "$c: the Mac (scratch copy) up, the host identified, the go taken"
wait_file "$d/out-mac/seam.reached" 400; ok $? "$c: the course's stream ended; the seam reached (the endpoint's snapshot lists the connection)"
r=$(req "$d" '{"op":"close"}' 50); wait_file "$d/out-mac/seam.passed" 100
grep -q 'connection alive false' "$d/out-mac/seam.passed"; ok $? "$c: the host closed; the connection's process ended before the read ($(cat "$d/out-mac/seam.passed" 2>/dev/null))"
wait $MBG; MRC=$?; host_stop
if [ "$MODE" = old ]; then
  [ "$MRC" = 1 ] && [ ! -e "$d/out-mac/summary.json" ] && [ "$(evn "$d/out-mac" finished)" = 0 ] && grep -qE 'noproc|no process' "$d/console-mac.txt"
  ok $? "$c (before the correction): REPRODUCED: exit $MRC, summary.json $( [ -e "$d/out-mac/summary.json" ] && echo present || echo absent), finished events $(evn "$d/out-mac" finished); $(grep -o '\*\* (exit) [a-z]*' "$d/console-mac.txt" | head -1)"
else
  [ "$MRC" = 0 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = ended_by_host ] && [ "$(marker "$d")" = "False connection_ended_before_the_read noproc" ] && [ "$(jget "$d/out-mac/summary.json" connection_counts)" = None ]
  ok $? "$c: exit $MRC, $(jget "$d/out-mac/summary.json" outcome); counters $(marker "$d"); connection_counts $(jget "$d/out-mac/summary.json" connection_counts) (unavailable, not zeros)"
  [ "$(jget "$d/out-mac/summary.json" sources_done.0.reason)" = course_complete ] && [ "$(jget "$d/out-mac/summary.json" sources_done.0.sent)" = 241 ] && [ "$(jget "$d/out-mac/summary.json" endpoint_counts.connections)" = 1 ]
  ok $? "$c: the source's own facts kept: reason $(jget "$d/out-mac/summary.json" sources_done.0.reason), sent $(jget "$d/out-mac/summary.json" sources_done.0.sent); one connection"
  python3 -I -c 'import json,sys
e=[json.loads(l) for l in open(sys.argv[1])]
ce=[x for x in e if x["event"]=="course_ended"]; fi=[x for x in e if x["event"]=="finished"]
sys.exit(0 if len(ce)==1 and ce[0]["connection_counts"] is None and ce[0]["connection_counts_read"]["available"] is False and len(fi)==1 and fi[0]["exit_status"]==0 else 1)' "$d/out-mac/events.ndjson"
  ok $? "$c: events: one course_ended (counters unavailable, recorded), then one finished (exit 0)"
  grep -q 'the connection ended before its counters were read (noproc)' "$d/console-mac.txt" && ! grep -q 'noproc, {GenServer' "$d/console-mac.txt"
  ok $? "$c: the console states it ($(grep -o 'the connection ended before its counters were read ([a-z_]*)' "$d/console-mac.txt")); no exit term printed"
fi
p=$(pid_of "$d/out-mac"); ! ps -p "$p" > /dev/null 2>&1; ok $? "$c: the peer process ($p) is gone"

if [ "$MODE" = corrected ]; then
  # ---- the forced unexpected failure: the read meets a process that exits abnormally -------------------------------------------
  variant fail fail; ok $? "the scratch bundle copy with the fail seam ($(cat "$A/seam-fail.txt"))"
  c=unexpected; d=$A/$c
  up_and_go "$d" "$V" "$VMS"; ok $? "$c: the Mac (scratch copy) up, the host identified, the go taken"
  wait $MBG; MRC=$?
  [ "$MRC" = 8 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = connection_status_unreadable ] && [ "$(marker "$d")" = "False status_read_failed exit_abnormal" ] && [ "$(evn "$d/out-mac" finished)" = 1 ]
  ok $? "$c: a failure, never a success: exit $MRC, $(jget "$d/out-mac/summary.json" outcome); counters $(marker "$d"); finished events $(evn "$d/out-mac" finished)"
  ! grep -q 'seam_abnormal_exit' "$d/out-mac/summary.json" "$d/out-mac/events.ndjson" "$d/console-mac.txt"; ok $? "$c: the exit's term is not printed or recorded (its class only)"
  r=$(req "$d" '{"op":"status"}' 50); host_stop
  p=$(pid_of "$d/out-mac"); ! ps -p "$p" > /dev/null 2>&1; ok $? "$c: the peer process ($p) is gone"

  # ---- through the UNMODIFIED bundle: a disconnect mid-course; an operator stop mid-course ------------------------------------------
  MS=$(sha "$B/MANIFEST.sha256")
  c=close-in-course; d=$A/$c
  up_and_go "$d" "$B" "$MS"; ok $? "$c: the Mac (the bundle under test) up, the go taken"
  sleep 2; r=$(req "$d" '{"op":"close"}' 50); wait $MBG; MRC=$?; host_stop
  m=$(marker "$d")
  [ "$MRC" = 4 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = disconnected_during_course ] && [ "$(jget "$d/out-mac/summary.json" sources_done.0.reason)" = peer_link_lost ] && [ "$(evn "$d/out-mac" finished)" = 1 ] \
    && case "$m" in "False not_read None"|"False connection_ended_before_the_read noproc"|"False connection_ended_before_the_read ended_during") true;; *) false;; esac
  ok $? "$c: a non-success: exit $MRC, $(jget "$d/out-mac/summary.json" outcome), the source ended $(jget "$d/out-mac/summary.json" sources_done.0.reason); counters $m"
  c=stop-in-course; d=$A/$c
  up_and_go "$d" "$B" "$MS"; ok $? "$c: the Mac (the bundle under test) up, the go taken"
  sleep 1; sh "$B/kit/stop.sh" "$d/out-mac" > "$d/stop.txt" 2>&1; wait $MBG; MRC=$?; r=$(req "$d" '{"op":"status"}' 50); host_stop
  [ "$MRC" = 6 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = stopped_by_signal ] && [ "$(marker "$d")" = "False not_read None" ] && [ "$(evn "$d/out-mac" finished)" = 1 ]
  ok $? "$c: exit $MRC, $(jget "$d/out-mac/summary.json" outcome); counters $(marker "$d"); finished events $(evn "$d/out-mac" finished)"
fi

# ---- the scanner over everything written, with both keys known; no process left ----------------------------------------------------
$EX "$B/kit/scan.exs" "$A" --known-key "$S/creds-mac/own-key.pem" --known-key "$S/creds-host/own-key.pem" > "$A/scan-attempt.txt.partial" 2>&1; rc=$?
mv "$A/scan-attempt.txt.partial" "$A/scan-attempt.txt"
grep -q "MATERIAL HITS: 0 " "$A/scan-attempt.txt" && grep -q "; known keys 2 " "$A/scan-attempt.txt" && [ "$rc" = 0 ]
ok $? "material scan of the attempt directory ($(grep -o '^scanned [0-9]* files' "$A/scan-attempt.txt")) with both keys known: $(grep -o 'MATERIAL HITS: [0-9]*' "$A/scan-attempt.txt")"
left=0; for f in "$A"/*/out-mac/peer.pid; do p=$(sed -n 1p "$f"); ps -p "$p" > /dev/null 2>&1 && left=$((left + 1)); done
[ "$left" = 0 ]; ok $? "no peer process left running ($left)"
say "CLOSE-RACE TESTS ($MODE): $( [ $fails = 0 ] && echo PASS || echo FAIL ) ($checks checks, $fails failed)"
[ $fails = 0 ]

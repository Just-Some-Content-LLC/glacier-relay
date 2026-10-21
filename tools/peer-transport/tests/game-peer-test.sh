#!/bin/bash
# M7-L3 — focused loopback tests of the game-facing peer (game-peer.exs, go.sh, the start.sh / stop.sh changes) from a BUNDLE,
# exactly as an operator runs it, against the stand-in game host tests/fake-host.exs (NOT the relay's game host: the real host
# path, with the run console and the native6 probe, is the M7-L3 dry run's). Loopback stands in for the LAN; this proves nothing
# about a Mac, a LAN, a firewall or another OTP build.
#   game-peer-test.sh <bundle-dir> <new-attempt-dir> <state-dir> <m7c-course-plan.json>
# <m7c-course-plan.json> is M7-C's presented course (m7c-run1/r4-ct-plan-course.json, sealed): the course the Mac sends must be
# byte-identical to it, sample for sample. <state-dir> (existing, empty, 0700, Linux filesystem) receives the disposable credentials,
# which this script never prints and the caller removes after the scan. Every check prints PASS / FAIL; the last line is the result.
set -uo pipefail
[ "$#" -eq 4 ] || { echo "usage: game-peer-test.sh <bundle-dir> <new-attempt-dir> <state-dir> <m7c-course-plan.json>" >&2; exit 2; }
B=$(cd "$1" && pwd -P); A=$2; S=$3; PLAN=$4
[ -e "$A" ] && { echo "game-peer-test: REFUSED: $A exists" >&2; exit 2; }
[ -d "$S" ] && [ -z "$(ls -A "$S")" ] || { echo "game-peer-test: REFUSED: $S must be an existing empty directory" >&2; exit 2; }
mkdir -p "$A"
T=$(cd "$(dirname "$0")" && pwd -P)
EX="elixir -pa $B/ebin/glacier_relay"
MS=$(sha256sum < "$B/MANIFEST.sha256" | cut -c1-64)
checks=0; fails=0
say() { echo "$(date -u +%FT%T.%3NZ) $*"; }
ok() { checks=$((checks + 1)); if [ "$1" = 0 ]; then say "PASS $2"; else fails=$((fails + 1)); say "FAIL $2"; fi; }
jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=(d[int(k)] if int(k) < len(d) else None) if isinstance(d,list) else (d or {}).get(k)
print(json.dumps(d) if isinstance(d,(dict,list)) else d)' "$1" "$2"; }
free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
sha() { sha256sum < "$1" | cut -c1-64; }
wait_grep() { local i=0; while ! grep -q "$2" "$1" 2>/dev/null && [ $i -lt "$3" ]; do sleep 0.1; i=$((i + 1)); done; grep -q "$2" "$1" 2>/dev/null; }
listen_lines() { ss -H -ltnp 2>/dev/null | grep "pid=$1," | awk '{print $4}' | sort | tr '\n' ' '; }
pid_of() { sed -n 1p "$1/peer.pid" 2>/dev/null; }

say "game-peer-test: bundle $B (MANIFEST.sha256 $MS); attempt $A; state $S; M7-C plan $PLAN ($(sha "$PLAN"))"
say "runtime: OTP $(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().'), Elixir $(elixir -e 'IO.write(System.version())')"

# ---- the PeerKit module of game-peer.exs is peer.exs's, byte for byte ----------------------------------------------------------
python3 -I - "$B/kit/peer.exs" "$B/kit/game-peer.exs" <<'PY' > "$A/peerkit-identity.txt" 2>&1
import hashlib, sys
def mod(p):
    s = open(p).read(); a = s.index("defmodule PeerKit do\n"); b = s.index("\nend\n", a) + 5
    return s[a:b]
m1, m2 = mod(sys.argv[1]), mod(sys.argv[2])
print("peer.exs PeerKit %s (%d lines); game-peer.exs PeerKit %s (%d lines); identical %s" % (hashlib.sha256(m1.encode()).hexdigest(), m1.count("\n"), hashlib.sha256(m2.encode()).hexdigest(), m2.count("\n"), m1 == m2))
PY
grep -q "identical True" "$A/peerkit-identity.txt"; ok $? "game-peer.exs's PeerKit module is peer.exs's, byte for byte ($(cut -c1-120 "$A/peerkit-identity.txt"))"

# ---- the expected course: M7-C's presented plan, as digest lines ----------------------------------------------------------------
EXPECT=$(python3 -I -c 'import json,sys,hashlib; d=json.load(open(sys.argv[1])); print(hashlib.sha256("".join("%d\t%d\t%s\n" % (s[0], s[1], s[2]) for s in d["sample_words"]).encode()).hexdigest(), len(d["sample_words"]), d["origin_words"], d["course"].replace(" ", "~"))' "$PLAN")
read -r EXP_DIGEST EXP_N EXP_ORIGIN EXP_DESC <<< "$EXPECT"; EXP_DESC=${EXP_DESC//\~/ }
say "M7-C's course: $EXP_N samples from $EXP_ORIGIN, digest $EXP_DIGEST, described '$EXP_DESC'"

# ---- credentials: the Mac side and the host side, each for itself; only the public files cross ----------------------------------
for side in mac host; do $EX "$B/kit/creds.exs" generate "$S" $side > "$A/creds-generate-$side.txt" 2>&1; ok $? "creds generate $side"; done
mkdir -p "$S/xfer"
for side in mac host; do cp "$S/creds-$side/own-ca.pem" "$S/xfer/$side-ca.pem"; cp "$S/creds-$side/own-identity.json" "$S/xfer/$side-identity.json"; done
$EX "$B/kit/creds.exs" import "$S" mac "$S/xfer/host-ca.pem" "$S/xfer/host-identity.json" > "$A/creds-import-mac.txt" 2>&1; ok $? "creds import into mac"
$EX "$B/kit/creds.exs" import "$S" host "$S/xfer/mac-ca.pem" "$S/xfer/mac-identity.json" > "$A/creds-import-host.txt" 2>&1; ok $? "creds import into host"
MPIN=$(jget "$S/creds-mac/own-identity.json" leaf_pin); HPIN=$(jget "$S/creds-host/own-identity.json" leaf_pin)

# gcfg <file> <port> <out> [key=json ...]
gcfg() {
  local f=$1 port=$2 out=$3; shift 3
  python3 -I - "$f" "$port" "$out" "$S" "$MS" "$HPIN" "$@" <<'PY'
import json, sys
f, port, out, S, ms, hpin = sys.argv[1:7]
c = {"schema": "glacier-relay.peer-game-run/1", "run_id": "m7l3-test", "side": "mac", "role": "listen",
     "network": {"profile": "lan_ipv4", "prefix_length": 8, "listen": ["127.0.0.1", int(port)], "initiator": "127.0.0.1"},
     "label": "l3-mac", "expected_label": "l3-host",
     "credentials": {"cert_file": f"{S}/creds-mac/own-cert.pem", "key_file": f"{S}/creds-mac/own-key.pem",
                     "peer_ca_file": f"{S}/creds-mac/peer-ca.pem", "peer_pin": hpin},
     "course": {"profile": "m7c_out_and_back", "anchor_words": ["c2b2fae1", "416d47ae"]},
     "limits": {"lifetime_s": 60},
     "out_dir": out, "bundle": {"manifest_sha256": ms}, "runtime": {"otp_release": "28", "elixir_version_prefix": "1.19."}}
for kv in sys.argv[7:]:
    k, v = kv.split("=", 1); d = c; *path, last = k.split(".")
    for p in path: d = d[p]
    if v == "DELETE": del d[last]
    else: d[last] = json.loads(v)
open(f, "x").write(json.dumps(c, indent=1) + "\n")
PY
}

# mac_start <case-dir> <port> : the game-facing peer from start.sh, in the background (MBG = its pid)
mac_start() {
  local d=$1 port=$2
  sh "$B/kit/start.sh" "$B" "$d/mac.json" "$(sha "$d/mac.json")" game-peer.exs > "$d/console-mac.txt" 2>&1 &
  MBG=$!
  wait_grep "$d/console-mac.txt" "waiting for the game host" 150
}
# host_start <case-dir> <port> : the stand-in host, driven through a FIFO on fd 8. The FIFO lives in the state directory (the Linux
# filesystem): the Windows drive (drvfs) has none ("mkfifo: Operation not supported": game-peer-tests-attempt1 of m7l3-prep)
host_start() {
  local d=$1 port=$2 fifo=$S/host-in-$(basename "$1")
  mkfifo -m 600 "$fifo" || { say "ABORT: no FIFO at $fifo"; exit 3; }
  $EX "$T/fake-host.exs" "$port" "$S/creds-host/own-cert.pem" "$S/creds-host/own-key.pem" "$S/creds-host/peer-ca.pem" "$MPIN" l3-host l3-mac < "$fifo" > "$d/host-out.txt" 2>&1 &
  HBG=$!
  exec 8> "$fifo"
  wait_grep "$d/host-out.txt" '"event":"ready"' 150
}
# req <case-dir> <json-without-id> <timeout-0.1s> : one request; prints the answer line (without @@)
req() {   # (called in $(...) subshells: the request counter lives in a file)
  local d=$1 rid; rid=$(( $(cat "$d/rid" 2>/dev/null || echo 0) + 1 )); echo "$rid" > "$d/rid"
  echo "${2%\}},\"id\":$rid}" >&8
  wait_grep "$d/host-out.txt" "\"id\":$rid[,}]" "$3" || { echo "{}"; return; }
  grep "\"id\":$rid[,}]" "$d/host-out.txt" | head -1 | sed 's/^@@//'
}
host_stop() { exec 8>&-; wait "$HBG" 2>/dev/null; }
jf() { python3 -I -c 'import json,sys; d=json.loads(sys.argv[1])
for k in sys.argv[2].split("."): d=d[int(k)] if isinstance(d,list) else (d or {}).get(k)
print(json.dumps(d) if isinstance(d,(dict,list)) else d)' "$1" "$2"; }
obs_ok() {   # every summary socket observation: observed, listening exactly the declared socket
  python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); o=s.get("socket_observations") or []
print(1 if o and all(x["status"]=="observed" and x["listening"]==[sys.argv[2]] and x["kernel_agrees"] is True for x in o) else 0, [(x["at"], x["status"], x["listening"]) for x in o])' "$1" "$2"
}

# ---- refusals before any socket (exit 2; no output directory) -------------------------------------------------------------------
refusal() {   # <name> <expect-text> [key=json ...]
  local n=$1 want=$2; shift 2; local d=$A/refuse-$n port; port=$(free_port); mkdir -p "$d"
  gcfg "$d/mac.json" "$port" "$d/out" "$@"
  sh "$B/kit/start.sh" "$B" "$d/mac.json" "$(sha "$d/mac.json")" game-peer.exs > "$d/console.txt" 2>&1; local rc=$?
  [ "$rc" = 2 ] && grep -q "$want" "$d/console.txt" && [ ! -e "$d/out" ]; ok $? "refused before any socket ($n): exit $rc, '$want', no output directory"
}
refusal anchor "are not P's" 'course.anchor_words=["00000000","00000000"]'
refusal role-connect "role must be listen" 'role="connect"'
refusal course-key "course must be exactly" 'course.speed_mps=1.0'
refusal profile "course must be exactly" 'course.profile="out_and_back"'
refusal lifetime "limits must be exactly" 'limits.lifetime_s=901'
refusal limits-key "limits must be exactly" 'limits.connect_window_s=0'
refusal schema "schema must be glacier-relay.peer-game-run/1" 'schema="glacier-relay.peer-transport-run/1"'
refusal wildcard "the network profile is refused" 'network.listen=["0.0.0.0",4760]'
d=$A/refuse-sha; mkdir -p "$d"; gcfg "$d/mac.json" "$(free_port)" "$d/out"
sh "$B/kit/start.sh" "$B" "$d/mac.json" "$(printf '0%.0s' $(seq 64))" game-peer.exs > "$d/console.txt" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q "not the approved" "$d/console.txt"; ok $? "refused before any socket (configuration sha256 mismatch): exit $rc"
sh "$B/kit/start.sh" "$B" "$d/mac.json" "$(sha "$d/mac.json")" other.exs > "$d/console-script.txt" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q "must be peer.exs or game-peer.exs" "$d/console-script.txt"; ok $? "start.sh refuses any other kit script (exit $rc)"

# ---- the normal sequence: identified; the share recorded; the go; the one course; the host closes ---------------------------------
c=normal; d=$A/$c; mkdir -p "$d"; port=$(free_port); gcfg "$d/mac.json" "$port" "$d/out-mac"
mac_start "$d" "$port"; ok $? "$c: the game-facing peer is up and waiting (no course by itself)"
MDIG=$(grep -o 'COURSE DIGEST [0-9a-f]*' "$d/console-mac.txt" | awk '{print $3}')
[ "$MDIG" = "$EXP_DIGEST" ]; ok $? "$c: the Mac's printed course digest $MDIG = M7-C's presented course ($EXP_DIGEST)"
host_start "$d" "$port"
r=$(req "$d" '{"op":"wait_up","ms":10000}' 120); [ "$(jf "$r" up)" = True ]; ok $? "$c: the stand-in host is identified by the game-facing peer"
MP=$(pid_of "$d/out-mac")
sleep 1; [ ! -e "$d/out-mac/go.taken" ] && ! grep -q "GO " "$d/console-mac.txt"; ok $? "$c: identification alone starts no course"
echo "mac pid $MP: $(listen_lines "$MP")| host pid $HBG: $(listen_lines "$HBG")|" > "$d/listeners-during.txt"
grep -q "mac pid $MP: 127.0.0.1:$port | host pid $HBG: |" "$d/listeners-during.txt"; ok $? "$c: (ss, independent) the Mac process listens only on 127.0.0.1:$port; the host listens on nothing"
r=$(req "$d" '{"op":"share","n":40,"end":true}' 100); [ "$(jf "$r" sent)" = 40 ]; ok $? "$c: the host's 40-sample share stream sent and ended"
sleep 0.5
sh "$B/kit/go.sh" "$d/out-mac" > "$d/go.txt" 2>&1; ok $? "$c: go.sh accepted ($(tail -1 "$d/go.txt" | cut -c1-160))"
grep -q '"outcome":"started"' "$d/out-mac/go.taken"; ok $? "$c: the peer took the go and started the course"
sh "$B/kit/go.sh" "$d/out-mac" > "$d/go-second.txt" 2>&1; [ $? = 2 ] && grep -q "one go per run" "$d/go-second.txt"; ok $? "$c: a second go.sh is refused"
r=$(req "$d" '{"op":"wait_course","ms":20000}' 220); echo "$r" > "$d/course-received.json"
[ "$(jf "$r" ended)" = True ] && [ "$(jf "$r" received)" = "$EXP_N" ] && [ "$(jf "$r" seqs_contiguous)" = True ]; ok $? "$c: the host received the course to its end: $(jf "$r" received) samples, contiguous"
[ "$(jf "$r" digest)" = "$EXP_DIGEST" ]; ok $? "$c: the received course is M7-C's, sample for sample (digest $(jf "$r" digest))"
[ "$(jf "$r" open.source_kind)" = synthetic ] && [ "$(jf "$r" open.course)" = "$EXP_DESC" ] && [ "$(jf "$r" open.src_clock)" = beam ]; ok $? "$c: the stream declares synthetic, src_clock beam, M7-C's course description"
[ "$(jf "$r" stream_end.reason)" = course_complete ] && [ "$(jf "$r" stream_end.sent)" = "$EXP_N" ] && [ "$(jf "$r" stream_end.last_seq)" = "$EXP_N" ]; ok $? "$c: stream.end course_complete, sent $EXP_N, last seq $EXP_N"
# the host closes only after the Mac has read its connection's counters (M7-L3 record section 15: close-race-test.sh forces the
# other order)
wait_grep "$d/out-mac/events.ndjson" '"event":"course_ended"' 50
r=$(req "$d" '{"op":"close"}' 50); [ "$(jf "$r" closed)" = True ]; ok $? "$c: the host closes the connection"
wait $MBG; MRC=$?; host_stop
[ "$MRC" = 0 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = ended_by_host ]; ok $? "$c: the Mac ends by itself: exit $MRC, $(jget "$d/out-mac/summary.json" outcome)"
[ "$(jget "$d/out-mac/summary.json" connection_counts_read.available)" = True ] && [ "$(jget "$d/out-mac/summary.json" connection_counts.samples_out)" = "$EXP_N" ] && [ "$(grep -c '"event":"finished"' "$d/out-mac/events.ndjson")" = 1 ]; ok $? "$c: the connection's counters read at the course's end (available $(jget "$d/out-mac/summary.json" connection_counts_read.available), samples_out $(jget "$d/out-mac/summary.json" connection_counts.samples_out)); one finished event"
[ "$(jget "$d/out-mac/summary.json" sinks_done.0.received)" = 40 ] && [ "$(jget "$d/out-mac/summary.json" sinks_done.0.transport_complete)" = True ] && [ "$(jget "$d/out-mac/summary.json" sinks_done.0.source_kind)" = game ]; ok $? "$c: the Mac's sink recorded the share: 40 received, transport-complete, source kind game"
[ "$(jget "$d/out-mac/summary.json" sources_done.0.sent)" = "$EXP_N" ] && [ "$(jget "$d/out-mac/summary.json" sinks_open)" = 0 ]; ok $? "$c: the Mac's source sent $EXP_N; no inbound stream left open"
o=$(obs_ok "$d/out-mac/summary.json" "127.0.0.1:$port"); [ "${o%% *}" = 1 ]; ok $? "$c: every socket observation (endpoint, identification, go, finish) is 'observed', listening exactly 127.0.0.1:$port: ${o#* }"
[ "$(grep -c '"event":"socket_observation"' "$d/out-mac/events.ndjson")" = 3 ] && [ "$(grep -c '"socket_observation":{' "$d/out-mac/events.ndjson")" = 1 ]; ok $? "$c: one observation per reporting point in events.ndjson (endpoint + 3)"
r=$(python3 -I -c 'import json,sys; t=[json.loads(l) for l in open(sys.argv[1])]; print(sum(1 for x in t if x.get("event")=="source.sample" and x.get("outcome")=="sent"), sum(1 for x in t if x.get("event")=="sink.sample"))' "$(ls "$d"/out-mac/trace/*.ndjson | head -1)")
[ "$r" = "$EXP_N 40" ]; ok $? "$c: the Mac's trace: $EXP_N course samples sent, 40 share samples recorded ($r); nothing received was ever sent"

# ---- a go before identification: refused, final; the run still ends cleanly ---------------------------------------------------------
c=go-early; d=$A/$c; mkdir -p "$d"; port=$(free_port); gcfg "$d/mac.json" "$port" "$d/out-mac"
mac_start "$d" "$port"
sh "$B/kit/go.sh" "$d/out-mac" > "$d/go.txt" 2>&1
wait_grep "$d/out-mac/go.taken" "refused: not identified" 30; ok $? "$c: a go before identification is refused and recorded"
host_start "$d" "$port"; r=$(req "$d" '{"op":"wait_up","ms":10000}' 120)
sh "$B/kit/go.sh" "$d/out-mac" > "$d/go-second.txt" 2>&1; [ $? = 2 ]; ok $? "$c: no second go after a refused one (go.sh refuses)"
sleep 1; r=$(req "$d" '{"op":"wait_course","ms":500}' 30); [ "$(jf "$r" streams)" = 0 ]; ok $? "$c: no course stream reached the host"
req "$d" '{"op":"close"}' 50 > /dev/null; wait $MBG; MRC=$?; host_stop
[ "$MRC" = 0 ] && [ "$(jget "$d/out-mac/summary.json" course.go.outcome)" = "refused: not identified: no game host connected" ]; ok $? "$c: ended by the host, exit $MRC; the summary records the refused go"

# ---- a go while the share's stream is open: refused (the phases never overlap) ----------------------------------------------------
c=go-during-share; d=$A/$c; mkdir -p "$d"; port=$(free_port); gcfg "$d/mac.json" "$port" "$d/out-mac"
mac_start "$d" "$port"; host_start "$d" "$port"; req "$d" '{"op":"wait_up","ms":10000}' 120 > /dev/null
req "$d" '{"op":"share","n":20,"end":false}' 60 > /dev/null
sh "$B/kit/go.sh" "$d/out-mac" > "$d/go.txt" 2>&1
wait_grep "$d/out-mac/go.taken" "the phases never overlap" 30; ok $? "$c: a go while the share's stream is open is refused"
req "$d" '{"op":"close"}' 50 > /dev/null; wait $MBG; MRC=$?; host_stop
[ "$MRC" = 5 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = ended_by_host_unreconciled ] && [ "$(jget "$d/out-mac/summary.json" sinks_open)" = 1 ]; ok $? "$c: the host closed with the share open: exit $MRC, unreconciled, one stream open"

# ---- the host closes during the course: exit 4, no reconnection --------------------------------------------------------------------
c=close-in-course; d=$A/$c; mkdir -p "$d"; port=$(free_port); gcfg "$d/mac.json" "$port" "$d/out-mac"
mac_start "$d" "$port"; host_start "$d" "$port"; req "$d" '{"op":"wait_up","ms":10000}' 120 > /dev/null
sh "$B/kit/go.sh" "$d/out-mac" > "$d/go.txt" 2>&1; sleep 2
req "$d" '{"op":"close"}' 50 > /dev/null; wait $MBG; MRC=$?; host_stop
[ "$MRC" = 4 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = disconnected_during_course ] && [ "$(jget "$d/out-mac/summary.json" endpoint_counts.connections)" = 1 ]; ok $? "$c: exit $MRC, disconnected during the course, one connection (no reconnection)"
[ "$(jget "$d/out-mac/summary.json" connection_counts_read.available)" = False ] && [ "$(jget "$d/out-mac/summary.json" connection_counts)" = None ]; ok $? "$c: the counters marked unavailable ($(jget "$d/out-mac/summary.json" connection_counts_read.reason)), never zeros"

# ---- stop.sh during the run: exit 6 with a summary ----------------------------------------------------------------------------------
c=stop; d=$A/$c; mkdir -p "$d"; port=$(free_port); gcfg "$d/mac.json" "$port" "$d/out-mac"
mac_start "$d" "$port"
sh "$B/kit/stop.sh" "$d/out-mac" > "$d/stop.txt" 2>&1; ok $? "$c: stop.sh accepts the game-facing peer's recorded pid"
wait $MBG; MRC=$?
[ "$MRC" = 6 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = stopped_by_signal ]; ok $? "$c: exit $MRC, stopped_by_signal, summary written"
[ "$(jget "$d/out-mac/summary.json" connection_counts_read.reason)" = not_read ]; ok $? "$c: the counters marked not read"

# ---- no game host within the lifetime: exit 3 (the minimum lifetime, 60 s) ------------------------------------------------------------
c=lifetime; d=$A/$c; mkdir -p "$d"; port=$(free_port); gcfg "$d/mac.json" "$port" "$d/out-mac"
mac_start "$d" "$port"; wait $MBG; MRC=$?
[ "$MRC" = 3 ] && [ "$(jget "$d/out-mac/summary.json" outcome)" = lifetime_expired_no_peer ]; ok $? "$c: exit $MRC, lifetime_expired_no_peer after $(jget "$d/out-mac/summary.json" elapsed_ms) ms"

# ---- the scanner over everything written, with every key known --------------------------------------------------------------------
$EX "$B/kit/scan.exs" "$A" --known-key "$S/creds-mac/own-key.pem" --known-key "$S/creds-host/own-key.pem" > "$A/scan-attempt.txt.partial" 2>&1; rc=$?
mv "$A/scan-attempt.txt.partial" "$A/scan-attempt.txt"
nf=$(grep -o '^scanned [0-9]* files' "$A/scan-attempt.txt" | grep -o '[0-9]*')
grep -q "MATERIAL HITS: 0 " "$A/scan-attempt.txt" && grep -q "; known keys 2 " "$A/scan-attempt.txt" && [ "${nf:-0}" -gt 30 ] && [ "$rc" = 0 ]
ok $? "material scan of the attempt directory ($nf files) with both keys known: $(grep -o 'MATERIAL HITS: [0-9]*' "$A/scan-attempt.txt")"
left=0; for f in "$A"/*/out-*/peer.pid; do p=$(sed -n 1p "$f"); ps -p "$p" > /dev/null 2>&1 && left=$((left + 1)); done
[ "$left" = 0 ]; ok $? "no peer process left running ($left)"
say "GAME-PEER TESTS: $( [ $fails = 0 ] && echo PASS || echo FAIL ) ($checks checks, $fails failed)"
[ $fails = 0 ]

#!/bin/bash
# M7-L1 — the loopback rehearsal of the peer transport kit (its qualification on the Windows/WSL host; README.md).
#   rehearsal.sh <bundle-dir> <new-attempt-dir> <state-dir>
# Runs the BUNDLED kit exactly as an operator would — start.sh / peer.exs / creds.exs / stop.sh / scan.exs, two separate,
# non-distributed OS processes — with the lan_ipv4 profile on 127.0.0.1 only (loopback stands in for the LAN; this proves nothing
# about a Mac, a LAN, a firewall or another OTP build). <new-attempt-dir> receives every case's configurations, outputs and console
# logs (created here; must not exist); <state-dir> (an existing, empty 0700 directory on the Linux filesystem) receives the
# disposable credentials, which this script never prints and the caller removes after scanning.
# Cases: two successful exchanges (the second a fresh restart), a wrong pin (fail closed), a wrong hello label (a connection that
# ends before identification on the listener), no peer (lifetime), a disconnect before completion (no reconnection), a stop at
# start, a listen failure (the declared port taken: exit 7), the argument refusals (exit 2 before any socket, ssl never started:
# addresses, ports, roles, the configuration / bundle / runtime pins, a modified or an extra bundle file, the output directory,
# the key, the approval), the scanner self-test and a material scan of everything written. Every check prints PASS / FAIL; the
# last line is the result.
set -uo pipefail
[ "$#" -eq 3 ] || { echo "usage: rehearsal.sh <bundle-dir> <new-attempt-dir> <state-dir>" >&2; exit 2; }
B=$(cd "$1" && pwd -P); A=$2; S=$3
[ -e "$A" ] && { echo "rehearsal: REFUSED: $A exists" >&2; exit 2; }
[ -d "$S" ] && [ -z "$(ls -A "$S")" ] || { echo "rehearsal: REFUSED: $S must be an existing empty directory" >&2; exit 2; }
mkdir -p "$A"
EX="elixir -pa $B/ebin/glacier_relay"
MS=$(sha256sum < "$B/MANIFEST.sha256" | cut -c1-64)
checks=0; fails=0
say() { echo "$(date -u +%FT%T.%3NZ) $*"; }
ok() { checks=$((checks + 1)); if [ "$1" = 0 ]; then say "PASS $2"; else fails=$((fails + 1)); say "FAIL $2"; fi; }
jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]));
for k in sys.argv[2].split("."): d=d[int(k)] if isinstance(d,list) else d.get(k)
print(json.dumps(d) if isinstance(d,(dict,list)) else d)' "$1" "$2"; }
free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

say "rehearsal: bundle $B (MANIFEST.sha256 $MS); attempt $A; state $S"
say "runtime: OTP $(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().'), Elixir $(elixir -e 'IO.write(System.version())')"

# ---- credentials: each side for itself; only the public files cross ----------------------------------------------------------
for side in lsn con zzz; do $EX "$B/kit/creds.exs" generate "$S" $side > "$A/creds-generate-$side.txt" 2>&1; ok $? "creds generate $side"; done
mkdir -p "$S/xfer"
cp "$S/creds-lsn/own-ca.pem" "$S/xfer/lsn-ca.pem"; cp "$S/creds-lsn/own-identity.json" "$S/xfer/lsn-identity.json"
cp "$S/creds-con/own-ca.pem" "$S/xfer/con-ca.pem"; cp "$S/creds-con/own-identity.json" "$S/xfer/con-identity.json"
$EX "$B/kit/creds.exs" import "$S" lsn "$S/xfer/con-ca.pem" "$S/xfer/con-identity.json" > "$A/creds-import-lsn.txt" 2>&1; ok $? "creds import into lsn"
$EX "$B/kit/creds.exs" import "$S" con "$S/xfer/lsn-ca.pem" "$S/xfer/lsn-identity.json" > "$A/creds-import-con.txt" 2>&1; ok $? "creds import into con"
$EX "$B/kit/creds.exs" import "$S" con "$S/xfer/lsn-ca.pem" "$S/xfer/lsn-identity.json" > "$A/creds-import-twice.txt" 2>&1; [ $? = 2 ]; ok $? "creds import refuses an existing peer-ca.pem"
[ "$(stat -c %a "$S/creds-lsn/own-key.pem")" = 600 ] && [ "$(stat -c %a "$S/creds-lsn")" = 700 ]; ok $? "key file 0600 in a 0700 directory"
LPIN=$(jget "$S/creds-lsn/own-identity.json" leaf_pin); CPIN=$(jget "$S/creds-con/own-identity.json" leaf_pin)
ZPIN=$(jget "$S/creds-zzz/own-identity.json" leaf_pin)
[ "$(jget "$S/creds-lsn/peer.json" peer_leaf_pin)" = "$CPIN" ] && [ "$(jget "$S/creds-con/peer.json" peer_leaf_pin)" = "$LPIN" ]; ok $? "each side pins the other's leaf"
pub=0; for side in lsn con; do for f in own-ca.pem own-identity.json peer-ca.pem peer.json; do
  [ -s "$S/creds-$side/$f" ] && ! grep -q "PRIVATE KEY" "$S/creds-$side/$f" && pub=$((pub + 1)); done; done
[ "$pub" = 8 ]; ok $? "the eight public files exist and hold no private key ($pub)"
[ "$(ls "$S/creds-lsn" | sort | tr '\n' ' ')" = "own-ca.pem own-cert.pem own-identity.json own-key.pem peer-ca.pem peer.json " ]; ok $? "exactly the expected files per side: no CA private key was written"

# ---- configuration / approval writers -------------------------------------------------------------------------------------------
# cfg <file> <side> <role> <port> <out> [key=json ...]   (later keys override; "network" etc. as JSON)
cfg() {
  local f=$1 side=$2 role=$3 port=$4 out=$5; shift 5
  python3 -I - "$f" "$side" "$role" "$port" "$out" "$S" "$MS" "$LPIN" "$CPIN" "$@" <<'PY'
import json, sys
f, side, role, port, out, S, ms, lpin, cpin = sys.argv[1:10]
port = int(port)
own, peer_pin = ("lsn", cpin) if role == "listen" else ("con", lpin)
c = {"schema": "glacier-relay.peer-transport-run/1", "run_id": "m7l1-rehearsal", "side": side, "role": role,
     "network": ({"profile": "lan_ipv4", "prefix_length": 8, "listen": ["127.0.0.1", port], "initiator": "127.0.0.1"}
                 if role == "listen" else {"profile": "lan_ipv4", "prefix_length": 8, "connect": ["127.0.0.1", port]}),
     "label": "l1-" + own, "expected_label": "l1-" + ("con" if own == "lsn" else "lsn"),
     "credentials": {"cert_file": f"{S}/creds-{own}/own-cert.pem", "key_file": f"{S}/creds-{own}/own-key.pem",
                     "peer_ca_file": f"{S}/creds-{own}/peer-ca.pem", "peer_pin": peer_pin},
     "course": {"profile": "out_and_back", "prefix_ms": 1000, "distance_m": 0.2, "speed_mps": 0.5, "hold_ms": 500, "interval_ms": 50},
     "limits": {"lifetime_s": 60, "connect_window_s": 0 if role == "listen" else 30, "start_after_up_ms": 500, "drain_ms": 500},
     "out_dir": out, "bundle": {"manifest_sha256": ms}, "runtime": {"otp_release": "28", "elixir_version_prefix": "1.19."}}
for kv in sys.argv[10:]:
    k, v = kv.split("=", 1)
    d = c
    *path, last = k.split(".")
    for p in path: d = d[p]
    if v == "DELETE": del d[last]
    else: d[last] = json.loads(v)
open(f, "x").write(json.dumps(c, indent=1) + "\n")
PY
}
# approval <file> <config-file> <reply> [recorded-offset-s] [config-sha-override]
approval() {
  python3 -I - "$@" "$MS" <<'PY'
import json, sys, hashlib, datetime
f, cfgf, reply = sys.argv[1:4]
import os
off = int(sys.argv[4]) if len(sys.argv) > 5 and sys.argv[4] != "" else 0
sha = sys.argv[5] if len(sys.argv) > 6 and sys.argv[5] != "" else hashlib.sha256(open(cfgf, "rb").read()).hexdigest()
ms = os.environ.get("APPROVAL_BUNDLE") or sys.argv[-1]
late = 10 if os.environ.get("APPROVAL_PRESENTED_LATE") else -5
now = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=off)
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
json.dump({"schema": "glacier-relay.peer-transport-approval/1", "run_id": "m7l1-rehearsal",
           "gate": "M7-L1 loopback rehearsal — TEST FIXTURE, not an operator's approval",
           "presented_utc": iso(now + datetime.timedelta(seconds=late)), "config_sha256": sha, "bundle_manifest_sha256": ms,
           "operator_reply_verbatim": reply, "recorded_utc": iso(now)}, open(f, "x"), indent=1)
PY
}
sha() { sha256sum < "$1" | cut -c1-64; }
listen_lines() { ss -H -ltnp 2>/dev/null | grep "pid=$1," | awk '{print $4}' | sort | tr '\n' ' '; }
pid_of() { sed -n 1p "$1/peer.pid" 2>/dev/null; }
wait_file() { local i=0; while [ ! -s "$1" ] && [ $i -lt "$2" ]; do sleep 0.1; i=$((i + 1)); done; [ -s "$1" ]; }
wait_grep() { local i=0; while ! grep -q "$2" "$1" 2>/dev/null && [ $i -lt "$3" ]; do sleep 0.1; i=$((i + 1)); done; grep -q "$2" "$1" 2>/dev/null; }

# exchange <case> : a listener and a connector, both from start.sh, the listener first
exchange() {
  local c=$1 port; port=$(free_port); mkdir -p "$A/$c"
  cfg "$A/$c/lsn.json" mac listen "$port" "$A/$c/out-lsn" "${@:2}"
  cfg "$A/$c/con.json" windows connect "$port" "$A/$c/out-con" \
      'approval={"file":"'"$A/$c"'/approval.json","max_age_s":1800,"accepted_replies":["Go ahead"]}'
  approval "$A/$c/approval.json" "$A/$c/con.json" "Go ahead"
  sh "$B/kit/start.sh" "$B" "$A/$c/lsn.json" "$(sha "$A/$c/lsn.json")" > "$A/$c/console-lsn.txt" 2>&1 &
  LBG=$!
  wait_file "$A/$c/out-lsn/peer.pid" 100
  wait_grep "$A/$c/console-lsn.txt" "endpoint up" 100
  echo "$port" > "$A/$c/port.txt"
  sh "$B/kit/start.sh" "$B" "$A/$c/con.json" "$(sha "$A/$c/con.json")" > "$A/$c/console-con.txt" 2>&1 &
  CBG=$!
  wait_grep "$A/$c/out-con/events.ndjson" '"peer_up"' 200
  LP=$(pid_of "$A/$c/out-lsn"); CP=$(pid_of "$A/$c/out-con")
  echo "listener pid $LP: $(listen_lines "$LP")| connector pid $CP: $(listen_lines "$CP")|" > "$A/$c/listeners-during.txt"
  wait $CBG; CRC=$?; wait $LBG; LRC=$?
  echo "listener exit $LRC; connector exit $CRC" > "$A/$c/exits.txt"
}

for c in ok1 ok2; do
  exchange $c
  say "$c: $(cat "$A/$c/exits.txt"); $(cat "$A/$c/listeners-during.txt")"
  [ "$LRC" = 0 ] && [ "$CRC" = 0 ]; ok $? "$c: both sides exit 0"
  port=$(cat "$A/$c/port.txt")
  grep -q "listener pid $LP: 127.0.0.1:$port | connector pid $CP: |" "$A/$c/listeners-during.txt"; ok $? "$c: the listener's only listening socket is 127.0.0.1:$port; the connector listens on nothing"
  for s in lsn con; do
    o=$A/$c/out-$s
    [ "$(jget "$o/summary.json" outcome)" = complete ]; ok $? "$c/$s: outcome complete"
    other=$A/$c/out-$([ $s = lsn ] && echo con || echo lsn)/summary.json
    [ "$(jget "$o/summary.json" sinks_done.0.transport_complete)" = True ]; ok $? "$c/$s: the inbound stream is transport-complete (all sent received, in order, nothing twice)"
    sent_other=$(jget "$other" sources_done.0.sent)
    [ "$(jget "$o/summary.json" sinks_done.0.received)" = "$sent_other" ] && [ "$sent_other" -gt 20 ]; ok $? "$c/$s: received = the other side's sent ($sent_other)"
    # exact accounting across the two summaries: each of the other course's samples is one of sent / spaced / dropped, and of
    # the sent ones the other side's connection may drop a stale or expired one (counted there); every other one arrived once
    tot=$(jget "$other" sources_done.0.total); sn=$(jget "$other" sources_done.0.sent); rc=$(jget "$o/summary.json" sinks_done.0.received)
    sk=$(( $(jget "$other" sources_done.0.spaced) + $(jget "$other" sources_done.0.dropped) ))
    cd_=$(( $(jget "$other" connection_counts.samples_stale) + $(jget "$other" connection_counts.samples_expired) ))
    [ $((sn + sk)) = "$tot" ] && [ $((sn - cd_)) = "$rc" ] && [ $((tot - rc)) = $((sk + cd_)) ]
    ok $? "$c/$s: total $tot = sent $sn + skipped $sk; received $rc = sent - connection drops $cd_"
    [ "$(jget "$o/summary.json" sinks_done.0.source_kind)" = synthetic ]; ok $? "$c/$s: the inbound stream is labelled synthetic"
    [ "$(jget "$o/summary.json" endpoint_counts.connections)" = 1 ] && [ "$(jget "$o/summary.json" peer_seen.generation)" = 1 ]; ok $? "$c/$s: one connection, generation 1"
    [ "$(jget "$o/summary.json" endpoint_counts.refused_address)" = 0 ] && [ "$(jget "$o/summary.json" endpoint_counts.handshake_failures)" = 0 ]; ok $? "$c/$s: no refusal on the declared path"
    grep -q '"approval":{"reply_verbatim":"Go ahead"}' "$o/events.ndjson" && [ $s = con ] || [ $s = lsn ]; ok $? "$c/$s: approval recorded verbatim where required"
    ! ps -p "$(pid_of "$o")" > /dev/null 2>&1; ok $? "$c/$s: its OS process has ended"
  done
done
b1=$(jget "$A/ok1/out-lsn/summary.json" own.boot_id); b2=$(jget "$A/ok2/out-lsn/summary.json" own.boot_id)
s1=$(jget "$A/ok2/out-con/summary.json" peer_seen.boot_id)
[ "$b1" != "$b2" ] && [ "$s1" = "$b2" ]; ok $? "restart: a fresh boot ($b1 -> $b2), seen as such by the other side; nothing inherited"

# ---- a wrong pin: fails closed on both sides, no data ----------------------------------------------------------------------------
c=wrongpin; port=$(free_port); mkdir -p "$A/$c"
cfg "$A/$c/lsn.json" mac listen "$port" "$A/$c/out-lsn" 'limits.lifetime_s=14'
cfg "$A/$c/con.json" windows connect "$port" "$A/$c/out-con" "credentials.peer_pin=\"$ZPIN\"" 'limits.lifetime_s=10' 'limits.connect_window_s=6'
sh "$B/kit/start.sh" "$B" "$A/$c/lsn.json" "$(sha "$A/$c/lsn.json")" > "$A/$c/console-lsn.txt" 2>&1 & LBG=$!
wait_grep "$A/$c/console-lsn.txt" "endpoint up" 100
sh "$B/kit/start.sh" "$B" "$A/$c/con.json" "$(sha "$A/$c/con.json")" > "$A/$c/console-con.txt" 2>&1; CRC=$?
wait $LBG; LRC=$?
[ "$CRC" = 3 ] && [ "$LRC" = 3 ]; ok $? "wrong pin: both end with exit 3 (connector $CRC, listener $LRC)"
[ "$(jget "$A/$c/out-con/summary.json" outcome)" = lifetime_expired_no_peer ] && [ "$(jget "$A/$c/out-con/summary.json" endpoint_counts.connect_failures)" -ge 3 ]; ok $? "wrong pin: the connector never identified a peer ($(jget "$A/$c/out-con/summary.json" endpoint_counts.connect_failures) refused attempts, one per second)"
[ "$(jget "$A/$c/out-lsn/summary.json" endpoint_counts.handshake_failures)" -ge 1 ] && [ "$(jget "$A/$c/out-lsn/summary.json" endpoint_counts.connections)" = 0 ]; ok $? "wrong pin: the listener refused every handshake, no connection"
[ "$(jget "$A/$c/out-lsn/summary.json" sinks_done)" = "[]" ] && [ "$(jget "$A/$c/out-con/summary.json" sinks_done)" = "[]" ]; ok $? "wrong pin: no data either way"

# ---- no peer: the lifetime ends the run --------------------------------------------------------------------------------------
c=nopeer; port=$(free_port); mkdir -p "$A/$c"
cfg "$A/$c/lsn.json" mac listen "$port" "$A/$c/out-lsn" 'limits.lifetime_s=10'
t0=$(date +%s); sh "$B/kit/start.sh" "$B" "$A/$c/lsn.json" "$(sha "$A/$c/lsn.json")" > "$A/$c/console-lsn.txt" 2>&1; LRC=$?; t1=$(date +%s)
[ "$LRC" = 3 ] && [ "$(jget "$A/$c/out-lsn/summary.json" outcome)" = lifetime_expired_no_peer ] && [ $((t1 - t0)) -le 14 ]; ok $? "no peer: exit 3 after the 10 s lifetime ($((t1 - t0)) s)"

# ---- a disconnect before completion: the connector ends, never reconnects -------------------------------------------------------
c=disconnect; port=$(free_port); mkdir -p "$A/$c"
cfg "$A/$c/lsn.json" mac listen "$port" "$A/$c/out-lsn" 'course.prefix_ms=8000'
cfg "$A/$c/con.json" windows connect "$port" "$A/$c/out-con" 'course.prefix_ms=8000'
sh "$B/kit/start.sh" "$B" "$A/$c/lsn.json" "$(sha "$A/$c/lsn.json")" > "$A/$c/console-lsn.txt" 2>&1 & LBG=$!
wait_grep "$A/$c/console-lsn.txt" "endpoint up" 100
sh "$B/kit/start.sh" "$B" "$A/$c/con.json" "$(sha "$A/$c/con.json")" > "$A/$c/console-con.txt" 2>&1 & CBG=$!
wait_grep "$A/$c/out-con/events.ndjson" '"course_started"' 200
wait_grep "$A/$c/out-lsn/events.ndjson" '"course_started"' 200
sh "$B/kit/stop.sh" "$A/$c/out-lsn" > "$A/$c/stop-lsn.txt" 2>&1; ok $? "disconnect: stop.sh ended the listener by its own recorded pid"
wait $CBG; CRC=$?; wait $LBG; LRC=$?
echo "listener exit $LRC; connector exit $CRC" > "$A/$c/exits.txt"
[ "$CRC" = 4 ] && [ "$(jget "$A/$c/out-con/summary.json" outcome)" = disconnected_before_completion ]; ok $? "disconnect: the connector ends with exit 4, disconnected before completion"
[ "$(grep -c '"peer_up"' "$A/$c/out-con/events.ndjson")" = 1 ] && [ "$(jget "$A/$c/out-con/summary.json" endpoint_counts.connections)" = 1 ]; ok $? "disconnect: one identification, no reconnection"
[ "$(jget "$A/$c/out-con/summary.json" sources_done.0.reason)" = peer_link_lost ]; ok $? "disconnect: the connector's own stream ended as peer_link_lost"
[ "$LRC" = 6 ] && [ "$(jget "$A/$c/out-lsn/summary.json" outcome)" = stopped_by_signal ]; ok $? "disconnect: the stopped listener recorded stopped_by_signal (exit $LRC) before ending"
sh "$B/kit/stop.sh" "$A/$c/out-con" > "$A/$c/stop-con-after.txt" 2>&1; grep -q "not running" "$A/$c/stop-con-after.txt"; ok $? "stop.sh on an ended run reports it, kills nothing"
echo "999999999" > "$A/$c/fake-pid"; mkdir -p "$A/$c/fakeout"; printf '%s\n%s\n' "$$" "/nonexistent.json" > "$A/$c/fakeout/peer.pid"
sh "$B/kit/stop.sh" "$A/$c/fakeout" > "$A/$c/stop-foreign.txt" 2>&1; [ $? = 2 ] && grep -q REFUSED "$A/$c/stop-foreign.txt" && kill -0 $$; ok $? "stop.sh refuses a process that is not that peer (this shell survives)"

# ---- argument refusals: exit 2 before any socket, ssl never started, no output directory ------------------------------------
refuse() {
  local name=$1 expect=$2; shift 2
  local d=$A/args-$name; mkdir -p "$d"
  local port; port=$(free_port)
  case "$name" in
    out-exists) mkdir -p "$d/out";;
  esac
  cfg "$d/cfg.json" mac "${ROLE:-listen}" "$port" "$d/out" "$@"
  local s; s=$(sha "$d/cfg.json"); [ -n "${SHA_OVERRIDE:-}" ] && s=$SHA_OVERRIDE
  [ -n "${APPROVAL:-}" ] && eval "$APPROVAL"
  local bb=${BUNDLE:-$B}
  sh "$bb/kit/start.sh" "$bb" "$d/cfg.json" "$s" > "$d/console.txt" 2>&1; local rc=$?
  local made=no; [ "$name" != out-exists ] && [ -e "$d/out" ] && made=yes
  # the evidence of "before any socket" is the exit 2 with peer.exs's own line (ssl not started) and no output directory
  [ "$rc" = 2 ] && grep -q "REFUSED (before any socket; ssl started: false)" "$d/console.txt" && grep -q -- "$expect" "$d/console.txt" && [ $made = no ]
  ok $? "refused before any socket: $name (exit $rc; '$(grep -o 'REFUSED.*' "$d/console.txt" | cut -c1-150)')"
}
refuse wildcard "unspecified" 'network.listen=["0.0.0.0", 4760]'
refuse port-80 "invalid_port" 'network.listen=["127.0.0.1", 80]'
refuse hostname "malformed_address" 'network.listen=["localhost", 4760]'
refuse ipv6 "unsupported_family" 'network.listen=["::1", 4760]'
refuse public "not_private" 'network={"profile":"lan_ipv4","prefix_length":8,"connect":["8.8.8.8",4760]}' 'role="connect"'
ROLE=connect refuse role-mismatch "role_mismatch" 'network={"profile":"lan_ipv4","prefix_length":8,"listen":["127.0.0.1",4760],"initiator":"127.0.0.1"}'
refuse loopback-default "lan_ipv4" 'network={"profile":"loopback"}'
SHA_OVERRIDE=$(printf '%064d' 0) refuse config-sha "not the approved"
refuse bundle-pin "bundle manifest" "bundle={\"manifest_sha256\":\"$(printf '%064d' 1)\"}"
refuse runtime "OTP release" 'runtime={"otp_release":"27","elixir_version_prefix":"1.19."}'
refuse out-exists "already exists"
refuse unknown-key "unknown configuration keys" 'bind_any=true'
refuse bundle-not-object "bundle must be exactly" 'bundle="x"'
# a modified and an extra bundle file, against the unchanged manifest (verifier V4/V10)
cp -a "$B" "$A/bundle-modified"; echo "an edit" >> "$A/bundle-modified/kit/README.md"
BUNDLE=$A/bundle-modified refuse bundle-modified "bundle files differ from the manifest"
cp -a "$B" "$A/bundle-extra"; : > "$A/bundle-extra/ebin/glacier_relay/Elixir.Stray.beam"
BUNDLE=$A/bundle-extra refuse bundle-extra "manifest does not list"
rm -rf "$A/bundle-modified" "$A/bundle-extra"
cp -a "$S/creds-lsn" "$S/creds-lsn-0644"; chmod 644 "$S/creds-lsn-0644/own-key.pem"
refuse key-mode "mode 0600" "credentials.key_file=\"$S/creds-lsn-0644/own-key.pem\""
rm -rf "$S/creds-lsn-0644"
# a key that PEM-decodes but whose body is no key (verifier V3): refused by the kit, never left to fail inside a handshake
mkdir -m 700 "$S/creds-badkey"; cp "$S/creds-lsn/own-cert.pem" "$S/creds-lsn/peer-ca.pem" "$S/creds-badkey/"
printf -- '-----BEGIN EC PRIVATE KEY-----\n%s\n-----END EC PRIVATE KEY-----\n' "$(head -c 60 /dev/urandom | base64 -w0)" > "$S/creds-badkey/own-key.pem"; chmod 600 "$S/creds-badkey/own-key.pem"
refuse key-not-decoding "does not decode" "credentials.key_file=\"$S/creds-badkey/own-key.pem\"" "credentials.cert_file=\"$S/creds-badkey/own-cert.pem\"" "credentials.peer_ca_file=\"$S/creds-badkey/peer-ca.pem\""
rm -rf "$S/creds-badkey"
for v in not-standalone:'Go ahead, but wait for me' word-inside:'I am ready, go ahead' ready-not-accepted:'Ready'; do
  n=${v%%:*}; r=${v#*:}
  ROLE=connect APPROVAL="approval \"\$d/approval.json\" \"\$d/cfg.json\" '$r'" refuse "approval-$n" "not a standalone approval" \
    'network={"profile":"lan_ipv4","prefix_length":8,"connect":["127.0.0.1",4760]}' 'role="connect"' \
    "approval={\"file\":\"$A/args-approval-$n/approval.json\",\"max_age_s\":1800,\"accepted_replies\":[\"Go ahead\"]}"
done
ROLE=connect APPROVAL="approval \"\$d/approval.json\" \"\$d/cfg.json\" 'Go ahead' 7200" refuse approval-too-old "old (maximum" \
  'network={"profile":"lan_ipv4","prefix_length":8,"connect":["127.0.0.1",4760]}' 'role="connect"' \
  "approval={\"file\":\"$A/args-approval-too-old/approval.json\",\"max_age_s\":1800,\"accepted_replies\":[\"Go ahead\"]}"
ROLE=connect APPROVAL="approval \"\$d/approval.json\" \"\$d/cfg.json\" 'Go ahead' '' $(printf '%064d' 2)" refuse approval-other-config "names configuration" \
  'network={"profile":"lan_ipv4","prefix_length":8,"connect":["127.0.0.1",4760]}' 'role="connect"' \
  "approval={\"file\":\"$A/args-approval-other-config/approval.json\",\"max_age_s\":1800,\"accepted_replies\":[\"Go ahead\"]}"

APPROVAL_BUNDLE=$(printf '%064d' 3) ROLE=connect APPROVAL="approval \"\$d/approval.json\" \"\$d/cfg.json\" 'Go ahead'" refuse approval-other-bundle "names bundle" \
  'network={"profile":"lan_ipv4","prefix_length":8,"connect":["127.0.0.1",4760]}' 'role="connect"' \
  "approval={\"file\":\"$A/args-approval-other-bundle/approval.json\",\"max_age_s\":1800,\"accepted_replies\":[\"Go ahead\"]}"
APPROVAL_PRESENTED_LATE=1 ROLE=connect APPROVAL="approval \"\$d/approval.json\" \"\$d/cfg.json\" 'Go ahead'" refuse approval-presented-late "recorded before its presentation" \
  'network={"profile":"lan_ipv4","prefix_length":8,"connect":["127.0.0.1",4760]}' 'role="connect"' \
  "approval={\"file\":\"$A/args-approval-presented-late/approval.json\",\"max_age_s\":1800,\"accepted_replies\":[\"Go ahead\"]}"

# ---- a wrong hello label: the listener's one connection ends before identification; no reconnection ------------------------------
c=wronglabel; port=$(free_port); mkdir -p "$A/$c"
cfg "$A/$c/lsn.json" mac listen "$port" "$A/$c/out-lsn" 'limits.lifetime_s=20'
cfg "$A/$c/con.json" windows connect "$port" "$A/$c/out-con" 'label="l1-someone-else"' 'limits.lifetime_s=20' 'limits.connect_window_s=10'
sh "$B/kit/start.sh" "$B" "$A/$c/lsn.json" "$(sha "$A/$c/lsn.json")" > "$A/$c/console-lsn.txt" 2>&1 & LBG=$!
wait_grep "$A/$c/console-lsn.txt" "endpoint up" 100
sh "$B/kit/start.sh" "$B" "$A/$c/con.json" "$(sha "$A/$c/con.json")" > "$A/$c/console-con.txt" 2>&1; CRC=$?
wait $LBG; LRC=$?
[ "$LRC" = 4 ] && [ "$(jget "$A/$c/out-lsn/summary.json" outcome)" = connection_ended_before_identification ]; ok $? "wrong label: the listener ends with exit 4, its one connection never identified ($LRC)"
[ "$CRC" = 4 ] && [ "$(jget "$A/$c/out-con/summary.json" endpoint_counts.connections)" = 1 ]; ok $? "wrong label: the connector ends with exit 4 after one connection, no reconnection ($CRC)"
[ "$(jget "$A/$c/out-lsn/summary.json" endpoint_counts.connections)" = 1 ] && [ "$(jget "$A/$c/out-lsn/summary.json" sinks_done)" = "[]" ]; ok $? "wrong label: no data reached the listener"

# ---- a stop right at the start: still a recorded stop (the trap precedes peer.pid) --------------------------------------------
c=early-stop; port=$(free_port); mkdir -p "$A/$c"
cfg "$A/$c/lsn.json" mac listen "$port" "$A/$c/out-lsn"
sh "$B/kit/start.sh" "$B" "$A/$c/lsn.json" "$(sha "$A/$c/lsn.json")" > "$A/$c/console-lsn.txt" 2>&1 & LBG=$!
wait_file "$A/$c/out-lsn/peer.pid" 100
sh "$B/kit/stop.sh" "$A/$c/out-lsn" > "$A/$c/stop.txt" 2>&1; wait $LBG; LRC=$?
[ "$LRC" = 6 ] && [ "$(jget "$A/$c/out-lsn/summary.json" outcome)" = stopped_by_signal ]; ok $? "early stop: exit 6 with its summary ($LRC)"

# ---- the declared port already taken: the endpoint cannot start (exit 7, recorded) --------------------------------------------
c=port-taken; port=$(free_port); mkdir -p "$A/$c"
python3 -I -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); time.sleep(30)' "$port" & HOLD=$!
sleep 0.5
cfg "$A/$c/lsn.json" mac listen "$port" "$A/$c/out-lsn"
sh "$B/kit/start.sh" "$B" "$A/$c/lsn.json" "$(sha "$A/$c/lsn.json")" > "$A/$c/console-lsn.txt" 2>&1; LRC=$?
kill "$HOLD"; wait "$HOLD" 2>/dev/null
[ "$LRC" = 7 ] && [ "$(jget "$A/$c/out-lsn/summary.json" outcome)" = endpoint_failed ] && grep -q eaddrinuse "$A/$c/out-lsn/summary.json"; ok $? "port taken: exit 7, endpoint_failed (eaddrinuse) recorded ($LRC)"

# ---- scans: the self-test's planted controls, then every byte this rehearsal wrote ----------------------------------------------
$EX "$B/kit/scan.exs" --selftest "$A/scan-selftest" > "$A/scan-selftest.txt" 2>&1; ok $? "scanner self-test (planted positives found by class, negatives clean)"
elixir "$B/kit/scan.exs" "$A" --known-key "$S/creds-lsn/own-key.pem" --known-key "$S/creds-con/own-key.pem" --known-key "$S/creds-zzz/own-key.pem" \
  > "$A/scan-attempt.txt.partial" 2>&1; rc=$?
mv "$A/scan-attempt.txt.partial" "$A/scan-attempt.txt"
nf=$(grep -o '^scanned [0-9]* files' "$A/scan-attempt.txt" | grep -o '[0-9]*')
grep -q "MATERIAL HITS: 0 " "$A/scan-attempt.txt" && grep -q "; known keys 3 " "$A/scan-attempt.txt" && [ "${nf:-0}" -gt 100 ] && [ "$rc" = 0 ]
ok $? "material scan of the attempt directory ($nf files) with all three keys known: $(grep -o 'MATERIAL HITS: [0-9]*' "$A/scan-attempt.txt")"

# ---- leftovers ----------------------------------------------------------------------------------------------------------------
left=0; for f in "$A"/*/out-*/peer.pid; do p=$(sed -n 1p "$f"); ps -p "$p" > /dev/null 2>&1 && left=$((left + 1)); done
[ "$left" = 0 ]; ok $? "no peer process left running ($left)"
say "REHEARSAL RESULT: $([ $fails = 0 ] && echo PASS || echo FAIL) ($checks checks, $fails failures)"
[ $fails = 0 ]

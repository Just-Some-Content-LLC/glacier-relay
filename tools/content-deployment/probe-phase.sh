#!/bin/bash
# probe-phase.sh — the owned-process lifecycle of ONE offline probe phase (M6-F2a): a phase starts its own relay node and its own
# frozen command probe, records exactly which processes it owns, and ENDS AS SOON AS ITS OUTCOME IS KNOWN: it stops only those
# processes — the node by RPC and then by its own OS pid, the probe by its own Windows PID — within a bounded teardown deadline.
# A probe's duration argument is its failsafe lifetime, never a wait. No process is ever killed by name.
# Ownership is established, not assumed:
#   the node   start-beam.sh must succeed, and the node answering as relay@<host> must report as its OS pid the very pid
#              start-beam.sh launched (beam.pid; `elixir` execs into beam.smp); otherwise the phase refuses to own it. Before a
#              signal, /proc/<pid>/cmdline is checked again (a BEAM named relay).
#   the probe  no probe image may be running when a phase launches its own; its Windows PID is then found by ANCESTRY — the
#              GlacierRelayCommandProbe.exe whose parent is the cmd.exe launched with this phase's own native-log directory on its
#              command line — so a phase whose probe never links still knows (and can stop) its probe. Before taskkill, the image
#              of that PID is checked again.
# What a stopped process left is captured (its exit code, the probe's counter lines when it printed them, every log); when a
# process had to be terminated, the record says so, and its missing final output stays missing.
# Source it after evidence-guard.sh and evg_attach; every destination goes through the guard. Functions (0 = ok, 1 = failed):
#   pp_beam_start <phase-dir> <state-dir> [effectful]     start-beam.sh into <phase-dir>; the node's pid verified and recorded
#   pp_rpc <expr>                                          evaluates an Elixir expression on the node (a fresh client VM)
#   pp_wait <seconds> <expr>                               polls pp_rpc until <expr> prints "yes" (1 s apart), bounded
#   pp_probe_start <phase-dir> <tag> <native-log-dir> <probe-exe> <probe args...>
#                                                          refuses when any probe image runs; launches the probe (its token from
#                                                          GLACIER_PROBE_TOKEN through WSLENV); finds and records its Windows PID
#   pp_probe_link_pid <phase-dir> <tag>                   a cross-check after the link: the owner of the one ESTABLISHED
#                                                          connection to 127.0.0.1:4749 must be the recorded PID
#   pp_probe_killed <phase-dir> <tag> <why>                a scenario's own termination of the probe (by its recorded PID)
#   pp_probe_end <phase-dir> <tag> <deadline-s>            exited by itself -> its exit code and counters; still running ->
#                                                          taskkill /PID <its pid> /F after re-checking the image; bounded wait
#   pp_beam_end <phase-dir> <deadline-s>                   init:stop over RPC; waits for the node's pid to exit; past the deadline:
#                                                          TERM, then KILL, of that pid only (after re-checking it); ports
# Every function appends one line per event to <phase-dir>/lifecycle.tsv (utc, event, detail).
PP_T=${PP_T:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
PP_RELAY=${PP_RELAY:-$(cd "$PP_T/../.." && pwd)/relay}
PP_NODE=${PP_NODE:-relay@$(hostname -s)}
PP_IMG=GlacierRelayCommandProbe.exe
PP_PROBE_WSL=""; PP_PROBE_PID=""; PP_PROBE_KILLED=""

pp_log() {   # <phase-dir> <event> <detail...>
  local d=$1 ev=$2; shift 2
  local f; f=$(evg_log "$d/lifecycle.tsv") || return 2
  printf '%s\t%s\t%s\n' "$(date -u +%FT%T.%3NZ)" "$ev" "$*" >> "$f"
  printf '%s\t%s\n' "$ev" "$*"
}

pp_rpc() {
  elixir --sname "pp$RANDOM$RANDOM" -e "case :net_kernel.connect_node(:\"$PP_NODE\") do true -> (fn -> $1 end).(); _ -> IO.puts(\"nodedown\") end" 2>/dev/null | tail -1
}

pp_wait() {   # <seconds> <expression printing yes|no>
  local i
  for i in $(seq 1 "$1"); do [ "$(pp_rpc "$2")" = yes ] && return 0; sleep 1; done
  return 1
}

_pp_is_relay_beam() {   # <pid>: a live BEAM whose command line names the relay node
  [ -r "/proc/$1/cmdline" ] && tr '\0' ' ' < "/proc/$1/cmdline" | grep -q 'beam' && tr '\0' ' ' < "/proc/$1/cmdline" | grep -qE -- '-sname relay( |$)'
}

pp_beam_start() {
  local d=$1 s=$2 mode=${3:-inert} rc lp pid t0
  t0=$(date +%s%3N)
  bash "$PP_T/start-beam.sh" "$d" "$s" "$mode" > "$(evg_out "$d/beam-start.txt")" 2>&1; rc=$?
  lp=$(cat "$d/beam.pid" 2>/dev/null)
  if [ "$rc" != 0 ]; then
    # start-beam.sh refused or failed; a launcher it did start (beam.pid) is still this phase's to stop
    [ -n "$lp" ] && _pp_is_relay_beam "$lp" && printf 'beam\t%s\t%s\n' "$lp" "$PP_NODE (start-beam.sh rc $rc)" >> "$(evg_log "$d/owned.tsv")"
    pp_log "$d" beam.start.FAILED "start-beam.sh rc $rc: $(tail -2 "$d/beam-start.txt" | tr '\n' ' ' | cut -c1-200)" > /dev/null; return 1
  fi
  pid=$(pp_rpc 'IO.puts(:rpc.call(:"'"$PP_NODE"'", :os, :getpid, []))')
  if [ -z "$lp" ] || [ "$pid" != "$lp" ]; then
    [ -n "$lp" ] && _pp_is_relay_beam "$lp" && printf 'beam\t%s\t%s\n' "$lp" "$PP_NODE (launcher; the answering node differs)" >> "$(evg_log "$d/owned.tsv")"
    pp_log "$d" beam.start.NOT-OWNED "the node answering as $PP_NODE reports os pid '$pid', not the launched pid '$lp': not adopted" > /dev/null; return 1
  fi
  printf 'beam\t%s\t%s\n' "$pid" "$PP_NODE" >> "$(evg_log "$d/owned.tsv")"
  pp_log "$d" beam.started "node $PP_NODE os pid $pid = the launched pid ($mode; $(( $(date +%s%3N) - t0 )) ms)" > /dev/null
}

pp_probe_start() {   # <phase-dir> <tag> <native-log-dir> <probe-exe> <args...>
  local d=$1 tag=$2 nl=$3 exe=$4; shift 4
  local o nlw i out
  PP_PROBE_WSL=""; PP_PROBE_PID=""; PP_PROBE_KILLED=""
  if tasklist.exe /FI "IMAGENAME eq $PP_IMG" /FO CSV /NH 2>/dev/null | tr -d '\r' | grep -qi "^\"$PP_IMG\""; then
    pp_log "$d" probe.start.REFUSED "$tag: a $PP_IMG is already running (not this phase's): nothing launched" > /dev/null; return 1
  fi
  o=$(evg_out "$d/probe-$tag.txt") || return 2; nlw=$(evg_win "$nl") || return 2
  cmd.exe /c "$(wslpath -w "$PP_T/run-probe-m6f.cmd")" "$nlw" "$(wslpath -w "$exe")" "$@" > "$o" 2>&1 &
  PP_PROBE_WSL=$!
  printf 'probe-wsl\t%s\t%s\n' "$PP_PROBE_WSL" "$tag" >> "$(evg_log "$d/owned.tsv")"
  # the probe's Windows PID by ancestry: the child probe of the cmd.exe whose command line carries this phase's log directory
  for i in $(seq 1 20); do
    out=$(powershell.exe -NoProfile -Command "\$p = Get-CimInstance Win32_Process -Filter \"Name='cmd.exe'\" | Where-Object { \$_.CommandLine -like '*$nlw*' }; foreach (\$c in \$p) { Get-CimInstance Win32_Process -Filter \"ParentProcessId=\$(\$c.ProcessId) AND Name='$PP_IMG'\" | ForEach-Object { \$_.ProcessId } }" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$')
    [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && break; sleep 0.25
  done
  if [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ]; then
    PP_PROBE_PID=$out; printf 'probe-win\t%s\t%s %s\n' "$PP_PROBE_PID" "$tag" "$PP_IMG" >> "$(evg_log "$d/owned.tsv")"
    pp_log "$d" probe.launched "$tag: WSL interop pid $PP_PROBE_WSL, Windows PID $PP_PROBE_PID (the child of this phase's cmd.exe); args $* (the duration argument is the failsafe lifetime)" > /dev/null
  else
    pp_log "$d" probe.pid.UNKNOWN "$tag: WSL interop pid $PP_PROBE_WSL; the Windows PID was not found by ancestry ('$out')" > /dev/null; return 1
  fi
}

pp_probe_link_pid() {   # <phase-dir> <tag>: cross-check after the link is up
  local d=$1 tag=$2 rows
  rows=$(netstat.exe -ano 2>/dev/null | tr -d '\r' | awk '$1=="TCP" && $3 ~ /:4749$/ && $4=="ESTABLISHED" {print $5}' | sort -u | tr '\n' ' ' | sed 's/ $//')
  if [ "$rows" = "$PP_PROBE_PID" ]; then pp_log "$d" probe.link-owner "$tag: the one ESTABLISHED connection to 4749 is owned by the recorded PID $PP_PROBE_PID" > /dev/null
  else pp_log "$d" probe.link-owner.MISMATCH "$tag: connection owner(s) [$rows] vs the recorded PID $PP_PROBE_PID" > /dev/null; return 1; fi
}

_pp_image() { tasklist.exe /FI "PID eq $1" /FO CSV /NH 2>/dev/null | tr -d '\r' | head -1 | cut -d'"' -f2; }

pp_probe_killed() {   # <phase-dir> <tag> <why>: a scenario terminates the phase's own probe (by its recorded PID, image re-checked)
  local d=$1 tag=$2; shift 2
  if [ -n "$PP_PROBE_PID" ] && [ "$(_pp_image "$PP_PROBE_PID")" = "$PP_IMG" ]; then
    taskkill.exe /PID "$PP_PROBE_PID" /F > /dev/null 2>&1; PP_PROBE_KILLED="$*"
    pp_log "$d" probe.killed.by-scenario "$tag: taskkill /PID $PP_PROBE_PID /F ($*)" > /dev/null
  else pp_log "$d" probe.killed.REFUSED "$tag: PID '$PP_PROBE_PID' is not the probe (image '$(_pp_image "$PP_PROBE_PID")'); nothing killed" > /dev/null; return 1; fi
}

pp_probe_end() {   # <phase-dir> <tag> <deadline-s>
  local d=$1 tag=$2 dl=$3 t0 im rc i res=0
  t0=$(date +%s%3N)
  if [ -z "${PP_PROBE_WSL:-}" ]; then pp_log "$d" probe.end.NONE "$tag: no probe launched by this phase" > /dev/null; PP_PROBE_PID=""; return 0; fi
  if ! kill -0 "$PP_PROBE_WSL" 2>/dev/null; then
    wait "$PP_PROBE_WSL" 2>/dev/null; rc=$?
    if [ -n "$PP_PROBE_KILLED" ]; then
      pp_log "$d" probe.exited.by-scenario "$tag: terminated by the scenario ($PP_PROBE_KILLED; exit $rc); its final counter lines are not produced by a terminated probe" > /dev/null
    else
      pp_log "$d" probe.exited "$tag: exited by itself before teardown (exit $rc); counters: $(tr -d '\r' < "$d/probe-$tag.txt" | grep -c '^command probe: \(link version\|queue pushed\|transform inspected\)') counter line(s) printed" > /dev/null
    fi
    PP_PROBE_WSL=""; PP_PROBE_PID=""; PP_PROBE_KILLED=""; return 0
  fi
  if [ -n "${PP_PROBE_PID:-}" ]; then
    im=$(_pp_image "$PP_PROBE_PID")
    if [ "$im" = "$PP_IMG" ]; then
      taskkill.exe /PID "$PP_PROBE_PID" /F > /dev/null 2>&1
      pp_log "$d" probe.terminated "$tag: outcome known; taskkill /PID $PP_PROBE_PID /F (image re-checked); its final counter lines are NOT produced by a terminated probe and are not reconstructed" > /dev/null
    else
      pp_log "$d" probe.pid.gone "$tag: PID $PP_PROBE_PID is no longer the probe (image '$im'); nothing killed" > /dev/null
    fi
  else
    pp_log "$d" probe.pid.UNKNOWN "$tag: no recorded Windows PID; nothing killed (the failsafe lifetime bounds it)" > /dev/null; res=1
  fi
  for i in $(seq 1 $((dl * 10))); do kill -0 "$PP_PROBE_WSL" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$PP_PROBE_WSL" 2>/dev/null; then pp_log "$d" probe.teardown.TIMEOUT "$tag: still running after ${dl} s" > /dev/null; return 1; fi
  wait "$PP_PROBE_WSL" 2>/dev/null; rc=$?
  pp_log "$d" probe.gone "$tag: exit $rc; teardown $(( $(date +%s%3N) - t0 )) ms" > /dev/null
  PP_PROBE_WSL=""; PP_PROBE_PID=""; PP_PROBE_KILLED=""
  return $res
}

pp_beam_end() {   # <phase-dir> <deadline-s>
  local d=$1 dl=$2 pid t0 i r
  t0=$(date +%s%3N)
  pid=$(awk -F'\t' '$1=="beam" {p=$2} END {print p}' "$d/owned.tsv" 2>/dev/null)
  [ -n "$pid" ] || { pp_log "$d" beam.end.NONE "no owned node recorded by this phase" > /dev/null; return 0; }
  if ! kill -0 "$pid" 2>/dev/null; then pp_log "$d" beam.end.gone "os pid $pid already exited" > /dev/null; return 0; fi
  _pp_is_relay_beam "$pid" || { pp_log "$d" beam.end.NOT-OWNED "os pid $pid is no longer a relay BEAM: nothing signalled" > /dev/null; return 1; }
  r=$(pp_rpc ':rpc.call(:"'"$PP_NODE"'", :init, :stop, []); IO.puts("init.stop sent")')
  for i in $(seq 1 $((dl * 10))); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    _pp_is_relay_beam "$pid" && kill "$pid" 2>/dev/null; sleep 2
    kill -0 "$pid" 2>/dev/null && _pp_is_relay_beam "$pid" && kill -9 "$pid" 2>/dev/null
    pp_log "$d" beam.terminated "os pid $pid did not exit within ${dl} s of init:stop ($r); signalled (TERM, then KILL if needed)" > /dev/null
  else
    pp_log "$d" beam.stopped "os pid $pid exited after init:stop ($r); teardown $(( $(date +%s%3N) - t0 )) ms" > /dev/null
  fi
  for i in $(seq 1 50); do ss -ltn | grep -qE ':4747 |:4749 ' || break; sleep 0.1; done
  if ss -ltn | grep -qE ':4747 |:4749 '; then pp_log "$d" ports.STILL-BOUND "$(ss -ltn | grep -E ':4747 |:4749 ' | awk '{print $4}' | tr '\n' ' ')" > /dev/null; return 1; fi
  pp_log "$d" ports.free "4747 / 4749" > /dev/null
  kill -0 "$pid" 2>/dev/null && return 1 || return 0
}

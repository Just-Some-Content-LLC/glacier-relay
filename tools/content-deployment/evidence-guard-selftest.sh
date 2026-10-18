#!/bin/bash
# evidence-guard-selftest.sh <scratch-base> <report-file> — proves evidence-guard.sh on SCRATCH directories only:
# a scratch "historical" tree with a sentinel, a scratch active run root claimed exclusively, and then: an intentionally
# supplied historical destination (WSL form, Windows form, a ".." traversal from inside the active root, a symlink inside
# the active root pointing into the historical tree, a short-name alias when the volume generates one) is refused before
# the sentinel changes; a claim of an existing directory is refused and the directory is untouched; a reused label and a
# reused finalized capture are refused and the earlier content is unchanged; a retried phase gets a fresh attempt
# directory; a WSL subprocess and a Windows subprocess given guarded destinations write exactly into the fresh
# destinations and nothing under the historical tree changes. The scratch base must be on a Windows filesystem
# (/mnt/<drive>/...) so that Windows forms exist. The real evidence and the game are never touched. Every expectation is
# a check; the last line is "SELFTEST RESULT: PASS (0 failures)" or "FAIL (n)". Exit 0 only on PASS.
set -u
T="$(cd "$(dirname "$0")" && pwd)"
B=${1:?scratch base}; R=${2:?report file}
case "$B" in /mnt/[a-zA-Z]/*) ;; *) echo "ABORT: the scratch base must be on a Windows filesystem: $B"; exit 2;; esac
[ -e "$B" ] && { echo "ABORT: the scratch base exists: $B (use a fresh one)"; exit 2; }
: > "$R" || { echo "ABORT: cannot write the report $R"; exit 2; }
fail=0
say() { echo "$(date -u +%H:%M:%S.%3NZ) $*" | tee -a "$R"; }
bad() { say "FAIL: $*"; fail=$((fail + 1)); }
ok() { say "ok: $*"; }
# shellcheck source=evidence-guard.sh
. "$T/evidence-guard.sh"
say "evidence-guard self-test on scratch base $B; guard $(sha256sum "$T/evidence-guard.sh" | cut -c1-16)…"
mkdir -p "$B/historical/sealed" "$B/state-parent"
printf 'historical sentinel: must never change\n' > "$B/historical/sealed/sentinel.txt"
printf 'another sealed file\n' > "$B/historical/sealed/other.txt"
hsum() { (cd "$B/historical" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
H0=$(hsum); S0=$(sha256sum "$B/historical/sealed/sentinel.txt" | cut -c1-64)
unchanged() { [ "$(sha256sum "$B/historical/sealed/sentinel.txt" | cut -c1-64)" = "$S0" ] && [ "$(hsum)" = "$H0" ]; }
refused() { # <case> <description> <command...>: the command must fail with rc 2 and print nothing on stdout; the historical tree unchanged
  local c=$1 d=$2; shift 2; local out rc
  out=$("$@" 2>"$B/stderr.txt"); rc=$?
  if [ "$rc" = 2 ] && [ -z "$out" ] && unchanged; then ok "case $c: $d: refused (rc 2, no path printed, the sentinel and the historical tree unchanged): $(head -c 200 "$B/stderr.txt")"; else bad "case $c: $d: rc $rc, printed '$out', historical unchanged: $(unchanged && echo yes || echo NO)"; fi
}

say "== claim"
ACT=$B/active-run1; ST=$B/state-parent/state-run1
evg_claim "$ACT" "$ST" >> "$R" && [ -f "$ACT/.evidence-root" ] && [ -d "$ST" ] && ok "case 1: the run root and the state root created exclusively; claim record written (scratch state root mode $(stat -c %a "$ST"): 700 is effective on ext4, where a run's state root lives; a Windows filesystem ignores modes)" || bad "case 1: claim"
n_before=$(find "$B/historical" | wc -l)
if evg_claim "$B/historical" 2>"$B/stderr.txt"; then bad "case 2: a claim of an EXISTING directory was accepted"; else [ "$(find "$B/historical" | wc -l)" = "$n_before" ] && unchanged && ok "case 2: a claim of an existing directory refused; untouched: $(head -c 160 "$B/stderr.txt")" || bad "case 2: refused but the directory changed"; fi
if evg_claim "$ACT" 2>"$B/stderr.txt"; then bad "case 2b: re-claiming the active root was accepted"; else ok "case 2b: re-claiming the active root refused (a new run identifier is required)"; fi
evg_attach "$ACT" "$ST" || bad "attach"

say "== historical destinations are refused before anything changes"
WH=$(wslpath -w "$B/historical/sealed/sentinel.txt")
refused 3a "a WSL path into the historical tree" evg_out "$B/historical/sealed/sentinel.txt"
refused 3b "a Windows path into the historical tree ($WH)" evg_win "$WH"
refused 3c "a Windows path with forward slashes" evg_win "$(echo "$WH" | tr '\\' '/')"
refused 3d "a '..' traversal from inside the active root" evg_out "$ACT/sub/../../historical/sealed/sentinel.txt"
refused 3e "a Windows '..' traversal from inside the active root" evg_win "$(wslpath -w "$ACT")\\..\\historical\\sealed\\sentinel.txt"
ln -s "$B/historical/sealed" "$ACT/link-out"
refused 3f "a symlink INSIDE the active root pointing into the historical tree" evg_out "$ACT/link-out/sentinel.txt"
refused 3g "a live-log path into the historical tree" evg_log "$B/historical/sealed/sentinel.txt"
refused 3h "a directory under the historical tree" evg_dir "$B/historical/sealed/newdir"
[ -e "$B/historical/sealed/newdir" ] && bad "case 3h: the directory was created" || ok "case 3h: no directory created"
refused 3i "a relative path escaping the active root" bash -c 'cd "$1" && . "$2/evidence-guard.sh" && evg_attach "$1" > /dev/null && evg_out "../historical/sealed/sentinel.txt"' _ "$ACT" "$T"
refused 3j "the state root's parent (outside both roots)" evg_out "$B/state-parent/leak.txt"
short=$(cmd.exe /c "dir /x /ad \"$(wslpath -w "$B")\"" 2>/dev/null | tr -d '\r' | awk '$NF=="historical" && $(NF-1) ~ /~/ {print $(NF-1)}' | head -1)
if [ -n "$short" ]; then refused 3k "a short-name (8.3) alias of the historical tree ($short)" evg_win "$(wslpath -w "$B")\\$short\\sealed\\sentinel.txt"; else say "case 3k: the volume generated no short name for the scratch historical directory; the alias case is covered by the physical device:inode walk-up (cases 3b–3f), not exercised here"; fi

say "== reuse cannot overwrite"
A1=$(evg_attempt preflight) && [ "$A1" = "$ACT/preflight-attempt1" ] && ok "case 4a: first attempt directory $A1" || bad "case 4a: attempt 1"
printf 'attempt 1 result\n' > "$A1/preflight.txt"; a1sum=$(sha256sum "$A1/preflight.txt" | cut -c1-64)
A2=$(evg_attempt preflight) && [ "$A2" = "$ACT/preflight-attempt2" ] && [ -d "$A1" ] && [ "$(sha256sum "$A1/preflight.txt" | cut -c1-64)" = "$a1sum" ] && ok "case 4b: the retry got a FRESH attempt directory $A2; attempt 1 intact" || bad "case 4b: attempt 2"
F=$(evg_out "$ACT/final-capture.txt") && printf 'first content\n' > "$F" && fsum=$(sha256sum "$F" | cut -c1-64) && ok "case 4c: finalized capture created exclusively: $F" || bad "case 4c: evg_out"
if evg_out "$ACT/final-capture.txt" > /dev/null 2>"$B/stderr.txt"; then bad "case 4d: a second evg_out on the same capture was accepted"; else [ "$(sha256sum "$F" | cut -c1-64)" = "$fsum" ] && ok "case 4d: the reused capture path refused (no-clobber); the earlier content unchanged" || bad "case 4d: refused but the content changed"; fi
if evg_out "$A1/preflight.txt" > /dev/null 2>"$B/stderr.txt"; then bad "case 4e: overwriting an earlier attempt's file was accepted"; else [ "$(sha256sum "$A1/preflight.txt" | cut -c1-64)" = "$a1sum" ] && ok "case 4e: an earlier attempt's file refused; unchanged" || bad "case 4e: changed"; fi
printf 'x\n' > "$ACT/r2-players-result.json"
if evg_label r2-players 2>"$B/stderr.txt"; then bad "case 4f: a reused label was accepted"; else ok "case 4f: the reused label 'r2-players' refused: $(head -c 120 "$B/stderr.txt")"; fi
evg_label r3-players && ok "case 4g: a fresh label accepted" || bad "case 4g: fresh label refused"
L=$(evg_log "$ACT/operator-actions.log") && printf 'line 1\n' >> "$L" && L2=$(evg_log "$ACT/operator-actions.log") && printf 'line 2\n' >> "$L2" && [ "$(wc -l < "$ACT/operator-actions.log")" = 2 ] && ok "case 4h: a live append log of this attempt stays appendable" || bad "case 4h: live log"

say "== both launch paths resolve to the intended fresh destinations"
# the Windows launch form of the run: a .cmd script invoked through cmd.exe /c with the destination as its OWN argument
# (as run-probe-*.cmd and tests-once-*.cmd take their output paths), and a PowerShell write through the committed
# timestamps-capture.sh (as the installer's exact-timestamp manifest is written)
printf '@echo off\r\necho %%~2> "%%~1"\r\nexit /b %%ERRORLEVEL%%\r\n' > "$B/writer.cmd"; WCMD=$(wslpath -w "$B/writer.cmd")
W1=$(evg_out "$ACT/wsl-out.txt") && bash -c 'printf "written by a WSL subprocess\n" > "$1"' _ "$W1" && [ "$(cat "$ACT/wsl-out.txt")" = "written by a WSL subprocess" ] && ok "case 5a: the WSL subprocess wrote exactly $W1" || bad "case 5a: WSL subprocess"
WIN=$(evg_win "$ACT/win-out.txt") && cmd.exe /c "$WCMD" "$WIN" win-subprocess 2>/dev/null; [ "$(tr -d '\r' < "$ACT/win-out.txt" 2>/dev/null)" = "win-subprocess" ] && ok "case 5b: the Windows subprocess (cmd script, destination as its own argument) wrote exactly $WIN (= $ACT/win-out.txt)" || bad "case 5b: Windows subprocess"
WINA=$(evg_win "$(wslpath -w "$ACT")\\win-out-2.txt") && cmd.exe /c "$WCMD" "$WINA" second 2>/dev/null; [ "$(tr -d '\r' < "$ACT/win-out-2.txt" 2>/dev/null)" = "second" ] && ok "case 5c: a destination GIVEN in Windows form under the active root accepted and written: $WINA" || bad "case 5c: Windows-form destination"
WD=$(evg_win "$ACT/nativelogs") && mkdir -p "$ACT/nativelogs" && cmd.exe /c "$WCMD" "$WD\\probe.log" log 2>/dev/null; [ -f "$ACT/nativelogs/probe.log" ] && ok "case 5d: a Windows-side log DIRECTORY under the active root resolves to $WD" || bad "case 5d: log directory"
TS=$(evg_out "$ACT/timestamps.tsv") && bash "$T/timestamps-capture.sh" "$ACT" "$TS" wsl-out.txt > "$B/ts.out" 2>&1 && [ -s "$ACT/timestamps.tsv" ] && grep -q '^wsl-out.txt	' "$ACT/timestamps.tsv" && ok "case 5e: the PowerShell helper (timestamps-capture.sh) wrote its manifest exactly at $TS" || bad "case 5e: PowerShell manifest: $(tail -2 "$B/ts.out" | tr '\n' ' ')"
SP=$(evg_out "$ST/token-like.txt") && printf 'state\n' > "$SP" && ok "case 5h: a destination under the declared state root accepted: $SP" || bad "case 5h: state root destination"
say "== a sealed root is never attached again (M6-F2a)"
SR=$B/sealed-run1
( evg_claim "$SR" > /dev/null ) && printf 'sealed sentinel\n' > "$SR/sentinel.txt" && (cd "$SR" && sha256sum sentinel.txt .evidence-root > sha256.txt)
ssum=$( (cd "$SR" && find . -type f -print0 | sort -z | xargs -0 sha256sum) )
out6=$(evg_attach "$SR" 2>"$B/stderr.txt"); rc6=$?
[ "$rc6" = 2 ] && [ -z "$out6" ] && grep -q 'sealed' "$B/stderr.txt" && [ "$( (cd "$SR" && find . -type f -print0 | sort -z | xargs -0 sha256sum) )" = "$ssum" ] && ok "case 6a: attaching a sealed root (sha256.txt present) refused (rc 2); its files unchanged: $(head -c 160 "$B/stderr.txt")" || bad "case 6a: rc $rc6 out '$out6'"
out6=$(bash -c '. "$1/evidence-guard.sh"; evg_attach "$2" && evg_out "$2/added-later.txt"' _ "$T" "$SR" 2>"$B/stderr.txt"); rc6=$?
[ "$rc6" = 2 ] && [ ! -e "$SR/added-later.txt" ] && ok "case 6b: a script that attaches a sealed root before writing is refused before anything is created" || bad "case 6b: rc $rc6; added-later exists: $([ -e "$SR/added-later.txt" ] && echo yes)"
evg_attach "$ACT" "$ST" && ok "case 6c: the active (unsealed) root still attaches" || bad "case 6c: the active root no longer attaches"
unchanged && ok "case 5f: the historical tree is byte-identical after every case ($(echo "$H0" | wc -l) files)" || bad "case 5f: the historical tree CHANGED"
expected="final-capture.txt nativelogs/probe.log operator-actions.log preflight-attempt1/preflight.txt r2-players-result.json timestamps.tsv win-out-2.txt win-out.txt wsl-out.txt"
actual=$(cd "$ACT" && find . -type f ! -name .evidence-root | sed 's#^\./##' | sort | tr '\n' ' ' | sed 's/ $//')
[ "$actual" = "$expected" ] && ok "case 5g: the active root holds exactly the expected files (+ .evidence-root): $actual" || bad "case 5g: unexpected active-root contents: $actual"
say "real evidence untouched: this self-test wrote only under $B and the report $R"
if [ "$fail" = 0 ]; then say "SELFTEST RESULT: PASS (0 failures)"; else say "SELFTEST RESULT: FAIL ($fail)"; fi
exit "$fail"

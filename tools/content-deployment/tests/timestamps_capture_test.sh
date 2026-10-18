#!/bin/bash
# M6-F2a: the targeted scratch test of the narrowed timestamps-capture.sh interface (ONE relative path per call). Scratch only:
# a fresh directory on a Windows filesystem that this test creates; nothing else is read or written but the report.
#   1 one path: captured, exactly one manifest line, the fixture's deliberately nonzero sub-second creation / write ticks exact
#   2 two paths: refused (exit 2) before PowerShell runs; an existing empty manifest stays empty; an absent one is not created
#   3 no path: refused (exit 2)
#   4 the round trip the installers rely on: drvfs truncates the write time (touch), timestamps-restore.sh restores the exact
#     ticks from the one-path manifest, a recapture equals the first capture
#   5 every committed caller in this directory passes exactly one path per call
#   timestamps_capture_test.sh <fresh-scratch-dir-on-/mnt/<drive>> <report-file>
set -u
R=$(realpath -m "${1:?fresh scratch dir}"); out=$(realpath -m "${2:?report file}")
T="$(cd "$(dirname "$0")/.." && pwd)"
case "$R" in /mnt/[a-zA-Z]/*) ;; *) echo "ABORT: the scratch directory must be on a Windows filesystem: $R"; exit 2;; esac
[ -e "$R" ] && { echo "ABORT: the scratch directory exists (use a fresh one): $R"; exit 2; }
[ -e "$out" ] && [ -s "$out" ] && { echo "ABORT: the report exists and is not empty: $out"; exit 2; }
mkdir -p "$R/root/sub" || exit 2
fail=0; say() { echo "$(date -u +%H:%M:%S.%3NZ) $*" | tee -a "$out"; }; bad() { say "FAIL: $*"; fail=$((fail + 1)); }
say "timestamps-capture.sh interface test: $(sha256sum "$T/timestamps-capture.sh" | cut -c1-16)… win-timestamps.ps1 $(sha256sum "$T/win-timestamps.ps1" | cut -c1-16)…; scratch $R"
printf 'fixture one\r\n' > "$R/root/sub/a.txt"; printf 'fixture two\r\n' > "$R/root/b.txt"
C=638937700241234567; W=638937700240339088
powershell.exe -NoProfile -Command "\$f = Get-Item -LiteralPath '$(wslpath -w "$R/root/sub/a.txt")'; \$f.CreationTimeUtc = [DateTime]::new($C, 'Utc'); \$f.LastWriteTimeUtc = [DateTime]::new($W, 'Utc')" > /dev/null 2>&1
case "$(stat -c %y "$R/root/sub/a.txt")" in *.0339088*) say "fixture: nonzero sub-second write time set from the Windows side";; *) bad "fixture: the sub-second write time was not set ($(stat -c %y "$R/root/sub/a.txt"))";; esac

# 1 one path
bash "$T/timestamps-capture.sh" "$R/root" "$R/one.tsv" sub/a.txt > "$R/one.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ "$(wc -l < "$R/one.tsv")" = 1 ] && [ "$(cut -f1 "$R/one.tsv" | tr '\\' '/')" = sub/a.txt ] && [ "$(cut -f2 "$R/one.tsv")" = "$C" ] && [ "$(cut -f3 "$R/one.tsv")" = "$W" ] && [ "$(cut -f6 "$R/one.tsv")" = "$(sha256sum "$R/root/sub/a.txt" | cut -c1-64 | tr a-f A-F)" -o "$(cut -f6 "$R/one.tsv" | tr A-F a-f)" = "$(sha256sum "$R/root/sub/a.txt" | cut -c1-64)" ]; then
  say "case 1: one path captured: one line, creation $C and write $W ticks exact, the content hash recorded"
else bad "case 1: rc $rc; manifest: $(tr '\t' ' ' < "$R/one.tsv" 2>/dev/null | head -2 | tr '\n' '|'); output: $(tr '\n' ' ' < "$R/one.out" | cut -c1-200)"; fi

# 2 two paths
: > "$R/two-empty.tsv"
bash "$T/timestamps-capture.sh" "$R/root" "$R/two-empty.tsv" sub/a.txt b.txt > "$R/two.out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'exactly one relative path per call (got 2)' "$R/two.out" && [ ! -s "$R/two-empty.tsv" ] && ! grep -qi 'win-timestamps' "$R/two.out" && say "case 2: two paths refused (rc 2) before PowerShell ran; the existing empty manifest stays empty" || bad "case 2: rc $rc size $(stat -c %s "$R/two-empty.tsv") output $(tr '\n' ' ' < "$R/two.out")"
bash "$T/timestamps-capture.sh" "$R/root" "$R/two-absent.tsv" sub/a.txt b.txt > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -e "$R/two-absent.tsv" ] && say "case 2: two paths refused (rc 2); an absent manifest is not created" || bad "case 2b: rc $rc exists $([ -e "$R/two-absent.tsv" ] && echo yes)"

# 3 no path
bash "$T/timestamps-capture.sh" "$R/root" "$R/none.tsv" > "$R/none.out" 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -e "$R/none.tsv" ] && say "case 3: no path refused (rc 2)" || bad "case 3: rc $rc"

# 4 the round trip: drvfs truncation, exact restoration from the one-path manifest, recapture equal
touch "$R/root/sub/a.txt"
case "$(stat -c %y "$R/root/sub/a.txt")" in *.0339088*) bad "case 4: touch did not change the write time";; *) say "case 4: touch changed the write time (drvfs: $(stat -c %y "$R/root/sub/a.txt"))";; esac
bash "$T/timestamps-restore.sh" "$R/root" "$R/one.tsv" > "$R/restore.out" 2>&1; rc=$?
bash "$T/timestamps-capture.sh" "$R/root" "$R/again.tsv" sub/a.txt > /dev/null 2>&1
[ "$rc" = 0 ] && [ "$(cut -f1-3,5,6 "$R/again.tsv")" = "$(cut -f1-3,5,6 "$R/one.tsv")" ] && say "case 4: restored from the one-path manifest; the recapture equals the first (path, creation, write, length, hash)" || bad "case 4: restore rc $rc; again: $(tr '\t' ' ' < "$R/again.tsv" 2>/dev/null)"

# 5 the committed callers
calls=$(grep -h 'timestamps-capture.sh"' "$T"/*.sh | grep -v '^\s*#' | grep -v "^\[ \$# = 1 \]")
n=0; badc=0
while IFS= read -r line; do
  [ -n "$line" ] || continue; n=$((n + 1))
  # the words after the script up to the first redirection / list operator, split as the shell would (shlex; no expansion)
  args=$(printf '%s\n' "$line" | sed -E 's/.*timestamps-capture\.sh" //; s/ *([0-9]?>|\|\||&&|;|\|).*$//')
  cnt=$(python3 -I -c 'import shlex, sys; print(len(shlex.split(sys.argv[1])))' "$args")
  say "  call site: $cnt argument(s): $(printf '%s' "$args" | cut -c1-120)"
  [ "$cnt" = 3 ] || { badc=$((badc + 1)); say "  caller with $cnt arguments: $(printf '%s' "$line" | cut -c1-160)"; }
done <<< "$calls"
# a negative control: the same split counts a two-path call as 4 arguments (the check is not vacuous)
ctl=$(printf '%s\n' 'bash "$T/timestamps-capture.sh" "$ROOT" "$M" "a.txt" b.txt > "$x" 2>&1 || die' | sed -E 's/.*timestamps-capture\.sh" //; s/ *([0-9]?>|\|\||&&|;|\|).*$//')
[ "$(python3 -I -c 'import shlex, sys; print(len(shlex.split(sys.argv[1])))' "$ctl")" = 4 ] && say "case 5: control: a synthetic two-path call site counts 4 arguments" || bad "case 5: the control was not counted as 4"
[ "$n" -ge 2 ] && [ "$badc" = 0 ] && say "case 5: $n committed call sites, each <root> <manifest> <ONE path>" || bad "case 5: $badc of $n call sites do not pass exactly one path"

say "TIMESTAMPS INTERFACE TEST RESULT: $([ "$fail" = 0 ] && echo PASS || echo "FAIL ($fail)")"
exit "$fail"

#!/bin/bash
# Captures the exact Windows timestamps (100-ns ticks), length and SHA-256 of ONE named file under a root into a manifest,
# through win-timestamps.ps1 (WSL: the root and the manifest must be on a Windows-reachable filesystem).
#   timestamps-capture.sh <root> <manifest-out> <relative-path>
# ONE path per call (M6-F2a, the M6-F1b finding): `powershell.exe -File` hands a joined -Paths value to the helper as one string,
# so a second path was never captured as a path of its own and the call failed closed. Every caller makes one call per file
# (content-install.sh, rehearsal.sh, the run scripts); more than one path is now refused here, before PowerShell runs and before
# anything is written. Exit 0 only when the file was captured; the manifest is written only then.
set -u
ROOT=${1:?root}; OUT=${2:?manifest out}; shift 2
[ $# = 1 ] || { echo "timestamps-capture: ABORT: exactly one relative path per call (got $#); call once per file"; exit 2; }
T="$(cd "$(dirname "$0")" && pwd)"
case "$ROOT" in /mnt/[a-zA-Z]/*) ;; *) echo "timestamps-capture: ABORT: the root must be on a Windows filesystem (/mnt/<drive>/...): $ROOT"; exit 2;; esac
[ -d "$ROOT" ] || { echo "timestamps-capture: ABORT: not a directory: $ROOT"; exit 2; }
RW=$(wslpath -w "$ROOT") || exit 2; OW=$(wslpath -w "$(cd "$(dirname "$OUT")" && pwd)")\\$(basename "$OUT") || exit 2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$T/win-timestamps.ps1")" -Mode capture -Root "$RW" -Manifest "$OW" -Paths "$1" 2>&1 | tr -d '\r'
rc=${PIPESTATUS[0]}; [ "$rc" = 0 ] && [ -s "$OUT" ] || { echo "timestamps-capture: ABORT: capture failed (rc $rc)"; exit 2; }
exit 0

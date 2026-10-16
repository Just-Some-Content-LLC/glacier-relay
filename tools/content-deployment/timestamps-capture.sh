#!/bin/bash
# Captures the exact Windows timestamps (100-ns ticks), length and SHA-256 of the named files under a root into a
# manifest, through win-timestamps.ps1 (WSL: the root and the manifest must be on a Windows-reachable filesystem).
#   timestamps-capture.sh <root> <manifest-out> <relative-path>...
# Exit 0 only when every file was captured; the manifest is written only then.
set -u
ROOT=${1:?root}; OUT=${2:?manifest out}; shift 2; [ $# -ge 1 ] || { echo "timestamps-capture: no paths"; exit 2; }
T="$(cd "$(dirname "$0")" && pwd)"
case "$ROOT" in /mnt/[a-zA-Z]/*) ;; *) echo "timestamps-capture: ABORT: the root must be on a Windows filesystem (/mnt/<drive>/...): $ROOT"; exit 2;; esac
[ -d "$ROOT" ] || { echo "timestamps-capture: ABORT: not a directory: $ROOT"; exit 2; }
RW=$(wslpath -w "$ROOT") || exit 2; OW=$(wslpath -w "$(cd "$(dirname "$OUT")" && pwd)")\\$(basename "$OUT") || exit 2
paths=$(printf '%s,' "$@"); paths=${paths%,}
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$T/win-timestamps.ps1")" -Mode capture -Root "$RW" -Manifest "$OW" -Paths "$paths" 2>&1 | tr -d '\r'
rc=${PIPESTATUS[0]}; [ "$rc" = 0 ] && [ -s "$OUT" ] || { echo "timestamps-capture: ABORT: capture failed (rc $rc)"; exit 2; }
exit 0

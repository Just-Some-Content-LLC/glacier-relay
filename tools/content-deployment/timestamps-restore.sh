#!/bin/bash
# Restores the exact Windows CreationTime and LastWriteTime of the files named in a manifest written by
# timestamps-capture.sh, through win-timestamps.ps1: only for files whose current content equals the captured content
# (the byte restoration must already have succeeded), only under the given root, read back and compared exactly.
#   timestamps-restore.sh <root> <manifest>
# Exit 0 only when every entry was restored exactly; a missing manifest or any mismatch is a clear failure.
set -u
ROOT=${1:?root}; MAN=${2:?manifest}
T="$(cd "$(dirname "$0")" && pwd)"
case "$ROOT" in /mnt/[a-zA-Z]/*) ;; *) echo "timestamps-restore: ABORT: the root must be on a Windows filesystem (/mnt/<drive>/...): $ROOT"; exit 2;; esac
[ -d "$ROOT" ] || { echo "timestamps-restore: ABORT: not a directory: $ROOT"; exit 2; }
[ -f "$MAN" ] || { echo "timestamps-restore: ABORT: timestamp manifest missing: $MAN (the exact timestamps cannot be restored)"; exit 2; }
RW=$(wslpath -w "$ROOT") || exit 2; MW=$(wslpath -w "$MAN") || exit 2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$T/win-timestamps.ps1")" -Mode restore -Root "$RW" -Manifest "$MW" 2>&1 | tr -d '\r'
rc=${PIPESTATUS[0]}; [ "$rc" = 0 ] || { echo "timestamps-restore: ABORT: timestamp restoration failed (rc $rc)"; exit 2; }
exit 0

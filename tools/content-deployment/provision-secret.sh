#!/bin/bash
# Provisions the run-scoped token for ONE authorized run (M6-B2), or an ephemeral one for the tooling
# dry run: 64 lowercase hex characters from /dev/urandom written to <state-root>/token (mode 600,
# on ext4, outside the evidence tree and outside every git tree). The value is never printed.
# Refuses when a token file already exists. The cleanup removes the file.
#   token.sh <state-root>
set -u
S="$1"
[ -d "$S" ] || { echo "ABORT: state root $S missing"; exit 1; }
[ -e "$S/token" ] && { echo "ABORT: $S/token already exists"; exit 1; }
[ "$(stat -f -c %T "$S")" = "ext2/ext3" ] || { echo "ABORT: state root is not on ext4"; exit 1; }
case "$S" in /mnt/c/*) echo "ABORT: state root on the Windows filesystem"; exit 1;; esac
umask 077
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$S/token"
chmod 600 "$S/token"
if grep -qE '^[0-9a-f]{64}$' "$S/token"; then
  echo "token file $S/token: $(tr -d '\n' < "$S/token" | wc -c) hex characters, mode $(stat -c %a "$S/token"), created $(date -u +%FT%TZ) (value not shown)"
else
  rm -f "$S/token"; echo "ABORT: generated token malformed; removed"; exit 1
fi

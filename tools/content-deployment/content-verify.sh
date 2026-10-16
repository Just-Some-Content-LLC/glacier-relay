#!/bin/bash
# content-verify.sh <game-root> <baseline-dir>   — byte-identical restoration against the complete baseline:
# the full Runtime + Retail listing (sizes, mtimes), every Retail hash, the key-file hashes, the chunk0/chunk27
# package hashes when present in the baseline, no patch300 or temporary file. Exit 0 only when everything holds.
set -u
ROOT=$1; BL=$2; fail=0
say() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) verify: $*"; }
bad() { say "FAIL: $*"; fail=$((fail + 1)); }
cd "$ROOT" || { bad "no root"; exit 2; }
find Runtime Retail -type f -printf '%s\t%TY-%Tm-%TdT%TH:%TM:%TS\t%p\n' | sort -k3 > /tmp/.verify-listing.$$
if diff -q "$BL/listing.tsv" /tmp/.verify-listing.$$ > /dev/null; then say "listing identical ($(wc -l < "$BL/listing.tsv") files, sizes and mtimes)"; else bad "listing differs: $(diff "$BL/listing.tsv" /tmp/.verify-listing.$$ | grep -cE '^[<>]') lines"; diff "$BL/listing.tsv" /tmp/.verify-listing.$$ | head -10; fi
rm -f /tmp/.verify-listing.$$
(cd Retail && sha256sum -c --quiet "$BL/retail.sha256") && say "every Retail hash identical" || bad "a Retail hash differs"
sha256sum -c --quiet "$BL/key-files.sha256" && say "packagedefinition.txt, thumbs.dat, mods.ini identical" || bad "a key file differs"
[ -s "$BL/chunk0-chunk27.sha256" ] && { sha256sum -c --quiet "$BL/chunk0-chunk27.sha256" && say "chunk0 and chunk27 packages identical" || bad "a chunk0/chunk27 package differs"; }
[ "$(ls Runtime | grep -cE 'patch300|\.installing$|\.restoring$')" = 0 ] && say "no patch300 or temporary file" || bad "generated content or temporary files present"
[ "$(find . -iname '*hitmen*' | wc -l)" = 0 ] && say "no hitmen-named content" || bad "hitmen-named content present"
[ $fail = 0 ] && say "RESTORATION VERIFIED against the complete baseline" || say "RESTORATION FAILED ($fail)"
exit $fail

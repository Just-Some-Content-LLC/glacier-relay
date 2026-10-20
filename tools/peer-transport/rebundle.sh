#!/bin/bash
# M7-L3 — a KIT-ONLY bundle: the qualified bundle's compiled relay modules, byte for byte, with the kit of one exact commit
# (operator tooling; README.md). Nothing is compiled: the application's qualification is reused by identity, and the changed kit
# gets a new MANIFEST.sha256 identity (a run configuration pins it; an old manifest never covers the new kit).
#   rebundle.sh <qualified-bundle-dir> <qualified-manifest-sha256> <commit> <new-out-dir>
# Refuses unless:
#   - the qualified bundle verifies exactly as peer.exs checks it (its MANIFEST.sha256 has the given sha256; every listed file has
#     its listed sha256; the files present are exactly the listed ones);
#   - <commit>'s relay tree equals the relay_tree its BUNDLE.txt records (the modules are of the same application source);
#   - <new-out-dir> does not exist.
# Assembles <out>/peer-transport-<commit12>/ (ebin/glacier_relay copied from the qualified bundle and re-verified against its
# manifest; kit/ from `git archive <commit> tools/peer-transport`, never the working tree), BUNDLE.txt (the provenance of both
# parts), MANIFEST.sha256, the .tar.gz and its sha256. Nothing is installed, downloaded or written outside <new-out-dir>.
set -euo pipefail
[ "$#" -eq 4 ] || { echo "usage: rebundle.sh <qualified-bundle-dir> <qualified-manifest-sha256> <commit> <new-out-dir>" >&2; exit 2; }
Q=$(cd "$1" && pwd -P); QSHA=$2; OUT=$4
HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
C=$(git -C "$REPO" rev-parse --verify "$3^{commit}")
case "$OUT" in /*) ;; *) echo "rebundle.sh: the out dir must be absolute" >&2; exit 2;; esac
[ -e "$OUT" ] && { echo "rebundle.sh: REFUSED: $OUT exists" >&2; exit 2; }
say() { echo "$(date -u +%FT%TZ) rebundle: $*"; }
# 1 the qualified bundle, exactly
got=$(sha256sum < "$Q/MANIFEST.sha256" | cut -c1-64)
[ "$got" = "$QSHA" ] || { echo "rebundle.sh: REFUSED: $Q/MANIFEST.sha256 is $got, not $QSHA" >&2; exit 2; }
( cd "$Q" && sha256sum -c --quiet MANIFEST.sha256 ) || { echo "rebundle.sh: REFUSED: a qualified bundle file differs from its manifest" >&2; exit 2; }
diff <(cd "$Q" && find . -type f ! -path ./MANIFEST.sha256 | sed 's|^\./||' | LC_ALL=C sort) <(sed 's/^[0-9a-f]\{64\}  //' "$Q/MANIFEST.sha256" | LC_ALL=C sort) > /dev/null \
  || { echo "rebundle.sh: REFUSED: the qualified bundle's files are not exactly its manifest's" >&2; exit 2; }
qget() { awk -F'\t' -v k="$1" '$1 == k {print $2}' "$Q/BUNDLE.txt"; }
QREL=$(qget relay_tree); QCOMMIT=$(qget commit)
CREL=$(git -C "$REPO" rev-parse "$C:relay")
[ -n "$QREL" ] && [ "$QREL" = "$CREL" ] || { echo "rebundle.sh: REFUSED: commit $C's relay tree $CREL is not the qualified bundle's $QREL" >&2; exit 2; }
say "qualified bundle $Q (MANIFEST.sha256 $QSHA, commit $QCOMMIT, relay tree $QREL) verified; commit $C has the same relay tree"
# 2 assemble
NAME=peer-transport-${C:0:12}
mkdir "$OUT"; W=$OUT/work; mkdir -p "$W/src"
git -C "$REPO" archive "$C" tools/peer-transport | tar -x -C "$W/src"
B=$OUT/$NAME; mkdir -p "$B/ebin" "$B/kit"
cp -pR "$Q/ebin/glacier_relay" "$B/ebin/glacier_relay"
( cd "$B" && grep '  ebin/' "$Q/MANIFEST.sha256" | sha256sum -c --quiet - ) || { echo "rebundle.sh: the copied modules differ from the qualified manifest" >&2; exit 1; }
[ "$(find "$B/ebin" -type f | wc -l)" = "$(grep -c '  ebin/' "$Q/MANIFEST.sha256")" ] || { echo "rebundle.sh: the copied module set differs" >&2; exit 1; }
for f in peer.exs game-peer.exs sockets.exs creds.exs scan.exs start.sh stop.sh go.sh compat-check.sh README.md; do cp "$W/src/tools/peer-transport/$f" "$B/kit/$f"; done
chmod 755 "$B/kit/start.sh" "$B/kit/stop.sh" "$B/kit/go.sh" "$B/kit/compat-check.sh"
{
  echo "schema	glacier-relay.peer-transport-bundle/1"
  echo "commit	$C"
  echo "relay_tree	$CREL"
  echo "kit_tree	$(git -C "$REPO" rev-parse "$C:tools/peer-transport")"
  echo "mix_lock_sha256	$(qget mix_lock_sha256)"
  echo "built_utc	$(qget built_utc)"
  echo "built_with_otp	$(qget built_with_otp)"
  echo "built_with_elixir	$(qget built_with_elixir)"
  echo "mix_env	$(qget mix_env)"
  echo "modules	$(ls "$B/ebin/glacier_relay" | grep -c '\.beam$')"
  echo "ebin_from	the qualified bundle of commit $QCOMMIT (MANIFEST.sha256 $QSHA): its ebin/glacier_relay byte for byte, not recompiled"
  echo "assembled_utc	$(date -u +%FT%TZ)"
  echo "use	M7-L1 transport-only peer (kit/peer.exs) and M7-L3 game-facing peer (kit/game-peer.exs); the relay application is never started; no game, native or authority"
} > "$B/BUNDLE.txt"
( cd "$B" && find . -type f ! -name MANIFEST.sha256 | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) > "$OUT/MANIFEST.tmp"
mv "$OUT/MANIFEST.tmp" "$B/MANIFEST.sha256"
MS=$(sha256sum < "$B/MANIFEST.sha256" | cut -c1-64)
tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME"
TS=$(sha256sum < "$OUT/$NAME.tar.gz" | cut -c1-64)
echo "$TS  $NAME.tar.gz" > "$OUT/$NAME.tar.gz.sha256"
say "bundle $B: $(wc -l < "$B/MANIFEST.sha256") files; MANIFEST.sha256 sha256 $MS (the run configurations pin this)"
say "archive $OUT/$NAME.tar.gz sha256 $TS"
echo "REBUNDLE OK $MS"

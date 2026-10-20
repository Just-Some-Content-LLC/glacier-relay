#!/bin/bash
# M7-L1 — build the transport-only peer's bundle from ONE exact commit, on the Windows/WSL host (operator tooling; README.md).
#   bundle.sh <commit> <new-out-dir>
# <new-out-dir> must not exist. From `git archive <commit>` (relay/ and tools/peer-transport/ only; never the working tree) it
# compiles the relay with MIX_ENV=prod into an isolated build path (<out>/work/build) against a COPY of the repository's fetched
# dependencies (<out>/work/deps; the repository's own deps/ and _build/ are not written), refuses unless the commit's mix.lock
# equals the one those dependencies were fetched for, and assembles:
#   <out>/peer-transport-<commit12>/ebin/glacier_relay/   the relay's compiled modules (BEAM bytecode: OS- and CPU-independent;
#                                                          its OTP / Elixir pairing is recorded and checked at every start)
#   <out>/peer-transport-<commit12>/kit/                  peer.exs creds.exs scan.exs start.sh stop.sh compat-check.sh README.md
#   <out>/peer-transport-<commit12>/BUNDLE.txt            commit, trees, lock, runtime, counts
#   <out>/peer-transport-<commit12>/MANIFEST.sha256       every other file's sha256 (its own sha256 is what a run config pins)
#   <out>/peer-transport-<commit12>.tar.gz and .tar.gz.sha256
# No dependency's code is bundled: the headless peer path uses only the relay's own modules, Elixir and OTP (ssl, crypto,
# public_key); the relay application itself is never started by the kit. Nothing is installed or downloaded.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: bundle.sh <commit> <new-out-dir>" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
C=$(git -C "$REPO" rev-parse --verify "$1^{commit}")
OUT=$2
case "$OUT" in /*) ;; *) echo "bundle.sh: the out dir must be absolute" >&2; exit 2;; esac
[ -e "$OUT" ] && { echo "bundle.sh: REFUSED: $OUT exists" >&2; exit 2; }
NAME=peer-transport-${C:0:12}
mkdir "$OUT"; W=$OUT/work; mkdir -p "$W/src"
say() { echo "$(date -u +%FT%TZ) bundle: $*"; }
say "commit $C (relay tree $(git -C "$REPO" rev-parse "$C:relay"), kit tree $(git -C "$REPO" rev-parse "$C:tools/peer-transport"))"
git -C "$REPO" archive "$C" relay tools/peer-transport | tar -x -C "$W/src"
lock_c=$(sha256sum < "$W/src/relay/mix.lock" | cut -c1-64); lock_r=$(sha256sum < "$REPO/relay/mix.lock" | cut -c1-64)
[ "$lock_c" = "$lock_r" ] || { echo "bundle.sh: REFUSED: the commit's mix.lock ($lock_c) differs from the one the fetched deps are for ($lock_r)" >&2; exit 2; }
cp -a "$REPO/relay/deps" "$W/deps"
say "deps copied ($(ls "$W/deps" | wc -l) packages; lock $lock_c); compiling (MIX_ENV=prod, isolated build path)"
( cd "$W/src/relay" && MIX_ENV=prod MIX_BUILD_PATH="$W/build" MIX_DEPS_PATH="$W/deps" mix compile --warnings-as-errors ) > "$W/compile.txt" 2>&1 \
  || { echo "bundle.sh: compile FAILED (see $W/compile.txt)" >&2; tail -20 "$W/compile.txt" >&2; exit 1; }
B=$OUT/$NAME; mkdir -p "$B/ebin" "$B/kit"
cp -a "$W/build/lib/glacier_relay/ebin" "$B/ebin/glacier_relay"
for f in peer.exs creds.exs scan.exs start.sh stop.sh compat-check.sh README.md; do cp "$W/src/tools/peer-transport/$f" "$B/kit/$f"; done
chmod 755 "$B/kit/start.sh" "$B/kit/stop.sh" "$B/kit/compat-check.sh"
OTPV=$(cat "$(erl -noshell -eval 'io:format("~s",[code:root_dir()]), halt().')/releases/$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().')/OTP_VERSION")
{
  echo "schema	glacier-relay.peer-transport-bundle/1"
  echo "commit	$C"
  echo "relay_tree	$(git -C "$REPO" rev-parse "$C:relay")"
  echo "kit_tree	$(git -C "$REPO" rev-parse "$C:tools/peer-transport")"
  echo "mix_lock_sha256	$lock_c"
  echo "built_utc	$(date -u +%FT%TZ)"
  echo "built_with_otp	$OTPV"
  echo "built_with_elixir	$(elixir -e 'IO.write(System.version())')"
  echo "mix_env	prod"
  echo "modules	$(ls "$B/ebin/glacier_relay" | grep -c '\.beam$')"
  echo "use	the M7-L1 transport-only headless peer (kit/peer.exs); the relay application is never started; no game, native or authority"
} > "$B/BUNDLE.txt"
( cd "$B" && find . -type f ! -name MANIFEST.sha256 | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) > "$OUT/MANIFEST.tmp"
mv "$OUT/MANIFEST.tmp" "$B/MANIFEST.sha256"
MS=$(sha256sum < "$B/MANIFEST.sha256" | cut -c1-64)
tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME"
TS=$(sha256sum < "$OUT/$NAME.tar.gz" | cut -c1-64)
echo "$TS  $NAME.tar.gz" > "$OUT/$NAME.tar.gz.sha256"
say "bundle $B: $(wc -l < "$B/MANIFEST.sha256") files; MANIFEST.sha256 sha256 $MS (the run configurations pin this)"
say "archive $OUT/$NAME.tar.gz sha256 $TS"
echo "BUNDLE OK $MS"

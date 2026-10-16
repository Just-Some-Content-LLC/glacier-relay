#!/bin/bash
# content-install.sh <game-root> <artefacts-dir> <backup-dir> <expected.sha256>
# Installs exactly: Runtime/chunk0patch300.rpkg, Runtime/chunk27patch300.rpkg (new) and Runtime/packagedefinition.txt
# (replaced after a two-copy backup). Refuses to overwrite an existing patch300 package. Every step verified by hash.
# Never deletes or replaces any other file. Exit 0 only when the installed state is fully verified.
set -u
ROOT=$1; ART=$2; BAK=$3; EXP=$4
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) install: $*"; }
die() { log "ABORT: $*"; exit 2; }
[ -d "$ROOT/Runtime" ] && [ -d "$ROOT/Retail" ] || die "not a game root: $ROOT"
for f in chunk0patch300.rpkg chunk27patch300.rpkg packagedefinition.txt; do [ -f "$ART/$f" ] || die "artefact missing: $ART/$f"; done
(cd "$ART" && sha256sum -c --quiet "$EXP") || die "artefacts do not match the expected hashes"
for f in chunk0patch300.rpkg chunk27patch300.rpkg; do [ -e "$ROOT/Runtime/$f" ] && die "refusing to overwrite an existing $f (needs a separately reviewed recovery plan)"; done
[ -f "$ROOT/Runtime/packagedefinition.txt" ] || die "no packagedefinition.txt to back up"
mkdir -p "$BAK" || die "cannot create backup dir"
# 1. two backups of the original package definition (timestamps preserved: the restore carries the original mtime), verified
cp -p "$ROOT/Runtime/packagedefinition.txt" "$BAK/packagedefinition.txt.orig" && cp -p "$ROOT/Runtime/packagedefinition.txt" "$BAK/packagedefinition.txt.orig.2" || die "backup copy failed"
h0=$(sha256sum "$ROOT/Runtime/packagedefinition.txt" | cut -c1-64); h1=$(sha256sum "$BAK/packagedefinition.txt.orig" | cut -c1-64); h2=$(sha256sum "$BAK/packagedefinition.txt.orig.2" | cut -c1-64)
[ "$h0" = "$h1" ] && [ "$h0" = "$h2" ] || die "backup hashes differ"
echo "$h0  packagedefinition.txt.orig" > "$BAK/backup.sha256"; log "package definition backed up twice ($h0)"
# 2. the two new packages (copy to a temp name, verify, rename: an interrupted copy never leaves a half file under the final name)
for f in chunk0patch300.rpkg chunk27patch300.rpkg; do
  cp "$ART/$f" "$ROOT/Runtime/$f.installing" || die "copy failed: $f"
  a=$(sha256sum "$ART/$f" | cut -c1-64); b=$(sha256sum "$ROOT/Runtime/$f.installing" | cut -c1-64); [ "$a" = "$b" ] || die "copied $f hash differs"
  mv "$ROOT/Runtime/$f.installing" "$ROOT/Runtime/$f" || die "rename failed: $f"; log "installed $f ($a)"
done
# 3. the package definition: write beside, verify, rename over
cp "$ART/packagedefinition.txt" "$ROOT/Runtime/packagedefinition.txt.installing" || die "copy failed: packagedefinition.txt"
a=$(sha256sum "$ART/packagedefinition.txt" | cut -c1-64); b=$(sha256sum "$ROOT/Runtime/packagedefinition.txt.installing" | cut -c1-64); [ "$a" = "$b" ] || die "copied packagedefinition.txt hash differs"
mv "$ROOT/Runtime/packagedefinition.txt.installing" "$ROOT/Runtime/packagedefinition.txt" || die "rename failed: packagedefinition.txt"; log "package definition replaced ($a)"
# 4. verify the installed state
(cd "$ROOT/Runtime" && sha256sum -c --quiet "$EXP") || die "installed files do not match the expected hashes"
[ "$(ls "$ROOT/Runtime" | grep -c '\.installing$')" = 0 ] || die "a temporary file remains"
log "INSTALL VERIFIED: 2 packages added, packagedefinition.txt replaced, nothing else touched"

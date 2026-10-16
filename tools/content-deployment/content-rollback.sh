#!/bin/bash
# content-rollback.sh <game-root> <backup-dir>
# Removes the two generated packages (whatever state they are in, including .installing remnants) and restores
# packagedefinition.txt from the verified backup. Never touches any other file. Works after a crash, an
# interrupted install, a missing package or a failed replacement. Exit 0 only when the restored state is verified.
set -u
ROOT=$1; BAK=$2
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) rollback: $*"; }
die() { log "ABORT: $*"; exit 2; }
[ -d "$ROOT/Runtime" ] || die "not a game root: $ROOT"
[ -f "$BAK/packagedefinition.txt.orig" ] || [ -f "$BAK/packagedefinition.txt.orig.2" ] || die "no backup of packagedefinition.txt"
want=$(cut -c1-64 "$BAK/backup.sha256" 2>/dev/null); [ -n "$want" ] || die "backup.sha256 missing"
for f in chunk0patch300.rpkg chunk27patch300.rpkg; do
  for p in "$ROOT/Runtime/$f" "$ROOT/Runtime/$f.installing"; do [ -e "$p" ] && { rm -f "$p" && log "removed $(basename "$p")" || die "cannot remove $p"; }; done
done
rm -f "$ROOT/Runtime/packagedefinition.txt.installing"
src=""; for c in "$BAK/packagedefinition.txt.orig" "$BAK/packagedefinition.txt.orig.2"; do [ -f "$c" ] && [ "$(sha256sum "$c" | cut -c1-64)" = "$want" ] && { src=$c; break; }; done
[ -n "$src" ] || die "no backup copy matches backup.sha256"
cp -p "$src" "$ROOT/Runtime/packagedefinition.txt.restoring" && [ "$(sha256sum "$ROOT/Runtime/packagedefinition.txt.restoring" | cut -c1-64)" = "$want" ] && mv "$ROOT/Runtime/packagedefinition.txt.restoring" "$ROOT/Runtime/packagedefinition.txt" || die "restore failed"
[ "$(sha256sum "$ROOT/Runtime/packagedefinition.txt" | cut -c1-64)" = "$want" ] || die "restored packagedefinition.txt hash differs"
[ "$(ls "$ROOT/Runtime" | grep -cE 'patch300|\.installing$|\.restoring$')" = 0 ] || die "generated content or temporary files remain"
log "ROLLBACK VERIFIED: patch300 packages absent, packagedefinition.txt restored ($want)"

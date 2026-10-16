#!/bin/bash
# M6-C2 scratch installation and rollback rehearsal: a scratch game-tree MODEL outside the installation, populated with
# COPIES of the real baseline key files (packagedefinition.txt, thumbs.dat, mods.ini) and harmless placeholders for the
# unrelated packages; the SAME path-relative install / rollback / verify scripts intended for M6-C3; six cases, each
# ending in a byte-identical restoration check against the scratch baseline. The real installation is never touched.
#   rehearsal.sh <game-root> <artefacts-dir> <scratch-root> <real-baseline-listing.tsv> <report-file>
set -u
# the arguments are made absolute: the install / rollback / verify scripts cd into the tree they work on
GD=$(realpath "${1:?game root}"); ART=$(realpath "${2:?artefacts dir}"); R=$(realpath -m "${3:?scratch root}"); REALBL=$(realpath "${4:?real baseline listing}"); out=$(realpath -m "${5:?report file}")
T="$(cd "$(dirname "$0")" && pwd)"; ROOT=$R/game; BL=$R/baseline; BAK=$R/backup
: > "$out"; fail=0
say() { echo "$(date -u +%H:%M:%S.%3NZ) $*" | tee -a "$out"; }
bad() { say "FAIL: $*"; fail=$((fail + 1)); }
run() { "$@" >> "$out" 2>&1; }
rm -rf "$R"; mkdir -p "$ROOT/Runtime" "$ROOT/Retail/mods" "$BL"
# the model: real copies of the three key files; placeholders named like the real packages (content: their name)
cp "$GD/Runtime/packagedefinition.txt" "$ROOT/Runtime/"; cp "$GD/Retail/thumbs.dat" "$ROOT/Retail/"; cp "$GD/Retail/mods.ini" "$ROOT/Retail/"
for f in chunk0.rpkg chunk0patch1.rpkg chunk0patch4.rpkg chunk27.rpkg chunk27patch4.rpkg chunk3.rpkg chunk3patch4.rpkg; do printf 'placeholder %s\n' "$f" > "$ROOT/Runtime/$f"; done
printf 'placeholder dll\n' > "$ROOT/Retail/HITMAN3.exe"; printf 'placeholder\n' > "$ROOT/Retail/mods/NoPause.dll"
touch -d '2026-09-06 05:07:00' "$ROOT/Runtime"/chunk*.rpkg "$ROOT/Runtime/packagedefinition.txt"
# the model's package definition carries deliberately NONZERO sub-second creation and write timestamps (the case the real
# installation has; drvfs truncates them on copy), set from the Windows side (test fixture only; the scratch model)
powershell.exe -NoProfile -Command "\$f = Get-Item -LiteralPath '$(wslpath -w "$ROOT/Runtime/packagedefinition.txt")'; \$f.CreationTimeUtc = [DateTime]::new(638937700241234567, 'Utc'); \$f.LastWriteTimeUtc = [DateTime]::new(638937700240339088, 'Utc'); 'fixture: creation ' + \$f.CreationTimeUtc.Ticks + ' lastwrite ' + \$f.LastWriteTimeUtc.Ticks" 2>&1 | tr -d '\r' >> "$out"
case "$(stat -c %y "$ROOT/Runtime/packagedefinition.txt")" in *.0339088*) ;; *) echo "ABORT: the sub-second fixture timestamp was not set ($(stat -c %y "$ROOT/Runtime/packagedefinition.txt")); the scratch root must be on a Windows filesystem"; exit 2;; esac
# the scratch baseline with the same shape as the real one
(cd "$ROOT" && find Runtime Retail -type f -printf '%s\t%TY-%Tm-%TdT%TH:%TM:%TS\t%p\n' | sort -k3) > "$BL/listing.tsv"
(cd "$ROOT/Retail" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$BL/retail.sha256"
(cd "$ROOT" && sha256sum Runtime/packagedefinition.txt Retail/thumbs.dat Retail/mods.ini) > "$BL/key-files.sha256"
(cd "$ROOT" && sha256sum Runtime/chunk0.rpkg Runtime/chunk0patch1.rpkg Runtime/chunk0patch4.rpkg Runtime/chunk27.rpkg Runtime/chunk27patch4.rpkg) > "$BL/chunk0-chunk27.sha256"
say "scratch tree at $ROOT: $(wc -l < "$BL/listing.tsv") files; key files are COPIES of the real baseline ($(cut -c1-16 "$BL/key-files.sha256" | tr '\n' ' '))"
EXP=$R/expected.sha256; (cd "$ART" && sha256sum chunk0patch300.rpkg chunk27patch300.rpkg packagedefinition.txt) > "$EXP"
verify() { if run bash "$T/content-verify.sh" "$ROOT" "$BL"; then say "$1: restoration VERIFIED byte-identical"; else bad "$1: restoration verification failed"; fi; }
installed_ok() { (cd "$ROOT/Runtime" && sha256sum -c --quiet "$EXP") && [ -f "$BAK/packagedefinition.txt.orig" ]; }

say "== case 1: normal install, verify installed hashes, rollback, verify"
rm -rf "$BAK"; if run bash "$T/content-install.sh" "$ROOT" "$ART" "$BAK" "$EXP" && installed_ok; then say "case 1: install verified (2 packages + replaced packagedefinition.txt; backups $(ls "$BAK" | tr '\n' ' '))"; else bad "case 1: install failed"; fi
[ "$(ls "$ROOT/Runtime" | wc -l)" = $((7 + 1 + 2)) ] && say "case 1: exactly two files added under Runtime" || bad "case 1: unexpected Runtime file count $(ls "$ROOT/Runtime" | wc -l)"
run bash "$T/content-rollback.sh" "$ROOT" "$BAK" && say "case 1: rollback ran" || bad "case 1: rollback failed"; verify "case 1"

say "== case 2: interrupted installation (a .installing remnant and one package in place, the package definition untouched)"
rm -rf "$BAK"; mkdir -p "$BAK"; cp -p "$ROOT/Runtime/packagedefinition.txt" "$BAK/packagedefinition.txt.orig"; cp -p "$BAK/packagedefinition.txt.orig" "$BAK/packagedefinition.txt.orig.2"; sha256sum "$BAK/packagedefinition.txt.orig" | sed 's#  .*#  packagedefinition.txt.orig#' > "$BAK/backup.sha256"
run bash "$T/timestamps-capture.sh" "$ROOT" "$BAK/timestamps.tsv" "Runtime/packagedefinition.txt" || bad "case 2: the fixture's timestamp capture failed"   # as the installer does before its first write
cp "$ART/chunk0patch300.rpkg" "$ROOT/Runtime/chunk0patch300.rpkg"; head -c 1000 "$ART/chunk27patch300.rpkg" > "$ROOT/Runtime/chunk27patch300.rpkg.installing"
run bash "$T/content-rollback.sh" "$ROOT" "$BAK" && say "case 2: rollback ran" || bad "case 2: rollback failed"; verify "case 2"

say "== case 3: a missing generated package: the install must refuse before touching anything"
rm -rf "$BAK"; mkdir -p "$R/art-missing"; cp "$ART/chunk0patch300.rpkg" "$ART/packagedefinition.txt" "$R/art-missing/"
if run bash "$T/content-install.sh" "$ROOT" "$R/art-missing" "$BAK" "$EXP"; then bad "case 3: install did not refuse"; else say "case 3: install refused (rc $?)"; fi; verify "case 3 (nothing touched)"

say "== case 4: a failed package-definition replacement (the artefact's hash does not match after the packages were placed): the install aborts, the rollback restores"
rm -rf "$BAK"; mkdir -p "$R/art-badpd"; cp "$ART/chunk0patch300.rpkg" "$ART/chunk27patch300.rpkg" "$R/art-badpd/"; cp "$ART/packagedefinition.txt" "$R/art-badpd/packagedefinition.txt"; printf 'X' >> "$R/art-badpd/packagedefinition.txt"
if run bash "$T/content-install.sh" "$ROOT" "$R/art-badpd" "$BAK" "$EXP"; then bad "case 4: install did not abort"; else say "case 4: install aborted on the hash check (rc $?)"; fi
verify "case 4 (nothing touched: the hash check precedes every write)"
say "== case 4b: the package definition itself damaged after the packages were installed (a failed write): rollback restores from the backups"
rm -rf "$BAK"; run bash "$T/content-install.sh" "$ROOT" "$ART" "$BAK" "$EXP" && installed_ok && say "case 4b: installed" || bad "case 4b: install failed"
head -c 100 "$ART/packagedefinition.txt" > "$ROOT/Runtime/packagedefinition.txt"; printf 'garbage' > "$ROOT/Runtime/packagedefinition.txt.installing"
run bash "$T/content-rollback.sh" "$ROOT" "$BAK" && say "case 4b: rollback ran" || bad "case 4b: rollback failed"; verify "case 4b"

say "== case 5: an existing patch300 package: the install must refuse to overwrite"
rm -rf "$BAK"; printf 'someone else\n' > "$ROOT/Runtime/chunk0patch300.rpkg"
if run bash "$T/content-install.sh" "$ROOT" "$ART" "$BAK" "$EXP"; then bad "case 5: install overwrote an existing package"; else say "case 5: install refused (rc $?)"; fi
rm -f "$ROOT/Runtime/chunk0patch300.rpkg"; verify "case 5 (after removing the foreign file)"

say "== case 6: rollback with one backup copy missing and the other intact (the second copy carries it)"
rm -rf "$BAK"; run bash "$T/content-install.sh" "$ROOT" "$ART" "$BAK" "$EXP" && installed_ok && say "case 6: installed" || bad "case 6: install failed"
rm -f "$BAK/packagedefinition.txt.orig"
run bash "$T/content-rollback.sh" "$ROOT" "$BAK" && say "case 6: rollback ran from the second backup copy" || bad "case 6: rollback failed"; verify "case 6"

say "== case 7: rollback twice (idempotent) and the verify after a no-op"
run bash "$T/content-rollback.sh" "$ROOT" "$BAK" && say "case 7: second rollback ran" || bad "case 7: second rollback failed"; verify "case 7"

say "== case 8: the timestamp manifest missing: the rollback restores the bytes, then FAILS clearly; the listing differs in the sub-second field; a rollback with the manifest back succeeds (idempotent)"
rm -rf "$BAK"; run bash "$T/content-install.sh" "$ROOT" "$ART" "$BAK" "$EXP" && installed_ok && say "case 8: installed" || bad "case 8: install failed"
mv "$BAK/timestamps.tsv" "$R/timestamps.tsv.aside"
if run bash "$T/content-rollback.sh" "$ROOT" "$BAK"; then bad "case 8: rollback reported success without the timestamp manifest"; else say "case 8: rollback FAILED as required (rc $?; bytes restored, timestamps not)"; fi
[ "$(sha256sum "$ROOT/Runtime/packagedefinition.txt" | cut -c1-64)" = "$(cut -c1-64 "$BAK/backup.sha256")" ] && say "case 8: bytes restored before the failure" || bad "case 8: bytes not restored"
if run bash "$T/content-verify.sh" "$ROOT" "$BL"; then bad "case 8: verify passed although the timestamps were not restored"; else say "case 8: verify FAILED as required (the sub-second timestamp truncated by the copy)"; fi
mv "$R/timestamps.tsv.aside" "$BAK/timestamps.tsv"
run bash "$T/content-rollback.sh" "$ROOT" "$BAK" && say "case 8: rollback with the manifest back ran" || bad "case 8: rollback with the manifest failed"; verify "case 8"

say "== case 9: a manifest entry outside the root is refused and nothing is changed"
mkdir -p "$R/outside"; printf 'outside\n' > "$R/outside/victim.txt"; before=$(stat -c %y "$R/outside/victim.txt")
printf '..\\outside\\victim.txt\t638937700240339088\t638937700240339088\t638937700240339088\t8\t%s\n' "$(sha256sum "$R/outside/victim.txt" | cut -c1-64)" > "$R/bad-manifest.tsv"
if run bash "$T/timestamps-restore.sh" "$ROOT" "$R/bad-manifest.tsv"; then bad "case 9: a path outside the root was accepted"; else say "case 9: refused (rc $?)"; fi
[ "$(stat -c %y "$R/outside/victim.txt")" = "$before" ] && say "case 9: the outside file untouched" || bad "case 9: the outside file's timestamp changed"
printf 'C:\\Windows\\win.ini\t1\t1\t1\t1\t0000000000000000000000000000000000000000000000000000000000000000\n' > "$R/bad-manifest-2.tsv"
if run bash "$T/timestamps-restore.sh" "$ROOT" "$R/bad-manifest-2.tsv"; then bad "case 9: an absolute path was accepted"; else say "case 9: absolute path refused (rc $?)"; fi

say "== case 10: the generic capture / restore on another replaced file (mods.ini with sub-second creation and write times), the content check gating the restoration"
powershell.exe -NoProfile -Command "\$f = Get-Item -LiteralPath '$(wslpath -w "$ROOT/Retail/mods.ini")'; \$f.CreationTimeUtc = [DateTime]::new(638937700247654321, 'Utc'); \$f.LastWriteTimeUtc = [DateTime]::new(638937700246039433, 'Utc')" 2>&1 | tr -d '\r' >> "$out"
(cd "$ROOT" && find Runtime Retail -type f -printf '%s\t%TY-%Tm-%TdT%TH:%TM:%TS\t%p\n' | sort -k3) > "$BL/listing.tsv"   # the model baseline now carries mods.ini's fixture timestamps
run bash "$T/timestamps-capture.sh" "$ROOT" "$R/mods-ini.tsv" "Retail/mods.ini" && say "case 10: captured" || bad "case 10: capture failed"
cp "$ROOT/Retail/mods.ini" "$R/mods.ini.copy"; printf '\n[test]\n' >> "$ROOT/Retail/mods.ini"    # the file replaced with different content, then restored by bytes with a plain cp (new timestamps)
if run bash "$T/timestamps-restore.sh" "$ROOT" "$R/mods-ini.tsv"; then bad "case 10: timestamps restored although the content differs"; else say "case 10: restoration refused while the content differs (rc $?)"; fi
cp "$R/mods.ini.copy" "$ROOT/Retail/mods.ini"
run bash "$T/timestamps-restore.sh" "$ROOT" "$R/mods-ini.tsv" && say "case 10: timestamps restored after the byte restoration" || bad "case 10: restoration failed"
run bash "$T/timestamps-restore.sh" "$ROOT" "$R/mods-ini.tsv" && say "case 10: restoration idempotent" || bad "case 10: second restoration failed"
verify "case 10"
say "real installation untouched: $(bash "$T/game-tree-listing.sh" "$GD" | diff -q "$REALBL" - > /dev/null && echo yes || echo NO)"
if [ "$fail" = 0 ]; then say "REHEARSAL RESULT: PASS (0 failures)"; else say "REHEARSAL RESULT: FAIL ($fail)"; fi
exit $fail

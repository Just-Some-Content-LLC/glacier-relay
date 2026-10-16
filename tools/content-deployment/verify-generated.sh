#!/bin/bash
# M6-C2: independent verification of the generated packages (own reader; project-built ResourceTool from the SDK's pinned ZHMTools).
#   verify-generated.sh <evidence-dir> <work-dir> <ResourceTool.exe>
# The evidence directory has the M6-C2 layout: generated/ (the three artefacts), content/SDK.Hitmen/ (the authored copy),
# scene-compare/orig-TEMP-entry.txt and orig-TBLU-entry.txt (the original Paris scene entries); the work directory holds
# orig/ (the original scene's extracted TEMP/TBLU JSON) and receives gen/. The work directory must be reachable by cmd.exe.
set -u
E=${1:?evidence dir}; W=${2:?work dir}; RT=${3:?ResourceTool.exe}
T="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$W/gen" "$E/scene-compare" "$E/package-inventory"
echo "== package inventories (independent reader; RPKG v1 'GKPR' as rpkg-cli writes them)"
for p in chunk0patch300 chunk27patch300; do python3 -I "$T/rpkg_read.py" list "$E/generated/$p.rpkg" > "$E/package-inventory/$p.txt" || echo "READER FAILED on $p"; echo "--- $p"; grep -vE '^\s+dep ' "$E/package-inventory/$p.txt"; done
echo "== chunk0patch300 dependencies"; grep -E '^\s+dep ' "$E/package-inventory/chunk0patch300.txt" | awk '{print $2, $4}' | sort | uniq -c
echo "== extract + convert"
: > "$E/scene-compare/gen-extract.txt"
while read -r pkg hash kind; do
  python3 -I "$T/rpkg_read.py" extract "$E/generated/$pkg.rpkg" "$hash" "$W/gen/$hash.$kind" < /dev/null | tee -a "$E/scene-compare/gen-extract.txt"
  (cd "$W/gen" && cmd.exe /c "$(wslpath -w "$RT") HM3 convert $kind $hash.$kind $hash.$kind.json" < /dev/null 2>&1 | tr -d '\r' | grep -iE 'error|warn' | head -2)
done <<LIST
chunk0patch300 007C57A6EA581F8C TEMP
chunk0patch300 0030D5B5C5BCCBA3 TBLU
chunk27patch300 0011E323C2A9568F TEMP
chunk27patch300 001EAE67E7BAA6CC TBLU
LIST
ls -la "$W/gen" | awk '{print $5, $9}'
echo "== structured comparison: original vs generated Paris scene"
python3 -I - "$W" <<'PY' | tee "$E/scene-compare/paris-scene-structured-diff.txt"
import json, sys, os
W = sys.argv[1]
def load(p): return json.load(open(p, encoding='utf-8'))
def walk(a, b, path, diffs):
    if type(a) != type(b): diffs.append((path, 'TYPE', a, b)); return
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a: diffs.append((f"{path}.{k}", 'ADDED', None, b[k]))
            elif k not in b: diffs.append((f"{path}.{k}", 'REMOVED', a[k], None))
            else: walk(a[k], b[k], f"{path}.{k}", diffs)
    elif isinstance(a, list):
        if len(a) != len(b): diffs.append((path, f'LEN {len(a)}->{len(b)}', None, None))
        for i, (x, y) in enumerate(zip(a, b)): walk(x, y, f"{path}[{i}]", diffs)
        for i in range(min(len(a), len(b)), len(b)): diffs.append((f"{path}[{i}]", 'APPENDED', None, b[i]))
        for i in range(min(len(a), len(b)), len(a)): diffs.append((f"{path}[{i}]", 'DROPPED', a[i], None))
    elif a != b: diffs.append((path, 'VALUE', a, b))
for kind, h in (("TEMP", "0011E323C2A9568F"), ("TBLU", "001EAE67E7BAA6CC")):
    o = load(os.path.join(W, 'orig', f"{h}.{kind}.json")); g = load(os.path.join(W, 'gen', f"{h}.{kind}.json"))
    diffs = []; walk(o, g, kind, diffs)
    print(f"== {kind} {h}: {len(diffs)} difference(s) between the original (game) and the generated JSON (ResourceLib form)")
    for d in diffs: print("   ", d[0], d[1], json.dumps(d[2])[:200], "->", json.dumps(d[3])[:200])
    print(f"   externalSceneTypeIndicesInResourceHeader {o.get('externalSceneTypeIndicesInResourceHeader')} -> {g.get('externalSceneTypeIndicesInResourceHeader')}")
    print(f"   identical otherwise: {all(d[0].startswith(kind + '.externalSceneTypeIndicesInResourceHeader') for d in diffs)}")
PY
echo "== dependency lists (resource header): original vs generated"
python3 -I - "$E" <<'PY' | tee "$E/scene-compare/paris-scene-dependency-diff.txt"
import sys, os, re
E = sys.argv[1]
def deps_of(inv_path, key):
    cur = None; d = {}
    for l in open(inv_path):
        m = re.match(r'^\s{2}([0-9A-F]{16}) (\w+)', l)
        if m: cur = m.group(1); d[cur] = []
        elif l.strip().startswith('dep ') and cur: d[cur].append((l.split()[1], l.split()[3]))
    return d.get(key, [])
for kind, key, of in (("TEMP", "0011E323C2A9568F", "orig-TEMP-entry.txt"), ("TBLU", "001EAE67E7BAA6CC", "orig-TBLU-entry.txt")):
    o = deps_of(os.path.join(E, 'scene-compare', of), key); g = deps_of(os.path.join(E, 'package-inventory', 'chunk27patch300.txt'), key)
    print(f"== {kind} dependencies: original {len(o)} -> generated {len(g)}; original list preserved as a prefix: {g[:len(o)] == o}; appended: {g[len(o):]}; flag values: {sorted(set(f for _, f in g))}")
PY
echo "== hitmen.brick content (generated TEMP/TBLU vs the authored QuickEntity JSON)"
python3 -I - "$W/gen" "$E/content/SDK.Hitmen/hitmen/chunk0/_sdk/hitmen.entity.json" "$E/package-inventory/chunk0patch300.txt" <<'PY' | tee "$E/scene-compare/hitmen-brick-content-check.txt"
import json, sys, os, re
t = json.load(open(os.path.join(sys.argv[1], "007C57A6EA581F8C.TEMP.json"))); b = json.load(open(os.path.join(sys.argv[1], "0030D5B5C5BCCBA3.TBLU.json"))); q = json.load(open(sys.argv[2]))
names = [e.get('entityName') for e in b['subEntities']]; ids = [f"{e.get('entityId'):016x}" for e in b['subEntities']]
print("TBLU sub-entities:", list(zip(names, ids)), "root index", b.get('rootEntityIndex'))
print("authored:", [(v['name'], k) for k, v in q['entities'].items()])
def props(e): return {p['nPropertyID'] if isinstance(p.get('nPropertyID'), str) else p.get('nPropertyID'): p.get('value', {}).get('$val') if isinstance(p.get('value'), dict) else p.get('value') for p in e.get('propertyValues', [])}
for i, e in enumerate(t['subEntities']):
    pv = e.get('propertyValues', [])
    print(f"TEMP sub-entity {i} ({names[i]}): entityTypeResourceIndex {e.get('entityTypeResourceIndex')} logicalParent entityIndex {e.get('logicalParent',{}).get('entityIndex')} props {len(pv)}:")
    for p in pv:
        pid = p.get('nPropertyID'); val = p.get('value'); print("     ", pid, json.dumps(val)[:140])
cur=None; deps={}
for l in open(sys.argv[3]):
    m = re.match(r'^\s{2}([0-9A-F]{16}) (\w+)', l)
    if m: cur=m.group(1); deps[cur]=[]
    elif l.strip().startswith('dep ') and cur: deps[cur].append(l.split()[1])
print("TEMP resource-header deps (by index):", deps.get('007C57A6EA581F8C'))
print("expected: zspatialentity TEMP, the TBLU 0030D5B5C5BCCBA3, agent47_default TEMP 00D347CBA29EE6BA, herospawn TEMP 00F3EA8B2DB49189 (order as emitted)")
PY

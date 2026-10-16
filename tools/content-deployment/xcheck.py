#!/usr/bin/env python3
"""M6-B2 cross-checks between inspections already taken (read-only; reads the <label>-observed.json and
<label>-result.json files cmd.exs wrote; no RPC, nothing issued). Appends EVIDENCE lines to
operator-actions.log under the given label and writes <label>-xcheck.txt.

  xcheck.py <evidence-dir> <label> --players P --entity E [--outfit O] [--prev-players PP] [--prev-entity PE]
            [--expected-gen GEN] [--session-expect same|different] [--identity-expect same]

Comparisons: the same adapter instance across the results; frames advancing in issue order; the players
inspection's slot-0 hero kit id against the M5 outfit inspection's hero_outfit_id (adjacent stable frames);
slot 0's session id against the result generation and the outfit inspection's fresh generation (and the
expected generation when given); matches_m5; the loaded-brick scan completeness; the candidate's presence
field; and, against an earlier pair, the local hero's identity fields (authored id, owning brick, character
guid, initial outfit, round-trip outcome) and the STORED translation with its dirty flags (a dirty
transform is labelled potentially stale; a changed stored translation while stationary is recorded, not
judged), the registry's slots 1-3 and slot 0's session (expected different across a restart).
"""
import argparse, datetime, json, os, sys

ap = argparse.ArgumentParser()
ap.add_argument("evid"); ap.add_argument("label")
ap.add_argument("--players", required=True); ap.add_argument("--entity", required=True); ap.add_argument("--outfit")
ap.add_argument("--prev-players"); ap.add_argument("--prev-entity"); ap.add_argument("--expected-gen")
ap.add_argument("--session-expect", choices=["same", "different"]); ap.add_argument("--identity-expect", choices=["same"])
ap.add_argument("--candidate-expect", choices=["present", "absent"], default="absent"); ap.add_argument("--slots-expect", choices=["empty", "recorded"], default="recorded")
a = ap.parse_args()

out_lines = []
def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def log(msg):
    line = f"{now()} {a.label} {msg}"
    print(line); out_lines.append(line)
    with open(os.path.join(a.evid, "operator-actions.log"), "a", encoding="utf-8") as f: f.write(line + "\n")
def ev(name, ok, detail): log(f"EVIDENCE {name}: {'ok' if ok else 'NOT'} {detail}")

def load(label):
    try:
        o = json.load(open(os.path.join(a.evid, f"{label}-observed.json"), encoding="utf-8"))
        r = json.load(open(os.path.join(a.evid, f"{label}-result.json"), encoding="utf-8"))
    except FileNotFoundError as e:
        log(f"MISSING {e}"); sys.exit(2)
    return o, r
def v(o, k):
    f = o.get(k); return f.get("value") if isinstance(f, dict) and "value" in f else None
def s(o, k):
    f = o.get(k); return f.get("status") if isinstance(f, dict) else None
def fld(o, k):
    f = o.get(k)
    if not isinstance(f, dict): return repr(f)
    return f"{f.get('status')}{'=' + repr(f['value']) if 'value' in f else ''}{'(' + f['reason'] + ')' if f.get('reason') else ''}"

P, PR = load(a.players); E, ER = load(a.entity)
O, OR = load(a.outfit) if a.outfit else ({}, {})
log(f"xcheck players {a.players} (frame {PR.get('frame')}, gen {PR.get('mission_generation')!r}) entity {a.entity} (frame {ER.get('frame')}, gen {ER.get('mission_generation')!r})" + (f" outfit {a.outfit} (frame {OR.get('frame')}, gen {OR.get('mission_generation')!r})" if a.outfit else ""))

adapters = {PR.get("adapter_instance_id"), ER.get("adapter_instance_id")} | ({OR.get("adapter_instance_id")} if a.outfit else set())
ev("xcheck.same-adapter-instance", len(adapters) == 1 and None not in adapters, f"adapters {sorted(x or 'none' for x in adapters)}")
frames = [PR.get("frame"), ER.get("frame")] + ([OR.get("frame")] if a.outfit else [])
ev("xcheck.frames-advance-in-issue-order", all(isinstance(x, int) for x in frames) and frames == sorted(frames) and len(set(frames)) == len(frames), f"frames {frames}")
links = {PR.get("link_generation"), ER.get("link_generation")} | ({OR.get("link_generation")} if a.outfit else set())
ev("xcheck.same-link-generation", len(links) == 1, f"link generations {sorted(str(x) for x in links)}")

kit = v(P, "slot0_hero_kit_id")
if a.outfit:
    ev("xcheck.slot0-hero-kit-equals-m5-outfit-id", kit is not None and kit == v(O, "hero_outfit_id"), f"STOP CONDITION if NOT without a plausible intervening game event: players slot0_hero_kit_id {fld(P, 'slot0_hero_kit_id')} vs outfit hero_outfit_id {fld(O, 'hero_outfit_id')} (frames {PR.get('frame')} / {OR.get('frame')})")
    ev("xcheck.generation-fresh-equals-result-generation", (v(O, "generation_fresh") == PR.get("mission_generation") == OR.get("mission_generation")) or (PR.get("mission_generation") is None and OR.get("mission_generation") is None), f"outfit generation_fresh {fld(O, 'generation_fresh')}; result generations players {PR.get('mission_generation')!r} outfit {OR.get('mission_generation')!r}")
ev("xcheck.slot0-session-vs-generation", (s(P, "slot0_session") == "observed" and v(P, "slot0_session") == PR.get("mission_generation")) or (PR.get("mission_generation") is None), f"slot0_session {fld(P, 'slot0_session')} result generation {PR.get('mission_generation')!r} matches_m5 {fld(P, 'slot0_matches_m5')} registry outfit {fld(P, 'slot0_outfit_id')} (at the menu the registry id may persist from the last attempt: the C-1 finding)")
if a.expected_gen:
    ev("xcheck.expected-generation", v(P, "slot0_session") == a.expected_gen and PR.get("mission_generation") == a.expected_gen and ER.get("mission_generation") == a.expected_gen and (not a.outfit or v(O, "generation_fresh") == a.expected_gen), f"expected {a.expected_gen!r}; slot0_session {v(P, 'slot0_session')!r}; players/entity result generations {PR.get('mission_generation')!r} / {ER.get('mission_generation')!r}" + (f"; outfit fresh {v(O, 'generation_fresh')!r}" if a.outfit else ""))
ev("xcheck.scan-complete", v(E, "brick_count") is not None and v(E, "bricks_scanned") == v(E, "brick_count"), f"brick_count {fld(E, 'brick_count')} bricks_scanned {fld(E, 'bricks_scanned')} (incomplete = a finding; absence then not established)")
cp = E.get("cand_brick_present")
if a.candidate_expect == "present":
    ev("xcheck.candidate-present-as-expected", v(E, "cand_brick_present") is True, f"cand_brick_present {fld(E, 'cand_brick_present')} (FINDING if not: content not loaded or absence not established)")
    ids_differ = v(E, "cand_entity_id") not in (None, v(E, "hero_entity_id")); bricks_differ = v(E, "cand_brick") not in (None, v(E, "hero_owning_brick")); guids_differ = v(E, "cand_character_id") not in (None, v(E, "hero_character_id"))
    ev("xcheck.candidate-distinct-same-frame", v(E, "cand_distinct_from_local") is True and v(E, "cand_resolved") is True and ids_differ and bricks_differ, f"same frame {ER.get('frame')}: cand_distinct_from_local {fld(E, 'cand_distinct_from_local')}; entity ids {fld(E, 'cand_entity_id')} vs {fld(E, 'hero_entity_id')} differ {ids_differ}; owning bricks {fld(E, 'cand_brick')} vs {fld(E, 'hero_owning_brick')} differ {bricks_differ}; character guids {fld(E, 'cand_character_id')} vs {fld(E, 'hero_character_id')} differ {guids_differ} (recorded; the local hero's guid is zeros on this build) — simultaneous existence is claimed only from these authored elements, never from a pointer")
    ev("xcheck.candidate-lookup-facts", v(E, "cand_index_check") == "in_range" and v(E, "cand_hitman5") is True, f"cand_index_check {fld(E, 'cand_index_check')} count {fld(E, 'cand_subentity_count')} index {fld(E, 'cand_index')} resolved {fld(E, 'cand_resolved')} hitman5 {fld(E, 'cand_hitman5')} flags {fld(E, 'cand_entity_flags')} (out_of_range / count_invalid = stop-and-record; no interface = a finding)")
else:
    ev("xcheck.candidate-absent-or-inconclusive", v(E, "cand_brick_present") is not True, f"cand_brick_present {fld(E, 'cand_brick_present')}: " + ("absent on a complete scan" if v(E, "cand_brick_present") is False else ("absence NOT established (inconclusive scan)" if s(E, "cand_brick_present") == "unavailable" else "PRESENT — STOP")))
ev("xcheck.round-trip", v(E, "rt_outcome") != "different_entity" and v(E, "rt_index_check") not in ("out_of_range", "count_invalid"), f"rt_outcome {fld(E, 'rt_outcome')} rt_index_check {fld(E, 'rt_index_check')} count {fld(E, 'rt_subentity_count')} index {fld(E, 'rt_index')} resolved {fld(E, 'rt_resolved')} same {fld(E, 'rt_same_entity')} owner {fld(E, 'rt_owner_found')} template {fld(E, 'rt_factory_template')}")

if a.prev_entity:
    PE, PER = load(a.prev_entity)
    ident = ["hero_entity_id", "hero_owning_brick", "hero_character_id", "hero_initial_outfit_id", "rt_outcome", "rt_index", "rt_subentity_count", "rt_index_check", "rt_factory_template", "rt_owner_found"]
    same = {k: (v(PE, k) == v(E, k) and s(PE, k) == s(E, k)) for k in ident}
    ev("xcheck.identity-fields-vs-previous", all(same.values()), f"vs {a.prev_entity} (frame {PER.get('frame')}, gen {PER.get('mission_generation')!r}): " + "; ".join(f"{k} {'same' if same[k] else 'DIFFERENT'} ({fld(PE, k)} -> {fld(E, k)})" for k in ident) + (" [identity expected the same]" if a.identity_expect == "same" else " [recorded; the entity id and owning brick are the identity, never a pointer]"))
    try:
        d = [abs(float(v(E, k)) - float(v(PE, k))) for k in ("hero_x", "hero_y", "hero_z")]
        dd = f"|dx| {d[0]:.4f} |dy| {d[1]:.4f} |dz| {d[2]:.4f}"
    except (TypeError, ValueError):
        dd = "translation not comparable (a coordinate unavailable)"
    dirty = (v(PE, "hero_transform_dirty"), v(E, "hero_transform_dirty"))
    ev("xcheck.stored-translation-vs-previous", True, f"previous ({fld(PE, 'hero_x')}, {fld(PE, 'hero_y')}, {fld(PE, 'hero_z')}) dirty {dirty[0]} -> current ({fld(E, 'hero_x')}, {fld(E, 'hero_y')}, {fld(E, 'hero_z')}) dirty {dirty[1]}; {dd}" + (" — a dirty flag marks the STORED transform potentially stale" if True in dirty else "") + " (recorded, not judged: Glacier may legitimately update stored state)")
    ev("xcheck.bricks-vs-previous", v(PE, "brick_count") == v(E, "brick_count") and v(PE, "bricks_scanned") == v(E, "bricks_scanned"), f"brick_count {fld(PE, 'brick_count')} -> {fld(E, 'brick_count')}; scanned {fld(PE, 'bricks_scanned')} -> {fld(E, 'bricks_scanned')} (a different count is a finding, not a failure)")
    ev("xcheck.frames-advanced-since-previous", isinstance(PER.get("frame"), int) and isinstance(ER.get("frame"), int) and ER["frame"] > PER["frame"], f"{PER.get('frame')} -> {ER.get('frame')}")
    if a.candidate_expect == "present":
        cident = ["cand_brick", "cand_entity_id", "cand_character_id", "cand_index", "cand_subentity_count", "cand_index_check", "cand_hitman5", "cand_resolved"]
        csame = {k: (v(PE, k) == v(E, k) and s(PE, k) == s(E, k)) for k in cident}
        ev("xcheck.candidate-vs-previous", all(csame.values()), f"vs {a.prev_entity} (frame {PER.get('frame')}, gen {PER.get('mission_generation')!r}): " + "; ".join(f"{k} {'same' if csame[k] else 'DIFFERENT'} ({fld(PE, k)} -> {fld(E, k)})" for k in cident) + (" [the same authored identity under a NEW generation; not object survival]" if a.session_expect == "different" else " [identity within the attempt]"))
        try:
            cd = [abs(float(v(E, k)) - float(v(PE, k))) for k in ("cand_x", "cand_y", "cand_z")]; cdd = f"|dx| {cd[0]:.4f} |dy| {cd[1]:.4f} |dz| {cd[2]:.4f}"
        except (TypeError, ValueError):
            cdd = "candidate translation not comparable (a coordinate unavailable)"
        cdirty = (v(PE, "cand_transform_dirty"), v(E, "cand_transform_dirty"))
        ev("xcheck.candidate-translation-vs-previous", True, f"previous ({fld(PE, 'cand_x')}, {fld(PE, 'cand_y')}, {fld(PE, 'cand_z')}) dirty {cdirty[0]} -> current ({fld(E, 'cand_x')}, {fld(E, 'cand_y')}, {fld(E, 'cand_z')}) dirty {cdirty[1]}; {cdd}" + (" — a dirty flag marks the STORED transform potentially stale" if True in cdirty else "") + " (recorded, not judged)")

if a.prev_players:
    PP, PPR = load(a.prev_players)
    empty = all(v(PP, f"slot{i}_entity") is not True and v(PP, f"slot{i}_hero") is not True and v(P, f"slot{i}_entity") is not True and v(P, f"slot{i}_hero") is not True for i in (1, 2, 3))
    if a.slots_expect == "empty":
        ev("xcheck.slots-1-3-still-empty", empty, "; ".join(f"slot{i} entity {fld(PP, f'slot{i}_entity')} -> {fld(P, f'slot{i}_entity')} hero {fld(PP, f'slot{i}_hero')} -> {fld(P, f'slot{i}_hero')}" for i in (1, 2, 3)))
    else:
        ev("xcheck.slots-1-3-recorded", True, ("unchanged and empty" if empty else "CHANGED or populated — a FINDING: presence is not identity (attributable to Agent48 only through the candidate entry's authored elements or a per-slot entity id, which the accepted entry does not report)") + "; " + "; ".join(f"slot{i} entity {fld(PP, f'slot{i}_entity')} -> {fld(P, f'slot{i}_entity')} hero {fld(PP, f'slot{i}_hero')} -> {fld(P, f'slot{i}_hero')} id {fld(PP, f'slot{i}_player_id')} -> {fld(P, f'slot{i}_player_id')}" for i in (1, 2, 3)))
    ev("xcheck.slot0-unchanged-vs-previous", v(PP, "slot0_entity") is True and v(P, "slot0_entity") is True and v(PP, "slot0_hero") is True and v(P, "slot0_hero") is True and v(PP, "slot0_player_id") == v(P, "slot0_player_id") == 0 and v(PP, "slot0_flags_a0") == v(P, "slot0_flags_a0") == 0, f"STOP if NOT (the local-hero slot changed): slot0 entity {fld(PP, 'slot0_entity')} -> {fld(P, 'slot0_entity')} hero {fld(PP, 'slot0_hero')} -> {fld(P, 'slot0_hero')} id {fld(PP, 'slot0_player_id')} -> {fld(P, 'slot0_player_id')} flags_a0 {fld(PP, 'slot0_flags_a0')} -> {fld(P, 'slot0_flags_a0')}")
    changed = v(PP, "slot0_session") != v(P, "slot0_session") or PPR.get("mission_generation") != PR.get("mission_generation")
    if a.session_expect == "different":
        ev("xcheck.slot0-session-changed-across-restart", changed and PR.get("mission_generation") is not None and PPR.get("mission_generation") != PR.get("mission_generation"), f"slot0_session {fld(PP, 'slot0_session')} -> {fld(P, 'slot0_session')}; result generation {PPR.get('mission_generation')!r} -> {PR.get('mission_generation')!r} (the attempt generation is part of the identity evidence)")
    elif a.session_expect == "same":
        ev("xcheck.slot0-session-unchanged-within-attempt", not changed, f"slot0_session {fld(PP, 'slot0_session')} -> {fld(P, 'slot0_session')}; result generation {PPR.get('mission_generation')!r} -> {PR.get('mission_generation')!r}")
    else:
        ev("xcheck.slot0-session-vs-previous", True, f"slot0_session {fld(PP, 'slot0_session')} -> {fld(P, 'slot0_session')}; result generation {PPR.get('mission_generation')!r} -> {PR.get('mission_generation')!r} (recorded)")
    ev("xcheck.registry-words-vs-previous", v(PP, "registry_words") == v(P, "registry_words"), f"{fld(PP, 'registry_words')} -> {fld(P, 'registry_words')}")
    ev("xcheck.slot0-kit-vs-previous", True, f"slot0_hero_kit_id {fld(PP, 'slot0_hero_kit_id')} -> {fld(P, 'slot0_hero_kit_id')}; registry outfit {fld(PP, 'slot0_outfit_id')} -> {fld(P, 'slot0_outfit_id')} (recorded)")

with open(os.path.join(a.evid, f"{a.label}-xcheck.txt"), "w", encoding="utf-8") as f: f.write("\n".join(out_lines) + "\n")
print(f"xcheck: {sum(1 for l in out_lines if ': NOT ' in l)} NOT line(s) of {sum(1 for l in out_lines if 'EVIDENCE' in l)}")

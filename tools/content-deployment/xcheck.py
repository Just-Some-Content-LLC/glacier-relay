#!/usr/bin/env python3
"""M6-B2 cross-checks between inspections already taken (read-only; reads the <label>-observed.json and
<label>-result.json files cmd.exs wrote; no RPC, nothing issued). Appends EVIDENCE lines to
operator-actions.log under the given label and writes <label>-xcheck.txt.

  xcheck.py <evidence-dir> <label> --players P --entity E [--outfit O] [--prev-players PP] [--prev-entity PE]
            [--expected-gen GEN] [--session-expect same|different] [--identity-expect same]
            [--candidate C] [--prev-candidate PC]   (M6-D1a: the relay.inspect.candidate result beside the entity and players
            inspections of the same phase: the same adapter and link, frames in order, the candidate's presence, lookup facts,
            flags and stored translation equal to the entity inspection's on adjacent frames, the registry slots by identity
            consistent with the players inspection's slot presence, the spawn facts recorded; against an earlier candidate
            result: the identity elements the same, the members / active / translations recorded)

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
ap.add_argument("--candidate"); ap.add_argument("--prev-candidate")
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

# ---- M6-D1a: the candidate inspection beside the entity and players inspections -------------------------------------------
def vec3(o, k):
    t = v(o, k)
    try:
        x, y, z = (float(p) for p in t.split(","))
        return (x, y, z)
    except (AttributeError, ValueError):
        return None
def slots(o):
    t = v(o, "registry_slots")
    if not isinstance(t, str): return None
    out = []
    for i, part in enumerate(t.split(",")):
        try:
            idx, rest = part.split(":")
        except ValueError:
            return None
        if idx != str(i): return None
        suffixed = rest.endswith("-nohero")
        match = rest[:-len("-nohero")] if suffixed else rest
        if match not in ("empty", "local", "candidate", "other", "inconclusive"): return None
        # "empty" = no entity reference, so no hero (the native encoder never suffixes it: reject "empty-nohero");
        # a nonempty token's hero interface resolved unless "-nohero" says it did not (M6-D1a review, correction A)
        if match == "empty" and suffixed: return None
        hero = False if match == "empty" else (not suffixed)
        out.append((match, hero))
    return out if len(out) == 4 else None
def near(p, q, tol=1e-4):
    return p is not None and q is not None and all(abs(x - y) <= tol for x, y in zip(p, q))

if a.candidate:
    C, CR = load(a.candidate)
    log(f"xcheck candidate {a.candidate} (frame {CR.get('frame')}, gen {CR.get('mission_generation')!r})")
    ev("xcheck.candidate-same-adapter-and-link", CR.get("adapter_instance_id") in adapters and len(adapters) == 1 and CR.get("link_generation") in links and len(links) == 1, f"adapter {CR.get('adapter_instance_id')} link {CR.get('link_generation')} vs players/entity {sorted(x or 'none' for x in adapters)} / {sorted(str(x) for x in links)}")
    cframes = [PR.get("frame"), ER.get("frame"), CR.get("frame")]
    ev("xcheck.candidate-frame-after-entity", all(isinstance(x, int) for x in cframes) and CR["frame"] > ER["frame"], f"frames players {PR.get('frame')} entity {ER.get('frame')} candidate {CR.get('frame')} (issue order)")
    ev("xcheck.candidate-generation-vs-players", CR.get("mission_generation") == PR.get("mission_generation") and ((v(C, "generation_fresh") == CR.get("mission_generation")) or (CR.get("mission_generation") is None and s(C, "generation_fresh") != "observed")), f"candidate result generation {CR.get('mission_generation')!r} fresh {fld(C, 'generation_fresh')} vs players {PR.get('mission_generation')!r} (at the menu a persisting registry id is the C-1 finding)")
    ev("xcheck.candidate-hero-identity-vs-entity", v(C, "hero_entity_id") == v(E, "hero_entity_id") and v(C, "hero_flags") == v(E, "hero_entity_flags"), f"candidate hero_entity_id {fld(C, 'hero_entity_id')} flags {fld(C, 'hero_flags')} vs entity hero_entity_id {fld(E, 'hero_entity_id')} flags {fld(E, 'hero_entity_flags')} (the same local hero on adjacent frames)")
    ev("xcheck.candidate-presence-vs-entity", v(C, "cand_brick_present") == v(E, "cand_brick_present") and s(C, "cand_brick_present") == s(E, "cand_brick_present") and v(C, "brick_count") == v(E, "brick_count") and v(C, "bricks_scanned") == v(E, "bricks_scanned"), f"candidate present {fld(C, 'cand_brick_present')} bricks {fld(C, 'brick_count')}/{fld(C, 'bricks_scanned')} vs entity present {fld(E, 'cand_brick_present')} bricks {fld(E, 'brick_count')}/{fld(E, 'bricks_scanned')}")
    tg = v(C, "targets") or ""
    ev("xcheck.candidate-targets-vs-entity", isinstance(tg, str) and tg.split(",")[:2] == [v(E, "cand_brick"), v(E, "cand_entity_id")], f"targets {fld(C, 'targets')} vs entity cand_brick {fld(E, 'cand_brick')} cand_entity_id {fld(E, 'cand_entity_id')}")
    if a.candidate_expect == "present":
        ev("xcheck.candidate-lookup-vs-entity", v(C, "cand_index") == v(E, "cand_index") and v(C, "cand_subentity_count") == v(E, "cand_subentity_count") and v(C, "cand_index_check") == v(E, "cand_index_check") == "in_range" and v(C, "cand_resolved") is True and v(E, "cand_resolved") is True and v(C, "cand_hitman5") == v(E, "cand_hitman5"), f"candidate count {fld(C, 'cand_subentity_count')} index {fld(C, 'cand_index')} check {fld(C, 'cand_index_check')} resolved {fld(C, 'cand_resolved')} hitman5 {fld(C, 'cand_hitman5')} vs entity count {fld(E, 'cand_subentity_count')} index {fld(E, 'cand_index')} check {fld(E, 'cand_index_check')} resolved {fld(E, 'cand_resolved')} hitman5 {fld(E, 'cand_hitman5')}")
        ev("xcheck.candidate-flags-vs-entity", v(C, "cand_flags") == v(E, "cand_entity_flags"), f"candidate cand_flags {fld(C, 'cand_flags')} vs entity cand_entity_flags {fld(E, 'cand_entity_flags')} (equal on adjacent stable frames; a change is a finding)")
        ev("xcheck.candidate-identity-checks", v(C, "cand_id_match") is True and v(C, "cand_distinct") is True and v(E, "cand_distinct_from_local") is True, f"STOP-AND-RECORD if NOT: id_match {fld(C, 'cand_id_match')} distinct {fld(C, 'cand_distinct')} (entity inspection distinct {fld(E, 'cand_distinct_from_local')}) owner {fld(C, 'cand_brick_owner')} vs cand_brick {fld(E, 'cand_brick')}")
        cw, ew = vec3(C, "cand_world"), (v(E, "cand_x"), v(E, "cand_y"), v(E, "cand_z"))
        ew = ew if all(isinstance(x, (int, float)) for x in ew) else None
        ev("xcheck.candidate-stored-translation-vs-entity", near(cw, ew, 1e-3), f"candidate cand_world {fld(C, 'cand_world')} vs entity ({fld(E, 'cand_x')}, {fld(E, 'cand_y')}, {fld(E, 'cand_z')}) (the same STORED cache on adjacent frames, 7 significant digits vs doubles; a difference beyond 1e-3 is a FINDING — recorded, never corrected)")
        hw, hew = vec3(C, "hero_world"), (v(E, "hero_x"), v(E, "hero_y"), v(E, "hero_z"))
        hew = hew if all(isinstance(x, (int, float)) for x in hew) else None
        ev("xcheck.hero-stored-translation-vs-entity", True, f"hero_world {fld(C, 'hero_world')} vs entity ({fld(E, 'hero_x')}, {fld(E, 'hero_y')}, {fld(E, 'hero_z')}): {'within 1e-3' if near(hw, hew, 1e-3) else 'DIFFERENT (recorded: the controlled hero may have moved between the frames)'}")
        sp = v(C, "spawn_player_id")
        ev("xcheck.candidate-spawn-recorded", v(C, "spawn_resolved") is True and v(C, "spawn_index_check") == "in_range", f"spawn index {fld(C, 'spawn_index')} check {fld(C, 'spawn_index_check')} class {fld(C, 'spawn_class')} world {fld(C, 'spawn_world')} dirty {fld(C, 'spawn_dirty')} player_id {fld(C, 'spawn_player_id')} select {fld(C, 'spawn_select')} hitman_ref {fld(C, 'spawn_hitman_ref')} ref_is_cand {fld(C, 'spawn_ref_is_cand')} (an authored relationship; never evidence the spawn system ran; player id {sp!r} is NOT registry membership)")
    else:
        ev("xcheck.candidate-absent-vs-entity", v(C, "cand_brick_present") is not True and v(E, "cand_brick_present") is not True and s(C, "cand_index") != "observed", f"candidate present {fld(C, 'cand_brick_present')} index {fld(C, 'cand_index')}; entity present {fld(E, 'cand_brick_present')}")
    sl = slots(C)
    pres = [v(P, f"slot{i}_entity") for i in range(4)]
    consistent = sl is not None and all((sl[i][0] == "empty") == (pres[i] is False) for i in range(4) if pres[i] is not None)
    ev("xcheck.registry-slots-vs-players-presence", consistent, f"registry_slots {fld(C, 'registry_slots')} vs players slot entity presence {pres} (empty <=> no entity reference; identity only the candidate inspection can give)")
    ev("xcheck.registry-slot0-local", sl is not None and sl[0][0] == "local" and sl[0][1], f"slot 0 {sl[0] if sl else None} (the local hero; STOP if NOT with a hero in slot 0)")
    in_slot = sl is not None and any(m == "candidate" for m, _ in sl)
    inconclusive = sl is not None and any(m == "inconclusive" for m, _ in sl)
    ev("xcheck.registry-membership-by-identity", sl is not None, f"{fld(C, 'registry_slots')}: " + ("unavailable — INCONCLUSIVE" if sl is None else ("the candidate IS in a slot — a FINDING (recorded, not a stop)" if in_slot else ("a populated slot not comparable — INCONCLUSIVE for it" if inconclusive else "the candidate is in NO registry slot on this frame (by entity identity, not by the spawn's player id)"))))
    if a.prev_candidate:
        PC, PCR = load(a.prev_candidate)
        ident = ["targets", "hero_entity_id", "cand_brick_present", "cand_index", "cand_subentity_count", "cand_index_check", "cand_resolved", "cand_hitman5", "cand_id_match", "cand_distinct", "cand_brick_owner", "spawn_index", "spawn_class", "spawn_player_id", "spawn_select", "spawn_hitman_ref", "spawn_ref_is_cand"]
        same = {k: (v(PC, k) == v(C, k) and s(PC, k) == s(C, k)) for k in ident}
        ev("xcheck.candidate-identity-vs-previous", all(same.values()), f"vs {a.prev_candidate} (frame {PCR.get('frame')}, gen {PCR.get('mission_generation')!r}): " + "; ".join(f"{k} {'same' if same[k] else 'DIFFERENT'} ({fld(PC, k)} -> {fld(C, k)})" for k in ident) + (" [the same authored identity under a NEW generation; never object survival]" if a.session_expect == "different" else " [identity within the attempt]"))
        rec = ["cand_flags", "cand_spatial_flags", "cand_members", "cand_controllers", "cand_outfit", "cand_active", "cand_parent", "hero_members", "hero_active", "registry_slots", "spawn_dirty"]
        changed = [k for k in rec if not (v(PC, k) == v(C, k) and s(PC, k) == s(C, k))]
        ev("xcheck.candidate-state-vs-previous", True, ("unchanged" if not changed else "CHANGED (recorded, not judged): " + ", ".join(f"{k} {fld(PC, k)} -> {fld(C, k)}" for k in changed)) + f" — groups compared: {', '.join(rec)}")
        for who in ("cand", "hero", "spawn"):
            p, q = vec3(PC, f"{who}_world"), vec3(C, f"{who}_world")
            d = f"|dx| {abs(p[0]-q[0]):.4f} |dy| {abs(p[1]-q[1]):.4f} |dz| {abs(p[2]-q[2]):.4f}" if p and q else "not comparable (a translation unavailable)"
            ev(f"xcheck.{who}-stored-translation-vs-previous", True, f"{fld(PC, f'{who}_world')} -> {fld(C, f'{who}_world')}; {d} (recorded, not judged; a dirty flag marks the STORED value potentially stale)")
        ev("xcheck.candidate-frames-advanced-since-previous", isinstance(PCR.get("frame"), int) and isinstance(CR.get("frame"), int) and CR["frame"] > PCR["frame"], f"{PCR.get('frame')} -> {CR.get('frame')}")

with open(os.path.join(a.evid, f"{a.label}-xcheck.txt"), "w", encoding="utf-8") as f: f.write("\n".join(out_lines) + "\n")
print(f"xcheck: {sum(1 for l in out_lines if ': NOT ' in l)} NOT line(s) of {sum(1 for l in out_lines if 'EVIDENCE' in l)}")

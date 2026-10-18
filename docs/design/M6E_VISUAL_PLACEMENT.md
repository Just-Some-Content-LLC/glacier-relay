# M6-E1 — A visually observable Agent48: a content-initialized placement (research and decision record)

**Status:** research and design record (2026-10-18). Nothing was launched, built, installed, generated or edited. There is no native, BEAM or tooling change. M6 is not complete.

**Authorization:** "M6-F2b Acceptance and Bounded Visual-Placement Design". It covers ONE read-only content investigation and design decision whose objective is a visually observable Agent48. The acceptance addendum it asked for is M6-F record section 17.

**Evidence:** `%TEMP%\glacier-m0\hitmen\m6e1-design\`:
- `checkpoint.txt`;
- `extract.txt`;
- `source-facts.txt` (derived facts only);
- `scripts\`;
- `verifier-report.txt` (the one independent check, and the corrections it led to);
- the manifest `sha256.txt`, 13 entries, `8dab580a69830934f3ba331ee124631af33f877df8ee1a3be55057f14e3973f9`, written last and verified.

The extracted game resources stay in the scratch root `%TEMP%\glacier-m0\m6e1-work\` (the guard's declared state root). They are proprietary and are never evidence or Git content.

**Working name:** the M6-A strategy table (M6 record section 13) already names **M6-E — visual existence**, and no stage has used it.
- This record is **M6-E1** (design).
- The proposal's offline preparation would be **M6-E2**, and its attended run **M6-E3**, mirroring M6-C1 / C2 / C3.
- No milestone is renumbered.

**Labels:**
- **[S] source.** The frozen content:
  - the preserved `chunk0patch300.rpkg` `f4a3295a…`;
  - the game's `chunk0.rpkg`, `chunk0patch4.rpkg` `5ec42f45…` and `chunk27patch4.rpkg` `e167bf37…`.

  They were read through the project's `rpkg_read.py` and the SDK-pinned ResourceTool `1941d7e9…`. Also: the SDK headers, and the native source at `relay/m2` `3b892cad`.
- **[R] runtime observation** (the runs named).
- **[I] inference.**
- **[H] hypothesis.**
- **[U] unknown.**

## 1. Starting point and checkpoint

**Already established and not re-opened:**
- Agent48's authored instance has no transform property (M6-D2 F1).
- The `agent47_default` template root defaults to an identity transform at (0, 0, 0) (F2).
- The brick's one authored transform belongs to `Agent48Spawn` (F1).
- The observed z −1.5393555 is not authored in the brick or on the template root (M6-D2 3.1).
- The stock Paris hero has a per-instance transform but stands elsewhere at runtime (F5).
- The spawn's cached transform is dirty and is not a position (F4).

This record reconfirms only what the design depends on.

**Checkpoint** (`checkpoint.txt`, 10:08–10:09Z):
- **Repositories:** glacier-relay `main` `c7d69458…` = origin, and ZHMModSDK `relay/m2` `3b892cad…` = origin; both clean.
- **Adapter:** native4 `806de7a9…`.
- **M6-F2b evidence:** the manifest file hashes to `05fd0a4e…`. Separately, all 7,215 files it lists verify.
- **Content:** the preserved files `f4a3295a…`, `58e9a10f…` and `9433888b…`.
- **Game:**
  - `chunk0patch4` and `chunk27patch4` equal the M6-C2 baseline;
  - no patch300 package;
  - the baseline package definition;
  - no HITMAN or BEAM process.
- **Extracts:** the three TEMPs (the hero template, the spawn template and the Paris location brick) were re-extracted from the game. They are byte-identical to M6-D's extracts (`extract.txt`), so M6-D's derived facts stand on the same bytes. The blueprints (the hero template's `000A263E54999100`, the Paris brick's `00AE87315CD24E96`, the brick's `0030D5B5C5BCCBA3`) were extracted for the first time in this stage, so there is no earlier copy to compare.

## 2. The trace: from Agent48's instance to the members that receive its initialization

| Step | Resource / entity | What it carries | Inspected |
|---|---|---|---|
| Instance | `hitmen.brick` TEMP `007C57A6EA581F8C` / TBLU `0030D5B5C5BCCBA3` (in the preserved `chunk0patch300`). Sub-entity 1, `Agent48` `feede715906f747f`. Factory = resource-header dependency 2 = `agent47_default` TEMP `00D347CBA29EE6BA` | Five properties: `m_InitialOutfitId` `07ab08e1…`; `m_eidParent` → sub 0 `Hitmen` (a `zspatialentity` with no properties); `m_bIsInvincible` false; `m_eRoomBehaviour` `ROOM_DYNAMIC`; `m_CharacterId` `787c1ff2…`. **No `m_mTransform`.** No property overrides | complete |
| Template | `agent47_default` TEMP `00D347CBA29EE6BA` (chunk0patch4, `4b9eb7eb…`) and its TBLU `000A263E54999100` (chunk0patch4, `6a333d4b…`, the TEMP's dependency 295). 529 sub-entities | Root: sub-entity **526 `Agent47_Default`**, entity id `158cb860b1fce56d` | complete (TEMP and TBLU) |
| Root type | ASET `0042285D030BDADC` (chunk0.rpkg) with seven component types: **`ZLinkedEntity`** `00EC8416C5D64860`, **`ZHitman5`** `00D04A0A943E057A`, and five not resolved by name | The SDK chains:<br>`ZHitman5` → `ZHM5BaseCharacter` → `ZEntityImpl` (not spatial).<br>`ZLinkedEntity` → `ZGeomEntity` → `ZPrimitiveContainerEntity` → `ZRenderableEntity` → `ZBoundedEntity` → `ZSpatialEntity`.<br>So the spatial interface the inspectors read is, by these layouts, the root's renderable linked-geometry component. It sits in the same entity as the `ZHitman5` component [S] + [I]. This assumes none of the five unresolved components is itself spatial | the five unresolved components' names and roles are missing |
| Root defaults | 60 properties, including `m_mTransform` = identity at (0, 0, 0), `m_InitialOutfitId` `4fc9396e…` and `m_bActive` true. No `m_eidParent`; no `m_CharacterId` | Nine property aliases. **None** for `m_mTransform`, `m_eidParent`, `m_CharacterId` or `m_InitialOutfitId`. `m_bActive` is aliased to sub 15 (4.4) | complete |
| Spatial subtree | 80 sub-entities carry `m_eidParent`; 47 of them name the root. They include `TestCharacterCam` (15), the eyebrow and eyelash geometry, the hand rigid bodies, the audio emitters, and the `Pelvis` / `Spine` / hand attachers. All 76 `m_mTransform` values are small parent-relative offsets | — | complete for TEMP values; the runtime parenting is not observed |
| The z | No float within 2·10⁻³ of ±1.5393555 among all 1,548 property floats (property, post-init and platform-specific values) of the 529 sub-entities | — | complete |

**Consequence [S] + [R] + [I]:** an instance-level `m_mTransform` on Agent48 would resolve to the root entity's own `m_mTransform`, by the same unaliased property name as the root's identity default.
- [S]: there is no alias.
- [R]: the analogue in 4.1.
- [I]: that the engine applies it to the spatial component.
- That is the transform of the entity the read-only inspectors read: `relay.inspect.entity`, `relay.inspect.candidate` and `relay.inspect.candidate_transform` all take `QueryInterface<ZSpatialEntity>()` on the sub-entity reference for `feede715906f747f`.
- At runtime, the brick root behaves as the identity. Agent48's world and parent-relative translations are equal and its rotation words are the identity (M6-F2b `r3-ct`) [R]. So the parent-relative value is the intended world placement.

**Not established by source:**
- the five unresolved components;
- the order in which the engine applies the template defaults, the instance values, and the character, physics and animation initialization.

## 3. Is the intervention expressible in the format already used?

**Yes [S].**
- **The same file already carries an `SMatrix43` `m_mTransform`:** `Agent48Spawn`'s, in QuickEntity 3.1 form `{"rotation": …, "position": …}`. The qualified framework converted it into the TEMP. M6-C2 verified that, and this stage re-read it (Trans words `c223fecb` / `c1c25969` / `3efc305e`).
- **No new format, type or converter path:** adding the same property object to Agent48 needs none.
- **The stock comparison:**
  - The Paris hero `Hitman_L01` `69bdf7f855ea15e0` (location brick sub 31836) has exactly three instance properties.
  - They are `m_mTransform` (−109.588, −89.883, −0.536, yaw −81.86°), `m_InitialOutfitId`, and `m_eidParent` → sub 24031 `Scene` (the brick root, with no properties).
  - With one added `m_mTransform`, Agent48 would have the stock hero instance's shape: a transform plus a parent link to its brick root.
- **What the comparison does not show:**
  - **It shows that the shape is stock. It does not show that the engine honours it.** The spawn path places the stock hero at (−83.74, 14.70, −1.52) [R], away from its authored value.
  - No hero honouring an instance transform has been observed.

## 4. New source findings

### 4.1 The instance-property channel reaches the entity the inspectors read [R] + [S]

- The template root has no `m_CharacterId` default; the brick's instance sets `787c1ff2…`.
- Every content-backed run read `cand_character_id` = `787c1ff2…` from the resolved `ZHitman5` component (`SceneObservation.cpp:403`, `p_Hero->m_CharacterId`):

  | Run | Frame |
  |---|---|
  | M6-C3 | 33742 |
  | M6-D1b | 51085 |
  | M6-F1b | 32414 |
  | M6-F2b | 42385 |

- Conclusion: Agent48's instance values in this brick are applied to the entity whose spatial component the inspectors read.
- Limit: this is demonstrated for a property of the `ZHitman5` component. For the spatial component the evidence is consistency only: the observed x, y (0, 0) equal the root's default translation, the only `m_mTransform` in the chain.

### 4.2 Agent48's z matches the authored ground-level placements near the map origin, to within 5·10⁻⁵ m [S] + [R]

- **The placements:** the location brick has ground-level placements within 6 m of (0, 0):
  - a café terrace (two tables and eight chairs);
  - a bicycle backdrop;
  - a building backdrop.

  Their world z, composed along their parent chains inside the brick, is −1.539402, −1.539399 and −1.539360. A parent without a transform property is taken as the identity, and no chain leaves the brick. They stand 0.6–5.1 m from the origin. A floor surface at the origin itself is not read from the source.
- **Agent48:** observed at −1.5393555 (`bfc5099a`). That is within 5·10⁻⁵ m of these placements but not bit-equal, and there is no such literal in the template (section 2).
- **What it supports:** the ground branch of hypothesis H2, that the unspawned hero is placed onto the floor beneath its initial transform.
- **What it does not do:**
  - It does not identify a writer.
  - It does not explain the return within six frames after the M6-F2b lift.

### 4.3 The local hero's start position and its surroundings [S] + [R]

- **The start position:**
  - M6-F2b: (−83.74377, 14.69709, −1.522178); words `c2a77ccf` / `416b274b` / `bfc2d6ba`.
  - M6-F1b: (−83.85852, 14.74473, −1.52121).
- **What the location brick has there:**
  - An avenue of granite planters with small birch trees.
  - Two rows of planters, at y 11.99359 and 17.67185.
  - Columns of planters at x −80.477, −84.044, −87.670 and −91.318, with planter bases at z −1.537868.
  - The main gate in +x: `Exit_Gate_Main` 6.77 m from the start and `Gate_Entrance_Palace_Closed_00_01` 6.93 m.
  - Apart from a reflection-probe volume, the nearest authored placement to the start is a birch tree, at 2.69 m.
- **The hero's heading:** its observed world axes give a yaw of −80.36° for X and +9.64° for Y. Which axis is the character's forward is not established, and this design does not depend on it.

### 4.4 The template root aliases `m_bActive` to its camera sub-entity [S]

- The alias points to sub-entity 15, `TestCharacterCam`, which is also `m_rMainCamera`'s target.
- So M6-D1b's "`m_bActive` true" (a `GetProperty` on the root) is not established as a hero-activity flag.
- Source does not say whether the runtime lookup followed the alias or read a member of the root.
- This qualifies an earlier reading. It does not affect this design.

## 5. The research question, answered

*Is there a supported, narrowly scoped content intervention that could initialize the existing Agent48 representation at a chosen observable location, without changing Agent47 or requiring the quarter-metre setter to hold?*

**Yes — as a falsifiable hypothesis, not as a demonstrated route.**

What source and earlier runs establish:
- One instance property, `m_mTransform` on Agent48 in `hitmen.brick`, is expressible in the qualified format (section 3).
- By source, it resolves to the root entity whose transform the inspectors read (section 2).
- It has the stock hero instance's shape (section 3).
- The channel from this brick's instance values to that entity is demonstrated for another property (4.1).

What only the experiment can answer, for a hero that no spawn places:
- whether the engine's hero initialization honours the value;
- whether it keeps the value afterwards;
- whether it places the hero onto the floor.

Nothing in the source contradicts the candidate-local route, so no alternative was needed. Section 7.8 records one alternative for review.

## 6. What offline work can prove, and what only a run can measure

| Provable offline (M6-E2) | Measurable only at runtime (M6-E3) |
|---|---|
| The edited source differs from the frozen brick by exactly one property object | The brick loads and Agent48 resolves with its recorded identity |
| The built TEMP's sub-entity 1 gains exactly one `m_mTransform` with the intended binary32 words | The stored transform at the first Paris read. That is "present at the first read", seconds after the load and the intro, never the initialization frame |
| The TBLU, the resource ids, the dependency list, `Agent48Spawn` and the brick root are unchanged | The settled state at later reads |
| `chunk27patch300` and `packagedefinition.txt` are byte-identical to the preserved files | Rendering, from testimony and a recording |
| Scope: only Agent48's instance changes; no shared template, local hero, spawn flag, Paris brick or global data | Collision and occlusion at the chosen point; any NPC reaction (recorded, not interpreted) |
| Installation and rollback rehearsed with exact timestamps | The local hero's start, slot and outfit, and its stability while stationary |

## 7. The preferred proposal — M6-E3: one attended, content-modifying run with a read-only adapter

Designed only; not authorized.

### 7.1 The visual objective

An operator standing at Agent 47's start in Paris sees and records Agent48 standing about 5.7 m away along the planter avenue. Read-only inspections show Agent48's stored transform at the location the content defines, on the frames read before and after the recording.

### 7.2 The change and its dependency surface

**The change.** Make a scratch copy of the M6-C2 content (`SDK.Hitmen\hitmen\chunk0\_sdk\hitmen.entity.json`, the historical brick unchanged since 2023). In it, add one property to entity `feede715906f747f` (`Agent48`), and nothing else:

```json
"m_mTransform": {"type": "SMatrix43", "value": {"rotation": {"x": 0, "y": 0, "z": 0}, "position": {"x": -89.49, "y": 14.83, "z": -1.5221779}}}
```

**The intended binary32 values:**
- **Rotation:** the identity. That is the template root's own default, so the rotation part of the observed baseline is unchanged. Whether the converter writes −0 (`80000000`) for some zeros is not established; M6-E2's read-back records the exact words.
- **Trans:** `c2b2fae1` / `416d47ae` / `bfc2d6ba`, i.e. −89.49 / 14.83 / −1.5221779 rounded to binary32. The z word is the local hero's observed start z exactly.

**The dependency surface:** the brick TEMP only, inside `chunk0patch300.rpkg`. Expected unchanged, and verified byte for byte in M6-E2 (check 3 of 7.9):
- the brick's TBLU (structure, names and ids);
- its resource ids (the source's explicit `tempHash` / `tbluHash` fields, which are not edited);
- the Paris scene patch (`chunk27patch300`, which references the brick by id);
- the package definition.

Why "expected" rather than "by construction":
- properties live in the TEMP;
- but no second build has yet shown the framework to be byte-reproducible;
- and the package definition is regenerated from the game's current file.

**Untouched:**
- `agent47_default` and `herospawn` (game resources);
- `Agent48Spawn` (its transform, player id 2 and flags);
- the Paris location brick and `Hitman_L01`;
- global data;
- the player registry.

### 7.3 The location and the view

**The point P:** the x / y centre of the four planters 38990 / 1770 / 5211 / 2340, (−89.494, 14.833), rounded to (−89.49, 14.83).

**Its z:** the local hero's observed start z word `bfc2d6ba` (−1.5221779), as observed in M6-C3, D1b and F2b. The planter bases are at −1.537868, 0.016 m lower.

**The grounding:**
- P is 5.75 m from the M6-F2b start, along the avenue, away from the gate.
- No authored placement lies within 2.5 m of P.
- The nearest are the four planters, four birch trees and one ground decal, at 3.33–3.48 m (centre distances; their extents are unknown).
- The line from the start to P passes only a reflection-probe volume.

**Not established:**
- the collision extents of the planters and trees;
- the floor height at P (only the start's and the planter bases' heights are known);
- NPCs or crowds from the other loaded bricks (only the location brick was examined);
- the camera's position and reach.

**The operator's orientation:**
- Stay stationary at the start.
- Using the mouse only, turn the camera slowly through one full turn.
- P lies along the planter avenue, away from the closed main gate, between the next two pairs of planters.
- No free camera, debug or Editor mod, and no walking.

The camera turn is player input. It is outside M6-F2b's scope, so it needs the M6-E3 authorization's explicit permission.

### 7.4 The adapter: read-only by configuration

**Configuration:** the runtime-exercised native4 DLL `806de7a9…`, with `[command] effectful = false` and BEAM's effectful authority off.
- The transform setter and outfit applier are constructed only when `effectful` is set (`GlacierRelay.cpp:134–138`).
- The protocol rejects `candidate.transform.set/1` ("effectful setting disabled", `CommandProtocol.cpp:348–349`).
- Allowed: the probe and the five read-only inspections, including `relay.inspect.candidate_transform/1`. The hello advertises the effectful entries only when `effectful` is set (`CommandLink.cpp:327–332`); `GlacierRelay.cpp:152` logs the read-only allowlist.

This is read-only by configuration, not by construction: the setter's call site is still in the binary.

**Nature of the run:** content-modifying. The deployment changes the content the engine loads, even though no setter command is sent.

### 7.5 What the existing read-only inspector would distinguish (separate verdicts)

- **(a) Candidate loaded:** `relay.inspect.entity` reports `cand_brick_present` true on a complete scan.
- **(b) Candidate resolved:**
  - count 3, index 1, `in_range`;
  - `cand_resolved`, `cand_hitman5`, `cand_id_match`;
  - `cand_distinct` / `cand_distinct_from_local`;
  - parent `007c57a6ea581f8c`;
  - character guid `787c1ff2…`.
- **(c) The requested placement present at the first read.**
  - **The read:** `relay.inspect.candidate_transform`, compared as follows:
    - `cand_world_words` 9–11 against `c2b2fae1` / `416d47ae` / `bfc2d6ba`;
    - words 0–8 against the identity;
    - `cand_local_words` against P with the quaternion (0, 0, 0, 1);
    - `cand_dirty` false.
  - **The ±0 policy:** translation words are compared bit for bit. Rotation words are compared by value, with ±0 equal, and the actual words are recorded. The baseline's local quaternion words are already `80000000` / `00000000` / `80000000` / `3f800000`.
  - **The classes:**
    - exact;
    - x and y exact with z different (Δz recorded);
    - within the declared 1e-4;
    - at the template origin (0, 0, ≈ −1.539);
    - elsewhere.
- **(d) The later settled state:** the same read repeated at about +30 s, immediately before and after the camera turn, and before the exit. Each is classified against the first read with `xcheck.py --prev-transform`: bit-equal, within tolerance, or different.
- **(e) Visual testimony:**
  - The operator's own words, recorded verbatim through `op.sh note`, which is for operator words only.
  - The screenshot and the recording, hashed into evidence.
  - The tool-runner's analysis is written separately and never as testimony.
- **Controls:**
  - **The local hero's start, compared with the earlier content-backed runs** (M6-D1b / F1b / F2b: x −83.74…−83.86, y 14.697…14.745, z −1.5212…−1.5222). A start outside that spread is recorded as a finding and is not attributed.
  - **Slots:** slot 0 local, slots 1–3 empty, and Agent48 in no slot.
  - **The outfit tuple:** `874c4c48…` 0 / 0.
  - **The local hero's words while stationary**, compared under the declared policy.
  - **Stop conditions:** a change of slot 0 or the outfit, or the local hero moving beyond the declared tolerance while stationary. Either stops the visual steps; the exit and rollback still run.

### 7.6 The visual record

1. **A screenshot of the default view**, taken after the stability window.
2. **One continuous screen recording of the single slow full camera turn** (at least 20 s). It starts with the closed main gate in view, so the recording shows the bearing toward P.
3. **If a figure is seen**, the camera held on it for about 10 s.

The recording's start and end are noted in UTC. Exact inspections immediately before and after it bracket the recording; values between those reads are not observed. The files stay on the operator's machine as evidence, hashed, and are not uploaded automatically.

### 7.7 Outcome table

| Inspector (c) / (d) | Recording | Testimony | Reading, and what it does not mean |
|---|---|---|---|
| at P, held | covers P's bearing | figure seen at P | The content initialization was honoured and a representation is visible at P. Not established: simulation, animation, collision, perception or control |
| at P, held | covers it | not seen | At P but not seen: occluded, culled or not drawn, and which one is unresolved |
| at P | does not cover P's bearing | — | The camera coverage failed. No visual verdict |
| x, y at P, z different | covers it | as seen | x and y honoured, z adjusted. Consistent with placement onto the floor (H2) |
| at P at the first read, later different | — | — | Initialized but not maintained. The later writer is unknown, and nothing instruments it |
| at (0, 0, ≈ −1.539) | — | — | The override was not honoured at runtime, although the package was verified to contain it. This content route does not initialize this hero |
| elsewhere (for example near `Agent48Spawn`) | — | — | Something else places it. A finding |
| candidate absent or not resolved | — | — | Loading or content failure (M6-C3's verdict families). Stop |
| local hero outside its spread, or a slot / outfit change | — | — | A finding or a stop, as in 7.5. Recorded, not attributed |
| a figure seen somewhere other than where the reads place it | — | — | Inconsistent. Both are recorded and nothing is decided |

### 7.8 The alternative, for review only (not preferred): a candidate-only spatial owner

**The alternative:** add a new `zspatialentity` at P to `hitmen.brick` and point Agent48's `m_eidParent` at it.

**What changes:**
- It adds an entity, which changes the TBLU, its names and ids, and the sub-entity count from 3 to 4. Agent48's index may change too.
- These expectations recorded from M6-C3 to M6-F2b would then not hold:
  - the count of 3 and the index of 1;
  - the parent `007c57a6ea581f8c`;
  - world = parent-relative.
- The inspectors' parent field would presumably read the new owner's type id. That is an inference: only a brick-root parent has been observed, and it reads the brick's id `007c57a6ea581f8c`, not its TBLU entity id `fffffffffffffffe`.
- `Agent48Spawn`'s index (part of `xcheck.py`'s identity comparison) and the TBLU subset indices may also shift.

**Preference:** the preferred route changes none of these.

A template-internal initialization target was not examined further, because the candidate-local route is not contradicted.

### 7.9 Rollback surface, invalidated qualifications and the checks a content-build authorization would need

**The rollback surface** is the same kind as in M6-C3 / F2b:
- `Runtime\chunk0patch300.rpkg` (a new hash);
- `Runtime\chunk27patch300.rpkg` and `Runtime\packagedefinition.txt` (expected to be the preserved bytes);
- `Retail\mods\GlacierRelay.dll` and `.ini`;
- `Retail\mods.ini`.

It is restored by the committed `content-install.sh` / `content-rollback.sh` / `content-verify.sh`, with the Windows-side 100-ns timestamps (`9786418`), against the complete M6-C2 baseline; M0 26/26.

**Qualifications that would no longer hold.** They are re-established in M6-E2 with the existing tools, not a new framework:
- the run kit's frozen content identity (`record-check.py` pins `f4a3295a…`);
- the readiness records pinned to it;
- M6-C2's "generated = preserved" claim for `chunk0patch300`;
- the F-stage's recorded candidate baseline words (no lift is planned).

The committed tools:
- `xcheck.py` hard-codes no candidate baseline, parent or content hash.
- `verify-generated.sh` hard-codes the resource ids and the M6-C2 paths, and prints the brick check without asserting it. M6-E2 must compare the brick check explicitly.

**The offline checks for M6-E2:**
1. **The source edit:** the edited scratch source differs from the frozen brick by exactly one added property, shown by a structural JSON diff.
2. **The build:** the qualified SMF 2.33.42 in Output mode, isolated, with no game write.
3. **The unchanged packages:** `chunk27patch300` and `packagedefinition.txt` byte-identical to `58e9a10f…` / `9433888b…`. If not, stop and explain.
4. **The independent read-back** (`rpkg_read.py` + ResourceTool):
   - the brick TEMP's sub 1 has six properties, the new one with the intended words;
   - every other value and sub-entity is identical;
   - the TBLU is byte-identical;
   - the resource ids and the dependency list are unchanged.
5. **The rehearsal:** installation and rollback on a scratch tree (`rehearsal.sh`) with the new package and exact timestamps.
6. **The run kit:** a read-only kit derived from the F2b kit, then dry-run against the frozen probe. It has effectful off, no arming and no lift, and carries the inspections of 7.5 and the capture steps of 7.6.
7. **The readiness record:** one record pinned to the new identities.

## 8. Remaining hypotheses and unknowns

- **H-E1 (the experiment's hypothesis):** the engine initializes this unspawned hero at its instance `m_mTransform` (x and y at P; z at P or on the floor) and keeps it there.
- **H2's ground branch (supported by 4.2):** placement onto the floor beneath the initial transform.
- **Unknowns about the representation:**
  - whether the hero's linked geometry is drawn, and its level of detail and culling;
  - which way an identity rotation makes the figure face;
  - the five unresolved root components.
- **The return after the lift:** what returned the lifted transform within six frames (M6-F2b). Content initialization does not answer this, and a held placement would not identify it.
- **Interactions:**
  - NPC and AI perception of a second hero;
  - whether Agent48's own `TestCharacterCam` takes part in the view.
- **Risks:**
  - P may be inside unexamined geometry or occupied by an NPC (residual collision and occlusion).
  - Otherwise, the content path's crash risk is unchanged from M6-C3 to F2b: no new adapter capability is used.

## 9. The smallest next authorization (proposed, not granted)

**M6-E2 — offline only:**
- the one-property scratch edit of 7.2;
- the isolated build with the qualified framework;
- the independent verification, rehearsal, read-only run kit, dry run and pinned readiness record of 7.9.

Out of scope for M6-E2: the game, installation, a DLL build, native or BEAM changes, and a token. M6-E3 would then need its own review, authorization and a fresh operator Ready.

## 10. Stop

**Not authorized by this record:**
- a game launch, installation, content edit, package generation or new DLL;
- a native or BEAM change;
- transform calls, lifts or per-frame writes;
- camera or debug-mod operation;
- activation or spawn application;
- registry or input changes;
- physics or controller overrides;
- writer hooks;
- multiplayer work;
- M6 closure or a tag.

## 11. M6-E2 — offline visual-placement preparation: record (2026-10-18)

**Status:** offline preparation, done.
- Nothing was installed and HITMAN was not launched.
- No native, BEAM application, protocol or dependency change; no committed tooling change; no real token.
- The real game tree was only read, and is at its complete baseline at the end.
- M6 is not complete; nothing is tagged.

**Authorization:** "M6-E1 Review and M6-E2 Offline Visual-Placement Preparation". It accepts M6-E1 as a source-backed, falsifiable design, not as evidence that the engine honours the placement or renders Agent48. It authorizes:
- the one property in a scratch copy;
- the isolated build;
- the independent verification;
- the affected installation / rollback rehearsal;
- the inert-only kit and its dry run;
- one pinned offline readiness record.

M6-E3 stays separately reviewed, with a fresh operator Ready.

**Evidence:** `%TEMP%\glacier-m0\hitmen\m6e2-offline\` — 1,805 files; manifest `sha256.txt` `2ef6a0a8ada105c1dda20c27962b6b485c086f33968c51595e62097be50769e3`, written last by the kit's own `finalize-manifest.sh` after every writer stopped, and verified.
- **Scratch (not evidence, not Git):**
  - `m6e2-work\` holds the fresh framework extraction, the source copy and the proprietary extracts;
  - `m6e2-scratch\` held the rehearsal trees (removed);
  - the guard's state root `~/.local/state/glacier-relay-m6e2-offline` held the dry run's throwaway token directories (removed; empty at the end).
- **Phase times (UTC):**
  - checkpoint 16:23–16:26;
  - source edit 16:28;
  - build 16:29–16:30;
  - verification and layout about 16:35–16:45;
  - content rehearsal 16:52–16:53;
  - tests 16:53;
  - installer rehearsal 16:53–16:55 (attempt 1), 17:08–17:10 (attempt 2) and 17:45–17:47 (attempt 3, of record);
  - drift test about 16:57 (attempt 1) and 17:44 (attempt 2, of record);
  - dry run 17:00, 17:02–17:04, 17:05–17:07 (attempts 1–3) and 17:47–17:49 (attempt 4, of record);
  - record (a) 17:10–17:18 (attempt 1, superseded) and 17:49–17:56 (attempt 2, of record);
  - preview check 17:19–17:22 (attempt 1) and 17:56–18:00 (attempt 2, of record);
  - the independent check: part 1 about 16:46–16:55, part 2 about 17:22–17:41;
  - final checks 18:00–18:04Z: the final checks 18:00:46–18:03:35, the seal 18:04:17.

### 11.1 Resolved identities and the starting state (`checkpoint.txt`, `checkpoint-game-verify.txt`)

**Repositories, resolved from Git:**
- glacier-relay `main` `97268fa1364c8e715edfcb14227a9e275bf3fd00` = origin, clean.
- ZHMModSDK `relay/m2` `3b892cad3f718037bcde286d7061342ba3ba34e8` = origin, clean.
- Both match the authorization's checkpoint.

**The source's provenance** (read with `git show`; the historical branch is never checked out or changed):
- `research/hitmen-revival` is `7ab0eceb…` locally and on origin.
- The preserved M6-C2 copies are byte-identical to the branch's blobs:
  - `manifest.json` = blob `6b0b86c6`, `3d52b9f4…`;
  - `hitmen.entity.json` = blob `2f9f4633`, `d91575ad…`.
- `paris_scene.entity.patch.json` is the branch's chunk3 global-data patch with exactly its two hash lines changed.
- All 473 files listed by `m6c2-offline`'s manifest verify. The manifest itself is `e81e7248…`; its hash was not in the docs before and is recorded here.

**Artefacts:**
- **native4:** `artifacts.sha256` 5/5; the DLL `806de7a9…` (11,065,344 B); the frozen probe `4cb8cc0e…`.
- **Sealed roots:** `m6e1-design` `8dab580a…` (13/13 files) and `m6f2b-run1` `05fd0a4e…`.
  - For `m6f2b-run1`, only the manifest file was compared here. Its 7,215 files were verified at the M6-E1 checkpoint, and record (a) verifies them all again.

**Tools:**
- **The framework:** `Release.zip` `08e68e76…` as recorded. Its 23 recorded file hashes (`framework-hashes.sha256`, identical to M6-C2's copy) verify on the fresh extraction.
- **The converter:** ResourceTool `1941d7e9…` as recorded.
- **The reader:** `rpkg_read.py` `a38b4107…`, both the committed copy and M6-C2's.
- Nothing was upgraded or replaced.

**The game:**
- `content-verify.sh` passes against the complete M6-C2 baseline: the 253-file listing with mtimes, every Retail hash, the chunk0 / chunk27 package hashes.
- M0 26/26.
- No `patch300` package; `packagedefinition.txt` `6c88d12d…`, `mods.ini` `b90b4c5e…`, `thumbs.dat` `ea5a4549…`; no relay file under `mods\`.
- No HITMAN, probe or BEAM process; no listener on 4747–4749; no token file.

### 11.2 The one edit — the asserted source diff (`source-edit.txt`, `content/edit-report.txt`, `content/source-diff.txt`)

**How the edit was made:**
- The scratch copy is `m6e2-work\src\SDK.Hitmen` (each file compared to the preserved bytes).
- The brick source is one line of compact JSON, so the edit is a byte-level insertion. Re-serialising could have changed other number texts silently.

**The bytes:**
- The original's first 988 bytes and its remaining 1,268 bytes are unchanged.
- Between them, 126 bytes are inserted: `,"m_mTransform":{"type":"SMatrix43","value":{"rotation":{"x":0,"y":0,"z":0},"position":{"x":-89.49,"y":14.83,"z":-1.5221779}}}`.
- 2,256 → 2,382 B; the edited file is `f09d93d3…`.

**Asserted:**
- A recursive structural diff of the two parsed documents, with key order compared, finds exactly one difference: an ADDED `entities.feede715906f747f.properties.m_mTransform`.
- The value is exactly the authorized object, number texts and int / float kinds included.
- Agent48 keeps its five properties in order, and the new one is sixth.
- Unchanged:
  - `tempHash` / `tbluHash`, the root, `Agent48Spawn`;
  - Agent48's name, factory, blueprint, parent and subsets.

**The words** (decimal → binary64 → binary32, the parser's path): `c2b2fae1` / `416d47ae` / `bfc2d6ba` = −89.48999786376953 / 14.829999923706055 / −1.5221779346466064.
- The checker found that direct decimal → binary32 rounding gives the same words, and that each is the nearest binary32.
- The converter's own words are read back from the generated TEMP (11.4), never assumed from this computation.

`manifest.json` and the Paris patch are the preserved bytes.

A console-only artefact is noted in `source-edit.txt`: a convenience `sha256sum -c` over M6-C2's whole content list reported five absent historical files. The copy was verified file by file.

### 11.3 The isolated build (`build-attempt2\`; attempt 1: `build-attempt1-NOTE.txt`)

**The framework:** a FRESH extraction of the recorded zip into `m6e2-work\smf-attempt2\framework` (150 entries, zip integrity test).
- M6-C2's framework directory holds that stage's `Output\` and a conversion cache keyed to the old source, so it was not reused or touched.
- The 23 recorded hashes verify, and the release-default `config.json` equals M6-C2's copy.

**Asserted before execution:** the effective `config.json` is M6-C2's byte for byte (`89cc3fbe…`):
- `outputToSeparateDirectory` true;
- `skipIntro` false (no thumbs stage);
- `loadOrder` `[SDK.Hitmen]` only;
- `outputConfigToAppDataOnDeploy` false.

The mod manifest is asserted structurally: exactly the one super-partition package-definition line M6-C2 recorded, and no thumbs, blob or dependency entry.

**The run:** `Deploy.exe` (console logging), rc 0, 10 s. `Output\` holds exactly three files:

| File | Size | sha256 |
|---|---|---|
| `chunk0patch300.rpkg` | **1,960 B** | **`5ac6484842eb2c5dbb9370d0084ebbd49abaf8abcf6acd8605d60d4e075aa4fa`** |
| `chunk27patch300.rpkg` | 2,170 B | `58e9a10f57ba967352389efa20762fa5cb068bd68f21fd69af366ecca464a35c` |
| `packagedefinition.txt` | 90,716 B | `9433888bcb5dd2a639dc4eb426fa072963ee5c3ad2323438838a97eeec560b39` |

They are copied into `generated\` with `generated.sha256`. The M6-C2 package of record is never overwritten; it stays in sealed `m6c2-offline\generated`.

**The game during the build:**
- The game listing (sizes, mtimes) before the build equals the complete baseline listing, and it is unchanged after (0 lines of diff).
- The package-definition, `mods.ini` and `thumbs.dat` hashes are unchanged.
- The framework wrote only its own `Deploy.log`, `Output\` and `cache\`.

**Attempt 1 stopped before `Deploy.exe` ran.** The build script's own manifest check wrongly required no `packagedefinition` key; the qualified manifest carries one. Nothing was deployed. Attempt 2 repeated every step on a new extraction.

### 11.4 Independent output verification (`verify\`: `verify.txt`, `layout.txt`, `agent48-matrix.json`, `checker-report-1.txt`, `checker-corrections.txt`)

Both packages were read with the committed reader and the SDK-pinned ResourceTool: the original from sealed `m6c2-offline\generated`, the new one from `generated\`.

| Check (authorization 3) | Result |
|---|---|
| 1. TEMP resource id, entities, dependencies; Agent48 | `007C57A6EA581F8C` with the same four dependencies (ids, flags 0x1F, order). Three authored entities `Hitmen` / `Agent48` / `Agent48Spawn`; Agent48 is sub-entity 1 and gains exactly a sixth property, `m_mTransform` (`SMatrix43`) |
| 2. The twelve words (read from the TEMP binary, cross-checked with the converter's JSON) | XAxis `3f800000 00000000 00000000`, YAxis `00000000 3f800000 00000000`, ZAxis `00000000 00000000 3f800000`, **Trans `c2b2fae1 416d47ae bfc2d6ba`**. The translation is bitwise the intended words; the rotation is numerically the identity with no signed zeros (all `00000000`). Saved as `agent48-matrix.json` (sha256 `cd90df8d…`, the classifier's pin) |
| 3. Every other TEMP field and sub-entity | The ONLY semantic difference is one property value APPENDED to sub-entity 1. Identical: the root, the spawn (transform, flags, player id, references), subType, blueprint index, root index, property overrides, external scenes, and Agent48's logical parent, factory index and post-init / platform values |
| 3. The layout (explained separately) | The BIN1 data grew by 72 B: one 24-byte property-value entry at data offset 560 (Agent48's sixth) and one 48-byte value at 672. The relocation table and the type-pointer table each gain one offset (576, the value pointer; 568, the type field). Later offsets and pointer targets shift by the bytes inserted before them. The type list is byte-identical (the `SMatrix43` type already serves the spawn). Consequent counts: data 0x420 → 0x468; segments 228 → 232 B and 230 → 234 B. The checker rebuilt the generated TEMP byte for byte from the original plus only the intended edit, and found the insertion pair unique over every 8-aligned candidate |
| 4. TBLU and identifiers | The brick TBLU is byte-identical (`0c65a970…`, 1,212 B; its stored blob too); the resource ids and dependency identifiers are unchanged |
| 5. Unchanged packages | `chunk27patch300.rpkg` = `58e9a10f…` and `packagedefinition.txt` = `9433888b…`, full sha256 |
| 6. Inventory | Exactly the three framework outputs (+ the manifest). The new chunk0 is `5ac64848…`, 1,960 B; the original of record is unchanged |
| 7. The real game | Unchanged by the build: the listing and three key-file hashes. The complete baseline is the stage's start and end check |

**Recorded as a residual** (found by the checker, not by `verify.txt`): the package's resource-table entry for the TEMP changed with it.
- size 1,546 → 1,626 B; stored (compressed) 0x462 → 0x477; size-in-memory 991 → 1,043.
- The checker's hypothesis, framework code not read: a size-proportional estimate (≈ size × 0.641), the same rule that produced the M6-C2 values the engine loaded in M6-C3 through F2b.
- Whether the engine relies on the value is not established.

### 11.5 The installation / rollback rehearsal (scratch only; the real installation never written)

**The committed content rehearsal** (`content-rehearsal-attempt1\`): `tools/content-deployment/rehearsal.sh`, re-run with the CHANGED inputs, the M6-E2 package set. The committed scripts are unchanged since M6-F2b; only the artefacts differ.
- Ten cases pass, 0 failures. They include:
  - the normal install and rollback (installing `5ac64848…`);
  - an **interrupted installation** (a `.installing` remnant and one package) restored byte-identically;
  - a missing package and a failed package-definition replacement, both refused before any write;
  - the damaged-package-definition recovery, the existing-package refusal, the one-missing-backup rollback, the repeated rollback, the missing timestamp manifest, paths outside the root, and the generic `mods.ini` capture / restore.
- The game listing is identical to the baseline afterwards.

**The M6-E3 gated installer and cleanup** (`run-rehearsal-attempt3\`, of record): `kit/run-rehearsal.sh`, all M6-F2b cases re-run, because the installer is a changed input of every case. 0 failures:
- **V:** a valid scratch record through the pinned gate, the record check and the 7-input copy boundary.
  - The exact delta, with the settings file exactly `[command] / enabled = true / port = 4749 / effectful = false / token`.
  - Then the cleanup: the scratch tree is byte-identical, with the exact 100-ns creation / write ticks of `packagedefinition.txt` and `mods.ini`.
  - The original `mods.ini`, with `crash_reporting = true`, is back; the throwaway token is removed.
- **P, X, Y, S1, S2, N, R, O, M, I and D:** a wrong pin, another tool, a changed manifest, a record older than the confirmation, a record past its maximum age, a not-ready record, another run's record, another state root, a missing record, a changed INI, a changed DLL. Each is refused before any write, with the sentinels (listing, hashes, exact ticks) unchanged.
- **Two added wrong-artefact cases, both refused before any write:**
  - **A0:** M6-C2's package `f4a3295a…` supplied in place of the new one before the record. The record is not ready (the content checks FAIL), and the gate refuses it.
  - **A1:** the new package swapped for the old one after the record. Refused at the copy boundary.
- **B:** a failure after every write; the immediate rollback restores the original `mods.ini` bytes and exact timestamps.
- **K:** the positive controls of the sentinel and of the exact-tick comparison.
- **C:** rehearse-mode refusals of the real game root and of the run's state root.

Attempts 1 and 2 also passed, but are superseded: later kit edits changed one of their recorded inputs (`run-rehearsal-attempt1-NOTE.txt`, `SUPERSEDED-after-checker-part2-NOTE.txt`).

This rehearsal ran in rehearse mode with scratch records. `r1-install.sh`'s LIVE-only blocks are not exercised by it: the process check, the native4 manifest, the record (a) copy and live record check, the package-definition decryption / plaintext diff, `thumbs.dat`. They are M6-F2b's, which ran live, changed only in constants.

**Reused unchanged coverage, keyed in record (a):**
- the evidence-guard self-test and the narrowed timestamp-capture test (M6-F2a; their scripts unchanged);
- the readiness-tool tests (M6-F2b).

The real installation must still be verified against its full byte and timestamp baseline when M6-E3 runs; M0 26/26 alone is not that criterion.

### 11.6 The M6-E3 run kit (`kit\`: `SOURCE.txt`, `KIT-DIFF.txt`, `RUNBOOK.txt`)

**Derivation:** from the accepted M6-F2b kit. 28 files:
- 9 copied unchanged (including `mods.ini.run`);
- 13 derived (every difference in `KIT-DIFF.txt`, each header naming its changes);
- 4 new: `placement.py`, `placement_test.py`, `seq-read.sh`, `RUNBOOK.txt`;
- plus `SOURCE.txt` and `KIT-DIFF.txt`.

`kit\__pycache__\run_manifest.cpython-38.pyc` is also present. It is a bytecode cache written when the drift test imported `run_manifest.py` (`python -I` does not suppress it). It is not pinned by record (a), and never used: the kit runs `run_manifest.py` as a script. It is sealed with the evidence as found.

**Use in M6-E3:** run in place from the sealed M6-E2 root, read-only.

**Pinned inputs:**
- the native4 DLL;
- the M6-E2 package set and its manifest;
- the decoded matrix (`cd90df8d…`);
- `mods.ini.run` `f4f44345…` (unchanged);
- every committed tool the kit uses.

The effectful tool `cmd-m6f.exs` and the follow-up engine are not used and not pinned.

**Read-only by configuration:**
- The installer writes `effectful = false` and asserts it (one line `effectful = false`, no `effectful = true`, exactly five lines).
- The node starts without `effectful` (the BEAM authority OFF). `start-beam.sh` only warns if the authority is not reported disabled; the R2 identity baseline and `linkcheck` stop on it.
- **The DLL's first inert run.** `806de7a9…` has run only with `effectful = true`, and the native regression does not compile `GlacierRelay.cpp`. So the inert wiring rests on source:
  - `GlacierRelay.cpp:134–138`: both appliers only under the setting;
  - `GlacierRelay.cpp:152`: the read-only allowlist line;
  - `CommandLink.cpp:328–332`: the effectful entries advertised only under the setting (M6-E1 7.4 wrote 327);
  - `CommandProtocol.cpp:348–349` and `442–443`: both effectful commands rejected;
  - `CommandScheduler.cpp:624–628` and `650–654`: no applier, no application.
  
  The R2 `linkcheck` is its FIRST runtime evidence, and an advertised effectful entry there is a stop. M6-E1 7.4's "the runtime-exercised native4 DLL" holds for the effectful configuration only.
- **Two setter call sites remain** in the binary (`TransformApplier.cpp:72`, `OutfitApplier.cpp:75`), reachable only through the appliers.
- `linkcheck` expects the six inert entries and no effectful entry advertised or claimed.
- `op.sh` has no effectful kind. It allows only `status`, `journal`, `linkcheck`, `arm`, `disarm`, `players`, `entity` and `ctransform`. Any argument naming a lift, restoration, transform set, attestation, effectful arming or outfit command is refused before anything is issued.
- "No arming" in M6-E1 means no EFFECTFUL arming. The ordinary INERT `arm` the inspections need is kept.

**`ident.exs`:** the inert expectations. The authority must be disabled and disarmed at the baseline and at every check; there is no lift budget. A changed identity writes the stop marker.

**`placement.py`:** classifies each exact inspection against the INSTALLED package's decoded matrix (pinned), never against the old origin.
- **The translation classes:**
  - `at_P_exact` (bitwise);
  - `at_P_within_tolerance` (1e-4 m);
  - `at_P_xy_z_different` (dz recorded);
  - `at_template_origin`;
  - `elsewhere` (distances to P, the old origin, the spawn's authored position and the local hero);
  - `unavailable`.
- **Separate facts:**
  - the rotation by value (+0 = −0, the words and any −0 listed);
  - the parent-relative group;
  - `cand_dirty`;
  - the local hero against the earlier start spread (outside = a finding, not attributed);
  - with `--prev`: the sample-to-sample relation, and the hero stationary within 1e-4 m;
  - with `--after-turn`: an orientation change is a presentation change, recorded with the words.
- Every class prints its qualifier (section 6 of the authorization; 11.10).

**`seq-read.sh`:** one sampled read set:
- the identity check;
- inert `arm`, in the first set only (r3; the channel stays armed inert);
- players, entity (present) and ctransform (present);
- the decoded words;
- the cross-check;
- the placement class;
- the controls: slot 0 unchanged; the outfit `874c4c48…` in slot 0's hero kit and registry outfit, and unchanged; the hero stationary.

A failed control writes the stop marker. A read after a stop needs `--after-stop`.

**No committed tooling was changed.** Every edit is a kit file in the guarded evidence root, pinned by the readiness record.

### 11.7 Dry run and targeted tests

**The dry run** (`dry-run-attempt4\`, of record; `scripts/dry-run.sh`):
- **The setup:**
  - the kit as M6-E3 uses it;
  - against the frozen probe in INERT mode (fake frames, fake candidate; never HITMAN);
  - the BEAM application started without `effectful`;
  - an ephemeral token in a throwaway ext4 directory.
- **Lifecycle:** each phase started its own node and probe and ended them by their own PIDs as soon as its outcome was known.
- **The result:** 25 checks, 0 failures (17:47–17:49Z):
  - **menu (the R2 shape):**
    - `linkcheck`: the six inert entries, none effectful;
    - the inert identity baseline;
    - inert arming; players / entity absent / ctransform absent applied, decoded and cross-checked with 0 NOT;
    - disarmed; a boundary capture.
  - **paris (R3–R7):**
    - `linkcheck` and the identity baseline;
    - `seq-read` r3 complete, placement `elsewhere`. The probe's FAKE candidate stands at `Agent48Spawn`'s authored position, 0.000 m from it: a tooling result, never runtime evidence;
    - the outfit control passes. The fake local hero, at the probe's M6-B1 fake position, is recorded as a FINDING outside the real start spread and does not stop the set;
    - the inert arming once, at r3 (no redundant arm);
    - r4 / r5a / r5b bit-equal at the samples, printed as agreement at samples, not persistence. r5b declares the camera turn;
    - **the kit's refusals** before anything was issued: `opf`, an effectful action, the outfit inspection, the candidate property reader, a reused prefix;
    - **bypassing the kit:**
      - the authority refused an effectful arming with `effectful_disabled`;
      - a lift through the effectful tool was NOT SUBMITTED: that tool's own local guard refused it (`effectful-armed: FAILED`) and it never reached the authority. The kit's own `opf` attempt was refused by `op.sh`'s substring guard;
    - the stop marker: a read set is refused without `--after-stop`;
    - after the probe ended (the "game exit") and the link closed, the post-exit captures (`cap-final`, `final`, `fin-status`, `fin-journal`) were taken before the node stopped;
    - the journal: contiguous; 15 inspections; nothing effectful accepted, transmitted or armed;
    - the only EVIDENCE NOT lines are the five fake-hero spread findings;
    - the fresh-node replay at the exact `cap-final` boundary passed. The probe sends no telemetry, so this exercises the procedure, not a mission;
    - the probe's native log: inert, 0 WARN / ERROR / FAULT.
  - **the end:** the token in 0 evidence files, then removed; no process or listener left.
- **Attempts 1 and 2 failed and are retained with notes.** Both failures were defects of the dry-run script, not the kit:
  - attempt 1 passed a phase's token directory as the guard's state root;
  - attempt 2 had a wrong expectation for the fake hero, and a missed fix of one call.
- **Attempt 3 passed (23/23) but is superseded:** the kit's arming change and the dry run's corrected bypass assertion came after it.

**The classifier tests** (`tests-attempt1\`): `placement_test.py`, 13/13, with ResourceWarnings treated as errors.
- The fixtures:
  - the REAL M6-F2b r3 read (`at_template_origin`);
  - P exact with signed zeros;
  - z at the old floor height (dz −0.01717758 m);
  - one ULP (within tolerance);
  - the spawn position (`elsewhere`);
  - a rotated candidate;
  - a local group disagreeing with the world;
  - dirty and a moved hero (findings);
  - malformed or unavailable reads;
  - a wrong matrix pin (refused);
  - the sample-to-sample classes;
  - a declared turn;
  - the log.
- These are the classes the frozen probe cannot present.

**The drift-rule test** (`deps-attempt2\`, of record): on a scratch clone with real commits, the refresh's rule (imported from the kit) through `readiness.py`.
- **ok:** HEAD = record (a)'s commit; one and two docs-only commits.
- **FAIL:** a `tools/` commit; a `relay/` commit; a docs-only head not descending from it; a non-docs file renamed INTO `docs/` (the rule uses `--no-renames`; the checker's finding).
- The real repository was untouched.

### 11.8 The pinned OFFLINE readiness record (`readiness-attempt2\`)

**Record (a):** `readiness-attempt2/record-a.json`, run id `m6e2-offline`.
- **Pin:** **`195aa278b15c4d67170e53da5aacab0462186075091ca28d67eecb9be6cecf26`** (`record.sha256`).
- **Result:** RESULT ok, 122 checks: 108 performed now, 13 reused, 1 cached; 0 FAIL, 0 INVALIDATED (434 s).
- **The gate:** passes with the pin and refuses a wrong pin (`gate-check.txt`).
- **The superseded attempt:** `readiness-attempt1` (`de8b1986…`) preceded the corrections of 11.9; its pin must not be used.

**Performed now:**
- the frozen refs: relay head `97268fa…` clean, the four relay trees, the SDK head and `Mods/GlacierRelay/Src`, the mix files, the runtime files and `~/.local/opt/beam-env.sh` (it chooses the runtime through `PATH`);
- the native4 manifest with every listed file; the DLL; the probe;
- the M6-E2 content manifest with every listed file, the three packages and the decoded matrix; `mods.ini.run`;
- the 21 committed tools the kit uses and every kit file;
- the six sealed roots it relies on, each with every listed file re-hashed where the kit reads it (`m6f1b-run1`, `m6f2a-offline`, `m6f2b-run1`, `m6c2-offline`) and by manifest (`m6f1a-token-guard`, `m6f1a-offline`);
- the time-sensitive checks AS OF THIS RECORD ONLY: no run process, ports free, M0 26/26, no token file, no run file in the game, the complete game baseline, and the live `mods.ini` / `packagedefinition.txt` / `thumbs.dat`.

**Reused** (each keyed to the identities its own run recorded; what it is not keyed to is stated in its `covers`):

| Reused result | Source |
|---|---|
| The M6-F1b pre-flight's time-independent gates | `m6f1b-run1` |
| The BEAM qualification matrix of record (576 checks) and the five full suites (5 × 603) | `m6f1a-token-guard` |
| The native regression of record (25/25) | `m6f1a-offline` |
| The evidence-guard self-test and the timestamp-capture test | `m6f2a-offline` |
| The readiness-tool tests and the BEAM suite under the recorded runtime | `m6f2b-run1` `tests-attempt1`. Only `docs/` changed since |
| This stage's classifier tests, content rehearsal, installer rehearsal (attempt 3), dry run (attempt 4) and drift-rule test (attempt 2) | `m6e2-offline` |

Not keyed by any check: the compiled `relay/_build` and `relay/deps` (gitignored). `mix.lock` keys the dependency versions and the trees the sources.

**Cached:** the native source scan (`SetObjectToWorldMatrixFromEditor` call sites: 1). The cache key is identical, so the setter's call site is still in the binary's source: read-only by configuration, not by construction.

**Not carried, and why:**
- **M6-F2b's follow-up matrix groups:** no lift in this run.
- **The two M6-F1b historical-audit reuses:** statements about that checkpoint, relied on by nothing here, and no audit trigger.
- **The effectful tools:** not used.

**It qualifies; it does NOT authorize an installation.** The M6-E3 installer gates only on a post-confirmation record (b) of run `m6e3-run1` (`kit/refresh.sh`, then `kit/r1-install.sh`). Record (b) does three things:
1. Performs every file / git / manifest check of record (a) again.
2. Replaces record (a)'s exact relay head with the current head (clean, on `main`, = origin), plus the **docs-only drift rule**: the head must descend from `97268fa…`, and every path changed since must be under `docs/` (`git diff --no-renames`: a rename out of a non-docs path counts). So this stage's documentation commit, and documentation-only review corrections, do not invalidate it; any change to the tools, the kit's inputs, the relay or the dependency lock does.
3. Verifies the sealed M6-E2 root against the manifest hash this record publishes (`2ef6a0a8ada105c1dda20c27962b6b485c086f33968c51595e62097be50769e3`), with every listed file.

It also reuses record (a) by its pin, takes the pre-install captures, and performs every time-sensitive check now (including the empty state root).

**The preview check** (`preview-check-attempt2\`, `refresh-attempt2\`, of record; attempt 1 superseded with record (a) attempt 1): the refresh in preview mode (`pending`: the root not sealed yet) wrote a PREVIEW record (b) (run id `m6e3-run1-preview`, the M6-E2 roots, a scratch confirmation): 125 checks ok (124 performed now, record (a) reused by its pin), including the current-head check, the drift rule (trivially 0 at HEAD = record (a)'s commit), the captures and the empty state root. The installer's binding steps on copies (the copy = the pin, `readiness.py` = the record's tool, the manifest copy = its hash, record (a) copied as `readiness-a` names it) and `readiness.py gate` (after the confirmation, at most 1,800 s old) passed. `record-check.py` LIVE refused exactly ONE check, the absent `root-m6e2-offline` — the designed result for a preview inside M6-E2 — and, under the live run id, the run id as well: no installer accepts a preview record. `relied-on.py`: 31 verified, 0 changed; the cleanup's and `verify-after`'s capture references resolve through the record copy. Not exercisable before M6-E3 (stated by the checker, 11.9): the sealed-root check, the drift rule against a real later commit, the live roots and confirmation, a full live record-check pass, the installer's live branch, the 30-minute window to a live install

**Qualifications that no longer hold for M6-E3:**
- the M6-F2b kit's frozen content identity (`f4a3295a…`) and its readiness records;
- M6-C2's "generated = preserved" for `chunk0patch300` (it holds for chunk27 and the package definition);
- the F-stage's recorded candidate baseline words: the candidate's expected state is now the package's matrix, never the old origin;
- the superseded attempts (`run-rehearsal-attempt1` / `2`, `dry-run-attempt3`, `deps-attempt1`, `readiness-attempt1`, `preview-check-attempt1`): `SUPERSEDED-after-checker-part2-NOTE.txt`.

Record (a)'s time-sensitive results are as of 17:10–17:18Z and are re-performed by M6-E3.

### 11.9 The independent check (one checker; `verify\checker-report-1.txt`, `checker-report-2.txt`)

**Part 1** (the content diff, binary32 values, unchanged surfaces, layout): no discrepancy.
- It confirmed every number and claim by its own code: a typed JSON diff; exact rational binary32 rounding; its own BIN1 decoder; its own RPKG table parser.
- Its full byte-level rebuild of the new TEMP from the original plus only the intended edit is identical.

What it found, all recorded in `checker-corrections.txt`:
- three wording overstatements in `layout.txt`: offsets "shifted" possibly by 0; 27 null pointers exempt; the consequent count / size fields not listed;
- the unreported resource-table size fields (11.4).

`verify.txt` and `layout.txt` are not rewritten.

**Part 2** (qualification applicability): nothing blocking; ONE real discrepancy and several unstated gaps, each corrected or stated. Everything named below was re-run (`SUPERSEDED-after-checker-part2-NOTE.txt`).

**The discrepancy, a rename hole in the drift rule.**
- **The finding:** with git's rename detection, `git diff --name-only` lists only the new path of a non-docs file renamed into `docs/`, so the rule passed it.
- **Mitigation already in place:** the keyed paths stayed protected by their own checks, and nothing M6-E3 uses was exposed.
- **Corrected:** the rule now uses `--no-renames`, and the drift test gained that case (it must FAIL).

**Stated or corrected gaps:**
- **The DLL's inert wiring has never run.**
  - `806de7a9…` has run only with `effectful = true` (M6-F1b, F2b).
  - The native regression does not compile `GlacierRelay.cpp`, which holds the settings read and the applier construction.
  - So this binary's inert configuration rests on source: `GlacierRelay.cpp:134–138` (both appliers only under the setting) and `:152` (the read-only allowlist); `CommandLink.cpp:328–332` (M6-E1 wrote 327); `CommandProtocol.cpp:348–349` and `442–443`; `CommandScheduler.cpp:624–628` and `650–654`.
  - The M6-F1b source gate supports this, and the R2 `linkcheck` is its FIRST runtime evidence. The runbook makes an advertised effectful entry there a stop.
  - M6-E1 7.4's "the runtime-exercised native4 DLL" is true only for the effectful configuration.
  - The installed SDK core parses the setting: only true / 1 / yes / on / y mean true (`ModSDK.cpp:1563–1583`).
- **Two setter call sites remain** in the binary, `TransformApplier.cpp:72` and `OutfitApplier.cpp:75`. Both are reachable only through the appliers. Read-only by configuration, not by construction.
- **The installer rehearsal** ran in rehearse mode with scratch records. `r1-install.sh`'s LIVE-only blocks were not exercised: the process check, the native4 manifest, the record (a) copy and live record check, the package-definition decryption and diff, `thumbs.dat`. They are M6-F2b's, which ran live, changed only in constants. This is now stated in its `covers`.
- **Not covered by any qualification of record** (pinned only): `verify-after.sh` (it reports and asserts nothing), `watch-m6e3.sh`, and `finalize-manifest.sh`. The last of these sealed this stage's own root.
- **Unkeyed:** `relay/_build` and `relay/deps` (gitignored; `mix.lock` keys the versions, the trees the sources). Now stated in record (a)'s notes. `~/.local/opt/beam-env.sh`, which decides which OTP / Elixir run through `PATH`, is now pinned.
- **The dry run's lift bypass** was stopped by the effectful tool's own local guard and never reached the authority; the line now says exactly that. The `opf` case was refused by the kit's substring guard.
- **Redundant arming:** every later read set re-armed and logged a benign `{:error, :already_armed}` as an EVIDENCE NOT line. The inert arming now happens once (r3).
- **One `covers` overstatement** ("only docs/ changed") is corrected.
- **Still unexercised before M6-E3:**
  - the sealed-root check (possible only after the seal);
  - the drift rule against a real post-(a) commit;
  - the live roots and the real confirmation;
  - a full live record-check PASS;
  - `r1-install.sh`'s live branch;
  - the 30-minute window to a live install.

**Confirmed:**
- **Every reuse is applicable for what M6-E3 relies on:**
  - the relay trees are identical at `9ed2b38`, `69b742e` and `97268fa`;
  - the pre-flight's gates cover the inert advertisement and issuable set;
  - the matrix includes inert scenarios advertising only the six inert entries;
  - every recorded input of the M6-F2b tests is current.
- **The inert configuration** in the kit (the settings line written and asserted; the node without `effectful`; no effectful path in `op.sh` / `seq-read.sh` / `cmd.exs`) and in the native source.
- **Nothing in the kit requires an invalidated qualification.** M6-C2's chunk0 survives only as the rehearsal's wrong artefact.
- **The preview's single refusal** is the designed one.

### 11.10 Unresolved experimental risks and the proposed M6-E3 operator sequence (`kit/RUNBOOK.txt`)

**The interpretation refinements, carried into the runbook and printed by the tools:**
- **The first Paris inspection is a sampled state after load.**
  - "At P" means the requested placement is observed at the first sampled frame. It is not proof of the initialization event or its writer.
  - "At the old origin" means the placement is not observed at these samples. That cannot distinguish never applied from applied and subsequently changed.
- **Agreement between reads** is agreement at those samples, not continuous persistence. The bracketing reads do not observe the frames of a camera recording.
- **Floor and collision:** the nearby authored object bases support a floor-placement hypothesis only. They are not a measured floor or collision clearance at P.
- **A new exposure:** P is a new environmental exposure. The unchanged adapter does not prove an unchanged crash or collision risk.
- **Rendering is not proven:** the root's linked / renderable ancestry supports the spatial-interface reading, but does not prove that geometry is drawn. Five root components stay unresolved; no new investigation of them was made.
- **The `m_bActive` alias** to the template's camera is not a proven hero-activity switch.
- **The camera turn is operator input,** proposed and needing M6-E3's explicit approval. It is not autonomous control, and not permission to walk.
  - **The bearing:** the gate and P lie on opposite sides along the planter avenue. With the closed main gate centred, P is directly behind: between the planter rows, between the second and third pairs counted from the pair beside the start (≈ 3.6 m and 7.3 m away), on the centreline.
  - **Coverage:** a full turn does not by itself establish an unobstructed, correctly elevated view of P. Ambiguous coverage is INCONCLUSIVE.
- **Presentation versus identity:** identity, registry and outfit checks are separate from presentation changes caused by an authorized camera turn. An orientation change after a declared turn is recorded with its exact words, and is not an identity change.
- **Visual testimony:** a figure near P is testimony correlated with the inspected candidate, not a proven pixel-to-entity mapping. Ambiguity is retained. A negative visual result is not automatically "not rendered".
- **The capture is the operator's own,** with an already set-up tool. Nothing is installed or uploaded, and no recording is promised.

**The separate verdicts:**
1. Loaded.
2. Resolved.
3. Intended position observed (r3).
4. Later sampled position (r4–r6).
5. Camera coverage.
6. Operator observation.

**The proposed sequence:**
- **0:** verify the sealed M6-E2 root; claim `m6e3-run1`.
- **Checkpoint:** the plain-language statements above, and a fresh "Ready".
- **R1:** the refresh, record (b); a run token; the node without `effectful`; the gated installation with `effectful = false`; the watcher; the operator launches HITMAN.
- **R2, the menu:** `linkcheck`, the inert identity baseline, the absent-candidate reads, a capture.
- **R3:** the first Paris read set, with Agent 47 stationary.
- **R4:** about 30 s later.
- **R5, only with the separate camera-turn go-ahead:**
  - the default-view screenshot;
  - the bracketing read r5a;
  - ONE slow full turn, recorded, starting with the gate in view;
  - the bracketing read r5b (`--after-turn`);
  - the operator's words.
- **R6:** the final read.
- **R7:** the exit; the post-exit captures before the node stops; the cleanup; `verify-after`; the verdicts; the manifest.

**Stop conditions:**
- a changed identity, slot 0, outfit, or a hero moved while stationary (`seq-read`);
- a crash, a native WARN / ERROR / FAULT, a restart, or a malformed result (the operator).

None leads to a retry or a second deployment. No effectful command exists in the run.

**Residual risks:**
- the five unresolved components and the rendering;
- the facing direction of an identity rotation;
- what returned the lifted transform in M6-F2b (not answered by this route);
- NPC / AI reaction to a second hero;
- whether Agent48's own `TestCharacterCam` takes part in the view;
- occlusion and occupancy at P;
- the package's size-in-memory field (11.4).

### 11.11 A source note prompted by the operator's report (outside the evidence; hypothesis only)

The operator reported seeing, in a video, the SDK's menu teleport every NPC to Agent 47. A read of the SDK source (`relay/m2` `3b892cad`, read only):

| Feature | Source | What it does |
|---|---|---|
| "Teleport all actors to player" | `Mods/Player/Src/Player.cpp:366–379` | Iterates the actor manager's ACTIVATED actors and calls `ZSpatialEntity::SetObjectToWorldMatrixFromEditor` with the local hero's world matrix |
| The FreeCam hitman teleport | `Mods/FreeCam/Src/FreeCam.cpp:301–311` | Uses the same call on the LOCAL hero |

**[S]:** that is the setter M6-F1b / F2b called once on Agent48 [S]. Its quarter-metre lift was back at baseline within six frames [R].

**[I] / [H]:** the call itself evidently places the actor manager's NPCs (`ZActor`s) and the controlled hero. Agent48 is neither:
- it is a hero (`ZHitman5`), not a `ZActor` in that list;
- it is not the controlled hero (in no player slot).

M6-D's entity ACTIVATED flag does not distinguish them: it is clear on the controlled hero too. So what returns Agent48's transform is more plausibly tied to its unspawned state than to the call path.

This changes nothing in M6-E2 or the M6-E3 design. It is not evidence, and no investigation or runtime step follows from it here.

### 11.12 Commits and stop

- **The commit:** documentation only (this record, HANDOFF, ROADMAP), pushed to `main`; a docs-only descendant of record (a)'s `97268fa…`.
- **No change:** no native, BEAM, protocol, dependency or committed-tooling change.
- **Not in Git:** generated packages, extracted templates, decrypted content and third-party executables. They are in the guarded evidence and scratch roots.

**At the end** (18:00–18:04Z: the final checks 18:00:46–18:03:35, the seal 18:04:17):
- the complete game baseline is verified again: `content-verify.sh`, M0 26/26;
- no process, listener or token file;
- the state root empty;
- both repositories clean.

**Stop.** Not authorized by this record:
- installing anything into HITMAN, or launching it;
- a real token;
- live camera operation;
- any runtime command;
- activation;
- registry, input or physics changes;
- an alternate content experiment;
- M6 completion or a tag.

The next decision is M6-E3, under its own authorization and a fresh operator Ready.

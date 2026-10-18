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

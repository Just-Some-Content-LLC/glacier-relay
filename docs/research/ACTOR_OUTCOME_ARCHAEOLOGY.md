# Actor Outcome Archaeology — death, incapacitation, identity, causality

Date: 2026-10-06. Status: **static archaeology only.** No code changed, nothing deployed, no runtime observation. Sources: ZHMModSDK fork at `relay/m2` `bf8908ce` (SDK headers, upstream mods, upstream history), the M1/M2 run logs (`ZHMModLoader.log` hook-install lines on game `3.280.0.0`), `HITMEN_ENTITY_IDENTITY.md`, and — for the schema of the game's own telemetry events, which the SDK does not model — the Peacock project's TypeScript types (`components/types/events.ts`, `types.ts`), read as prior art under ADR 0004.

Everything marked *unverified* has not been observed on `3.280.0.0`. Nothing here is a design decision.

## 1. Question

What can contemporary Glacier prove about an actor becoming dead or incapacitated, who the actor is, and what caused it — so the next M2 stage can choose the weakest defensible vocabulary for kills/pacifications.

## 2. Surfaces found

Five candidate observation surfaces exist in the current SDK. All of the hooks among them **installed successfully on `3.280.0.0`** in every run so far (the only failing hook in the SDK is the EOS one, irrelevant on Steam).

| # | Surface | Kind | What it carries | Prior art |
|---|---|---|---|---|
| S1 | `Hooks::ZAchievementManagerSimple_OnEventSent(th, eventIndex, const ZDynamicObject& event)` | detour on the game's own telemetry/event stream (vtable index 7); the event is a JSON-shaped object `{"Name": ..., "Value": {...}, ...}` serializable with `Functions::ZDynamicObject_ToString` | the engine's own semantic events: `Kill`, `Pacify`, `BodyHidden`, `MurderedBodySeen`, `NoticedKill`, `Unnoticed_Kill`, `NoticedPacified`, `Dart_Hit`, `ActorTagged`, `ContractStart`, `ObjectiveCompleted`, `Spotted`, `Trespassing`, `Disguise*`, `ItemPickedUp/Dropped`, `SecuritySystemRecorder`, … | `Mods/AdvancedRating` parses `Kill`/`Pacify`/`ContractStart`/`SecuritySystemRecorder` from exactly this hook, reading `Value.IsTarget`, `Value.RepositoryId`, `Value.ActorType`; pattern fixed twice upstream (`19e626e4`, `43bb86b2` for Game Pass) |
| S2 | per-frame state over `Globals::ActorManager->m_activatedActors` (dense `TMaxArray<TEntityRef<ZActor>,500>` at `0x1F68`) reading `IActor::IsDead()/IsAlive()/IsPacified()` (vtable, 2021) and/or `ZActor::m_bAlive` (bitfield at `0x1178`, named 2026-01-14 in `c4366323`, no stated evidence), `m_fCurrentHitPoints` (`0x1028`) | polling, no hook | per-actor state; identity must be derived by us; no cause | `Mods/WakingUpNpcs` polls `m_activatedActors` every frame and calls `IsPacified()` (plus `m_bBodyHidden`, `m_bIsBeingDumped`) to pick actors to revive via `Functions::ZActor_ReviveActor` — functional evidence that the `IsPacified` slot means "knocked out" on current builds; `Mods/Player` sets `m_fCurrentHitPoints = 0` for one-hit kills; `Mods/Editor` lists `m_aliveActors` and filters on `m_bContractTarget` |
| S3 | `Hooks::SignalOutputPin(ZEntityRef, pinId, const ZObjectRef&)` | detour on every entity output pin fired in the game | pin names known to the SDK include `Dead`, `Death`, `DeathContext`, `Pacified`, `PacifiedData`, `OnPacified`, `OnActorPacified`, `TargetKilled`, `NonTargetKilled`, `ActorKillIActor`, `ActorPacifyIActor`, `BodyFound*`, `DetectedKill/Pacified` (`Pins.h`) | Editor uses the hook for tracing; **which entity emits the actor pins is not established** from source |
| S4 | `Hooks::ZActor_YouGotHit(IBaseCharacter*, const SHitInfo&)` | detour on damage application | a hit, before state changes | `SHitInfo` is only forward-declared in the SDK: no layout, so nothing readable from it today; `Mods/Player` uses it only to zero hit points |
| S5 | `Hooks::ZGameStatsManager_SendAISignals01/02(ZGameStatsManager*)` | detour; `th->m_gameState` / `m_oldGameState` are `ZAIGameState` snapshots | aggregates: `m_actorCounts.m_nLastEnemyKilled`, `m_nAliveGuards`, `m_nUnconsciousWitnesses`, `m_bBodyFound{,Pacify,Murder}`, `m_bDeadBodySeen`, tensions | `AdvancedRating` diffs old/new for body-found and alert signals; **no actor identity** |

Also present but not an observation surface: `ZActorManager::m_CurrentDyingActors` (`TSet`, `0x87788`), `m_aliveActors` (`0x8D08`, 400 entries, plus ids and grid nodes), `m_aTargetList` / `m_aCollateralTargetList` (`0x877B0/0x877C8`), `m_SpawnedActors` (`0x10630`), and `Functions::ZActor_KillActor(th, rKillItem, rKillSetpiece, EDamageEvent, EDeathBehavior)` / `ZActor_ReviveActor` (mutators; relevant only because their signatures show the engine's own death vocabulary).

Engine enums that name the concepts (`Enums.h`, from the game's reflection data, so these are the engine's words, not upstream's guesses): `EActorState {DEACTIVATED, ALIVE, DYING, DEAD, DISABLED}` (no SDK field uses it yet), `EDeathType {SLAP, PUNCH, PACIFY, KILL, BLOODY_KILL}`, `EDeathContext {UNDEFINED, NOT_HERO, HIDDEN, ACCIDENT, MURDER}`, `EDamageEvent {Subdue, CloseCombat, PushOver, KickDownStairs, DeadlyThrow, Shoot, Sedated, InstantTakeDown, CoupDeGrace, ContextKill, Garotte, …}`, `EKillType {Throw, Fiberwire, PistolExecute, …, KnockOut, Push, Pull}`, `EActorType {Civilian, Guard, Hitman}`. Note `EActorGroup` is just `Group_A..D` — it is not guard/civilian.

### The `Kill` / `Pacify` event payload (S1)

Not modelled in the SDK. From Peacock's types (the server that receives this stream), both events have the **same shape**:

```
RepositoryId, ActorId (number), ActorName, ActorType (EActorType), KillType, KillContext, KillClass (string),
Accident, WeaponSilenced, Explosive, ExplosionType, Projectile, Sniper, IsHeadshot, IsTarget, ThroughWall,
BodyPartId, TotalDamage, IsMoving, RoomId, ActorPosition, HeroPosition, DamageEvents (string[]), PlayerId,
OutfitRepositoryId, OutfitIsHitmanSuit, KillItemRepositoryId, KillItemInstanceId, KillItemCategory,
KillMethodBroad, KillMethodStrict, EvergreenRarity?, IsReplicated?, History
```

wrapped as `{Name, Value, Timestamp, ContractSessionId, ContractId}`. `AdvancedRating` confirms `Name`, `Value.IsTarget`, `Value.RepositoryId`, `Value.ActorType` on a current build; the remaining fields are Peacock's observation of the real client and are *unverified here*. `KillContext`'s numeric range matches `EDeathContext`; `KillType` plausibly `EKillType`; the value sets of `KillClass`, `KillMethodBroad/Strict`, `DamageEvents` are strings to be captured, not assumed.

## 3. Identity (Area A)

| Identity | Where | Scope | Instance-unique? | Notes |
|---|---|---|---|---|
| authored entity id `ZEntityType::m_nEntityID` (`0x58`, 64-bit) | `actor->GetID(ref); ref->GetType()->m_nEntityID`; used by `ZActorManager::GetActorById`, the Editor's external protocol, the game's own cross-brick references | **globally authored**: same content → same id across restarts, relaunches, machines | **only within its instantiation context**: a template instantiated twice yields the same sub-entity ids under different owners (`HITMEN_ENTITY_IDENTITY.md`). Qualifier available in the SDK: `ZEntityRef::GetClosestParentWithBlueprintFactory()` / `GetBlueprintFactory()` (the owning brick/template root) | collision rate among live actors in a real mission: *unverified* (H8 open question) |
| repository id (`RepositoryId` in S1 events; `ZTargetManager::STargetInfo::m_RepositoryId` for targets) | event payload; target manager; not modelled as a `ZActor` field in the SDK | globally authored **character** identity (the GUID contracts and challenges use) | **no** — it names a character definition; identical generic NPCs can share one | the right key for "which character", the wrong key for "which body" |
| `ZActor::m_nActorRuntimeId` (`0x119C`) | actor; `ZActorManager::m_aFreeActorRuntimeIds` free list, `m_aActivatedActorIds` parallel list | **scene** (recycled slot id, 0..499) | yes, while the actor is activated | unknown whether it survives deactivation/reactivation of the same actor |
| `ActorId` (number) in S1 events | event payload | unknown | unknown | hypothesis: `m_nActorRuntimeId`; *unverified* |
| `ZEntityImpl::m_nEntityPtrIndex` (`0x10`) | every entity | process/scene entity table index | yes while allocated | not used by any mod for identity; semantics *unverified* |
| position in `m_activatedActors` | manager | **frame** | no | the 2023 Hitmen identity; **rejected** (`HITMEN_ENTITY_IDENTITY.md`) |
| `m_sActorName` / `GetActorName()` | actor | authored | no | label only; many "Guard"s |

Runtime-spawned actors (`m_SpawnedActors`, crowd characters with `m_bCrowdCharacter`): authored entity id is a template id shared by every spawn of that template; repository id is the character's; the only instance-unique handles are runtime (runtime id, ptr index, pointer). *All unverified at runtime.*

Save/load: `ZActorManager::m_pSavableHandler` / `ISavable` exist; whether a loaded save preserves runtime ids, or whether the actor set is rebuilt with new ones, is *unverified*. Mission restart: the scene is rebuilt (M2 run: stage 0 → 8 without `LoadScene`), so runtime ids may or may not be reassigned identically; authored ids are the same by construction. Nothing in this document depends on either.

**What BEAM needs for M2 telemetry:** uniqueness *within one mission attempt*, plus enough to say which character it was. A tuple carried as observation satisfies that without claiming more: `{entity_id, instantiation qualifier if available, repository_id, actor_runtime_id, actor_name}`, with BEAM keying on `(attempt, entity_id[, qualifier])` and treating `repository_id` as character identity. Engine identity and Relay identity are therefore different things: the Relay key is attempt-scoped and opaque; the engine fields are evidence attached to it.

## 4. State (Area B)

| Concept | Confirmed by | Status |
|---|---|---|
| alive / dead (binary) | `IActor::IsAlive()` / `IsDead()` vtable slots (2021 layout; adjacent to `IsPacified`, which a shipped mod exercises); `m_aliveActors` list maintained by the engine; `ZActorManager::m_CurrentDyingActors` suggests an intermediate **dying** state (`EActorState::AS_DYING`) | suggestive-to-likely; the exact moment the engine flips alive→dead relative to the `Kill` event and to the animation is *unverified* |
| `m_bAlive` bit | positional rename, no stated evidence | **suggestive only**; do not build on it before correlation with `IsAlive()` |
| hit points `m_fCurrentHitPoints` | `Player` mod zeroes it to kill | numeric; `0` is not proven to equal "dead" (ragdoll/dying may lag) |
| unconscious / incapacitated | `IActor::IsPacified()` — `WakingUpNpcs` revives exactly the actors for which it is true and that works in play; `ZActor_ReviveActor` exists, so the state is **reversible** (vanilla NPCs are also woken by other NPCs) | functional evidence for "knocked out"; whether sedation (`eDE_Sedated`), emetic sickness, or being dragged/dumped are reported identically is *unverified* |
| pacified as the engine's word | `EDeathType::eDT_PACIFY`, the `Pacify` event, pins `Pacified`/`OnActorPacified` | the engine itself uses "pacify" for the non-lethal takedown outcome; using it would mirror engine vocabulary rather than invent it, **but** only once S1/S2 are shown to agree |
| body hidden / found / seen | `m_bBodyHidden`, `m_bIsBeingDragged/Dumped`; `ZAIGameState.m_bBodyFound*`, `m_bDeadBodySeen*`; events `BodyHidden`, `MurderedBodySeen`, `NoticedKill` | adjacent; out of scope for the first vocabulary |

State lives in the actor object (bits, hit points, vtable queries) and in manager collections (`m_aliveActors`, `m_CurrentDyingActors`); the authoritative *classification* of an outcome lives in the stats/event system (S1), not in the actor.

## 5. Causality (Area D)

| Fact | Directly observed | Derivable | Unknown |
|---|---|---|---|
| that a transition happened | S2 (edge) or S1 (event) | | |
| lethal vs non-lethal | S1 `Name` = `Kill`/`Pacify`; S2 `IsDead` vs `IsPacified` | | agreement between the two |
| whether the engine attributes it to the player | S1 `KillContext` (`EDeathContext`: `MURDER`, `ACCIDENT`, `HIDDEN`, `NOT_HERO`, `UNDEFINED`) and `Accident` | | what the client sends for NPC-on-NPC and scripted deaths (does `NOT_HERO` occur? is an event sent at all?) |
| method / weapon | S1 `KillClass`, `KillMethodBroad/Strict`, `DamageEvents`, `KillItemRepositoryId`, `WeaponSilenced`, `Explosive`, `IsHeadshot`, … | | exact value sets |
| instigator entity | — | S1 `PlayerId` only names the player; no field names an NPC instigator | NPC-caused outcomes |
| from S2 alone | nothing about cause | | everything |

So: causality is available **only** as the engine's own classification on S1, and only to the extent the engine chose to record it. Relay must not add to it. "Player killed actor" is at most "the engine recorded a `Kill` with `KillContext = MURDER` (or `ACCIDENT`) during this attempt".

## 6. Classification (Area E)

| Class | Native state (S2) | Event (S1) |
|---|---|---|
| mission target | `m_bContractTarget` (named; the Editor filters on it; `m_bContractTargetLive/Hidden` too), `ZActorManager::m_aTargetList` | `IsTarget` (confirmed read by `AdvancedRating`) |
| guard vs civilian | **no modelled field** (`m_eActorGroup` is A–D; enforcer/sentry bits exist but are not the type) | `ActorType` ∈ `EActorType {Civilian, Guard, Hitman}` (confirmed read by `AdvancedRating`) |
| crowd character | `m_bCrowdCharacter` | — (`CrowdKill*` pins suggest crowd deaths are a different path) |
| player | not an actor (`ZHitman5`) | `ActorType = Hitman`, `Hero_Health` events |

Target status is observable both ways; guard/civilian only through S1.

## 7. Observation-surface comparison

| Strategy | Invasiveness | Identity | Cause | Dedup | Risk |
|---|---|---|---|---|---|
| S2 polling | none (no hook); ≤500 vtable calls/frame, which `WakingUpNpcs` already does in production | ours to derive (entity id + qualifier + runtime id) | none | ours: per-actor edge memory, reset at attempt boundaries; must handle revive and deactivation (an actor leaving `m_activatedActors` is not a death) | `m_bAlive` unproven; dying-vs-dead timing; semantics of `IsPacified` for sedation/sickness |
| S1 event hook | one detour, log-and-continue, read-only; the first hook in the Relay adapter (a policy change: M1 had none by choice, not by rule) | engine-provided (`RepositoryId`, `ActorId`, `ActorName`, `IsTarget`, `ActorType`) | engine-provided classification | presumably one event per occurrence; *unverified* (re-pacify after wake-up? kill of an already-pacified actor?) | timing relative to the state change; whether it fires offline (AdvancedRating implies yes); whether it fires for non-player-caused deaths; a JSON parse in a hook on the game thread (AdvancedRating does it) |
| S3 pin hook | one detour on a very hot path; must filter by pin id | entity ref of the emitter | `DeathContext` pin exists | per pin | emitter unknown; ordering unknown |
| S4 hit hook | one detour | `IBaseCharacter*` | would be the richest, but `SHitInfo` is unmodelled | n/a | nothing readable today |
| S5 stats snapshot | one detour | none | none | n/a | aggregates only |

**Recommendation for the next step (not for the event):** do not choose yet. Run one read-only probe that records S1 and S2 (and S3 filtered) side by side, and choose from the correlation. The archaeology suggests S1 is the only surface with defensible causality and guard/civilian classification, and S2 is the only one with no hook; the probe decides whether S1 is reliable enough to be the primary and S2 its cross-check, or the reverse.

## 8. Weakest defensible vocabulary (proposal, pending the probe)

Names mirror the engine's own words where the engine supplies them and claim nothing it does not:

- `actor.died` — emitted when the engine records a lethal outcome for an actor. Evidence: S1 `Kill` (and/or S2 `IsDead` edge). Not `killed`: the event does not name a killer.
- `actor.pacified` — emitted when the engine records the non-lethal takedown outcome. Evidence: S1 `Pacify` / `EDeathType::eDT_PACIFY` / S2 `IsPacified` rise. The engine's own term; if the probe shows `IsPacified` also covers sedation or sickness, fall back to `actor.incapacitated` with `kind`.
- (only if observed) `actor.recovered` — `IsPacified` fall for a previously pacified actor. Reversibility is real (`ZActor_ReviveActor`, NPC wake-ups), so a summary that counts pacifications must know it.

Fields, each with its evidence:

| Field | Evidence | Claim strength |
|---|---|---|
| `actor.entity_id` (hex64) | `m_nEntityID` | authored; needs qualifier for uniqueness |
| `actor.owner_entity_id` / qualifier | `GetClosestParentWithBlueprintFactory()` | *to be shown useful by the probe* |
| `actor.runtime_id` | `m_nActorRuntimeId` | scene-scoped |
| `actor.repository_id` | S1 `RepositoryId` | character identity, not instance |
| `actor.name` | `m_sActorName` / S1 `ActorName` | label |
| `is_target` | `m_bContractTarget` / S1 `IsTarget` | both observed |
| `actor_type` (`civilian`/`guard`/`hitman`/`unknown`) | S1 `ActorType` only | engine classification |
| `context` (`murder`/`accident`/`hidden`/`not_hero`/`undefined`/`unknown`) | S1 `KillContext` as `EDeathContext` | engine classification, passed through, never upgraded by Relay |
| `accident` | S1 `Accident` | engine flag |
| `method` (`kill_class`, `method_broad`, `method_strict`, `damage_events[]`, `item_repository_id`) | S1 | strings as sent; no Relay taxonomy |
| `source` (`event`/`state`/`both`) | which surface produced it | honesty about provenance |

No field says `killed_by_player`, `eliminated`, or `score`. BEAM may later *derive* "attributed to player" from `context ∈ {murder, accident}` once the probe shows what the client sends for other causes; until then it only records.

## 9. Deduplication

One occurrence → one Relay event, by construction on the native side:

- S1: one envelope per `Kill`/`Pacify` event received; the adapter keeps, per attempt, the set of `(Name, ActorId or entity id)` already published and logs (does not re-publish) any repeat with the same key and lethal class; a `Pacify` followed later by a `Kill` for the same actor is two occurrences and two events.
- S2: per-actor last-state memory keyed by entity pointer + runtime id, edges only, cleared when the mission predicate falls; an actor disappearing from `m_activatedActors` clears its memory without emitting.
- Both surfaces active: S1 publishes; S2 only logs agreement/disagreement during the probe stage. If a later stage makes S2 authoritative, S1 becomes the enrichment, never a second emitter.

## 10. Attempt association

Actor events are published only while `MissionObserver::Playing()` is true (otherwise logged as "outside attempt" and dropped, or — decision for the design — published and classified by BEAM as unattributed). Because every event type shares one monotonic sequence per adapter instance, BEAM attributes each actor event to the attempt that is open at that point of the stream: after the attempt's `mission.playing`, before its `mission.stopped`. No game session id is involved. S1's `ContractSessionId` is recorded as observation and compared with the registry session id for the record only.

## 11. Unknowns static archaeology cannot settle

1. Does `OnEventSent` fire with no server reachable, on this build, in the M0 mod set? (AdvancedRating implies yes.)
2. Timing of `Kill`/`Pacify` relative to `IsDead()/IsPacified()` flipping and to `m_CurrentDyingActors`; whether a *dying* window exists in which neither says dead.
3. Whether `Kill` fires for NPC-on-NPC and scripted deaths, and what `KillContext` says then (`NOT_HERO`?).
4. What `ActorId` is (runtime id? ptr index?), and whether `RepositoryId` is unique among live actors in Paris.
5. Collision rate of `m_nEntityID` among activated actors; whether the blueprint-factory qualifier disambiguates.
6. Whether `IsPacified` is true for sedated / emetic-sick / dragged actors; whether `Pacify` fires on re-pacify after a wake-up; whether a `Kill` on an already pacified actor arrives as `Kill` only.
7. Whether crowd characters (`m_bCrowdCharacter`) produce `Kill` events at all.
8. Whether `m_bAlive` tracks `IsAlive()`.
9. Which entity emits the `Dead`/`Pacified` pins, and in what order relative to S1.
10. Cost of the per-frame S2 scan in a dense scene (Paris, ~300 activated actors) — WakingUpNpcs suggests negligible, unmeasured here.
11. Behaviour across restart: whether per-actor state and runtime ids persist or reset (affects S2 memory reset; S2 memory is reset at the predicate fall regardless).

## 12. Proposed read-only runtime probe (NOT authorized, not built)

**Artifact:** a separate probe mod (`Mods/GlacierRelayActorProbe`, from `relay/m2`), log-only, no wire, no writes, no `GlacierRelay` change. It is a probe in the Hitmen-revival sense: evidence, then discarded or folded into a design. It uses the durable `RelayLog`.

**Observations:**

1. Detour `ZAchievementManagerSimple_OnEventSent` → log `eventIndex` and the full `ZDynamicObject_ToString` JSON for **every** event (not only Kill/Pacify), log-and-continue. (`OnEventReceived` too, to see whether the server answers at all.)
2. Detour `SignalOutputPin` → only when `pinId ∈ {Dead, Death, DeathContext, Pacified, PacifiedData, OnPacified, OnActorPacified, TargetKilled, NonTargetKilled, ActorKillIActor, ActorPacifyIActor}`: log the emitting entity id, its owner chain root, whether it is a `ZActor`, and the data type; continue.
3. Per frame, inside the existing fault guard: for each entry in `m_activatedActors` keep `(ptr, m_nEntityID, owner-root entity id, m_nActorRuntimeId, name, m_bContractTarget, m_bCrowdCharacter, IsAlive(), IsDead(), IsPacified(), m_bAlive, m_bBodyHidden, hitpoints)`; log on any change per actor, with the frame timestamp; also log size changes of `m_aliveActors`, `m_CurrentDyingActors`, `m_SpawnedActors`, and entries entering/leaving `m_activatedActors`. On first mission frame, log a census: count, distinct entity ids, duplicates (with names), distinct runtime ids.
4. The existing scene/predicate lines, so everything aligns with `mission.playing/stopped`.

**Setup:** M0 mod set plus the probe; BEAM not needed. Paris (known actor census from experiment 4: 23 bricks). Script, deliberately small:

| Step | Purpose |
|---|---|
| load Paris, stand still 10 s | census; baseline noise of S2 |
| subdue (non-lethal melee) one non-target guard; wait 15 s | `Pacify` event vs `IsPacified` rise; pins; identity fields |
| drag and hide that body in a container | `BodyHidden`; `m_bBodyHidden`; no spurious state edge |
| kill one non-target civilian with a silenced pistol | `Kill`, `KillContext`, `ActorType=Civilian`, `IsDead` timing, dying window |
| kill a target (Novikov) by any method | `IsTarget`, target-list behaviour, `TargetKilled` pin |
| cause one accident if cheaply available (e.g. push a non-target over a railing); otherwise skip | `Accident`, `KillContext=ACCIDENT` |
| restart | reset behaviour: `ContractStart`, census again, runtime-id reuse |
| exit to menu, quit | clean end |

**Competing outcomes to record:** S1 fires before / after / never relative to the S2 edge; `KillContext` values seen; whether `ActorId == m_nActorRuntimeId`; duplicate entity ids among live actors (count); whether the hidden body changes any state bit; whether S1 fires for the restart's `ContractStart`; whether any event arrives on `OnEventReceived`.

**Abort:** any `FAULT`/`ERROR`, a debugger break in the probe, visible frame hitching after the probe's per-frame scan, or a `Kill`/`Pacify` JSON that fails to parse. Rollback by hash as always.

**Learned:** enough to pick S1-primary/S2-check or S2-primary/S1-enrichment, fix identity fields and their qualifier, fix the names (`pacified` vs `incapacitated`), and write the Stage B design with real payload samples instead of Peacock's schema.

## 13. Proposed staging after the probe (not authorized)

- **B0** — the probe above; one run; findings into this document.
- **B1** — design doc for `actor.died` / `actor.pacified` (`M2_TELEMETRY.md` §14): names, fields with evidence, dedup, attempt association; decision on the first hook in `GlacierRelay` (or S2-only if the probe allows); BEAM `Attempt` gains an ordered list of actor outcomes and the summary gains per-attempt counts by `is_target`/`actor_type`/`context`, each labelled with provenance.
- **B2** — native implementation on `relay/m2` (observer + event structs + adapter overloads, same layering), BEAM validation/model/summary, tests replaying the probe's recorded events; standalone wire test.
- **B3** — controlled run with the same script; pass = every engine occurrence appears exactly once in BEAM with the engine's own classification and nothing stronger.

Later vocabularies (disguise, items, objectives, player state) all have S1 events (`Disguise*`, `ItemPickedUp/Dropped`, `ObjectiveCompleted`, `Hero_Health`), which is one more reason the probe should log the whole stream once.

---

## 14. B0 as authorized (2026-10-06) — probe built, not run

The reviewer accepted the archaeology, reframed the question from "S1 or S2 for kills" to "**is S1 Glacier's usable semantic telemetry boundary for M2**", and authorized B0 with these changes to section 12: S1 logged raw and complete with no schema assumption, no filter, no normalization and **no dedup** (multiplicity is to be measured, not suppressed); S2 reduced to an identity census plus `IsAlive/IsDead/IsPacified` edges (no hit points, body flags or collection sizes); S3 kept, filtered, for emitter and ordering only; the script gains **pacify then kill the same unconscious actor** and drops body hiding; no Relay actor identity is created during the probe — every engine identity is captured side by side and correlated afterwards. BEAM, wire and semantic implementation are out of scope. The output is to be a correlation timeline per controlled occurrence, and the go/no-go for S1 as the preferred M2 surface is: reliable `Kill`/`Pacify` for the controlled actions; enough identity to correlate; classification matching gameplay; understandable multiplicity; works offline on this build; hook inert and cheap.

### Artifact

| Item | Value |
|---|---|
| Source | ZHMModSDK `research/actor-probe-b0` `ebaa0eb4` (from `relay/m2` `bf8908ce`); `Mods/GlacierRelayActorProbe`, registered in `MODS`; `Mods/GlacierRelay` unmodified, its `RelayLog`, `SceneObservation`, `MissionObserver` compiled in by path |
| Binary | `_build/relay-x64-Debug/Mods/GlacierRelayActorProbe/GlacierRelayActorProbe.dll`, SHA-256 `d814c2dfb1934c14f79456d22f07e18a9a44e54df29002a948345cf93c5fe1f3` |
| Detours | `ZAchievementManagerSimple_OnEventSent`, `ZAchievementManagerSimple_OnEventReceived`, `SignalOutputPin` — all log-and-continue, bodies inside the log-only fault guard |
| Per frame | scene state and the M1 predicate (for alignment); `m_activatedActors` scan: new actors identified at ≤50/frame (`m_nEntityID`, closest blueprint-factory owner id, `m_nActorRuntimeId`, `m_sActorName`, `GetActorName()`, entity property `RepositoryId`, `m_bContractTarget`, `m_bCrowdCharacter`) and logged with initial state; thereafter only `IsAlive()/IsDead()/IsPacified()` changes; departures logged as "left the activated list"; census with duplicate entity ids on each predicate rise |
| Pins watched | `Dead`, `Death`, `DeathContext`, `Pacified`, `PacifiedData`, `OnPacified`, `OnActorPacified`, `TargetKilled`, `TargetPacified`, `NonTargetKilled`, `ActorKillIActor`, `ActorPacifyIActor`, `AccidentKill`, `AllTargetsKilled` |
| Imports | `ZHMModSDK.dll` (21 symbols, every one exported by the installed M0 SDK DLL), `KERNEL32`, `USER32`, `SHELL32`, `IMM32`; **no `WS2_32`** |
| Exports | the three SDK plugin exports |
| Engine calls | `IActor::IsAlive/IsDead/IsPacified`, `ZEntityImpl::GetID`, `ZActor::GetActorName` (repository lookup), `ZEntityRef::GetProperty<ZRepositoryID>`, `Functions::ZDynamicObject_ToString`; no setter, no `KillActor`/`ReviveActor`, no `SetProperty` |
| Log | the relay's durable log (`%LOCALAPPDATA%\GlacierRelay\Relay\relay-*.log`); first line says "actor probe" |

Not built from a deleted tree (incremental reconfigure of `_build/relay-x64-Debug`); a clean build is cheap to add before the run if wanted.

### Proposed run (requires its own authorization)

M0 mod set plus the probe only (no `GlacierRelay.dll`, no BEAM). Pre-flight, install (`Retail\mods\GlacierRelayActorProbe.dll` + `[glacierrelayactorprobe]`), VS attach after the menu, rollback and hash verification exactly as in the Stage A run. Paris.

| Step | Action | What to read afterwards |
|---|---|---|
| 1 | load Paris; stand still ~10 s | census line: identified vs activated, duplicate entity ids, targets vs manager target list; S1 `ContractStart` and whatever else the stream sends at start; baseline S2 noise |
| 2 | subdue one non-target guard (non-lethal melee) | S1 `Pacify` raw; S3 pins; S2 `IsPacified` edge; order and gaps between the three |
| 3 | wait ~15 s next to the body | any further S1/S2/S3 activity for the same actor (none expected) |
| 4 | kill that unconscious guard | S1 `Kill` raw for the same actor; whether `ActorId`/`RepositoryId` match step 2; S2 `IsDead` edge; whether `IsPacified` stays true after death |
| 5 | kill one conscious non-target civilian with a silenced pistol | S1 `Kill` with `ActorType = Civilian`, `KillContext`, method fields; S2 edge timing; a *dying* window (IsAlive false before IsDead true?) |
| 6 | kill Novikov by any method | `IsTarget`, `TargetKilled` pin, target-list behaviour |
| 7 | optional: one easy accident on a non-target (skip if not cheap) | `Accident`, `KillContext = ACCIDENT` |
| 8 | restart | `ContractStart` again?; census again; runtime-id reuse; S2 memory reset (actors leave and re-enter) |
| 9 | exit to menu; quit | clean end; `OnEventReceived` count for the whole session |

Abort: any `FAULT`/`ERROR` line, a debugger break in the probe, visible hitching, or a `Kill`/`Pacify` line that is not well-formed JSON (keep the log either way). Deliverable: a per-occurrence timeline (`player action → S1 → S3 → S2`, with offsets) plus the raw S1 corpus and the identity correlation table, written up as section 15.

---

## 15. B0 runtime probe (2026-10-07, 01:48Z to 02:11Z) — PASS; S1 is a semantic telemetry bus

Authorized with the tightened scope of section 14 plus a clean-build gate. Objective: can `ZAchievementManagerSimple::OnEventSent` serve as Glacier Relay's preferred semantic observation surface for M2, with actor outcomes as the controlled case and S2/S3 as correlation instruments.

### Artifact and health

Clean configure/build from a deleted tree (`_build/probe-x64-Debug`, separate from the validated relay tree) of `research/actor-probe-b0` `ebaa0eb4`: `GlacierRelayActorProbe.dll` SHA-256 `215fa976fc0f0bda60f6047a36378ac7a4898091a2a07a4ac257bad37710e4da`; dependencies, the 21 `ZHMModSDK.dll` imports (all exported by the installed M0 SDK), exports and inertness identical to the incremental build; the one build warning is ResourceLib's. Pre-flight as in Stage A (build `24833614`, 26 M0 hashes, 107-file `Retail` baseline identical to the M2 pre-flight, `mods.ini` = M0, repos clean). Two game-directory changes, both reverted; all 107 hashes verified afterwards; no probe, relay or Hitmen file left. Evidence: `%TEMP%\glacier-m0\hitmen\b0-run1\` (native log SHA-256 `85aaba91…5059`, 1972 lines, SDK log, `mods.ini` before/probe/after, listings and hashes, the analysis script and its output).

Runtime: **0 `WARN`/`ERROR`/`FAULT`**, no debugger break, process stable, normal exit. All three detours installed. Frame counter versus wall clock: **115.4 fps** through the whole first attempt (107 279 frames / 930 s) and 113.1 fps in the second, with the per-frame S2 scan of 338 activated actors and the S1 serializer running; no hitching reported by the operator. 204 `OnEventSent` lines, 0 JSON parse failures; 146 `OnEventReceived`; 172 watched pins; 61 state edges; 676 actor identifications (338 per attempt).

### What was done (deviations recorded, not retried)

Step 3 produced three pacified **civilians** (not one guard); step 5 killed one of them (neck snap); step 6 shot a conscious **guard** (not a civilian); step 7 "lots of stuff": seven more kills and three more pacifications including an **explosion** that killed a guard by accident, pacified a civilian and pacified Novikov, who was then shot 23 s later; step 8 therefore needed no separate accident; restart; exit to menu; quit. The deviations improved coverage: civilian and guard, pacify and kill, melee, thrown, pistol, explosion, accident and non-accident, target and non-target, pacified-then-killed twice.

### S1 inventory (whole run, 43 distinct names, 204 events)

`ChallengeCompleted` 22 (all `"_DONTSEND": true`, client-only), `AmbientChanged` 19, `Level_Setup_Events` 12, `ItemPickedUp` 12, `OpportunityEvents` 11, `Investigate_Curious` 11, **`Kill` 10**, `BodyFound` 10, `Spotted` 9, `Unnoticed_Kill` 7, `ItemRemovedFromInventory` 6, `ItemThrown` 6, **`Pacify` 6**, `OpportunityStageEvent` 5, `Unnoticed_Pacified` 5, `DeadBodySeen` 5, `setpieces` 4, `HoldingIllegalWeapon` 4, `Witnesses` 3, `NoticedKill` 3, and 2 each of `HeroSpawn_Location`, `ContractStart`, `StartingSuit`, `IntroCutEnd`, `Trespassing`, `Disguise`, `DisguiseBlown`, `BrokenDisguiseCleared`, `Agility_Start`, `BodyBagged`, **`ContractFailed`**, and 1 each of `SituationContained`, `SecuritySystemRecorder`, `FirstMissedShot`, `FirstNonHeadshot`, `MurderedBodySeen`, `AccidentBodyFound`, `Noticed_Pacified`, **`ObjectiveCompleted`**, `Guard_FoundItem`, `ItemStashed`, `ShotsFired`, `ShotsHit`.

Every sent event (except `ChallengeCompleted`) carries `Name`, `Timestamp` (mission seconds), `ContractSessionId`, `ContractId`, `Value`, `Origin: "gameclient"`, `Id` (GUID), plus user/session ids (not reproduced here). `eventIndex` is a running counter; indices 5, 82, 91, 134, 139, 149, 201 never reached `OnEventSent` (7 of 211) — something is counted that this hook does not see; unknown what.

`OnEventReceived` (server → client): `ChallengeCompleted` 118, `Progression_XPGain` 22, `SegmentClosing` 3, `ContractSessionMarker` 2, `ContractFailed` 1 — all backend acknowledgements, delivered in bursts (at the menu for the previous process's session; at restart; at exit). The backend was reachable throughout; whether `OnEventSent` fires with it unreachable remains untested, but nothing in the sent path waited on it (sent events arrived within the same or next frame as the state change).

### Lifecycle on the stream

- Session start: `HeroSpawn_Location` → `ContractStart` (loadout) → `Level_Setup_Events` → `AmbientChanged` → … → `StartingSuit`, `IntroCutEnd`; a new `ContractSessionId` per attempt (`…628137904204-c00b2d17…`, then `…618691980006-9666b5ad…`).
- **Restart:** the client sent `ContractFailed` with `Value: "Contract ended manually: OnRestartLevel"` 0.3 s **before** the relay predicate fell. **Exit to menu:** `ContractFailed` with `"Contract ended manually: User pressed exit to Main menu"` in the **same frame** as the fall. The restart/exit distinction Stage A could not derive is stated by the engine, as a reason string.
- **Quit from inside a mission** (Stage A's Sapienza): nothing sent (process terminated); on the next launch the backend returned `ContractFailed {FailType: "OrphanedSession"}` and `SegmentClosing {CloseType: "ContractFailed:OrphanedSession"}` for `ContractSessionId 2516109693561278430-4afc9528…` — **exactly the `game_session_id` Stage A carried on `mission.playing #5`.** The registry session id is the backend's `ContractSessionId`.
- Objectives: `ObjectiveCompleted {Id, Type: "kill", Category: "primary", ExcludeFromScoring}` on the Novikov kill.

### Kill / Pacify payloads versus Peacock

All 16 events parsed; **the observed key set equals Peacock's 33-field schema exactly** — nothing missing, nothing extra. `KillItemRepositoryId/InstanceId/Category` and `IsReplicated` are present only on some events. Numeric fields arrive as floats (`"ActorId":195054661.000000`). Value sets observed: `KillType` ∈ {3 pacify, 4 kill, 5 bloody kill} — this is `EDeathType`, not `EKillType`; `KillContext` ∈ {3 accident, 4 murder} — `EDeathContext`; `KillClass` ∈ {melee, ballistic, explosion}; `KillMethodBroad` ∈ {unarmed, throw, pistol, melee_lethal, accident, explosive}; `KillMethodStrict` ∈ {"", accident_explosion}; `DamageEvents` ∈ {Subdue, CloseCombat, DeadlyThrow, CoupDeGrace, Shoot}; `ActorType` ∈ {0 civilian, 1 guard}; `PlayerId` ∈ {0, 4294967295}; `History` holds prior damage entries (1 on the coup de grâce, 3 on Novikov's kill after the explosion).

| # | Event | Actor | Type | Target | KillType | Context | Class | Accident | DamageEvents | MethodBroad |
|---|---|---|---|---|---|---|---|---|---|---|
| 34 | Pacify | Mark Parker | civ | no | 3 | 4 | melee | no | CloseCombat | melee_lethal |
| 39 | Pacify | Adèle Rousseau | civ | no | 3 | 4 | melee | no | DeadlyThrow | throw |
| 42 | Pacify | Jacqueline Ducloitre | civ | no | 3 | 4 | melee | no | Subdue | unarmed |
| 55 | **Kill** | Jacqueline Ducloitre | civ | no | 4 | 4 | melee | no | CoupDeGrace | unarmed |
| 67 | Kill | Philippe Quiron | guard | no | 5 | 4 | ballistic | no | Shoot (silenced, headshot) | pistol |
| 93 | Kill | Satordi Roux | civ | no | 4 | 4 | ballistic | no | Shoot | pistol |
| 99 | Kill | Félicien Bourque | civ | no | 5 | 4 | ballistic | no | Shoot | pistol |
| 107 | Kill | Olivier Lauzier | civ | no | 5 | 4 | melee | no | CloseCombat | melee_lethal |
| 111 | Pacify | Auguste Marcheterre | civ | no | 3 | 4 | melee | no | DeadlyThrow | throw |
| 117 | Kill | Justin Mills | civ | no | 5 | 4 | melee | no | DeadlyThrow | throw |
| 131 | Kill | Kurt Donovan | guard | no | 4 | **3** | explosion | **yes** | Shoot | accident / accident_explosion |
| 132 | Pacify | André Furchard | civ | no | 3 | **3** | explosion | **yes** | Shoot | accident / accident_explosion |
| 134 | Pacify | Viktor Novikov | civ | **yes** | 3 | 4 | explosion | no | Shoot | explosive |
| 156 | **Kill** | Viktor Novikov | civ | **yes** | 4 | 4 | ballistic | no | Shoot | pistol |
| 163 | Kill | Olivier Assis | civ | no | 5 | 4 | ballistic | no | Shoot | pistol |
| 168 | Kill | Sibyla Auger | civ | no | 5 | 4 | ballistic | no | Shoot | pistol |

The same explosion was classified `ACCIDENT` for the two non-targets and `MURDER`/`explosive` for the target. Recorded; not interpreted.

### Timelines (S3 pin group → S2 edge → S1 event; offsets relative to S1)

| Occurrence | pins | S2 edge | S2 transition |
|---|---|---|---|
| Pacify Parker | −134 ms | −124 ms | alive T→F, dead F→**T**, pacified F→T |
| Pacify Rousseau | −150 | −140 | same |
| Pacify Ducloitre | −11 | −1 | same |
| **Kill Ducloitre (pacified)** | −9 | −2 | alive F→F, dead T→T, **pacified T→F** |
| Kill Quiron (conscious) | −10 | −2 | alive T→F, dead F→T, pacified F→F |
| Kill Roux | −349 | −341 | same |
| Kill Bourque / Lauzier / Auger | −9 … −12 | −1 … −2 | same |
| Pacify Marcheterre | −121 | −111 | pacify pattern |
| Kill Mills | −59 | −51 | kill pattern |
| explosion: Kill Donovan / Pacify Furchard / Pacify Novikov | −100 / −437 / −641 | −135 / −441 / −625 | one pin group (26 pins) for three victims; S1 events queued over 0.5 s |
| **Kill Novikov (pacified)** | −14 | −4 | alive F→F, dead T→T, pacified T→F |
| Kill Assis | −169 | −157 | kill pattern |

Order was **S3 → S2 → S1 in every case** (pins in frame N, the actor's state in frame N+1, the event 1 ms to 640 ms later), never S1 first. No "dying" window was visible at frame granularity.

### Pacify → Kill of the same actor (twice: Ducloitre, Novikov)

Both S1 events exist; `RepositoryId`, `ActorName` and **`ActorId` are identical** across the pair (195054661; 1171052055); the Kill carries the pacifying hit in `History`; S2 shows `IsDead` already true from the pacification and only `IsPacified` falling on the kill; S3 emits `PacifiedData` on the pacification and not on the kill.

### Identity correlation

For all 16 Kill/Pacify events the S1 `RepositoryId` matched the S2 `RepositoryId` **entity property** of exactly one identified actor, whose `GetActorName()` matched `ActorName` (the native `m_sActorName` carries mangled UTF-8 for accented names; the repository name is correct). **`ActorId` is neither the runtime id nor the low 32 bits of the entity id**, and it is **not** a per-actor constant across event types: the same NPC had different `ActorId`s in `Investigate_Curious` and `Pacify`, and in `Kill` and `BodyBagged`. It was constant only across `Pacify`→`Kill`. Its derivation is unknown; it must not be used as actor identity. `RepositoryId` was the consistent cross-event key in this run, with the known caveat (308 distinct among 338 actors: 30 generic NPCs share a character).

Census at first entry: 338 activated, **338 distinct authored entity ids** (no duplicates, so the blueprint-owner qualifier was not needed in Paris; all 338 share owner `006d465c6f70c066`, the mission brick), 338 distinct runtime ids, 2 targets by `m_bContractTarget` (the manager's `m_aTargetList` was empty both times — it is not the target source), 32 crowd. **Restart:** all 338 left the activated list and 338 were re-identified; the 306 non-crowd actors seen in both attempts had **identical entity id and runtime id** (Novikov: `28aab529a006ecb1`, runtime 86, both times). The scene rebuild is deterministic for identity.

### S2 semantics (correlation instrument)

- `IsAlive()` false does not mean dead: 76 actors were identified with `alive false, dead false` (not yet enabled), and the 42 `John/Jane Doe` crowd edges are activation churn. `IsAlive` alone is not usable.
- **`IsDead()` is "down", not "dead": it went true on every pacification.** `IsPacified()` is the discriminator. Death clears `IsPacified`.
- `IsDead` is not sticky either: it returned to false for two bodies when they were **bagged** (`BodyBagged` events for exactly those two) and for one pacified actor who was **revived** (`alive F→T, dead T→F, pacified T→F`, 13 minutes after the explosion — the recovery case is real and observed).
- An actor leaving the activated list happened only at the restart (338) — never for a death.

### S3 (ordering instrument)

172 pins in 16 groups, one group per occurrence (9–12 pins; 26 for the three-victim explosion), all from a fixed set of **seven non-actor logic entities** (two emit `Dead`/`DeathContext`/`PacifiedData`, five emit `Death`), plus `OnPacified` from one of sixteen other entities per pacification (owned by the mission brick or `003a5474312d63cd`). **No pin was emitted by the actor.** The pins carry order (one frame before the state edge) and a lethal/non-lethal distinction (`PacifiedData` present only for pacifications, including the target's); they carry no identity the probe could read without decoding payloads.

### Multiplicity

`Kill` and `Pacify`: exactly one per occurrence per actor (16 events, 16 occurrences). Repeats exist in the *follow-up* vocabulary and are per observer, not per fact: `BodyFound` 1–3 per body (Novikov 3, Auger 3), `DeadBodySeen` 5, `Spotted` 9 (including a doubled line with and without `XboxGameMode` fields), `Witnesses` 3, `Noticed/Unnoticed_*` one per outcome. Nothing in the run needed deduplication to count outcomes; follow-ups would need an explicit policy.

### Answers

**A. Is S1 reliable enough to be the primary actor-outcome source?** Yes, on this evidence. 16 controlled outcomes produced exactly 16 `Kill`/`Pacify` events, each within one frame to 0.6 s of the state change, each with engine-classified type, context, class, method, item, target flag and actor type, each correlating to exactly one actor by `RepositoryId`+`ActorName`, with a complete and Peacock-identical schema, no parse failure, no fault, no measurable frame cost. Unknowns that remain: behaviour with the backend unreachable; NPC-on-NPC and scripted deaths (none occurred); crowd-character deaths (one `MurderedBodySeen` with `IsCrowdActor: true` and a null repository id hints they are reported differently).

**B. Does S2 agree strongly enough to serve as validation/fallback, and what does it add?** It agreed 16/16 on *that* something happened and on lethal vs non-lethal (via `IsPacified`), one frame before S1. It adds: the pointer-level identity (authored entity id, runtime id, repository property) that lets a `RepositoryId` be resolved to a specific live actor even where repository ids are shared; the **recovery** and **body-bagged** transitions, which S1 reports only indirectly (`BodyBagged`) or not at all (the revive had no S1 event); and a fallback if S1 ever stops. It cannot by itself say dead vs pacified without `IsPacified`, and cannot say why.

**C. Does S3 add semantic information or only ordering/correlation?** Ordering, a frame earlier than S2, plus one bit (`PacifiedData`). Nothing identifying. Not worth a hook on its own.

**D. Does the complete S1 corpus justify treating the achievement-manager stream as a candidate general M2 semantic telemetry boundary?** Yes. In one 22-minute session the stream covered, with engine-authored semantics: mission lifecycle (`ContractStart`, `ContractFailed` **with the restart/exit reason**, `IntroCutEnd`, `HeroSpawn_Location`, and the orphaned-session resolution from the backend), kills/pacifications with cause and classification, objectives (`ObjectiveCompleted`), disguises (`Disguise`, `DisguiseBlown`, `BrokenDisguiseCleared`, `StartingSuit`), items (`ItemPickedUp/Dropped/Thrown/RemovedFromInventory/Stashed`, `HoldingIllegalWeapon`), body handling and discovery (`BodyFound`, `BodyBagged`, `BodyHidden` known, `DeadBodySeen`, `MurderedBodySeen`, `Noticed/Unnoticed_*`), detection and tension (`Spotted`, `Witnesses`, `Trespassing`, `AmbientChanged`, `Investigate_Curious`, `SituationContained`, `SecuritySystemRecorder`), opportunities and level script (`OpportunityEvents`, `OpportunityStageEvent`, `Level_Setup_Events`, `setpieces`), and player action stats (`ShotsFired/Hit`, `FirstMissedShot`, `Agility_Start`). That is every vocabulary the M2 roadmap names except player health (`Hero_Health` exists in Peacock's list and did not occur here because 47 was never hurt). The stream is the game's own semantic interpretation, already versioned by the backend contract, already keyed by a session id that the backend and the registry agree on.

### Implications (recommendation, not a decision)

1. The next architecture step is an ADR, not an actor event: *Glacier-authored telemetry (`OnEventSent`) is the preferred M2 observation surface where it covers a fact; direct state observation validates it, supplements it (identity resolution, recovery, bagging), and covers what the stream lacks.* The M1 predicate stays as the hook-free lifecycle backbone and the thing that bounds attempts; the stream's `ContractStart`/`ContractFailed` become evidence attached to those attempts, not a replacement.
2. Relay normalization should sit on the stream: pass the engine's `Name` and classification through as observations (`game.event` with the engine's `Name`, `ContractSessionId` observational, `Value` validated per name/schema version on the BEAM side), and derive the M2 summary from that, rather than building one native observer per vocabulary.
3. Actor identity for Relay: `RepositoryId` + `ActorName` from the stream, resolved to the authored entity id by the S2 census when a specific body matters; never `ActorId`.
4. Dedup policy is needed only for the observer-relative follow-ups, and only when a summary wants to count them.
5. Open before any implementation: offline behaviour of `OnEventSent`; the 7 unseen event indices; crowd deaths; NPC-caused deaths; `Hero_Health`/player death; whether `_DONTSEND` events should cross the Relay boundary at all.

Nothing was implemented after the run. `GlacierRelay`, `relay/` and `relay/m2` are unchanged.

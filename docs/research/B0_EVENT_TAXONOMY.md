# Event Taxonomy — the `OnEventSent` corpus, classified (B0 payloads, B1 names)

**This taxonomy is not exhaustive.** It lists what two Paris sessions on one build happened to emit. Section "Observed in B1" records which names recurred in the B1 production run (names only; B1 logs no payloads), which were new, and which B0 names did not recur. Any name absent here is simply unobserved, and any name present here may have shapes not yet seen.

Date: 2026-10-07. Dataset: the B0 native log (`%TEMP%\glacier-m0\hitmen\b0-run1\relay-20261007-014849-93996.log`, SHA-256 `85aaba91…5059`): 204 sent events, 43 names, one Paris session with a restart (`ACTOR_OUTCOME_ARCHAEOLOGY.md` section 15). Shapes below are what the client emitted on `3.280.0.0`; user and platform session identifiers are omitted. "Suitable" means *a plausible candidate for Relay normalization*, not a decision. Confidence is about the shape and meaning on this build; "needs evidence" lists what another run would have to show before the event is normalized.

Common envelope on every sent event except the client-only ones: `Name`, `Timestamp` (seconds since contract start), `ContractSessionId`, `ContractId`, `Value`, `Origin: "gameclient"`, `Id` (GUID), plus user/session ids. Some events additionally carry `XboxGameMode` and `XboxDifficulty` (a second emitter path; see `Spotted`).

## Contract / mission lifecycle

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `ContractStart` | 2 | `{Loadout: [{RepositoryId, InstanceId, OnlineTraits[], Category}], Disguise, LocationId, GameChangers[], ContractType, DifficultyLevel, IsVR, IsHitmanSuit, SelectedCharacterId}` | yes (as attempt enrichment first) | high: loadout, location, difficulty, contract type at attempt start | high | contracts/escalations/Freelancer shapes |
| `ContractFailed` | 2 | `str` reason: `"Contract ended manually: OnRestartLevel"`, `"…User pressed exit to Main menu"` | yes (as attempt enrichment first) | **high**: states restart vs exit, which Stage A could not derive | high for these two reasons | other reasons (player death — unobserved); on completion the engine emitted **`ContractEnd`, not `ContractFailed`** (section 44, by name only; payload unknown; B2 follow-up in section 46.9) |
| `HeroSpawn_Location` | 2 | `{RepositoryId}` | later | medium: starting location | high | — |
| `IntroCutEnd` | 2 | `""` | later | low–medium: "player has control" marker | medium | whether it fires without an intro |
| `StartingSuit` | 2 | `str` (outfit repository id) | later (disguise domain) | medium | high | — |
| `Level_Setup_Events` | 12 | `{Contract_Name_metricvalue, Location_MetricValue, Event_metricvalue}` | no (mission-script metrics) | low | high | — |

Expected on the stream per prior art: `ContractEnd` (**seen by name once, section 44, on the completion transition; payload never captured**), `ContractLoad` and `Hero_Dead` (never captured by name). A completed mission has been run once (section 44); a player death has not.

## Actor outcomes

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `Kill` | 10 | 33 fields: `RepositoryId, ActorId, ActorName, ActorType, KillType, KillContext, KillClass, Accident, WeaponSilenced, Explosive, ExplosionType, Projectile, Sniper, IsHeadshot, IsTarget, ThroughWall, BodyPartId, TotalDamage, IsMoving, RoomId, ActorPosition, HeroPosition, DamageEvents[], PlayerId, OutfitRepositoryId, OutfitIsHitmanSuit, [KillItemRepositoryId, KillItemInstanceId, KillItemCategory], KillMethodBroad, KillMethodStrict, EvergreenRarity, [IsReplicated], History[]` | **yes** | **high** | high (16/16 correlated) | NPC-caused and scripted deaths; crowd deaths (`IsCrowdActor`); offline |
| `Pacify` | 6 | same 33 fields (`KillType 3`) | **yes** | **high** | high | re-pacify after recovery; sedation/emetic |
| `BodyBagged` | 2 | `{ActorId, RepositoryId, ActorName}` | later | medium: body handling; explains `IsDead` → false | high | — |
| `Unnoticed_Kill` / `Unnoticed_Pacified` / `NoticedKill` / `Noticed_Pacified` | 7 / 5 / 3 / 1 | `{RepositoryId, IsTarget}` | later (one per outcome, ~3 s after it) | medium: stealth classification of each outcome | high | — |

## Player state

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `Trespassing` | 2 | `{IsTrespassing: bool, RoomId: number}` (one `true`, one `false`); names only: B1 2, B3 6, section 34 3, section 36 3, section 40 1, section 44 8 — all inside the attempt; **engine field types unknown** | **yes** (B6 design, `M2_TELEMETRY.md` section 46: `player.trespassing` v1 proposed, awaiting review) | medium | high (shape, two samples) / none (types) | what `RoomId` identifies; the escalation the SDK's trespass situation models |
| `HoldingIllegalWeapon` | 4 | `{IsHoldingIllegalWeapon, WeaponEquipped: {IsPerceivedAsWeapon, …item shape with a non-empty InstanceId…}}` (one object, not an array; corrected in section 38); the `false` form carries no `WeaponEquipped`; names only: B1 6, B3 9, section 34 2, section 36 2, section 40 7, section 44 22 — all inside the attempt; **engine field types unknown** | **yes** (B6 design, `M2_TELEMETRY.md` section 46: `player.illegal_weapon` v1 proposed, awaiting review) | medium | high | — |
| `Agility_Start` | 2 | `""` | no | low | medium | — |
| `Hero_Health` | 0 | **payload unknown**; by name only in B3 (section 32): 5 occurrences during unscripted combat and in the 1.1 s before a quit from inside the mission; 0 in every other run | research candidate (B6, section 46.8: bounded shape diagnostic before any row) | high when observed | none | its keys and the scale of its value (not assumed 0–100); a run in which 47 is hurt |
| `Hero_Dead` | 0 | prior art only; **never captured by name** in any run | research candidate (B6, section 46.8) | high when observed | none | whether it exists on `OnEventSent`; the death-transition chronology; a run in which 47 dies |

## Disguise

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `Disguise` | 2 | `str` (outfit repository id) in the B0 JSON; **engine type `ZRepositoryID`** (sections 34–36) | **yes — normalized (B3 accepted, section 37)** | high | high | outfit name resolution (repository lookup, as `GetActorName` does) — not proposed |
| `DisguiseBlown` | 2 | `str` (outfit) in JSON; engine `ZRepositoryID` | yes — normalized (B3) | high | high | — |
| `BrokenDisguiseCleared` | 2 | `str` (outfit) in JSON; engine `ZRepositoryID` | yes — normalized (B3) | medium | high | which outfit it names at a change (section 36: the newly equipped one, once) |
| `StartingSuit` | 2 | `str` in JSON; engine `ZRepositoryID` | yes — normalized (B3) | medium | high | — |

## Item / inventory

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `ItemPickedUp` | 12 | `{InstanceId: "" (12/12), ItemType: str, ItemName: str, RepositoryId: str, OnlineTraits: [str], Category: null (12/12), ActionRewardType: "AR_None" (12/12)}` — JSON rendering; **engine field types unknown** | **yes** — `item.picked_up` v1 implemented (section 39, SDK `12ea5586`), runtime-validated in section 40 (7/7 live occurrences normalized, incl. a loadout pistol published without an instance identifier) and **accepted (section 41)** | high | high (shape) / none (types) | `ItemType` can be `"Unrecognized Item type"` (crowbar) — name/traits still present; `InstanceId` empty in all 12 sampled; 7 distinct definitions |
| `ItemRemovedFromInventory` | 6 | same JSON shape; **6/6 share the identical `Timestamp` with an `ItemThrown`** of the same id, emitted first (an observation on this build, not a rule; B1 2 and B3 3 agree by count and index order only) | yes — `item.removed_from_inventory` v1 implemented (section 39), runtime-validated in section 40 (2/2), published independently; **accepted (section 41)** | medium | high | a removal without an adjacent thrown — **observed once in section 44** (sniper rifle, index-adjacent to a pickup; operator: shot the security system) after 11/11 with a throw beside it |
| `ItemThrown` | 6 | same JSON shape; beside a removal in 6/6 B0 | yes — `item.thrown` v1 implemented (section 39), runtime-validated in section 40 (2/2; both beside a removal, identical `Timestamp`), counted directly; **accepted (section 41)** | medium | high | — |
| `ItemDropped` | 0 (B0); names only: B3 7, section 36 3, section 40 0, section 44 12 | **never captured with a payload**; precedes a locker/suit `Disguise` by ≈250 ms in 5/7 changes (0/2 when nothing was held, section 34) | research candidate — no production row (unsupported, counted by name in section 39's build) until its payload and subject are evidenced (section 38.9 diagnostic) | medium | none | its payload and subject (observation-only diagnostic) |
| `ItemDestroyed` | 0 (B0); names only: B3 1 | **never captured with a payload**; once, in unscripted combat | research candidate — no production row | low | none | its payload and cause (not producible on demand) |
| `ItemStashed`, `Guard_FoundItem` | 1 / 1 | `{ActorId, RepositoryId, ActorName, ItemId, ItemTypeId}` (the NPC who stashed/found) | later | low–medium | medium | — |

## Objectives / challenges

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `ObjectiveCompleted` | 1 | `{Id, Type: "kill", Category: "primary", ExcludeFromScoring}` — Name-first envelope variant (`XboxGameMode`/`XboxDifficulty`); 13 ms after the Novikov `Kill`; `Id` differs from the specific actor, item, contract, session and event ids compared in that sample (namespace not established; opaque); **engine field types unknown** | **yes** — `objective.completed` v1 implemented (section 43, SDK `97946eb1`; ungated, BEAM attribution fixed at receipt), runtime-validated for the observed shape in section 44 (2/2 live occurrences, ids `aca8cd5b…` — a match with B0 across two observations — and `9da41883…`, both `kill`/`primary`/`false`) and **accepted (section 45)** | **high** | high for this shape (one sample) / none (types) | other objective types and categories; the completion transition (never captured); `ObjectiveFailed`-like events (never captured); stability of `Id` across sessions |
| `ChallengeCompleted` (client) | 22 | `{ChallengeId, ChallengeName, ChallengeTags[], ChallengeDrops[], ChallengeDescription, ChallengeImageUrl, XPGain, IsRepeated}`; top-level `_DONTSEND: true`; **no** `ContractSessionId`/`ContractId` | **no by default** (see policy) | low–medium | high | — |
| `OpportunityEvents` | 11 | `{RepositoryId, Event: Triggered\|Failed\|…}` | later | medium (mission stories) | medium | event vocabulary |
| `OpportunityStageEvent` | 5 | `{RepositoryId, Event: StageActive\|StageInactive, OpportunityStageID}` | later | medium | medium | — |

## Detection / witness / body

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `Spotted` | 9 | `[RepositoryId]` of the spotter; **emitted twice per occurrence** (with/without `XboxGameMode`) | later, with an explicit pairing policy | medium | high | — |
| `Witnesses` | 3 | `[RepositoryId]` (carries `XboxGameMode`) | later | medium | medium | — |
| `BodyFound` | 10 | `{DeadBody: {RepositoryId, IsCrowdActor, DeathContext, DeathType}}`; 1–3 per body (per discoverer) | later | medium | high | — |
| `AccidentBodyFound` | 1 | same shape, `DeathContext 3` | later | medium | medium | — |
| `DeadBodySeen` | 5 | `str` (body repository id) | later | low–medium | high | — |
| `MurderedBodySeen` | 1 | `{Witness, IsWitnessTarget, DeadBody{RepositoryId, IsCrowdActor}}` (crowd body had a null repository id) | later | medium | medium | crowd actor identity |
| `Investigate_Curious` | 11 | `{ActorId, RepositoryId, SituationType, EventType, JoinReason, InvestigationType}` | no (AI situation detail) | low | medium | — |
| `SituationContained` | 1 | `""` | later | low–medium | medium | — |
| `SecuritySystemRecorder` | 1 | `{event: destroyed\|spotted, recorder}` (B0 payload: `{event: "destroyed", recorder: 2956087656}`); by name in B1 1, B3 1, section 44 1 | later (rating; outside B6) | medium (SA rating) | high (AdvancedRating uses it) | — |
| `AmbientChanged` | 19 | `{PreviousAmbientValue, AmbientValue, PreviousAmbient, Ambient}` (`EGameTension` names) | later | medium: alert level timeline | high | — |

## Combat

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `ShotsFired`, `ShotsHit` | 1 / 1 | `{Split: {instanceId: n}, Total}`; sent once at contract end | later (end-of-attempt totals) | medium | high | — |
| `FirstMissedShot`, `FirstNonHeadshot` | 1 / 1 | `""` | no | low (challenge triggers) | medium | — |

## Environment / setpiece / opportunity

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `setpieces` | 4 | `{RepositoryId, name_metricvalue, setpieceHelper_metricvalue, setpieceType_metricvalue (Enter_Closet/Exit_Closet/…), toolUsed_metricvalue, Item_triggered_metricvalue, Position}`; `Position` is an `SVector3` the engine's own `ToString` cannot render | later | low–medium | medium | a proper reader for `SVector3` if the position is wanted |

## Observed in B1 (2026-10-07 production run, `telemetry_log = names`)

Dataset: the B1 native log (`%TEMP%\glacier-m0\hitmen\b1-run1\relay-20261007-035647-91292.log`, SHA-256 `3ff9a9ab…0d8f`, `M2_TELEMETRY.md` section 26): 159 `OnEventSent` deliveries, 42 names, one Paris session with a restart and an exit to menu. B1 recorded names and the intake decision only; payload shapes come from B0.

| | Names |
|---|---|
| Seen in both B0 and B1 (38) | `AccidentBodyFound`, `AmbientChanged`, `BodyBagged`, `BodyFound`, `BrokenDisguiseCleared`, `ChallengeCompleted` (`_DONTSEND`, 22 → 23), `ContractFailed` (2 → 2), `ContractStart` (2 → 2), `DeadBodySeen`, `Disguise`, `DisguiseBlown`, `FirstMissedShot`, `HeroSpawn_Location`, `HoldingIllegalWeapon`, `IntroCutEnd`, `Investigate_Curious`, `ItemPickedUp`, `ItemRemovedFromInventory`, `ItemThrown`, `Kill` (10 → 10), `Level_Setup_Events`, `MurderedBodySeen`, `NoticedKill`, `ObjectiveCompleted`, `OpportunityEvents`, `OpportunityStageEvent`, `Pacify` (6 → 2), `SecuritySystemRecorder`, `setpieces`, `ShotsFired`, `ShotsHit`, `SituationContained`, `Spotted`, `StartingSuit`, `Trespassing`, `Unnoticed_Kill`, `Unnoticed_Pacified`, `Witnesses` |
| **New in B1 (4)** | `EvidenceHidden` (2), `BodyHidden` (2), `AllBodiesHidden` (2), `AllPacifiedHidden` (1; again by name in section 44, never with a payload) — body-handling notifications emitted when the operator hid bodies (a `BodyHidden`/`EvidenceHidden` pair per hidden body, then `AllBodiesHidden`/`AllPacifiedHidden` when no unhidden body of that kind remained). Payload shape unknown (names only). Category: detection / witness / body. Suitability: later, with the other body events. |
| Seen first in section 44, by name only | `BeingFrisked` (1), `FriskedSuccess` (2), `exit_gate` (1), `ExitInventory` (1), `ContractEnd` (1) — frisk and completion-transition names; no payloads. |
| Seen in B0 only (5) | `Agility_Start`, `FirstNonHeadshot`, `Guard_FoundItem`, `ItemStashed`, `Noticed_Pacified` — absent from B1 because the actions that trigger them were not performed; not evidence of removal. |

B1 intake decisions: 12 captured (`Kill`, `Pacify`), 124 unsupported, 23 `dont_send` (all `ChallengeCompleted`), 0 unreadable, 0 truncated. Nothing with `_DONTSEND` appeared on any other name.

## Observed in B2 (2026-10-08 production run, `telemetry_log = names`)

Dataset: the B2 native log (`%TEMP%\glacier-m0\hitmen\b2-run1\relay-20261008-192015-85348.log`, SHA-256 `fc043698…6490`, `M2_TELEMETRY.md` section 29): 41 `OnEventSent` deliveries, 9 names, three Paris sessions (fresh load, restart, exit to menu, fresh load, direct quit) in which the operator performed no gameplay action. **No new name.** Seen: `Level_Setup_Events` 15, `OpportunityStageEvent` 6, `StartingSuit` 3, `OpportunityEvents` 3, `IntroCutEnd` 3, `HeroSpawn_Location` 3, `AmbientChanged` 3, `ContractStart` 3 (captured), `ContractFailed` 2 (captured). 0 `_DONTSEND`. Engine indices 5, 20, 31, 36 never reached the hook (41 of 45). A direct quit from inside the third session emitted nothing at the hook before the process ended (section 29).

### Observation: disguise events (B3 archaeology, `M2_TELEMETRY.md` section 30)

`StartingSuit`, `Disguise`, `DisguiseBlown` and `BrokenDisguiseCleared` share one shape — `Value` is a non-empty string holding an outfit **definition** repository id — with one emission per occurrence and no `XboxGameMode` twin. `StartingSuit` is emitted in the same frame as `IntroCutEnd`, 2 to 30 s after the predicate rise (contract clock 2.28 s / 13.01 s in B0), restating `ContractStart.Disguise`; it is not at contract clock 0. `DisguiseBlown` carries the id most recently stated by `Disguise` and shares its `Timestamp` with a `Spotted`; `BrokenDisguiseCleared` carries the same id and, in all three observed instances (B0 ×2, B1 ×1 by name), followed the `Kill` of the last actor named in `Witnesses` by 9 to 222 ms — pacifying those actors did not clear it. `Kill`/`Pacify` `OutfitRepositoryId` agreed with the latest `Disguise` value in 16/16 B0 outcomes. No readable outfit name appears anywhere in the stream.

**B3 runtime (2026-10-08, `M2_TELEMETRY.md` section 32):** on the production typed intake, the copied `Value` of all four names failed the String requirement (9/9 captured occurrences rejected as `Value is not a string`); the string shape above is the B0 probe's `ZDynamicObject_ToString` JSON rendering, not the engine type. The type-discovery experiment (section 34, 2026-10-09) read the copied kind as `Unsupported` with engine type **`ZRepositoryID`** for all four names (6/6 samples). New names observed (production, names only): `ItemDropped` (7), `ItemDestroyed` (1), `Hero_Health` (5).

**B3 correction and acceptance (2026-10-09, `M2_TELEMETRY.md` sections 35–37):** the intake renders the exact reflection type `ZRepositoryID` as the dashed lowercase id; the controlled run of section 36 captured, normalized and published all four names (5 occurrences, 2 outfit definitions) with the ids equal to this corpus's strings for the same outfits, the `StartingSuit` id equal to the live `ContractStart.Disguise`, and — new chronology with ids — a `BrokenDisguiseCleared` at an outfit change naming the **newly equipped** outfit (`874c4c48…`), 26 ms after the `Disguise`. B3 is accepted for that bounded scope on this build; persistence, witness clearing and the ids of section 34's change-time pair remain unobserved. **Lesson recorded for every later vocabulary:** a JSON string in this corpus does not establish an engine `ZString`; field types are established only by the typed intake at runtime.

### Observation: `eventIndex` is not contiguous

The `eventIndex` argument of `OnEventSent` skipped 9 values in B1's first attempt (5, 20, 21, 106, 119, 130, 131, 143, 144 of 1..154) and value 5 in B0; the intake's `seen` counter equals the number of indices actually delivered (154 − 9 = 145), so the hook lost nothing: the engine advances its index on paths that never call `OnEventSent`. **`eventIndex` is not a Relay continuity or loss signal.** It is kept on the raw observation for log correlation only. Relay's own envelope `sequence` is the continuity mechanism for normalized Relay events, and BEAM's gap detection is computed from it alone.

### Observation: emission time versus occurrence time

Four explosion `Kill` events in B1 carried `Timestamp` values spanning about 50 ms while their `OnEventSent` deliveries spanned about 1.7 s of wall time (`M2_TELEMETRY.md` section 26, finding 6). `Timestamp` is Glacier's occurrence-time evidence on the contract clock; the time the hook sees an event is emission time. Both are preserved on the wire (`engine_timestamp_s`, envelope `timestamp`); no ordering policy is derived yet.

## Internal / client-only

| Name | Count | Note |
|---|---|---|
| `ChallengeCompleted` with `_DONTSEND: true` | 22 (10 distinct challenge ids) | all 10 ids later arrived from the backend as authoritative `ChallengeCompleted` over `OnEventReceived` |

## Unknown / uncertain

- Seven `eventIndex` values (5, 82, 91, 134, 139, 149, 201) were counted by the manager but never reached `OnEventSent`. Unknown what they were.
- `ActorId`: present on actor-related events, not derivable from runtime id or entity id, constant across `Pacify`→`Kill` but not across other event types for the same NPC. Not an identity.
- `PlayerId`: 0 or 4294967295 with no obvious rule.
- `IsReplicated`: present on some `Kill`/`Pacify` only.

## Received (server → client), for completeness

`ChallengeCompleted` 118, `Progression_XPGain` 22, `SegmentClosing` 3, `ContractSessionMarker` 2, `ContractFailed` 1 (`{FailType: "OrphanedSession"}` for the Stage A Sapienza session). These are backend acknowledgements, `Origin: "ContractSessionService"`, with a `Version {8.25.0.95}`. Not a Relay input; evidence that the client was online throughout B0.

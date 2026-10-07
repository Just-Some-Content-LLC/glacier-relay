# B0 Event Taxonomy — the `OnEventSent` corpus, classified

Date: 2026-10-07. Dataset: the B0 native log (`%TEMP%\glacier-m0\hitmen\b0-run1\relay-20261007-014849-93996.log`, SHA-256 `85aaba91…5059`): 204 sent events, 43 names, one Paris session with a restart (`ACTOR_OUTCOME_ARCHAEOLOGY.md` section 15). Shapes below are what the client emitted on `3.280.0.0`; user and platform session identifiers are omitted. "Suitable" means *a plausible candidate for Relay normalization*, not a decision. Confidence is about the shape and meaning on this build; "needs evidence" lists what another run would have to show before the event is normalized.

Common envelope on every sent event except the client-only ones: `Name`, `Timestamp` (seconds since contract start), `ContractSessionId`, `ContractId`, `Value`, `Origin: "gameclient"`, `Id` (GUID), plus user/session ids. Some events additionally carry `XboxGameMode` and `XboxDifficulty` (a second emitter path; see `Spotted`).

## Contract / mission lifecycle

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `ContractStart` | 2 | `{Loadout: [{RepositoryId, InstanceId, OnlineTraits[], Category}], Disguise, LocationId, GameChangers[], ContractType, DifficultyLevel, IsVR, IsHitmanSuit, SelectedCharacterId}` | yes (as attempt enrichment first) | high: loadout, location, difficulty, contract type at attempt start | high | contracts/escalations/Freelancer shapes |
| `ContractFailed` | 2 | `str` reason: `"Contract ended manually: OnRestartLevel"`, `"…User pressed exit to Main menu"` | yes (as attempt enrichment first) | **high**: states restart vs exit, which Stage A could not derive | high for these two reasons | other reasons (player death, `ContractEnd` on completion — never observed; a completed mission has not been run) |
| `HeroSpawn_Location` | 2 | `{RepositoryId}` | later | medium: starting location | high | — |
| `IntroCutEnd` | 2 | `""` | later | low–medium: "player has control" marker | medium | whether it fires without an intro |
| `StartingSuit` | 2 | `str` (outfit repository id) | later (disguise domain) | medium | high | — |
| `Level_Setup_Events` | 12 | `{Contract_Name_metricvalue, Location_MetricValue, Event_metricvalue}` | no (mission-script metrics) | low | high | — |

Not observed but expected on the stream per prior art: `ContractEnd`, `ContractLoad`, `Hero_Dead`. A completed mission and a player death have not been run.

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
| `Trespassing` | 2 | `{IsTrespassing, RoomId}` | later | medium | high | — |
| `HoldingIllegalWeapon` | 4 | `{IsHoldingIllegalWeapon, [WeaponEquipped{…item…}]}` | later | medium | high | — |
| `Agility_Start` | 2 | `""` | no | low | medium | — |
| `Hero_Health`, `Hero_Dead` | 0 | (prior art only) | — | high when observed | none | a run in which 47 is hurt / dies |

## Disguise

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `Disguise` | 2 | `str` (outfit repository id) | **yes** | high | high | outfit name resolution (repository lookup, as `GetActorName` does) |
| `DisguiseBlown` | 2 | `str` (outfit) | yes | high | high | — |
| `BrokenDisguiseCleared` | 2 | `str` (outfit) | yes | medium | high | — |
| `StartingSuit` | 2 | `str` | yes | medium | high | — |

## Item / inventory

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `ItemPickedUp` | 12 | `{InstanceId, ItemType, ItemName, RepositoryId, OnlineTraits[], Category, ActionRewardType}` | **yes** | high | high | `ItemType` can be `"Unrecognized Item type"` (crowbar) — name/traits still present |
| `ItemRemovedFromInventory` | 6 | same item shape | yes | medium | high | — |
| `ItemThrown` | 6 | same item shape | yes | medium | high | — |
| `ItemDropped` | 0 | (prior art) | — | medium | none | — |
| `ItemStashed`, `Guard_FoundItem` | 1 / 1 | `{ActorId, RepositoryId, ActorName, ItemId, ItemTypeId}` (the NPC who stashed/found) | later | low–medium | medium | — |

## Objectives / challenges

| Name | Count | `Value` shape | Suitable | M2 relevance | Confidence | Needs evidence |
|---|---|---|---|---|---|---|
| `ObjectiveCompleted` | 1 | `{Id, Type: "kill", Category: "primary", ExcludeFromScoring}` | **yes** | **high** | high for this shape | other objective types; `ObjectiveFailed`-like events; name resolution of `Id` |
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
| `SecuritySystemRecorder` | 1 | `{event: destroyed\|spotted, recorder}` | later | medium (SA rating) | high (AdvancedRating uses it) | — |
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

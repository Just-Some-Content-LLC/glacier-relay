# M5 C-2 — effectful `player.outfit.set` design record (2026-10-14; design and read-only source investigation; nothing implemented; M5 not complete)

Authorized by "C-1 Runtime Acceptance and C-2 Design Authorization": architectural design and read-only source investigation for one bounded, reversible `player.outfit.set` operation. No effectful implementation is authorized; the C-1 implementation and the M5-B command infrastructure are frozen while this design is reviewed. No source, binary, settings file, token, detour or game state changed. Every file reference is into ZHMModSDK `relay/m2` `c1bfe0c5` or glacier-relay `main` `555df541`; every runtime fact is from the recorded runs (M5 design sections 19, 23 and 24) and the committed fixtures.

Checkpoint verified before the design (M5 design section 24): both repositories clean and equal to their remotes, tags unchanged, the three DLL builds of record preserved, `c1-run1` 228/228, game at M0 26/26, nothing installed, no relay process or port.

---

## 1. Formal C-1 runtime acceptance

Recorded in `M5_COMMAND_CHANNEL.md` section 24: the thirteen demonstrated facts (five live inspections; frame-thread execution; the hero's kit id equal to the initial disguise telemetry; HeroA-compatible current kit at charset 0 / variation 0; the bounded 153-entry kit-map scan; `ZHitman5_SetOutfit` available through `Exists()`; stable mission-generation comparisons; the transition epoch advancing on the restart evidence; 10 / 10 / 10 envelopes; six replay comparisons; 35 contiguous journal entries; zero native warnings, errors or faults; M0 26/26), the two findings preserved (the hero resolves at the menu; the registry session id persists after exit), and the two narrow-window inspections marked **not performed**.

---

## 2. Target selection: the second suit kit

### 2.1 What the source offers

The SDK repository carries no outfit repository data: no JSON, no id table, no kit list. Every production mod resolves kits at runtime from the loaded bricks — the Player and Assets mods iterate `Globals::ContentKitManager->m_repositoryGlobalOutfitKits` and match on `m_sCommonName` (`Mods/Assets/Src/Assets.cpp:142–168`, filter `!m_bIsHitmanSuit` for NPCs); the Outfits mod loads and unloads whole global-data bricks (`Mods/Outfits/Src/Outfits.cpp:17–80`), which changes the kit population per scene. `ZGlobalOutfitKit` exposes, beside `m_sId` (0x200) and `m_bIsHitmanSuit` (0x19E), `m_sCommonName` (0x50), `m_sTitle` (0x60), `m_eOutfitType` (0x194; `EOutfitType::eOT_Suit = 1`, `Enums.h:2517–2525`), `m_eOutfitAICategory` (0x190), `m_bHeroDisguiseAvailable` (0xA9) and `m_aCharSets` (0x90) (`Include/Glacier/ZOutfit.h:45–85`). Two suit classifications therefore exist in the data (`m_bIsHitmanSuit` and `m_eOutfitType == eOT_Suit`); C-1 read only the first; their agreement is not established.

### 2.2 Every outfit id ever observed by the Relay

| Id | Where observed | What it is | Suit? |
|---|---|---|---|
| `874c4c48-0a8b-49e9-883e-49fc5f1fb051` | every Paris run since B3: `StartingSuit`, `contract.started` (`is_hitman_suit true`, 24 envelopes), `disguise.equipped (initial)`; C-1: the hero's `m_rOutfitKit->m_sId` on all three mission inspections, found in the Paris kit map (153 scanned), 1 charset, 1 HeroA variation | the Paris starting suit (the current tuple `874c4c48… / 0 / 0`) | yes (`m_bIsHitmanSuit true`, runtime-read) |
| `4fc9396e-2619-4e66-a51e-2bd366230da7` | C-1 only: the hero's `m_rOutfitKit->m_sId` at the main menu, before any mission (frame 8191) and after the exit (frame 48420); `hero_suit true`, 1 charset, 1 HeroA variation, charset 0 / variation 0 | the kit the frontend hero wears — a native outfit-kit definition (read through a `ZGlobalOutfitKit` reference, not an instance id) | yes (`m_bIsHitmanSuit true`, runtime-read) |
| `2018db77-aa8a-4bf9-9afb-56bdaa161156` | B0 corpus, B3 §36, B6 §48: `Disguise` / `DisguiseBlown` / `BrokenDisguiseCleared` | a mid-mission disguise (locker) | no (an AI-category change; excluded) |
| `992cc7b6-4ccf-4ae8-a467-e9b2aabaeeb5` | B0 corpus (M2 design section 30's B0 table: `Disguise` @497.756, blown, cleared); B6 §48 envelopes | a mid-mission disguise | no (excluded) |

No other outfit id exists in any source file, fixture, recording, journal, native log or design document of either repository.

### 2.3 The candidate and what is not established

**Candidate second kit: `4fc9396e-2619-4e66-a51e-2bd366230da7`.** Against the authorization's criteria:

| Criterion | Status | Evidence |
|---|---|---|
| Different repository id from `874c4c48…` | met | the two ids differ |
| A native outfit-kit definition, not an instance id | met | read from `ZHitman5::m_rOutfitKit->m_sId` of a resolved `ZGlobalOutfitKit` (C-1 r1, r4a) |
| Supports HeroA | met at the menu | `hero_heroa_valid true`, 1 HeroA variation (C-1 r1, r4a) |
| Supports charset 0 and variation 0 | met at the menu | the hero wore it at `0 / 0` |
| Classified as a suit | met | `hero_suit true` (`m_bIsHitmanSuit`); `m_eOutfitType` not read |
| Requires no shared outfit-kit mutation | met by construction | HeroA charset, no resource rewrite (research section 2.2.4) |
| **Resolvable from the loaded global outfit-kit map under Paris** | **not established** | C-1's Paris scans looked for `874c4c48…` only; the frontend kit may or may not be among the 153 Paris entries |
| Clear restoration path to the prior tuple | met | the prior tuple `874c4c48… / 0 / 0` is resolvable under Paris (C-1, three times) |

Runtime availability under Paris is **not claimed**. Also unknown: the kit's common name and title (not read), whether `SetOutfit` to a frontend kit inside a mission streams correctly (engine behaviour), and whether the engine emits any telemetry for it.

### 2.4 Decision: target discovery is a separate inert prerequisite (C-1b)

Because a second kit cannot be established from source, **C-1b — target discovery** is a prerequisite of C-3, inert, with **no code change**: one controlled run with the unchanged C-1 DLL `7fecf31a…` (build of record) issuing `relay.inspect.outfit` with `disguise_repository_id = 4fc9396e-2619-4e66-a51e-2bd366230da7` and the expected generation during a stable Paris attempt. Outcomes:

- `candidate_found true`, `candidate_heroa_usable true`, `candidate_suit true` → the target is established for C-3 (recorded with the frame, generation and `kits_scanned`).
- `candidate_found false` → the frontend kit is not in the Paris population; **C-1c** is then required: a bounded suit enumeration read-back (a new inert entry, e.g. `relay.list.suits/1`, listing entries with `m_bIsHitmanSuit == true` as `{id, common_name, charsets, heroa_variations_0}` paged to the 4,096-byte line, no write) — native code, its own gate and authorization.

The same C-1b run can attempt the two narrow-window inspections section 24.3 left open (one inside the first second after a rise; one between a restart's contract end and the fall), never rushed, optional, recorded as attempted or not.

**A same-kit no-op does not satisfy the effectful milestone**: `player.outfit.set` with `disguise_repository_id == expect_current.disguise_repository_id` (and equal charset and variation) is **rejected** by BEAM before transmission (`same_as_current`) and, defensively, by the native precondition (`target_equals_current`). The milestone's effect is a change of the hero's tuple to a different kit definition and its restoration.

---

## 3. The effectful precondition contract (the mandatory C-2 apply gate)

### 3.1 From hypothetical evaluator to apply gate

C-1's `PreconditionEvaluator::Evaluate` (`Src/PreconditionEvaluator.cpp:43–157`) is pure, collects every failed rule, and is evaluated on the inspection frame over values the scheduler copied from that frame. C-2 makes it the **apply gate**: `player.outfit.set` is dispatched only when `Verdict.ok` — every rule below — holds on the applying frame, immediately before the setter call, inside the same frame-thread function. Any missing or inconsistent required field is a failure (a `Field` whose status is not `Observed` never satisfies a rule; a `std::nullopt` generation is `*_missing`, never a wildcard). The verdict and its reasons are returned in the result either way.

| # | Required (authorization) | C-1 rule (reason code) | C-2 change |
|---|---|---|---|
| 1 | Expected mission generation present | `expected_generation_missing` | **mandatory** on the wire for this entry (BEAM refuses issuance without it; native rejects the command at decode) |
| 2 | Generation at receipt = expected | `generation_mismatch_receipt`, `receipt_generation_missing` | unchanged; stamped under the queue mutex (`CommandQueue.h:103`) |
| 3 | Cached mission generation = expected | `generation_mismatch_cached`, `cached_generation_missing` | unchanged |
| 4 | Fresh applying-frame registry generation = expected | `generation_mismatch_fresh`, `fresh_generation_unavailable`, `fresh_generation_inconsistent` | unchanged; **plus a post-call read** (3.4) |
| 5 | Predicate true now and on the previous frame | `mission_not_playing`, `previous_frame_not_playing` | unchanged |
| 6 | Minimum stability interval | `stable_interval_too_short`, `stable_frames_too_few` (1,000 ms / 60 frames) | the constants stay; C-3 issues ≥ 30 s after the rise anyway |
| 7 | Matching contract-start evidence | `contract_start_missing`, `contract_start_mismatch` | unchanged |
| 8 | No contract end for the active attempt | `contract_end_observed` | unchanged |
| 9 | Epoch unchanged since receipt | `epoch_changed` | unchanged; re-checked post-call (3.4) |
| 10 | Scene loaded, type and stage | `scene_unavailable`, `scene_not_loaded`, `loading_stage_not_playing`, `scene_type_not_mission` | unchanged |
| 11 | Scene resource consistent with the rise | `scene_resource_changed` | unchanged |
| 12 | Valid local hero on the applying frame | `player_unavailable` | unchanged (`player_resolved` requires the entity ref, the `ZHitman5` interface and the kit ref) |
| 13 | Current outfit tuple readable | `outfit_unreadable` | **extend**: `hero_charset`, `hero_variation`, `hero_charset_count`, `hero_heroa_vars` must all be `Observed` (today only the id is required) |
| 14 | `expect_current` supplied and matching | `expect_current_mismatch` (optional, id only) | **mandatory and a tuple**: `{disguise_repository_id, charset, variation}` all three equal to the hero's `{m_rOutfitKit->m_sId, m_nOutfitCharset, m_nOutfitVariation}` |
| 15 | Candidate resolved and HeroA-valid | `candidate_missing`, `candidate_unresolved`, `candidate_not_heroa_usable` | **extend**: the requested `charset` < `m_aCharSets.size()`, the HeroA collection of that charset non-null, the requested `variation` < its `m_aVariations.size()` (today `heroa_usable` only checks charset 0 has ≥ 1 variation, `OutfitObservation.cpp:78–90`); the kit entry's `TEntityRef` and interface non-null |
| 16 | SDK setter available | `setter_unavailable` | unchanged (`Exists()`), re-read on the applying frame |
| 17 | Current command-link generation unchanged | — (scheduler `Tick` drops a stale generation before dispatch, `CommandScheduler.cpp:218–224`) | **new**: `LinkGeneration()` re-read immediately before the call (3.4); mismatch → `unavailable (link_generation_changed)`, nothing applied |
| + | Target differs from current | — | **new**: `target_equals_current` |
| + | Apply on the frame thread | — | **new**: `thread_mismatch` when `GetCurrentThreadId()` ≠ the scheduler's `first_thread_id` (the detour's and frame update's thread, logged at the first frame) |
| + | No other effectful command pending | — | **new** (research section 4.3): `busy` at the link thread when an effectful command is already queued or applied-but-unreported |
| + | Effectful setting | — | **new**: `[command] effectful = true` in the mod's settings; otherwise the entry stays reserved and rejected at decode, exactly as today |

"Do not assume two identical registry reads provide atomicity": the twice-read (`SceneObservation.cpp:172–180`) detects a change that straddles the two reads; it does not prove the string is stable for the rest of the frame. The gate treats it as one of several independent witnesses (expected, at-receipt, cached, fresh, epoch, contract evidence, predicate) and adds the post-call read of 3.4; nothing in the design relies on the registry alone.

### 3.2 The actual frame ordering (verified by source)

`GlacierRelay::OnFrameUpdate` → `RelayLog::Guard("ObserveFrame")` → `ObserveFrame()` (`Src/GlacierRelay.cpp:189–283`):

1. `ReportQueueDrops()`; `SceneObservation::ObserveScene()` (:200–202).
2. The registry session id is read only on a frame where the predicate will change (:229–232).
3. **`RelayFrame::Process`** (:234–238): drains every telemetry observation queued since the last frame and publishes each through the adapter; a `contract.started` / `contract.ended` publish goes through `LifecycleTee::Publish` (`Src/LifecycleTee.cpp:32–53`), which calls the plugin's `OnContractLifecycle` **synchronously on the frame thread** (`GlacierRelay.cpp:365–379`): `m_ContractStartedSeen` / `m_ContractEndedSeen` are set and, for an end naming the cached generation, the epoch advances. Then the mission observer's edge is processed and published (`RelayFrame.cpp:115`).
4. The predicate edge (:243–272): `m_AttemptSessionId` set or cleared, `SetMissionGeneration`, **epoch advance** on rise or fall, rise bookkeeping (frame, clock, scene resource, once-per-attempt markers). Scene unavailable during an attempt advances the epoch once (:273–277).
5. `++m_Frame` (:279).
6. **`ScheduleCommand`** (:281–282, :288–320): a `FrameObservation` is built from the plugin's state as it is *after* steps 3–5 (epoch, contract markers, predicate, previous-frame predicate, rise data, scene, cached generation, link generation), then `CommandScheduler::Tick` (`Src/CommandScheduler.cpp:195–315`): `Pop(snapshot)` publishes this frame's snapshot under the queue mutex and takes at most one command; stale link generation → dropped; TTL → `expired`; dispatch. For an inspection the engine reads happen here through the inspector (`GlacierRelay.cpp:385–414`), then the pure evaluator.
7. C-2 adds, in the same dispatch: the apply (section 4) after the evaluator says `ok`, in the same function, on the same frame, before `Tick` returns.

**All transition evidence the adapter has drained by this frame is visible to the scheduler before its precondition evaluation.** There is no path by which a drained `contract.ended`, a predicate edge, a scene change or an epoch advance is observed by the plugin after the scheduler ran on the same frame.

### 3.3 The remaining races, named

| Window | What can happen | Visible to the gate? | Design response |
|---|---|---|---|
| **W1 — engine events after our callback, same engine frame** | The engine emits `ContractEnd` (or begins a teardown) later in engine frame N, after our frame update returned. The detour queues it on the same thread; the drain happens in our frame N+1. An apply in frame N ran before the event existed. | No — nothing can see the future of the same engine frame. | Inherent, ≤ 1 engine frame (≈ 10 ms at the observed ≈ 100 fps). The result's `contract_ended_seen`, `relay_transition_epoch` and `native_at` let BEAM place the apply before the end in the sequence; a `contract.ended` whose native timestamp follows the result's `native_at` within one frame is reported as **`applied_at_transition_edge`** (3.5) and the effect is treated as uncertain (the attempt tore down). The restart race in M5-B and C-1 showed the contract end 0.92–0.97 s *before* the fall; a command issued ≥ 30 s into a stable attempt, with the operator standing still, does not approach this window except by the operator's own action. |
| **W2 — registry reassignment between the twice-read and the call** | `ZPlayerRegistry` is a replica (`ZBaseReplica`); another thread may reassign `s_sSessionId` after our two equal reads. | Partially: the post-call third read (3.4). | `generation_post` in the result; a mismatch → `applied` with `effect uncertain` and `post_generation_changed`; the epoch advances (`registry generation differs…`) for every later frame. No reliance on the registry alone. |
| **W3 — link loss between the pre-call `LinkGeneration()` read and the call** | The network thread resets the generation to 0 and clears the queue (`CommandLink.cpp:235–236, 342, 348–349`). | Not closable from the frame thread (microseconds). | The command was already popped; the apply proceeds; the result is pushed to a link that is gone and is lost; BEAM holds `unknown (link_lost)`. The **native log line written before the call** (4.3 step 7) is the durable proof the engine was asked; the operator re-observes (`relay.inspect.outfit`) before any reversal. |
| **W4 — a second command enqueued between `Pop` and the apply** | Irrelevant to safety: one command per frame; the next is judged on its own frame with its own snapshot. | n/a | Keep the busy rule for a second effectful command. |
| **W5 — a `contract.ended` naming another generation** | Does not advance the epoch (`m_ContractEndsOtherGeneration`), but `contract_ended_seen` is overwritten. | Yes: the gate compares `contract_ended_seen` with the expected generation, so an end naming *another* generation does not fail the gate, which is correct (it is not this attempt's end) and also means an unknown-id end is not evidence. | Report `contract_ended_seen` and the other-generation counter in the result; no change. |
| **W6 — brick unload / scene clear inside the same engine frame after our call** | Same class as W1. | No. | The kit reference is resolved and used inside one function; a scene clear in the same frame is the engine's own ordering; the result's read-back is taken before our callback returns. |
| **W7 — the frame thread is not the engine's expected thread for `SetOutfit`** | The Player mod calls it from the UI draw, the Randomizer from inside the engine's own call; ours would be the frame update (`eUpdateAlways`, priority 1), the same thread as the detour on this build (46608). | Checked by the thread rule; not provable in general. | `thread_mismatch` refuses; C-3 verifies the thread identities in the log as section 23.5 did. |

**Transition detected during the frame invalidates the command before the setter call**: by construction of 3.2 every transition the adapter can detect on frame N is detected before the dispatch on frame N; the gate re-evaluates all of it, immediately before the call, with fresh engine reads. What remains (W1, W2, W3) is reported, never hidden, and never resolved by assumption.

### 3.4 Immediately around the call (the apply path's own checks, after the gate)

1. `LinkGeneration()` re-read (under the link mutex, `CommandLink.cpp:90–94`) must equal the command's; else `unavailable (link_generation_changed)`, no call.
2. `Functions::ZHitman5_SetOutfit != nullptr && ->Exists()` re-read; else `unavailable (setter_unavailable)`.
3. The hero's `TEntityRef<ZHitman5>` and the kit's `TEntityRef<ZGlobalOutfitKit>` resolved in this function are the only references used; nothing cached from the inspection or an earlier frame.
4. After the call returns (it returns `void`, `Include/Functions.h:98–101`): the registry read a third time (`generation_post`), the epoch compared again (it cannot have moved inside the call on this thread unless the setter re-entered our detour — `OnTelemetryEventSent` only queues, so it cannot), the hero's tuple read back (`current`).

---

## 4. Native apply design: `player.outfit.set` version 1 (revised schema, section 5)

### 4.1 Placement

New `Src/OutfitApply.h/.cpp`: a frame-thread function `OutfitApply::Apply(const Request&, const FrameObservation&, const Rules&, Applier&) → Outcome` where `Applier` is a small interface with `Reads Observe(candidate)`, `Reads ReadBack()`, `bool CallSetter(const Resolved&)`, `uint64_t LinkGeneration()`, `uint32_t ThreadId()`; the plugin implements it over `SceneObservation` and the SDK, tests and the probe implement fakes. The scheduler gains one dispatch case (`Entry::PlayerOutfitSet1`) that is compiled to `Rejected ("reserved")` unless the scheduler was constructed with an applier, which the plugin does only when `[command] effectful = true`. `CommandProtocol::DecodeCommand` keeps returning `!ok "reserved command: not issuable"` for the entry unless the link was constructed with `effectful` (the setting is read once at `OnEngineInitialized`; no runtime toggle). The hello advertises `player.outfit.set/1` in `capabilities` only when effectful; BEAM's welcome lists it as issuable only when the hello advertised it *and* the trust and arming of section 6 hold.

### 4.2 Wire request (after the schema revision of section 5)

```
params: { "disguise_repository_id": uuid,         # the target kit definition
          "charset": int 0..15, "variation": int 0..63,
          "expect_current": { "disguise_repository_id": uuid, "charset": int, "variation": int } }
preconditions: { "mission_generation": text 1..64 }   # mandatory for this entry
ttl_ms: 100..10000 (C-3 uses 2,000)
```

### 4.3 The operation, in order, all on the applying frame, inside the dispatch

1. **Validate the frame and generation** — the full gate of 3.1 over fresh engine reads (the C-1 inspector, extended with the target's charset/variation bounds); any failure → `precondition_failed` with every reason, or `unavailable` when a required read is not `Observed`; **no engine write**.
2. **Resolve the hero and the candidate kit** — slot-0 `m_HitmanEntity` → `TEntityRef<ZHitman5>`; the kit by the bounded byte scan of `m_repositoryGlobalOutfitKits` (`SceneObservation.cpp:231–249`); both references used only inside this function.
3. **Save the current tuple** — `previous = {m_rOutfitKit->m_sId, m_nOutfitCharset, m_nOutfitVariation}` plus the kit's shape (charset count, HeroA variations) — the evidence the reversal needs.
4. **Validate `expect_current`** — the three fields equal to `previous`; else `precondition_failed (expect_current_mismatch)`.
5. **Verify `ZHitman5_SetOutfit->Exists()`** — again, here.
6. **Check the link generation** immediately before application (3.4.1).
7. **Write the native log line `command: <id> applying player.outfit.set …`** with the previous tuple, the target, the frame, the generations and the epoch — *before* the call, so a fault or a lost link leaves durable evidence that the engine was asked.
8. **Invoke the SDK setter once**: `Functions::ZHitman5_SetOutfit->Call(hero, kitRef, charset, variation, false, false)` — the Player mod's HeroA path and flag values (`Mods/Player/Src/Player.cpp:452–454`; `bIgnoreOutifChange` semantics unknown by source, documented as such) — inside **its own `RelayLog::Guard("ApplyOutfit")` scope** (SEH, `Src/RelayLog.h:63–72`) nested in the frame guard, as `InspectOutfit` already nests its reads (`GlacierRelay.cpp:390–393`).
9. **Read the resulting tuple** in a second guard scope: `current = {id, charset, variation}`, `generation_post`, the epoch.
10. **Produce the bounded result** (4.4) and `MarkDone`; emit; write `command: <id> applied …` (or `failed …`) to the native log.
11. **Retain enough evidence for operator-directed reversal**: the result carries `previous_*` (the full prior tuple) and `current_*`; BEAM journals both in `command.terminal`; `Command.reverse/2` (section 6) builds the reversal from the journaled `previous` tuple — never from memory of the native side, which keeps nothing across frames.

No generic engine-call mechanism (one `->Call` site in the whole mod, by gate), no memory write (every write is the engine's own inside the setter), no change to shared outfit-kit tables (HeroA only; the Player mod's Actor/Nude rewrite paths are not reproduced), no additional detour (the import set and `AddDetour` count are gated; section 10).

### 4.4 Result read-back (≤ 48 entries, field objects as C-1; measured in C-2B against the 4,096-byte line)

Frame and scene (`scene_available`, `scene_loaded`, `loading_stage`, `scene_type`, `mission_playing`, `prev_frame_playing`, `frame`, `receipt_to_frame_ms`, `rise_age_ms`, `rise_age_frames`, `scene_same_as_rise`), generations and transition (`generation_expected`, `generation_at_receipt`, `generation_cached`, `generation_fresh`, **`generation_post`**, `relay_transition_epoch`, `epoch_at_receipt`, **`epoch_post`**, `contract_started_seen`, `contract_ended_seen`), **`previous_outfit_id`, `previous_charset`, `previous_variation`**, candidate (`candidate_id`, `candidate_found`, `candidate_charsets`, `candidate_heroa_vars`, `candidate_heroa_usable`, `candidate_suit`, `kits_scanned`), **`current_outfit_id`, `current_charset`, `current_variation`** (status `unavailable` when the read-back could not be made), `set_outfit_available`, `kit_map`, `reads_on_frame`, **`link_generation_at_call`**, **`setter_called`** (bool), **`effect`** (text: `changed` | `unchanged` | `uncertain` | `none`), `precondition_ok`, `precondition_reasons`. The reduction rule of C-1 (first 19 entries) is replaced for this entry by a fixed minimal set that always fits: the generations, `previous_*`, `current_*`, `setter_called`, `effect`, `precondition_ok`, `precondition_reasons` — the reversal must never lose `previous_*` to a line bound.

### 4.5 Fault behaviour (the result never pretends)

| Case | Native status / fields | Meaning |
|---|---|---|
| Gate fails | `precondition_failed` (or `unavailable`), `setter_called false`, `effect none` | nothing asked of the engine |
| Setter faults (SEH caught by the apply guard) | `failed`, `setter_called true`, `effect uncertain`, `current_*` from the second guard if it succeeds, else `unavailable ("read-back after fault")`; reason `fault inside the setter` | the engine may be inconsistent; **a run-stop condition** (research section 4.4); the native log has the fault line with the module and address |
| Setter returns, read-back equals `previous` | `applied`, `effect unchanged` | the engine took the call and the tuple did not change; not a success, not a failure — a fact for the operator |
| Setter returns, read-back equals the target | `applied`, `effect changed` | native evidence of the change; still `observed: :native` on BEAM |
| Setter returns, read-back is neither | `applied`, `effect uncertain`, reason `read-back matches neither` | reported as is |
| Read-back faults after a returning setter | `applied`, `current_* unavailable`, `effect uncertain` | the write may have happened; the operator inspects on a later frame |
| `generation_post` ≠ `generation_fresh` or `epoch_post` ≠ epoch | `applied`, `effect uncertain`, reason `post_generation_changed` / `post_epoch_changed` | the attempt moved during the frame (W1/W2) |

A `failed` with `effect uncertain` **requires later observation** (`relay.inspect.outfit`) before any reversal is issued; BEAM enforces this in the reversal helper (section 6.3).

---

## 5. Wire schema: why reserved v1 cannot carry the tuple, and the minimum revision

The reserved entry (`relay/lib/glacier_relay/command/schema.ex:74–86`; `Src/CommandProtocol.cpp:240–252`) is `params {disguise_repository_id: uuid, expect_current?: uuid}` with the reversal documented as "the previous `disguise_repository_id`". It cannot represent the prior tuple: a reversal to `(id, charset ≠ 0, variation ≠ 0)` is unrepresentable, and `expect_current` as an id alone cannot detect a charset or variation drift under the same kit. Every suit observed so far has one charset and one variation, so `(0, 0)` is the only valid tuple today — the schema must still carry the tuple to state restoration honestly.

**Minimum required revision (before any implementation):** `params` become `{disguise_repository_id: uuid (required), charset: integer 0..15 (required), variation: integer 0..63 (required), expect_current: object {disguise_repository_id: uuid, charset: integer, variation: integer} (required)}`; `preconditions.mission_generation` **required**; `reversal` documented as "`player.outfit.set` with `previous_outfit_id / previous_charset / previous_variation` of the result as the target and the result's `current_*` as `expect_current`". The parameter bounds are the same on both decoders (BEAM `validate_params`, native `DecodeCommand`), including the `object` type the native reader must gain for `expect_current` (depth 2 inside `params`; `CommandJson` already bounds depth at 4).

Recommendation: **revise the reserved v1 definition in place** rather than minting v2 — v1 was never issuable, never transmitted, and both decoders reject it today; the revision is recorded here and in the schema's doc string, and the C-2A commit states it. If the reviewer prefers the version to be immutable even when reserved, the alternative is `player.outfit.set` v2 with v1 deleted; the design is otherwise identical.

---

## 6. Reversal contract

1. **A separate, explicitly issued `player.outfit.set`** with its own command id, ladder, journal entries, precondition evaluation (the full gate, including a fresh `expect_current`), observation evidence and result. Nothing automatic: no reversal on timeout, link loss, disarm, node stop or game exit (the engine's own attempt teardown is expected to discard the outfit; that expectation is not verified and not relied on).
2. **The whole saved tuple** is restored: target `= previous_{outfit_id, charset, variation}` of the first command's result; `expect_current = current_{outfit_id, charset, variation}` of that result (so a reversal after any intervening change is refused by `expect_current_mismatch` instead of overwriting an unknown state).
3. **`Command.reverse(command_id, opts)`** (BEAM, C-2A): builds the reversal from the **journaled** `command.terminal` entry of the named command (never from the authority's memory alone), refuses when that command's status is not `applied`, when its `effect` is `uncertain` or `unchanged` without a later inspection recorded for the same generation (`Command.observe/2` or an `relay.inspect.outfit` result whose `hero_*` tuple equals the first command's `current_*`), when the generation differs from the live attempt's expected generation the operator supplies, or when effectful arming is not held. The reversal command is otherwise an ordinary issuance.
4. **Native target-state restoration** is the claim the reversal can make: the hero's tuple equals the saved prior tuple, as read back natively on the applying frame and on a later inspection frame, and as the operator sees it. **NPC suspicion, disguise compromise, scripted behaviour, witness memory, challenge or scoring state and any other gameplay consequence are not restored by the reversal and are unknown unless directly observed** (the B3 "change-time clear" shows the engine reacts to outfit changes; research section 6). Every report line about a reversal says "native tuple restored; gameplay consequences unknown".

---

## 7. Peer trust decision

### 7.1 Comparison (research section 5, re-decided for one operator-controlled experiment)

| Basis | Proves | Does not prove | Works across Windows → WSL2? | Decision |
|---|---|---|---|---|
| Ephemeral run-scoped token (attest exchange) | the connecting code could read the token placed under `retail/mods/` for this run, as the operator's user, during the install window | that the process is HITMAN or the code is ours | yes (application layer) | **adopt**, labelled `:token_verified` |
| Telemetry connection corroboration | both links present one adapter instance id; results' frames and scene read-backs agree with the observer's attempt state | origin (the id is printed in the native log) | yes (already available) | **adopt**, required true at arming |
| Windows socket-ownership inspection (`Get-NetTCPConnection -RemotePort 4749 -State Established`) | the kernel's statement that the sole Windows-side client of 4749 is `HITMAN3.exe` at that instant | that the code inside HITMAN is ours (other loaded mods share the process) | yes (run on Windows by the arming tooling; BEAM sees only the forwarder's peer) | **adopt**, recorded at every effectful arming; exactly one connection, owner `HITMAN3.exe` |
| Operator arming | the operator's intent, bounded in time | peer identity | yes | **adopt** as one-shot effectful arming with a TTL |
| Named pipes / SO_PEERCRED / signed attestation / certificates | process identity | — | **no** (the loopback forwarder hides the client; the DLL has no key store; a key in the DLL is readable by the same user) | rejected for this stage |

**An ephemeral token is not process authentication.** Trust after a successful attest is `:token_verified` — "possession of this run's token shown over this link" — never `:authenticated`; `player.outfit.set`'s `trust` becomes `:token_verified`, and `:authenticated` stays a reserved state no peer can reach.

### 7.2 The token, if `:token_verified` is adopted (design only; nothing implemented)

| Aspect | Design |
|---|---|
| Creation | the run's `install.sh` draws 32 bytes from `/dev/urandom`, hex-encodes them, writes `[command] token = <hex>` into `mods/GlacierRelay.ini` beside `enabled` and `effectful`, and writes the same hex into `<state-root>/command.token` (ext4, 0600) for BEAM (`GLACIER_RELAY_COMMAND_TOKEN_FILE`); never argv, never the environment, never a log |
| Delivery and exposure | the native side reads the ini once at `OnEngineInitialized` into memory; the file exists only between install and cleanup; the evidence copy of the ini (`glacierrelay.ini.installed/after-run`) is written **with the token line redacted** (`token = <redacted; sha256 …>`), and `installed.sha256` records the hash of the real file |
| Exchange | welcome gains `nonce` (16 random bytes, hex) and `attest_required: true`; the native side, when it holds a token, answers the welcome with one `{"kind":"attest","link_generation":N,"adapter_instance_id":…,"mac":HMAC-SHA256(token, nonce ‖ link_generation ‖ adapter_instance_id)}`; BEAM verifies with a constant-time compare, journals `peer.token_verified` (nonce and generation, never the mac or token), and sets `link.token_verified = true`. Both decoders are strict about keys and kinds (`CommandProtocol.cpp` `KnownKeys` on the welcome; `schema.ex:247` on kinds), so this is a lockstep protocol change on both sides: **`command_protocol_version` 1 → 2** for the handshake (hello, welcome, attest), the command and result lines unchanged in shape. A C-1 native (v1, no attest) against a v2 BEAM stays `identified`, never effectful |
| HMAC-SHA256 natively | a small vendored implementation with known-answer tests (no `bcrypt.dll` import; the import gate stays explainable); BEAM uses `:crypto` |
| Session and link binding | the mac covers the link generation and the adapter id; a new link (new generation, new nonce) requires a new attest; `token_verified` is a property of one link generation |
| Replay prevention | one nonce per link, one attest accepted per link (a second is a protocol violation and closes the link); a mac over another nonce or generation fails |
| Expiration and invalidation | the token's life is the run (install → cleanup); BEAM invalidates on link loss, on `disarm` of effectful arming (the link stays `token_verified`, the arming does not), on node stop; the native side drops it at unload; there is no renewal — a new run is a new token |
| Log redaction | the token and the mac never appear in the native log, BEAM log, journal, result or evidence; the native log says `attest sent (token present)`; the journal records `peer.token_verified` with the nonce |
| Exact cleanup | `run-cleanup.sh` removes the ini (already) and `<state-root>/command.token`, verifies both absent, and the evidence copy of the ini is the redacted one |
| Behaviour after reconnect | generation +1, arming lost (already), `token_verified` false until the new attest succeeds; BEAM refuses effectful issuance until then |
| Residual same-user risk | during the minutes between install and cleanup, any process running as the operator's Windows user could read the ini and attest; any code inside the HITMAN process (other mods in `mods.ini`) could issue without the token mattering. Accepted only for an operator-attended research run whose one effect is a suit-to-suit outfit change; recorded in every C-3 report |

### 7.3 One-shot effectful arming (BEAM, C-2A)

`Command.arm_effectful(ttl_ms: 30_000, ownership: <the recorded Windows check>)`: requires an intact audit, an identified **and token-verified** link, telemetry corroboration true (the telemetry connection identified with the same adapter id), the ownership check result supplied by the tooling (exactly one established client of 4749 on Windows, owner `HITMAN3.exe`, recorded in the journal entry `authority.armed_effectful`), nothing in flight; it is consumed by the **first** effectful issuance (journal `authority.effectful_consumed`, before `command.accepted`), expires after the TTL (`authority.effectful_expired`), and is cleared by `disarm`, link loss or any audit degradation. Inert commands keep the existing arming. Each effectful command — the change and the reversal — needs its own arming.

---

## 8. Effect confirmation vocabulary

| Level | Established by | Label |
|---|---|---|
| accepted | BEAM, journaled before send | `accepted` |
| transmitted | bytes written to the link | `transmitted` |
| received | the native link thread's `received` result | `received` |
| native invocation completed | the apply path: gate held, `setter_called true`, the call returned without fault | status `applied`; `invocation: :completed` |
| current outfit tuple changed | `current_* ≠ previous_*` and `== target` on the same frame | `effect: :changed` (native, same frame) |
| same-frame read-back | the result's `current_*` | `observed: :native_same_frame` |
| later-frame read-back | a later `relay.inspect.outfit` whose `hero_*` tuple equals the target, same generation, later frame | `observed: :native_later_frame` |
| engine-authored disguise telemetry, if present | a `disguise.equipped` with `kind change` correlated by the research section 7 rule (same adapter id on both links, same contract session id, same repository id, after the result's `native_at` within 5,000 ms, sequence after the command's acceptance, no other outfit command or operator change in the window) | `observed: :engine_consistent` — "consistent with command C", never "caused by" |
| operator visual confirmation | `Command.observe(command_id, note)` → journal `operator.observation` | `observed: :operator` |
| original tuple restored | the reversal's `applied` with `current_* == first.previous_*`, plus a later-frame inspection and the operator's note | `restored: :native_later_frame` (+ `:engine_consistent` / `:operator` when present) |
| residual gameplay consequences | nobody | `consequences: :unknown` — always |

**The setter's availability does not prove that calling it emits a `Disguise` event**; no telemetry event is invented. If no `disguise.equipped` follows, the report says "no engine-authored disguise event observed within 5,000 ms" and the observation rests on the native later-frame read-back and the operator, labelled as such (ADR 0009 reconciliation; M5 design section 13).

**Minimum evidence sufficient to claim the M5 exit criterion** ("one safe, reversible semantic command changes observable game state"): (1) the change command `applied`, `effect changed`, `previous_* ≠ current_* == target`; (2) `observed: :native_later_frame` for it; (3) `observed: :operator` for it; (4) the reversal command `applied` with `current_* == first.previous_*`; (5) `observed: :native_later_frame` and `:operator` for the reversal; (6) the journal contiguous with every entry correlated; (7) telemetry invariance (native = BEAM = recorder, replay holding); (8) M0 restored; (9) any `disguise.equipped` reported as consistent or its absence stated. The claim's wording: "the hero's outfit tuple changed from A to B and back to A on the observed build, observed natively on later frames and by the operator; engine-authored evidence [present and consistent / absent]; gameplay consequences unknown".

---

## 9. Unknown outcomes and failure containment

| Case | Native | BEAM | Operator rule |
|---|---|---|---|
| Engine fault during application | `failed`, `effect uncertain`, fault line with module and address; the frame guard also protects later frames | `failed`, `observed :none`, `effect :uncertain`; **run stop** | no reversal; inspect if the game is still responsive; exit; record |
| Setter returns, state unchanged | `applied`, `effect unchanged` | `applied`, labelled `applied_unchanged`; not counted toward the exit criterion | inspect; no retry |
| Successful write, missing terminal response | the result is pushed; if the link is gone it is lost; the native log holds `applying` and `applied` | `unknown (terminal_timeout | link_lost)`; a late result → `anomaly.late_result` (status stays `unknown`); a late non-application terminal → research section 8's `command.unknown_refined` (status stays `unknown`); **a late `applied` never refines** — it sets `late_applied_claim true` and the journal entry, nothing else | inspect before anything; the native log is evidence |
| Loss of the command link | the queue is cleared (`Clear()`, ids marked expired); a popped command may still apply (W3) | `unknown (link_lost)`, disarmed, effectful arming cleared; reconnect → new generation, re-attest, re-arm | inspect after reconnect |
| Scene transition during application | the gate refuses everything it can see (3.2); W1 reported as `applied_at_transition_edge` | `effect :uncertain` when `generation_post` / `epoch_post` moved or a `contract.ended` follows within a frame | inspect; the next attempt starts with its own suit; the reversal targets the **saved tuple only if the generation is the same** — otherwise refused (`generation_changed`) |
| Duplicate command id | the 64-id ring answers `duplicate` with the prior status; never re-applied while remembered; beyond the ring not recognized (no exactly-once claim) | the authority never reuses an id for the node's life; a duplicate result is an anomaly | none |
| Queue expiration (TTL) | `expired` before dispatch asserts non-application | `expired` | re-issue only after inspection |
| Reversal target unavailable | the reversal's gate: `candidate_unresolved` → `precondition_failed` | the reversal `precondition_failed`; the first command stays `applied` | the hero keeps the new kit; the operator may exit the mission (teardown is the engine's; not verified); record "not restored" |
| Current outfit ≠ expected | `precondition_failed (expect_current_mismatch)` | as reported | inspect; decide |
| Journal degradation | — | existing policy: accepted persisted before send; a later failure keeps the command in flight (uncertain), degrades and disarms for life; effectful arming cleared; no new issuance | restart the subtree with a new journal only after the run; the degraded journal is evidence |
| Operator disarm | — | `disarm` always succeeds (fail-closed direction) but **does not recall** a transmitted command; the one-shot arming is consumed at issuance anyway | the TTL (2,000 ms in C-3) bounds the in-flight window |

No automatic retries, no automatic reversal, no exactly-once claim. `effect :uncertain` is a terminal classification of its own in the journal and the report ("possible effect; later observation required"), never collapsed into `applied` or `failed`.

---

## 10. Implementation stages (prepared; none authorized or started)

**C-2A — BEAM effectful authorization and trust model (offline; no native change).** Schema: the revised reserved entry (section 5), trust `:token_verified`, protocol v2 handshake (nonce, attest), `issuable` derived from the hello's capabilities. Authority: `token_verified` state and the attest verification, telemetry corroboration check, one-shot effectful arming with TTL and the recorded ownership check, `same_as_current` refusal, effectful issuance rules, `effect` / `invocation` / `observed` labels from the result fields, `late_applied_claim`, the research section 8 refinement, `operator.observation`, the correlation rule as a pure function. Facade: `arm_effectful/1`, `set_outfit/2`, `reverse/2`, `observe/2`. Journal events: `peer.token_verified`, `authority.armed_effectful`, `authority.effectful_consumed`, `authority.effectful_expired`, `operator.observation`, `command.unknown_refined`. Tests: each rule, each refusal, attest positives and every negative (wrong token, wrong nonce, replay, second attest, missing attest → identified only), the fake peer extended; the boundary test unchanged; the headless tree unchanged. Nothing native; the C-1 native (v1) must still handshake (`identified`) against the v2 BEAM — or the decision that v2 drops v1 is recorded.

**C-2B — native guarded outfit application (offline tests only).** `OutfitApply` behind `[command] effectful = false` (default); the protocol v2 handshake and attest (vendored HMAC-SHA256 with known-answer tests); the revised entry's decoder (`expect_current` object, integer bounds); the extended gate rules of 3.1; the apply path of 4.3 with the pre-call log line and the two guard scopes; the result of 4.4 with the fixed minimal reduction; the busy rule for a second effectful command; tests through the `Applier` fake for every reason code, the thread rule, the link-generation re-check, the fault path (the fake raises a structured exception through `RaiseException` so the SEH guard is exercised), unchanged state, uncertain read-back, post-generation change, the reversal; the probe gains `apply-ok`, `apply-unchanged`, `apply-fault`, `apply-transition`, `apply-linkloss`, `apply-noeffectful` modes. Gates in section 11. No DLL installed.

**C-2C — offline end-to-end verification.** The real BEAM subsystem against the real probe (the real link, queue, scheduler and apply code over the fake engine): attest and `token_verified`; effectful refused without arming, without attest, without `expect_current`, with the same kit; the change ladder with `effect changed`; the reversal built by `reverse/2` from the journal; `apply-unchanged`; `apply-fault` as a run stop; restart between receipt and apply (`precondition_failed`); link loss after apply (`unknown`, native log proof); duplicate id; TTL expiry; `apply-noeffectful` (the entry rejected as reserved when the setting is off). Five Elixir runs; the invariance and boundary tests; the v1 (C-1 probe) handshake against the v2 BEAM.

**C-1b — target discovery (inert; one HITMAN run with the unchanged C-1 DLL; own authorization; no code).** Section 2.4. Can run before or after C-2A/B/C; must precede C-3.

**C-3 — the first effectful runtime experiment (own authorization, only after C-2 acceptance and C-1b).** Section 12.

A better decomposition found by the source: the native attest (C-2B) and the apply (C-2B) are independent; if the reviewer wants the trust change validated on the real game before any effectful code exists, **C-2B can be split** into C-2B-i (attest only, inert, one run) and C-2B-ii (the apply). The default plan keeps them together to avoid a third inert run.

---

## 11. Native and BEAM offline test strategy, and the build / import / hook safety gates

| Gate | C-2A | C-2B / C-2C | C-3 pre-flight |
|---|---|---|---|
| Elixir suite ×5, warnings as errors; boundary test (no observer/web/recording module references `Command.*`); headless-tree invariance | yes | yes | — |
| Clean native build, 0 relay warnings; 25/25 test loops (the `TcpRelaySinkTests.cpp:274` window reported if it recurs, never fixed in the same change) | — | yes | the C-2B build, hash recorded |
| **Raw import-symbol diff** vs the C-1 dump (`imports-symbol-diff-vs-c1.txt`): expected **zero** new names (the setter static is already imported for `Exists()`; HMAC vendored); any name explained or the gate fails; no `listen`/`accept`/`bind`; exports unchanged | — | yes | verified on the installed bytes |
| `AddDetour` count exactly 1 (`ZAchievementManagerSimple_OnEventSent`); `ZHitman5_SetOutfit->Call` sites exactly **1**, in `OutfitApply.cpp`; no `->Call(` of any other `EngineFunction`; no `SignalInputPin`, no `SetProperty`, no raw pointer write outside the SDK call | — | yes (source scan in `validate-c2.sh`) | yes |
| `[command] effectful` absent or `false` → the entry rejected at decode, hello without the capability, `OutfitApply` not constructed; the telemetry path byte-identical with `[command] enabled = false` (M2 invariance) | — | yes | the C-3 ini is the only one that sets it |
| Probe end-to-end scenarios of C-2C | — | yes | dry run |
| Result line bound: the apply result measured at its maximum (every field observed, 40-byte reasons) < 4,096 B, and the minimal reduction always < 4,096 B | — | yes | — |
| Token redaction: `grep -c <token>` over the evidence directory, both logs and the journal = 0 (the redacted ini copy only) | yes (BEAM side) | yes | yes, before and after |
| Thread identities in the native log (scheduler first frame, detour, apply) | — | — | yes |

---

## 12. Proposed first effectful runtime test (C-3) and rollback procedure

**Preconditions:** C-2A, C-2B, C-2C accepted; C-1b established the target kit under Paris; the C-2B DLL hash frozen; pre-flight as section 23.1 plus: the token drawn and placed (ini + state-root file), `[command] enabled = true, effectful = true, token = …`, the ownership-check tooling dry-run against the probe, the v2 handshake dry-run (`token_verified`), `apply-*` probe scenarios replayed, the operator present and ready.

**R1 — menu:** load; handshake v2; `peer.token_verified`; disarmed; `set_outfit` refused (`not_armed_effectful`); `inspect` (hero `4fc9396e…` expected at the menu, as C-1). **R2 — Paris, standing still at the start in the suit, ≥ 30 s after the rise:** `inspect` with the target candidate and the expected generation — must be `precondition_ok true`, `candidate_found true`, `candidate_heroa_usable true`; `arm_effectful` (TTL 30 s; ownership check recorded: one client, `HITMAN3.exe`); `set_outfit {target, 0, 0, expect_current {874c4c48…, 0, 0}}` with the generation, TTL 2,000 ms; wait for the terminal; `inspect` on a later frame (≥ 1 s later); the operator's visual note; a 5,000 ms correlation window for any `disguise.equipped`. **R3 — reversal:** `arm_effectful`; `reverse(<first id>)` with the generation; terminal; `inspect`; the operator's note; the window. **R4 — exit to the menu:** `inspect` (registry id persisting, hero `4fc9396e…`); quit. **Cleanup:** `run-cleanup.sh` (DLL, ini with the token, the state-root token file removed and verified absent; `mods.ini` restored; M0 26/26; ports free; redaction grep = 0).

**Abort conditions** (any → stop issuing, inspect if possible, exit, cleanup, record): a native fault of any kind; an `applied` without a read-back; `effect uncertain` on the change (no reversal until inspected); any WARN/ERROR in the native log; any `disguise.*` or outfit change observed without a command; an `unknown` on the change (inspect; reversal only on the operator's explicit decision after the inspection); the ownership check listing more than one client or a non-HITMAN owner (do not arm).

**Rollback:** the reversal command is the only in-game rollback and only by the operator's explicit issuance after evidence; a stuck outfit after an `unknown` is restored by `reverse/2` after an inspection, or left and recorded if the generation changed; a stuck game state beyond the outfit is a run stop with the evidence preserved; the installation rollback is the mechanical cleanup; the accepted native artifact stays the M2 DLL `6047a9a3…` until a C-stage DLL is accepted on its own evidence.

**Verdicts:** provenance (hash, zero-name import diff, one detour, one call site); handshake v2 and `token_verified`; disarmed default and the effectful refusals; the gate true on a stable frame; the change `applied` with `effect changed` and `previous ≠ current == target`; later-frame native observation; operator observation; engine-consistent event or its documented absence; the reversal `applied` with `current == original`; its observations; journal contiguity; telemetry invariance; redaction; thread identities; M0 restoration; the exit-criterion statement of section 8 with its exact wording.

---

## 13. Unresolved blockers (each needs an independent decision or authorization)

1. **The target kit** — `4fc9396e…` is a candidate with partial evidence; its presence in the Paris kit map is unknown; C-1b (no code) or, failing that, C-1c (new inert read) is required before C-3.
2. **The trust requirement** — the operator's decision to change `player.outfit.set`'s trust from `:authenticated` to `:token_verified` with the residual same-user risk of 7.2 accepted for the research run, and to move the handshake to protocol v2.
3. **The schema revision** — revising the reserved v1 in place (recommended) or minting v2.
4. **The two narrow-window inspections** — still not performed (section 24.3); the C-1b run can carry them.
5. **`bIgnoreOutifChange`, the setter's thread expectation, whether the setter emits `Disguise`, whether a frontend kit streams in a mission** — unknown by source; narrowed only by C-3 and its log; stated as such in every result and report.
6. **The W1 window** (an engine event later in the same engine frame) is inherent to a frame-callback observer; the design reports it and cannot close it; the reviewer accepts or rejects that limit for a reversible suit-to-suit change.

---

## 14. Smallest safe next implementation authorization

**C-2A — BEAM effectful authorization and trust model, offline only**: the schema revision of section 5, the protocol v2 handshake with the attest exchange and the `:token_verified` state (BEAM side; the fake peer extended; the v1 native still `identified`), telemetry corroboration, one-shot effectful arming with TTL and the recorded ownership check, the `same_as_current` refusal, the `effect` / `observed` labels, `reverse/2` from the journal, `observe/2`, the late-result refinement, journal events, tests ×5, boundary and invariance tests unchanged. No native code, no DLL, no token placed anywhere, no game. Independently of C-2A and without code: the **C-1b** target-discovery run under its own runtime authorization.

**Stop. Design and read-only source investigation only: no code changed, no command enabled or implemented, no token introduced, no detour added, no DLL built or installed, no game launched; C-2A, C-2B, C-2C, C-1b, C-3, the time-scale fallback, browser controls, telemetry or recording changes, M5 completion and M6–M9 remain unauthorized.**

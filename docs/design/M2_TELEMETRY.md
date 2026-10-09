# M2 Design — Telemetry, Stage A: Bounded Mission Lifecycle

Date: 2026-10-06. Status: **Stage A implemented and tested without the game; runtime experiment proposed, not executed.** Later stages of M2 are not designed here.

Inputs: `ROADMAP.md` (M2 as written), `M1_FIRST_SEMANTIC_EVENT.md` (sections 13 to 15), ADR 0001 to 0005, `research/HITMEN_COMPILE_ARCHAEOLOGY.md` experiment 4, and the M2 orientation review of 2026-10-06, which chose the first capability and the event name. Code: ZHMModSDK `relay/m2` (from the M1 checkpoint `a28840e6`) and `relay/` in this repository.

## 1. Position in M2

`ROADMAP.md` M2 reads:

> **M2 — Telemetry.** Capture a bounded useful vocabulary: mission lifecycle, player state, kills/pacifications, disguises, items and objectives. Exit: mission summary generated from events rather than manual state inspection.

M1 left BEAM with one lifecycle fact, `mission.playing`, and no way for a mission attempt to end: after the M1 final run `MissionSession` still said `playing?: true` with the game gone. Stage A closes that bracket and nothing else. It adds the falling edge of the same predicate as `mission.stopped`, models **bounded mission attempts** in BEAM from semantic events only, routes connection evidence into the model without letting it masquerade as mission evidence, and generates a first event-derived summary.

**Stage A is not M2.** The exit sentence could be read as satisfied by a lifecycle-only summary; the goal sentence names five more vocabularies. Stage A is recorded as the first stage of M2, the roadmap's M2 text is unchanged, and whether M2 closes after a later stage is a decision to be taken explicitly, not implied by this document.

## 2. Three kinds of evidence

Everything BEAM holds is one of these, and the model never converts one into another.

| Domain | Evidence | Source | What it can say | What it cannot say |
|---|---|---|---|---|
| **Game lifecycle** | `mission.playing`, `mission.stopped` | native predicate edges, published through `IRelaySink` | the engine started / stopped reporting a mission scene as playing | why; gameplay outcome; anything about the process or the socket |
| **Adapter / process** | `adapter_instance_id` on every envelope; sequence numbers | `RelayAdapter` | which game process spoke; whether envelopes were lost (gaps); that a new process exists (new id) | that the old process ended; anything about its missions |
| **Transport** | a connection accepted, attributed to an instance, closed (with reason) | BEAM's own `Wire.Connection` | whether evidence from an instance is currently arriving | that a mission ended; that the process ended (a closed socket is consistent with both and with neither) |

The native side knows nothing about the first two beyond what it emits; the third is entirely BEAM's own observation.

## 3. The events

### Predicate (unchanged from M1)

```
MissionPlaying := scene_available
               && scene_type == "mission"
               && loading_stage == 8          (eLoading_ScenePlaying)
               && scene_loaded == true
```

Evaluated every frame from engine state (`ZEntitySceneContext::m_SceneInitParameters.m_Type`, `m_LoadingStage`, `m_pScene`, `ZApplicationEngineWin32::m_bSceneLoaded`). No hook. Unobservable state (a null global) counts as false. Stage A does not change the predicate's definition and adds no second detection mechanism.

### `mission.playing` (schema version 1)

Emitted exactly once when the predicate goes **false → true**. It says: *the engine has started reporting a mission scene as playing.* It does not say that a mission "started" in any gameplay sense, that the player has control, or that this is the first time this mission was entered.

### `mission.stopped` (schema version 1)

Emitted exactly once when the predicate goes **true → false**. It says: *the previously true `MissionPlaying` predicate is now false.* It makes **no** claim about completion, success, failure, restart, abandonment, a menu transition, process termination or any gameplay outcome. Those are derived or future semantics, and most of them are not derivable from this event alone (section 4).

Observed causes of the fall so far (M1 stage 1 and final runs): a mission restart (loaded flag drops, stage still 8, then 0 → 5 → 6 → 7 → 8 without `LoadScene`) and an exit to the menu (loaded flag drops, stage still 8, then 2 → 5 → 6 → 7 → 8 with `LoadScene` of the frontend). On the fall frame the two are indistinguishable, which is one reason the event is not allowed to say which it was.

### Payload (both events, schema version 1)

```json
{"scene_resource": "...", "scene_type": "mission", "codename_hint": "Peacock", "game_session_id": "..."}
```

Read from the **frame the edge fired on**, in both directions. For `mission.stopped` that means the scene the fall frame reports. In every observed transition this is still the scene that was playing (the scene context is replaced only by a later `LoadScene`, and never on a restart). If observability is lost while playing (an engine global becomes null), the predicate falls, `mission.stopped` is emitted, and its scene fields are **empty**: the event reports what it saw rather than repeating the rise. BEAM accepts empty fields on `mission.stopped` (not on `mission.playing`) and records that the fall scene differed. This case has never been observed in a run; it is covered by tests so that if it happens it is recorded rather than rejected.

`game_session_id` is optional and observational (section 6). Reading it on the fall frame is new in Stage A; what it holds there is one of the things the runtime experiment is meant to show.

### Envelope and delivery

Envelope v1 unchanged: one `adapter_instance_id` per process, one monotonic `sequence` across both event types, adapter-clock `timestamp`. Delivery stays *ordered, best-effort while connected*. A dropped `mission.stopped` is a gap, and BEAM's model is written for that (section 4).

## 4. Bounded mission attempt

An **attempt** is the interval between a `mission.playing` and the evidence that ends it, for one adapter instance. It is derived from game lifecycle evidence only (`GlacierRelay.Lifecycle`).

| Attempt state | Opened by | Reached by | Meaning |
|---|---|---|---|
| `:playing` | `mission.playing` | — | open; **last known** playing |
| `:stopped` | | `mission.stopped` from the same instance | the predicate fell; stop time is the event's timestamp; duration is computable |
| `:superseded` | | another `mission.playing` from the same instance while this one was open | its end was **not observed** (normally with a sequence gap); it is not marked stopped |

Rules:

- `mission.stopped` with no open attempt is kept as an *unmatched stop*; no attempt is invented for it.
- Attempts are paired by **order within the instance**, never by scene or session id.
- Two consecutive attempts on the same scene are two attempts. The model has no `restart` field. Distinguishing a restart from "exit to menu, then the same mission again" needs scene-level evidence that Stage A does not emit; labelling it now would be a guess.
- No field says completed, failed, exited, quit or abandoned. The engine offers no such signal in the predicate, and nothing in Stage A observes one.

### Interaction with transport evidence

When the connection attributed to an instance closes while an attempt is open, the attempt gets an **interruption** record (time, reason) and stays `:playing`. The instance's `observation` becomes `:lost`. The summary then reads: *stop not observed; last known playing; observation lost at T (reason)*. No stop time is fabricated from the close. If the same instance later delivers `mission.stopped` (the native sink reconnects with the same instance id), the attempt closes from that evidence, keeping the interruption as history.

## 5. Why TCP disconnect does not imply mission termination

`tcp_closed` means: *the Relay adapter connection disappeared.* It is consistent with the game having quit from a mission, with the game having quit from the menu, with the sender thread's socket having failed while the game runs on, with a WSL2 forwarder hiccup, and with a BEAM-side error. It carries no timestamp from the game, no scene, and no sequence number. Treating it as `mission.stopped` would assign a mission end time that no game evidence supports and would make BEAM's summary differ depending on which of those unrelated things happened.

Experiment 4 (F9) showed the game ends by terminating its own process with no DLL teardown, so there will never be a native "goodbye". That is why the model needs an honest representation of *last known playing with the source lost*, and why the Stage A runtime experiment ends with a quit from inside a mission: to learn which of the two possible native outcomes occurs (section 11), not to force one.

Conversely, `tcp_connected` is not `mission.playing`: a socket exists from the main menu onward and before any event. BEAM cannot even attribute a socket to an instance until its first valid envelope arrives; until then it is an unidentified connection, and if it closes first it stays one. Stage A deliberately does not add an `adapter.started` event to close that gap.

## 6. Session id non-authority

`game_session_id` is copied from the player registry's inline slot 0 when readable on an edge frame. It has changed on every mission entry observed, including restarts, and persisted at the menu (experiment 4, F7). Its semantics are not established. It is **not** used as attempt identity, pairing key, deduplication key, adapter identity or protocol identity, in native code or in BEAM. The model records the value seen at the rise and at the fall of each attempt as observational payload, so the runtime experiment can show whether it changes before or after the fall without anything depending on the answer.

## 7. BEAM model

```
GlacierRelay.Lifecycle            pure: Instance / Attempt / Connection / Observation; apply_event,
                                  connection_identified, connection_closed, observation, duration_ms
GlacierRelay.Summary              pure: build/1 (data), render/2 (text) from Instances
GlacierRelay.MissionSession       GenServer: instances by adapter id, live connections by pid,
                                  unidentified closed connections (bounded), subscribers
GlacierRelay.Wire.Connection      reports open, each validated envelope with its receipt time, close reason
GlacierRelay.Events               mission.playing v1, mission.stopped v1
```

`Instance` keeps `last_sequence`, `received`, `gaps`, `last_event`, ordered `attempts`, `unmatched_stops`, and `connections` (newest first; each with peer, opened/identified/closed times and close reason). `observation/1` is `:never`, `:live` or `:lost`, derived from the newest connection. The M1 `playing?` flag is gone; its two meanings are now `current_attempt/1` (last known playing, or nil) and `observation/1`.

Every observation records both the adapter's `timestamp` and BEAM's `received_at`, so the gap between them is available and so transport evidence (which has only BEAM time) is never confused with game evidence (which has adapter time).

### Summary semantics (Stage A)

`MissionSession.summary/0` (data) and `summary_text/0` (text) describe, per adapter instance, oldest first:

- events received, last sequence, gaps, current observation status;
- each connection attributed to the instance: peer, opened, identified, closed, close reason;
- each attempt: number, scene and codename, `playing` timestamp and sequence, then one of: `stopped T (#n), duration D` / `stop not observed; last known playing` / `stop not observed; superseded by attempt n`; plus `observation lost T (reason)` for each interruption; the session id at rise and fall;
- unmatched stops;
- and, outside any instance, connections that closed before identifying one.

Every line is a statement about evidence. The words restart, completed, failed, exited and ended do not appear in the renderer, and the summary tests assert that they do not.

## 8. Native changes (`relay/m2`)

| Commit | Change |
|---|---|
| `605697c3` M2-R1 | `RelayAdapter::Publish` logs `published <type> #<seq>: <json>` once, before the sink, so the complete envelope is on the native side whichever sink is active; `LogRelaySink` logs only `log sink: delivered <type> #<seq>`; `TcpRelaySink`'s queued/sent lines unchanged (transport, not semantics) |
| `b01a0833` M2-R2 | `MissionObserver::Update` returns `std::optional<MissionEvent>` (`variant<MissionPlayingEvent, MissionStoppedEvent>`), one edge per frame in either direction; `MissionScenePayload` shared by both; `RelayAdapter` gains one `Publish` overload per type plus one for the variant, all through one envelope builder (one sequence); the plugin reads the registry session id on either edge frame |
| `bf8908ce` M2-R3 | wire probe `stop` step; its `stage1` replay now yields six edges |

Layering and boundary as in M1: the semantic layer, events, envelope, adapter and sinks include no SDK header, and `GlacierRelayTests` still compiles them without the SDK on its include path. No hook, no engine write, no new engine read beyond the existing session-id slot, no new import.

## 9. What remains unknown

Carried into the runtime experiment or beyond; none is assumed by the model.

1. **Other exit paths.** Only restart and exit-to-menu have been observed to drop the predicate. Mission completion (the debrief is presumably still the mission scene at stage 8, so the fall would come when leaving it), death and retry, loading a save, and quit-to-desktop have not been observed.
2. **Quit from inside a mission.** Whether the native observer sees the predicate fall before the process terminates (`mission.stopped` then close) or not (`mission.playing` last known, then close). Both are valid results; the model represents both.
3. **Session id at the fall frame.** Same as at the rise (changes on the next entry) or already different.
4. **Flicker.** Three clean rise/fall pairs so far. A true→false→true within a few frames would produce a real pair of events; the model would record a very short attempt, which is what happened, but it would be worth knowing.
5. **Scene types other than `"mission"` and `""`.** Never observed; not needed by Stage A.
6. **Observability loss while playing** (empty-payload `mission.stopped`). Covered by tests, never observed.

## 10. Explicitly deferred

`scene.changed`, `adapter.started`, player telemetry, kill/pacification telemetry, disguise telemetry, inventory telemetry, objective telemetry, actor enumeration, actor identity, SDK player-registry fixes, second Hitman, inbound commands, stronger delivery guarantees. Each needs its own decision.

## 11. Proposed Stage A runtime experiment (NOT executed; requires explicit authorization)

Same discipline as the M1 final run (`M1_FIRST_SEMANTIC_EVENT.md`, section 14 step list): pre-flight hashes, BEAM up first, two game-directory changes, debugger attached after the menu, rollback and hash verification.

Script:

```
launch → menu → attach VS → Paris → walk → restart → exit to menu → Sapienza → walk
       → quit to desktop directly from inside Sapienza (pause menu, not via the main menu)
```

The in-mission quit is the point of the run. Expected envelopes:

| Step | Expected |
|---|---|
| menu | no event; BEAM: `accepted`, connection unidentified |
| Paris load | `mission.playing #1`; BEAM: connection identified, attempt 1 open |
| Paris restart | `mission.stopped #2` (fall; scene Paris), then `mission.playing #3`; attempt 1 stopped with a duration, attempt 2 open |
| exit to menu | `mission.stopped #4`; attempt 2 stopped |
| Sapienza load | `mission.playing #5`; attempt 3 open |
| quit from inside Sapienza | **either** `mission.stopped #6` then TCP close (attempt 3 stopped, then observation lost) **or** TCP close with no #6 (attempt 3 last known playing, observation lost at the close) |

Pass criteria (both quit outcomes pass; the criterion is faithful representation):

1. Native log and BEAM agree field by field on every envelope (`published` lines versus decoded events), including `game_session_id` on both edges.
2. Exactly one `mission.stopped` per observed fall, strictly alternating with `mission.playing`; no event at the menu; no flicker pairs (any sub-second attempt is recorded and reported as a finding, not hidden).
3. `MissionSession.summary_text()` after the quit describes three attempts: 1 and 2 stopped with durations matching native timestamps; 3 either stopped (if #6 arrived) or *last known playing; observation lost* with the close time and `:peer_closed`; nothing in the summary says restart, completed, failed or exited.
4. No gaps, no drops, no rejected lines; one adapter instance; sequences contiguous.
5. No `WARN`/`ERROR`/`FAULT` in the native log beyond the expected ones; game stable; exit code 0; rollback verified by hash.

Record as findings, whichever way they fall: which quit outcome occurred; the session id at each fall versus the preceding rise; the fall-frame scene fields; the time between the predicate fall and BEAM's receipt; whether the Paris restart fall and the exit-to-menu fall look the same at the fall frame (they did in experiment 4).

If a second run is wanted later for Q1 (completion, death/retry, save load), it is a separate authorization.

---

## 12. Stage A implementation record (2026-10-06)

Authorized as "M2 Stage A — Bounded Mission Lifecycle" with the event name `mission.stopped`, its narrow semantics, the three-domain modelling rule, and a hard stop at the runtime gate. **Built and tested without the game. `GlacierRelay.dll` has not been deployed since the M1 final run.** The Stage A runtime experiment (section 11) needs its own authorization.

### Commits

ZHMModSDK `relay/m2`, from the M1 checkpoint `a28840e6`: `605697c3` M2-R1, `b01a0833` M2-R2, `bf8908ce` M2-R3 (section 8). 14 files, +292/−72.

glacier-relay `main`, from `53d4346`:

| Commit | Change |
|---|---|
| `72316b5` | `Events`: `mission.stopped` v1 validation; empty scene fields accepted for the stopped event only |
| `07dd2e5` | `Lifecycle` (pure model: Instance, Attempt, Connection, Observation) and `Summary` (data and text) |
| `bcbb622` | `MissionSession` routes connection evidence; `Wire.Connection` reports open, receipt time per event, close reason; `playing?` removed in favour of `current_attempt/1` and `observation/1`; listener tests |
| `8aba482` | fixture of the six native-produced Stage A envelopes and its test |

### Tests

| Layer | Coverage | Result |
|---|---|---|
| Native `GlacierRelayTests` (107 checks: 46 observer, 32 adapter, 29 TCP sink) | predicate unchanged; rise and fall on the experiment-4 timeline with 100 duplicate frames while true and 50 while false; session id on both edges and absent on both; observability loss as a fall with an empty payload and regain as a rise; strict alternation over an adversarial frame list; the full M1 final-run timeline → exactly `+Paris −Paris +Paris −Paris +Sapienza −Sapienza`; stopped payload and exact envelope text; one sequence across both types, also through the variant; UUID, clock; the M1 sink tests unchanged | all pass, from a clean tree |
| Elixir `Lifecycle` (14) | new instance; playing→stopped with duration 66 013 ms from the M1 timestamps; open attempt; M1 timeline with falls → three stopped attempts and no restart field; playing-while-open → superseded with a gap; stopped with no open attempt → unmatched; fall scene differing from rise; close with no open attempt; close while open → last known playing, interruption, no duration; stop after reconnect closes from evidence; reconnect with no events invents nothing; close with no connection; gaps; unparseable timestamp | 14 pass |
| Elixir `Summary` (4) | build and render of the proposed Stage A run in the quit-without-stop outcome; superseded and unmatched rendering; empty state and unidentified connections; the words restart/ended/complete absent | 4 pass |
| Elixir `Envelope` (10) | M1 tests plus: `mission.stopped` decodes; empty scene fields accepted; malformed stopped rejected (missing/mistyped fields, bad session id type, schema v2, non-object payload) | 10 pass |
| Elixir `Listener` (18, over TCP) | M1 tests plus: open/close with no event stays unidentified; playing then stopped is one bounded attempt with `received_at`; close with no open attempt; close while open → last known playing, no stop invented; stop then close; reconnect with the same id resumes observation and closes the open attempt; replacement connection with a new id invents nothing for the old; malformed stopped rejected and attempt stays open; gaps across both types; summary from delivered events | 18 pass |
| Elixir `Framing` (5), fixture (2) | unchanged; the six native envelopes decode, alternate, and fold to three bounded attempts | pass |

54 Elixir tests, run 5× without a failure.

### Clean native build and inertness

`_build/relay-x64-Debug` deleted; configure, build and tests at `bf8908ce`: pass, no warnings from relay sources. `GlacierRelay.dll` SHA-256 `9e978ac9c4cc95ecf3302e38ef7b6c16086b5512bfb532c1ee82cf7d28ce1ace`.

| Check | Result |
|---|---|
| Imports | `ZHMModSDK.dll`, `KERNEL32`, `USER32`, `SHELL32`, `IMM32`, `WS2_32` — the M1 set. `WS2_32`: the same 14 client-side functions (closesocket, connect, htons, inet_pton, ioctlsocket, recv, select, send, setsockopt, socket, WSAStartup, WSACleanup, WSAGetLastError, __WSAFDIsSet); no `listen`, `accept`, `bind` |
| Exports | the three SDK plugin exports only |
| Hooks | none (`AddDetour` absent) |
| Engine writes | none (`SetProperty`, `SetWorldMatrix`, `SetObjectToWorld*` absent) |
| Boundary | SDK headers only in `GlacierRelay.cpp` and `SceneObservation.cpp`; `GlacierRelayTests` still builds every other source without the SDK include path |
| New engine reads | none; the session-id slot read now also happens on the fall frame |
| SDK core, Hitmen | unchanged, untouched |

### Standalone wire tests (Windows probe → WSL2 BEAM, no game)

BEAM `mix run` with a subscriber script; `GlacierRelayWireProbe.exe` from the clean build on Windows, log directory `%TEMP%\glacier-m0\hitmen\wire-probe\m2\`.

| Run | Script | Native | BEAM |
|---|---|---|---|
| A | `sleep:1500,stage1,sleep:1000` (the M1 scene timeline through the real observer) | instance `cba1b5ec…`; `published` lines with full JSON for #1..#6, alternating playing/stopped (412/335/412/335/403/326 bytes); `sent #1..#6`; clean disconnect | `accepted` → identified at #1 → six events, each logged ~1 ms after its native timestamp → `closed (:peer_closed)`. Summary: three attempts, all stopped, durations 204/203/202 ms (the probe's 200 ms pacing), `observation lost`, gaps `[]` |
| B | `sleep:1500,publish,sleep:500` then process exit (the in-mission-quit shape) | instance `066392b0…`; `published mission.playing #1`; `sent #1`; exit | one event, then `closed (:peer_closed)`. Summary: `attempt 1: Peacock …: playing … (#1), stop not observed; last known playing; observation lost 2026-10-06T23:34:18.277Z (:peer_closed)`; warning logged `connection … closed while attempt 1 is last known playing; no mission.stopped observed`; no stop time fabricated |

Native and BEAM envelopes compared field by field in run A (instance id, sequence, timestamp, event type, schema version, scene fields, session id present on rises and absent on falls as the probe supplied them): identical. Native logs SHA-256 `20f4032d…` (A), `1dd8aff9…` (B); BEAM outputs `beam-a.log`, `beam-b.log` beside them; the six run-A envelopes are committed as `relay/test/stage_a_probe_envelopes.ndjson`.

### Not done, by design

No deployment into HITMAN, no game launch, no file under the game directory touched. The M2 exit criterion in `ROADMAP.md` is unchanged. Stage A is **not** M2 completion (section 1).

---

## 13. Stage A runtime experiment (2026-10-06, 23:53Z to 2026-10-07 00:06Z) — PASS, outcome B

Authorized explicitly, with the fall-edge session-id read allowed as optional observational metadata and both in-mission-quit outcomes declared valid. Objective: validate the bounded-attempt model against the live runtime, keeping observed mission lifecycle, observation availability and transport lifecycle distinct.

Setup: `GlacierRelay.dll` from `relay/m2` `bf8908ce` (SHA-256 `9e978ac9…1ace`, byte-identical copy), M0 mod set plus GlacierRelay, `mods.ini` byte-identical to the M1 run's, defaults (`tcp`, 4747). BEAM: `elixir --sname relay -S mix run --no-halt` with a subscriber script, output captured, state read over RPC. Pre-flight: game `3.280.0.0` / build `24833614`, all 26 M0 hashes, 107-file `Retail` baseline identical to the M1 pre-flight, no stale artifacts, `mods.ini` = M0 (`b90b4c5e…`), both repositories clean (`bf8908ce`, `4bc474e`), OTP 28.4.2 / Elixir 1.19.6, port free on both sides. Two game-directory changes, both reverted. Operator attached Visual Studio after the menu connection; symbols loaded for `GlacierRelay.dll`; no exception line at any point.

### Event sequence (complete)

| # | Event | Native timestamp | BEAM receipt (Δ) | Scene | Fall/rise frame | `game_session_id` |
|---|---|---|---|---|---|---|
| — | connection | 23:53:14.424Z connected | accepted 23:53:14.442Z | menu 5 → 8, type empty | — | — |
| 1 | `mission.playing` | 23:58:15.172Z | +33 ms (first decode) | Paris / Peacock | stage 8 + loaded, same frame | **A** `2516109697203110658-17f5ff3e…` |
| 2 | `mission.stopped` | 23:59:51.671Z | +3 ms | Paris / Peacock | loaded false, stage still 8 | **B** `2516109696087575442-babec0aa…` |
| — | restart | 0 → 5 → 6 → 7 → 8, no `LoadScene`, resource unchanged | | | | |
| 3 | `mission.playing` | 00:00:02.498Z | +2 ms | Paris / Peacock | stage 8 + loaded | **B** (same as #2) |
| 4 | `mission.stopped` | 00:02:08.469Z | +1 ms | Paris / Peacock | loaded false, stage still 8 | **B** (same as #3) |
| — | exit to menu | 2 → frontend 5 → 6 → 7 → 8 | | | | no event |
| 5 | `mission.playing` | 00:04:20.206Z | +2 ms | Sapienza / Octopus | loaded true at stage 7 (00:04:20.031Z), event at stage 8 | **C** `2516109693561278430-4afc9528…` |
| — | quit from inside Sapienza | native log ends at `sent #5` | TCP close 00:06:05.322Z (`:peer_closed`) | — | **no fall observed** | — |

Sequences 1 to 5 contiguous; types strictly alternating; one `mission.stopped` per observed fall; no event at the menu (three times); no duplicate edge; no flicker (shortest attempt 96.5 s). Native `published` lines and BEAM decoded envelopes agree field by field on all five (protocol 1, instance `2dd57c3e-98ae-472f-ba88-c9f30ceeee92`, sequence, timestamp, type, schema 1, three scene fields, session id).

### Final BEAM state (`summary_text/0`, after the process exit)

```
adapter 2dd57c3e-98ae-472f-ba88-c9f30ceeee92: 5 event(s), last sequence 5, gaps [], observation lost
  connection 127.0.0.1:52582: opened 2026-10-06T23:53:14.442354Z, identified 2026-10-06T23:58:15.204677Z, closed 2026-10-07T00:06:05.322185Z (:peer_closed)
  attempt 1: Peacock (.../Paris/_Scene_FashionShowHit_01.entity): playing 2026-10-06T23:58:15.172Z (#1), stopped 2026-10-06T23:59:51.671Z (#2), duration 96.5 s
  attempt 2: Peacock (.../Paris/_Scene_FashionShowHit_01.entity): playing 2026-10-07T00:00:02.498Z (#3), stopped 2026-10-07T00:02:08.469Z (#4), duration 126.0 s
  attempt 3: Octopus (.../CoastalTown/Mission01.entity): playing 2026-10-07T00:04:20.206Z (#5), stop not observed; last known playing; observation lost 2026-10-07T00:06:05.322185Z (:peer_closed)
```

Two bounded attempts from semantic events only; one unbounded attempt; the connection's close recorded as transport evidence on the instance and as an interruption on attempt 3; no stop timestamp fabricated; `summary/0` and `state/0` saved in `beam-final-state.txt`. BEAM logged the expected warning: `connection … closed (:peer_closed) while attempt 3 is last known playing; no mission.stopped observed`.

### Findings

1. **Direct in-mission quit is outcome B.** The native log's last line is `sent #5`; no scene change, no predicate fall, no `mission.stopped`, no detach. The process terminated before the frame update observed anything (consistent with F9: self-termination, no loader teardown; Visual Studio: every thread exit 0, `exited with code 0`, no module unloads). The native observer therefore cannot see a mission end that coincides with process exit, and BEAM's only evidence is the TCP close 105 s after #5. The model represented exactly that.
2. **The fall frame is the same on both observed fall paths**: loaded flag false with the stage still 8 and the scene context still the mission's. Restart and exit-to-menu are indistinguishable at the fall, as the design assumed.
3. **Fall-edge session id behaves differently on the two fall paths.** On the restart fall (#2) the slot already held the *upcoming* attempt's id (B, the value #3 then carried), so the registry changed before the scene unloaded. On the exit-to-menu fall (#4) the slot still held the *stopped* attempt's own id (B). Both reads were clean (no fault, well-formed `<decimal>-<guid>`). Nothing keys on this; it is recorded as two data points, not a rule. The leading decimal again decreased monotonically (A > B > C).
4. **Latency**: 33 ms for the first event (first decode path), 1 to 3 ms thereafter, on the same connection throughout.
5. **One connection for the whole process**: connect at 23:53:14, identified at #1 (4 min 61 s after accept, during which BEAM correctly held it as unidentified), five sends, close at 00:06:05. No reconnects, no drops, no rejected lines, no inbound bytes.
6. **Native health**: 58 lines, 0 `WARN`/`ERROR`/`FAULT`, two threads (frame thread and sender thread), no debugger break, game stable, normal exit.

### Pass criteria

All met: every native semantic event appears identically in BEAM; sequences contiguous; alternation per observed edges; no duplicate edges; no menu event; attempts bounded only by semantic evidence; TCP closure fabricated no stop; connection evidence separate from mission evidence; the summary distinguishes observed from unobserved; no fault, no unexpected break, no instability. Session ids compared field by field on all five events.

### Cleanup

BEAM stopped (`:init.stop/0` over RPC); `GlacierRelay.dll` removed; `mods.ini` restored from the M0 backup (`b90b4c5e…`); all 107 `Retail` files and the listing verified identical to this run's pre-flight baseline (itself identical to M1's); no relay or Hitmen file under the game root; nothing new in `Runtime`; port 4747 free on both sides. Evidence in `%TEMP%\glacier-m0\hitmen\m2-run1\` (native log SHA-256 `d6028603…7fa8`, `beam.log`, `beam-final-state.txt`, SDK log, `mods.ini` before/relay/after, `Retail` listings and hashes).

### Implications for the M2 lifecycle model

- The bounded-attempt model held against the live runtime without adjustment; the three evidence domains stayed separate under the one condition designed to confuse them.
- "Last known playing; observation lost" is a **normal end state** for the last attempt of a session that ends by quitting from a mission, not an edge case. Any later summary, recorder or dashboard must present it as such rather than as an error or as an ended mission.
- If a future stage wants an end time for that attempt, it has to come from new evidence (an engine signal that precedes termination, or a BEAM-side policy that is explicitly labelled as inference), never from the socket close.
- Restart versus exit-to-menu remains underivable from Stage A events alone (finding 2); the session-id behaviour (finding 3) is suggestive but is not to be used.
- Stage A is validated. **M2 is not complete**: lifecycle is the first of the roadmap's vocabularies. Stage B and the other vocabularies need their own decisions.

---

# Part B — M2 telemetry architecture after B0 (2026-10-07)

Status: **proposal for review; nothing implemented.** Inputs: ADR 0006, `research/ACTOR_OUTCOME_ARCHAEOLOGY.md` sections 12 to 15, `research/B0_EVENT_TAXONOMY.md`. The question is no longer how to detect kills; it is how Relay consumes the semantic telemetry Glacier already produces without becoming coupled to Glacier's backend protocol.

## 16. Evidence hierarchy

As decided in ADR 0006: (1) engine-authored semantic occurrence from `OnEventSent` for *what Glacier recorded*; (2) engine state observation for *what state the runtime is in* and for facts the stream lacks; (3) pins for archaeology and ordering only. The scene predicate from M1/Stage A is rank 2 evidence and remains the thing that bounds a Relay mission attempt (section 20).

## 17. Normalization boundary

```
Glacier  ZAchievementManagerSimple::OnEventSent(th, index, ZDynamicObject)     engine memory
   │  detour, log-and-continue, inside the fault guard; frame thread
   ▼
Raw observation      GlacierEvent { name, contract_session_id, contract_id, timestamp_s,
                                    value (engine-independent tree), has_dontsend, event_index }
   │  TelemetryObservation.cpp (Glacier-facing: walks the ZDynamicObject, copies plain values;
   │  never hands the ZDynamicObject upward)
   ▼
Normalization / policy   TelemetryNormalizer (engine-independent, unit-tested against the B0 corpus)
   │  - recognizes supported names (a bounded table), ignores the rest with a counter
   │  - applies the _DONTSEND and duplicate-emitter policies
   │  - validates required fields and types per (name, expected shape)
   │  - maps to a Relay-owned event + schema version, choosing fields deliberately
   │  - attaches provenance
   ▼
Relay semantic event     e.g. actor.killed v1, actor.pacified v1, (later) disguise.changed v1 …
   │  RelayAdapter: instance id, one monotonic sequence, timestamp, envelope v1 (unchanged)
   ▼
IRelaySink  →  TcpRelaySink  →  BEAM: Wire.Envelope → Events.validate(name, version) → Lifecycle / Summary
```

Responsibilities of the normalizer, stated so the adapter cannot drift into a proxy:

| Responsibility | Rule |
|---|---|
| Recognize | A static table of supported Glacier event names, each with the Relay event it maps to and the schema version. Unknown names are counted and (in the durable log only) named; they never cross the sink. |
| Validate | Required `Value` fields and their types, per name, written from the captured corpus. A recognized event that fails validation is logged with the failing field and dropped; the sequence does not advance. |
| Map | Field by field into Relay-owned names and types. Numbers that are engine enums (`KillType`, `KillContext`, `ActorType`) are mapped to Relay strings (`pacify`/`kill`/`bloody_kill`; `accident`/`murder`/`hidden`/`not_hero`/`undefined`; `civilian`/`guard`/`hitman`) with an `unknown(<n>)` fallback that preserves the number. Floats that are integers in meaning are emitted as integers. |
| Provenance | Every normalized event carries `source: {surface: "glacier.telemetry", name: "<Glacier Name>", contract_session_id, timestamp_s}`. BEAM can always say which engine event produced a Relay event. |
| Unsupported | Not forwarded. Counted per name; counts appear in the native log at attempt end so the corpus can grow deliberately. |
| Raw retention | Fields that are useful as *observation* but carry no Relay semantics yet (e.g. `ActorId`, `RoomId`, positions) are either omitted or placed under an explicit `observed` sub-object, never promoted to identity or keys. Positions are omitted until a use exists. |
| Client-only | Events with `_DONTSEND` are not normalized (section 18). |
| Duplicate emitters | Names known to be emitted twice per occurrence (`Spotted`) are paired by `(Name, Timestamp, Value)` before mapping, documented per name; nothing else is deduplicated. |
| Engine independence | Nothing below the raw observation sees a `ZDynamicObject`, a `ZString`, a pointer or an offset. The normalizer and its tests compile without SDK headers, like the rest of the engine-independent set. |
| Identifiers | `UserId`, platform `SessionId`, `XboxGameMode`, `XboxDifficulty` are dropped at the raw-observation step. `ContractSessionId` is kept as observational provenance (section 20). |
| Evidence log | The adapter's existing `published` line remains the native record of what crossed the sink. The complete raw event is logged only when a diagnostic setting is on (`[relay] telemetry_log = raw`), so the stream's shape can be re-captured on a new build without redeploying a probe. |

What the boundary refuses: a generic `glacier.event` carrying arbitrary `Value` JSON; forwarding by name without a schema; letting BEAM parse Glacier field names; making the Relay protocol version depend on IOI's event schema.

## 18. `_DONTSEND` policy

Evidence (B0): the marker is a **top-level key in the event object itself** (`"_DONTSEND": true`), present on all 22 `ChallengeCompleted` events and on nothing else; those events lack `ContractSessionId` and `ContractId` while keeping `Timestamp`, `Origin: "gameclient"` and an `Id`. The hook sees them because `OnEventSent` is the event manager's intake for every event the client raises, before the transmission path; the transmission path evidently honours the flag, since the backend later delivered its own authoritative `ChallengeCompleted` for **all ten** distinct challenge ids the client had raised locally. The string does not occur in the SDK source or history; Peacock treats `ChallengeCompleted` as a server-emitted event. Conclusion for this build: `_DONTSEND` marks client-local notifications of facts the backend owns and will restate.

Policy: **do not normalize events marked `_DONTSEND` unless Relay has a specific, documented reason to observe the client-local fact.** Record them in the raw diagnostic log and count them. If a future vocabulary wants challenge completions, the decision is taken per name, in the normalizer table, with the reason written next to it (for example: "client-side challenge notification; useful offline where no backend restates it"). The policy is narrow on purpose: it is keyed on the flag, not on the event name, so a `_DONTSEND` on a new name is handled the same way.

## 19. Contract session versus Relay mission attempt

Promoted to documented fact for this build: **the registry value Stage A called `game_session_id` is the backend's `ContractSessionId`.** Three independent matches: the Stage A Sapienza value equals the `ContractSessionId` the backend later resolved as `OrphanedSession`; the Stage A Paris values have the same `<decimal>-<guid>` form and monotonic leading number as B0's `ContractSessionId`s; both are read from player slot 0 where the contract session lives. Documentation should use the name `contract_session_id` from here on, with "observational" still attached: it identifies a *Glacier contract session*, not a Relay attempt.

| | Relay mission attempt | Glacier contract session |
|---|---|---|
| Bounded by | scene predicate rise/fall (state, rank 2) | `ContractStart` / `ContractFailed` or `ContractEnd` (stream, rank 1) and the backend's `SegmentClosing` |
| Identity | `(adapter instance, attempt number)` | `ContractSessionId` |
| Observed relationship (Stage A + B0) | restart: the registry already held the *next* session id at the fall frame; `ContractFailed("…OnRestartLevel")` came ~1.9 s **before** the fall (originally written here as 0.3 s; corrected from the B0 log timestamps in section 26, finding 2); `ContractStart` of the new session came in the same frame as the next rise | exit to menu: `ContractFailed("…exit to Main menu")` in the **same frame** as the fall; the registry kept the old id |
| Quit from inside a mission | attempt stays "last known playing; observation lost" | nothing sent; the backend resolves `OrphanedSession` on the next launch |

So: one attempt ↔ one contract session in every case seen, but the boundaries differ by up to a few hundred milliseconds and in a different direction per path, and the session id changes before the scene does on restart. They must not be merged. What can now be stated **directly from engine evidence**: that a contract session started (`ContractStart`, with loadout, location, difficulty, type); that it ended, and whether by restart or by exit to menu (`ContractFailed` reason); which session an actor outcome belongs to (`ContractSessionId` on every event). What remains **correlation**: the attempt ↔ session pairing itself, done by BEAM by order within the adapter stream (a `ContractStart` observed between an attempt's `mission.playing` and `mission.stopped` is that attempt's session), and never by the session id.

Proposal (**superseded by section 27.6 after the B1 runtime evidence**; kept as the pre-runtime position): do **not** introduce public `contract.started` / `contract.failed` Relay events in the first stage. Normalize `ContractStart` and `ContractFailed` into **attempt enrichment**: a `mission.contract` observation (Relay event, schema v1, carrying `contract_session_id`, `contract_id`, `location_id`, `contract_type`, `difficulty`, `loadout` summary) and a `mission.contract_ended` observation (`reason` as the engine string plus a mapped `kind: restart | exit_to_menu | other`). BEAM attaches them to the open attempt; the summary gains "ended by restart / by exit / not observed" from engine evidence; `Attempt.mission` stays `:playing | :stopped | :superseded`, bounded by the predicate. Whether these later become public lifecycle events is decided when a consumer needs them.

## 20. Revised actor-outcome model

| Point | Before B0 | After B0 |
|---|---|---|
| Primary surface | undecided between S1 and S2 | S1 `Kill` / `Pacify` |
| Relay events | `actor.died` / `actor.pacified` hedged on evidence | **`actor.killed` v1** and **`actor.pacified` v1** — the engine's own words, now known to be the engine's own classification (`EDeathType` 4/5 and 3) rather than a Relay inference. "killed" here means *Glacier recorded a Kill*; attribution to the player is still only what `context` says |
| Fields | proposal in archaeology §8 | `actor: {repository_id, name, type}`, `is_target`, `outcome: {kind: kill\|bloody_kill\|pacify, context: murder\|accident\|…, class, method_broad, method_strict, damage_events[], accident, silenced, headshot, projectile, explosive, through_wall}`, `item: {repository_id, category}` when present, `history_count`, `source` provenance. Omitted: positions, `RoomId`, `PlayerId`, `ActorId` (not identity), outfit fields (disguise domain), `EvergreenRarity`, `IsReplicated`. |
| Identity | undecided | `repository_id` + `name` from the event. Unique for the 16 named NPCs seen; 30 of 338 Paris actors share a repository id (generics), so two same-character outcomes are distinguishable only with S2 correlation, which the first stage does not do. Documented limitation. |
| Pacify → Kill | "two legitimate events?" | Yes: two events, same actor, in order; BEAM keeps both on the attempt's actor timeline; counting rules (a pacified-then-killed actor counts once as killed) live in the summary, not in the adapter |
| Dedup | native dedup by key proposed | **none.** Exactly one `Kill`/`Pacify` per occurrence was observed; any suppression would be invention. Multiplicity policy exists only for named duplicate-emitter events (`Spotted`). |
| Recovery | hypothetical | real (one case) and invisible on S1. Not in the first stage; when wanted it is an S2 requirement (`IsPacified` fall for a known pacified actor), justified on its own. |
| Classification | S1 only | confirmed: `ActorType` (guard/civilian), `IsTarget` |
| Causality | S1 only | confirmed and richer than expected: `KillContext`, `Accident`, method, item, `History` |
| `IsDead()` | candidate death signal | "down"; not used for death |

## 21. S2 and S3 in production

**S2** is a *state / correlation / gap-fill* surface, not a fallback semantic detector. Legitimate future requirements, each to be justified separately: actor recovery after pacification; current state of a specific actor; resolving a telemetry `repository_id` to a specific live entity when repository ids are shared; re-validating a new game build; facts absent from the stream. No continuous actor scan ships in `GlacierRelay` because the probe ran one. The existing per-frame scene predicate stays (it is cheap, hook-free, and bounds attempts).

**S3**: B0 gave ordering and one bit (`PacifiedData`) from logic entities, nothing identifying and nothing a Relay consumer needs. Leave the pin hook in the probe branch as archaeology tooling; do not add it to `GlacierRelay`.

## 22. Organizing M2 around the stream

Yes. The roadmap's vocabularies map onto stream events that already exist (taxonomy): lifecycle (`ContractStart/Failed`), kills/pacifications (`Kill/Pacify`), disguises (`Disguise`, `DisguiseBlown`, `BrokenDisguiseCleared`, `StartingSuit`), items (`ItemPickedUp/RemovedFromInventory/Thrown[/Dropped]`), objectives (`ObjectiveCompleted`), player state (`Trespassing`, `HoldingIllegalWeapon`, `Hero_Health`/`Hero_Dead` unobserved). Each later stage is therefore mostly a normalizer table entry, a Relay schema, BEAM validation and summary lines, and a short controlled run — not an archaeology project.

Proposed sequence, chosen from what B0 showed to be well-formed and what the summary needs first:

| Stage | Content | Why here |
|---|---|---|
| **B1** | Normalization infrastructure: the `OnEventSent` detour in `GlacierRelay`, `TelemetryObservation` (Glacier-facing), `TelemetryNormalizer` (engine-independent, table-driven), provenance, `_DONTSEND`/duplicate policies, unknown-name counters, raw diagnostic log setting; **first vocabulary: actor outcomes** (`actor.killed`, `actor.pacified`) because they are the best-evidenced payloads, the probe's controlled case, and the roadmap's named next item | one hook, one table, the hardest schema; proves the boundary |
| B2 | Contract lifecycle as attempt enrichment (`mission.contract`, `mission.contract_ended`) | settles restart vs exit on the summary from engine evidence; needs a completed-mission run to see `ContractEnd` |
| B3 | Disguise (`Disguise`, `DisguiseBlown`, `BrokenDisguiseCleared`, `StartingSuit`) | string payloads, trivially validated; outfit-name resolution via the repository is the only work |
| B4 | Items (`ItemPickedUp`, `ItemRemovedFromInventory`, `ItemThrown`, `ItemDropped`) | one shared item shape |
| B5 | Objectives (`ObjectiveCompleted`; plus whatever a completed mission emits) | needs the completion run |
| B6 | Player state (`Trespassing`, `HoldingIllegalWeapon`, `Hero_Health`, `Hero_Dead`) | needs a run where 47 is hurt and dies |
| B7 | Event-derived mission summary v2 across all of the above; decision on M2 completion | the roadmap exit |

Detection/body/witness events, `AmbientChanged`, `SecuritySystemRecorder` and combat totals are candidates after B7 or when a rating-style summary is wanted; `Level_Setup_Events`, `Investigate_Curious`, `setpieces` are not planned.

## 23. Exact smallest next implementation stage (B1) — not authorized

Native (`relay/m2`, from `bf8908ce`, one root cause per commit):

1. `TelemetryObservation.{h,cpp}` (Glacier-facing): detour on `ZAchievementManagerSimple_OnEventSent`, log-and-continue, in the fault guard; converts the `ZDynamicObject` into `GlacierEvent` (plain tree of strings/numbers/bools/lists/maps) via the SDK's dynamic-object accessors (not via `ToString` + parse); drops user/platform identifiers; detects `_DONTSEND`.
2. `TelemetryNormalizer.{h,cpp}` (engine-independent): the supported-name table with two entries (`Kill` → `actor.killed` v1, `Pacify` → `actor.pacified` v1), field validation and mapping, enum mapping with `unknown(n)` fallback, provenance, counters for unknown and `_DONTSEND` names; unit tests replay the 16 B0 payloads (committed as a fixture, identifiers redacted) and malformed variants.
3. `RelayEvent.h` gains `ActorOutcomeEvent`; `RelayAdapter` gains the overload; `RelaySerialization` the payload; the plugin wires detour → observation → normalizer → adapter, and publishes only while the mission predicate is true (otherwise logs "outside attempt" and counts).
4. Setting `[relay] telemetry_log = off | names | raw` (default `names`).

BEAM (`relay/`):

5. `Events.validate("actor.killed", 1, …)` / `("actor.pacified", 1, …)` with the mapped shape; `Lifecycle.Attempt` gains an ordered `outcomes` list; `Summary` gains per-attempt counts by kind × target × type × context, each line stating provenance (`glacier.telemetry`); tests from the fixture.

Standalone validation: the wire probe gains a `b0` step that replays the fixture through the real normalizer and adapter into BEAM; field-by-field comparison as in Stage A.

Controlled run (separate authorization): the B0 script again with `GlacierRelay` instead of the probe; pass = every `Kill`/`Pacify` in the native raw log appears exactly once in BEAM as the mapped event with the same values, attached to the right attempt, and the summary counts match the operator's actions; unknown-name counters list everything else.

## 24. Runtime questions still open — none block B1

| Question | Blocks B1? | Why not / when |
|---|---|---|
| Does `OnEventSent` fire with the backend unreachable? | no | B1 publishes only what the hook delivers; if it does not fire offline, BEAM sees no actor events and the summary says so. Worth one deliberate offline run before B2, since lifecycle enrichment would otherwise silently depend on connectivity. |
| What are the 7 unseen event indices? | no | counters in B1 will show whether anything relevant is missing; archaeology item |
| NPC-caused / scripted / crowd deaths | no | B1's normalizer maps whatever `KillContext` says; a later run that provokes them extends the fixture |
| `Hero_Health`, `Hero_Dead`, `ContractEnd` shapes | no (B5/B6/B2) | need a completion run and a death run |
| Shared repository ids (generic NPCs) | no | documented limitation of B1 identity; S2 correlation is a later, separately justified requirement |
| `ActorId` derivation | no | not used |

The only runtime work B1 itself needs is its own controlled validation run after it is built and tested offline.

---

## 25. B1 implementation record (2026-10-07) — built and validated without the game

Authorized as "M2 B1 — Telemetry Normalization + Actor Outcomes" with the names `actor.died` / `actor.pacified`, ADR 0006 accepted in principle, no native dedup, no Relay actor identity, `_DONTSEND` honoured from the flag, attempt association by stream order, and a hard stop at the runtime gate. **`GlacierRelay.dll` has not been deployed since the Stage A run.**

### Architecture as built

```
OnEventSent detour (frame thread, fault guard)
  TelemetryIntake::Inspect         Glacier-facing: find Name and _DONTSEND without copying; unsupported
                                   names counted and ignored; Kill/Pacify: copy ContractSessionId,
                                   ContractId, Timestamp and Value into an owned TelemetryObservation
                                   (by reflection type name; depth 6 / 512 nodes / 1 KiB strings)
  TelemetryQueue::Push             bounded (256), mutex-guarded; full -> drop newest, count
  return HookAction::Continue
frame update, before the scene read
  TelemetryQueue::Drain -> TelemetryNormalizer::Normalize (table: Kill -> actor.died, Pacify -> actor.pacified;
  _DONTSEND first; required fields validated; enum codes -> Relay names with the code kept beside "unknown";
  provenance) -> if MissionObserver.Playing(): RelayAdapter::Publish -> IRelaySink; else counted "outside
  attempt", logged, not published
```

Thread model: every `OnEventSent` call in B0 (204) ran on the frame thread, as do the frame update and the lifecycle observer; the queue does not assume it. Nothing inside the detour serializes JSON, touches the socket, or formats bodies; the only per-event work there is the name/flag lookup, a bounded copy for the two supported names, and (at `telemetry_log = names`, the default) one short log line per event seen. The drain runs before the predicate update so an outcome recorded in the frame of a fall still belongs to the attempt in which it happened.

Hand-off object: `TelemetryObservation { name, contract_session_id, contract_id, timestamp_s, dont_send, event_index, value: TelemetryValue }`, a plain tree (null/bool/number/string/array/object/unsupported-with-type-name). After the detour returns no Relay object holds a `ZDynamicObject`, `ZString` view, pointer, entity reference or SDK container; the normalizer and its tests compile without SDK headers.

### Normalized schema (`actor.died` v1, `actor.pacified` v1; identical shape)

| Field | Source field | Required | Type / values |
|---|---|---|---|
| `source` | — | yes | `"engine_telemetry"` |
| `repository_id` | `RepositoryId` | yes, non-empty | string (character definition id; shared by generic NPCs) |
| `actor_name` | `ActorName` | yes | string |
| `engine_actor_id` | `ActorId` | yes | integer 0..2³²−1 (observational; not an identity) |
| `actor_type` | `ActorType` (`EActorType`) | yes | `civilian` \| `guard` \| `hitman` \| `unknown` (+ `actor_type_code`) |
| `is_target` | `IsTarget` | yes | bool |
| `death_type` | `KillType` (`EDeathType`) | yes | `pacify` \| `kill` \| `bloody_kill` \| `unknown` (+ `death_type_code`) |
| `death_context` | `KillContext` (`EDeathContext`) | yes | `undefined` \| `not_hero` \| `hidden` \| `accident` \| `murder` \| `unknown` (+ `death_context_code`) |
| `accident` | `Accident` | yes | bool |
| `kill_class`, `method_broad`, `method_strict` | `KillClass`, `KillMethodBroad`, `KillMethodStrict` | yes | open-ended engine strings, preserved |
| `damage_events` | `DamageEvents` | yes | list of open-ended engine strings |
| `item_repository_id` | `KillItemRepositoryId` | optional | string |
| `contract_session_id` | envelope `ContractSessionId` | optional | string (Glacier's contract session; observational) |
| `engine_timestamp_s` | envelope `Timestamp` | optional | number |

Not carried: positions, `RoomId`, `PlayerId`, outfit fields, `BodyPartId`, `TotalDamage`, `IsMoving`, `EvergreenRarity`, `IsReplicated`, `History`, `KillItemInstanceId`, `KillItemCategory`, flags other than `Accident`. A supported event with any required field missing, mistyped, non-integral where an integer is expected, or an `ActorId` out of range is **malformed**: logged with the field, counted per name, not published, sequence not advanced. Unknown source names never leave the intake (counted; named in the log at `names`). `_DONTSEND == true` on any name: counted, not normalized, not published.

Terminology: the mission payload's v1 wire key `game_session_id` is unchanged and is now documented as Glacier's `ContractSessionId`; the actor schema uses `contract_session_id`. Neither is Relay attempt identity.

### BEAM

`Events` validates both types (Relay names only). `Lifecycle.Attempt.outcomes` holds `%Outcome{kind, sequence, timestamp, received_at, payload}` in stream order; an outcome with no open attempt goes to `Instance.unattributed_outcomes` with a logged note and is never attached to a neighbour. Pacify then died of one actor is two outcomes. `Summary` adds, per attempt, counts of died/pacified × target/non-target × actor type × engine death context × accidents, and one line per outcome, each marked `(engine_telemetry)`; no attribution, score, rating, mission outcome or unique-actor count.

### Commits

ZHMModSDK `relay/m2`: `ea20f49e` B1-R1 (observation, queue, normalizer, event, serialization, adapter, tests, fixture), `53688a47` B1-R2 (detour, intake, drain, setting), `a2d2cd4e` B1-R3 (wire probe `b1`). glacier-relay `main`: `97e11d9` validation, `15c092e` model/summary/tests/fixture.

### Tests

| Layer | Result |
|---|---|
| Native `GlacierRelayTests` | all 16 B0 payloads normalize (10 died / 6 pacified, 2 targets, 2 guards, 2 accidents); Kill→died, Pacify→pacified; Ducloitre and Novikov pacify→kill as two events with the same `engine_actor_id`; classification and method fields on Quiron/Donovan/Novikov; 16 malformed variants; Value not an object; optional fields absent; unknown enum codes keep their number; unsupported names counted and bounded; `_DONTSEND` on a supported name; exact payload text for the recorded Ducloitre kill; one sequence across `mission.playing`, `actor.pacified`, `actor.died`, `mission.stopped`; no dedup; queue order, overflow (newest dropped, counted, cumulative) and cross-thread push/drain. Pass from a clean tree. |
| Elixir | 64 tests, 3× stable: validation (required/optional/typed, rejections, unknown `actor.killed`), the 18 recorded B1 envelopes decode with every actor payload field equal to the native JSON (0 mismatches, checked programmatically), association in order, unattributed before/after/between attempts, no dedup, counts and text, listener end-to-end with the native envelopes and with an orphan outcome. |
| Standalone wire | `GlacierRelayWireProbe 4747 sleep:1500,publish,sleep:300,b1,sleep:300,stop,sleep:800` → BEAM: 18 lines, 0 rejected, one attempt with 16 outcomes, summary counts as above; native `published` lines are the committed BEAM fixture `relay/test/b1_probe_envelopes.ndjson`. Evidence in `%TEMP%\glacier-m0\hitmen\wire-probe\b1\`. |

Flaky test, resolved (B1-R4 gate cleanup, 2026-10-07): `TcpRelaySinkTests.cpp` scenarios 2 and 5 failed in ~30% of direct runs. Root cause, confirmed with a temporary diagnostic (accepted socket already closed by the peer, another connection pending in the backlog, sink `attempts 2 / connects 1`): on Windows loopback a non-blocking connect to a port with no listener is retried by the stack after ~500 ms, which is the test's `connect_timeout_ms`; when the test listener binds inside that window the sink's abandoned attempt completes in the kernel as the sink's `select` expires and it closes the socket, so a stale connection sits in the backlog ahead of the sink's next, live attempt, and the test accepted the stale one. The production sink is correct (it never treated the abandoned socket as connected and delivered on the next attempt; BEAM sees at most one accept that closes immediately, which `Wire.Listener` already tolerates). Test-only fix `d7c76b7f`: `TestListener::AcceptLive` waits for the sink to report connected, moves to the newest pending connection and confirms the peer has not closed it; no sleep or timeout was increased. Results: 25/25 consecutive full-suite runs on the incremental binary, 25/25 on the clean binary, 5/5 Elixir.

### Frame-order contract (B1-R4, `f6190fb5`)

The plugin's per-frame sequence now lives in the engine-independent `RelayFrame::Process` (called from `GlacierRelay::ObserveFrame`; behaviour, log lines and counters unchanged; an unavailable scene still drains the queue and leaves the observer untouched). The order is a documented contract: **telemetry captured while the previous mission-playing state was authoritative is drained and published before the next observed lifecycle edge is processed**, so a late outcome publishes as `actor.died`/`actor.pacified` #N followed by `mission.stopped` #(N+1) and never becomes unattributed terminal telemetry. `RelayFrameTests` exercises the production sequencing: the authorized model (playing → capture → scene falls → frame → outcome #2, stopped #3); several late observations in capture order; an observation after a processed fall is outside the attempt; one queued before the first rise is not attached to the attempt opening that frame; unavailable engine state; malformed observations consume no sequence; no adapter.

### Clean build and inertness

`_build/relay-x64-Debug` deleted; configure, build and tests at `f6190fb5` (after R4): pass, 0 warnings from relay sources. **`GlacierRelay.dll` SHA-256 `9bb7d4c38f3783234e81587f8240e2767da106dbb4bfed0ba7a123c7bccb90d9`** (the earlier `f2d72a84…506b` at `a2d2cd4e` is superseded). Standalone wire run repeated on the rebuilt binaries: 18 lines, 0 rejected, 0 field mismatches.

| Check | Result |
|---|---|
| Detours | exactly one `AddDetour` (`ZAchievementManagerSimple_OnEventSent`); no `SignalOutputPin`, no `ZActor_YouGotHit` |
| S2 production scan | none (`ActorManager` / `m_activatedActors` absent from `GlacierRelay`) |
| Engine writes | none |
| Networking | `WS2_32` import set identical to M1 (client calls only, no `listen`/`accept`/`bind`); `TcpRelaySink.{h,cpp}` unchanged (0 lines); no socket call in the detour or intake |
| Queue | bounded at 256; overflow drops and counts; drops logged with a rate limit |
| Imports | `ZHMModSDK.dll` (11 symbols, all exported by the installed M0 SDK), `KERNEL32`, `USER32`, `SHELL32`, `IMM32`, `WS2_32` |
| Exports | the three SDK plugin exports |
| Boundary | SDK headers only in `GlacierRelay.cpp`, `SceneObservation.cpp`, `TelemetryIntake.cpp`; `GlacierRelayTests` builds every other source without the SDK include path |
| BEAM absent | unchanged sink behaviour (drop while disconnected, backoff); telemetry is normalized and dropped by the sink like any other envelope; no new failure mode |

### Proposed B1 controlled runtime experiment (executed 2026-10-07 — see section 26)

Setup as Stage A: BEAM up first (`relay@…`, output captured), pre-flight hashes, install `GlacierRelay.dll` `f2d72a84…506b` + `[glacierrelay]`, no `glacierrelay.ini` (defaults: tcp, 4747, `telemetry_log = names`), M0 mod set, VS attached after the menu connection, rollback by hash. Script: the B0 script, so the results are comparable with a known corpus:

1. menu (gate: connected, no events; the intake should log unsupported names if the frontend emits any)
2. Paris, stand ~10 s (expect `mission.playing #1`; intake logs `ContractStart` etc. as `unsupported`)
3. subdue a non-target; wait ~15 s (expect `actor.pacified`)
4. kill that unconscious actor (expect `actor.died`, same `engine_actor_id`)
5. silenced-pistol a conscious non-target; 6. kill Novikov; 7. optional accident
8. restart (expect `mission.stopped`, counters line, `mission.playing`); 9. exit to menu; 10. quit normally.

Pass: every `Kill`/`Pacify` the native log shows as `captured` appears exactly once in BEAM as `actor.died`/`actor.pacified` with values equal to the native `published` line, attached to the attempt open at the time; counts in `summary_text/0` match the operator's actions; no gaps; queue `dropped = 0`; no `ERROR`/`FAULT`; frame rate unaffected; the `_DONTSEND` counter equals the number of client-only challenge notifications seen; rollback verified.

Expected but not safety-relevant (clarified before the run): `outside attempt = 0` and `malformed = 0` are what the B0 evidence predicts for this script. If a supported occurrence arrives outside the mission predicate, it is recorded, counted and left unattributed; no association is fabricated and nothing is fixed forward. If a live supported event fails B1 validation, the native warning names the field, the raw diagnostic evidence (the `telemetry seen` lines and the probe-style corpus if `telemetry_log` is raised) is preserved, validation is not loosened during the run, and the run continues; this is a semantic discrepancy to analyse, not a reason to terminate HITMAN. Abort conditions stay: native fault, unexpected debugger break, game instability, severe performance impact, unsafe memory behaviour, hook install failure or other safety-relevant behaviour.

Record as findings: anything `unsupported` that the taxonomy did not list; any `truncated`; the intake's per-event cost if measurable; any outside-attempt or malformed occurrence with its surrounding lines.

---

## 26. B1 controlled runtime experiment (2026-10-07, 03:50Z to 04:27Z) — PASS; B1 accepted

Authorized explicitly as "M2 B1 Runtime Experiment" against the pre-runtime gate of section 25: ZHMModSDK `relay/m2` `f6190fb5`, clean-built `GlacierRelay.dll` SHA-256 `9bb7d4c38f3783234e81587f8240e2767da106dbb4bfed0ba7a123c7bccb90d9` (byte-identical copy verified after install), glacier-relay `aa8d9f7`. No implementation change before, during or after the run. Objective: validate the first production use of Glacier's engine-authored telemetry inside `GlacierRelay` — `OnEventSent → owned TelemetryObservation → bounded queue → frame-thread drain → TelemetryNormalizer → actor.died / actor.pacified → RelayAdapter → TCP → BEAM → current attempt → event-derived summary` — for B1 actor outcomes and the normalization boundary. It does not validate the rest of the S1 stream as Relay telemetry.

**Outcome: accepted.** B1 is a validated M2 stage; `actor.died` v1 and `actor.pacified` v1 are validated M2 semantic vocabulary.

### Setup and pre-flight

Game `3.280.0.0`, Steam build `24833614`; all 26 M0 hashes OK; the 107-file `Retail` listing and hashes identical to both the B0 post-cleanup and the Stage A pre-flight baselines; no Hitmen, probe or Relay artifact under the game root; `mods.ini` = M0 (`b90b4c5e…`); both repositories clean at the authorized commits; OTP 28.4.2 / Elixir 1.19.6; port 4747 free on both sides before the listener started. BEAM first: `elixir --sname relay -S mix run --no-halt` with a live subscriber script, output captured, state read over RPC. Two game-directory changes, verified by a full-tree hash diff to be the only two: `Retail\mods\GlacierRelay.dll` and `mods.ini` with `[glacierrelay]` (byte-identical to the Stage A relay variant). No `glacierrelay.ini` (defaults `tcp`, 4747, `telemetry_log = names`). No actor probe, no Hitmen, no other instrumentation. Operator attached Visual Studio after the menu gate.

### R1 — menu gate

Pass. Loader: `Successfully installed detour for hook 'ZAchievementManagerSimple_OnEventSent' at address 0x140b6fd50`, `Mod glacierrelay successfully loaded`. Native: `plugin constructed … SDK 4.1.1 (ABI 1)`, `Init: one detour registered (…, read-only); lifecycle is polled`, adapter instance `c307a12d-55e9-4085-ba47-b626d71f2bf2`, `TcpRelaySink`, protocol 1, telemetry queue 256, `telemetry_log names`, `tcp sink: connected to 127.0.0.1:4747` at 03:57:07.150Z; BEAM `accepted` 16 ms later, connection unidentified. Menu scene 5 → 6 → 7 → 8, no event, no sequence consumed. **Zero Glacier telemetry at the frontend** (the engine emitted nothing on this bus before the mission loaded). 0 `WARN`/`ERROR`/`FAULT`. The debugger attach changed nothing (log still 13 lines afterwards).

### Complete Relay semantic sequence

One adapter instance, one TCP connection for the whole process, sequences 1 to 16 contiguous, BEAM `gaps []`, 16 lines received, 0 rejected.

| # | Event | Actor (engine fields, normalized) | Native timestamp | BEAM Δ | Attempt |
|---|---|---|---|---|---|
| 1 | `mission.playing` Paris / Peacock | — | 04:00:55.310Z | +48 ms (first decode) | 1 opens |
| 2 | `actor.pacified` | Jacqueline Ducloitre, civilian, non-target, `pacify`/`murder`, melee/unarmed, `[Subdue]`, id 195054661 | 04:03:43.445Z | +17 ms | 1 |
| 3 | `actor.died` | Ducloitre (same repository id and `engine_actor_id`), `kill`/`murder`, melee/unarmed, `[CoupDeGrace]` | 04:07:25.660Z | +2 ms | 1 |
| 4 | `actor.died` | Mark Parker, civilian, `bloody_kill`/`murder`, ballistic/pistol, `[Shoot]`, item `e70adb5b…` | 04:09:04.573Z | +2 ms | 1 |
| 5 | `actor.pacified` | Ad?le Rousseau, civilian, `pacify`/`murder`, `[Subdue]`, id 3951956299 | 04:09:24.690Z | +2 ms | 1 |
| 6 | `actor.died` | Rousseau (same ids as #5), `bloody_kill`/`murder`, pistol, `[Shoot]` | 04:12:54.744Z | +1 ms | 1 |
| 7 | `actor.died` | F?licien Bourque, civilian, `bloody_kill`/`murder`, pistol | 04:18:24.622Z | +2 ms | 1 |
| 8 | `actor.died` | Philippe Quiron, **guard**, `bloody_kill`/`murder`, pistol | 04:18:26.594Z | +2 ms | 1 |
| 9 | `actor.died` | Satordi Roux, civilian, `bloody_kill`/`murder`, pistol | 04:18:28.137Z | +2 ms | 1 |
| 10 | `actor.died` | Andr? Furchard, civilian, `kill`/**`accident`**, `accident: true`, explosion/accident/`accident_explosion`, `[Shoot]`, item `a8a0c154…` | 04:19:25.139Z | +2 ms | 1 |
| 11 | `actor.died` | **Viktor Novikov, `is_target: true`, `actor_type: civilian`**, `kill`/`accident`, explosion | 04:19:25.613Z | +2 ms | 1 |
| 12 | `actor.died` | Samantha Renard, civilian, `kill`/`accident`, explosion | 04:19:26.633Z | +2 ms | 1 |
| 13 | `actor.died` | Mathias Labelle, civilian, `kill`/`accident`, explosion | 04:19:26.887Z | +2 ms | 1 |
| 14 | `mission.stopped` (restart fall: loaded false, stage 8, Paris) | — | 04:22:49.397Z | +2 ms | 1 closes, 1314.1 s |
| 15 | `mission.playing` Paris / Peacock | — | 04:23:00.563Z | +2 ms | 2 opens |
| 16 | `mission.stopped` (exit-to-menu fall) | — | 04:25:00.876Z | +2 ms | 2 closes, 120.3 s |
| — | menu: no event; normal quit; TCP `:peer_closed` | | 04:25:26.714Z | | observation lost after #16 |

The controlled script was followed with two deviations that are themselves evidence: the operator's pistol kill of Parker (#4) was witnessed and the witness was subdued (#5), later shot (#6); and the Novikov kill was an explosion that took three bystanders (#10, #12, #13), which supplied the optional accident context without a separate action. The unplanned events were handled identically to the planned ones.

### Raw S1 occurrences versus normalized Relay occurrences

159 `OnEventSent` deliveries over the process (`telemetry seen` lines; counters at the second attempt end: `seen 158`, one `ContractFailed` arrived after that line). **12 captured** (10 `Kill`, 2 `Pacify`) → **12 normalized → 12 published** (#2 to #13), exactly one Relay event per engine occurrence. 124 unsupported across 40 names, never leaving the intake. 23 `ChallengeCompleted`, all `_DONTSEND` → counted, not normalized. 0 unreadable, 0 truncated. Full tally in `s1-names.txt` (evidence directory).

### Native ↔ BEAM comparison

Programmatic, over the Relay wire schema only (`compare.py` → `native-beam-compare.txt`): the 16 native `published` envelopes against BEAM's final `Lifecycle` state reconstructed as events (`beam-events.ndjson`). **16/16 present, 0 field mismatches** on event type, sequence, timestamp and every payload field: `repository_id`, `actor_name`, `engine_actor_id`, `actor_type`, `is_target`, `death_type`, `death_context`, `accident`, `kill_class`, `method_broad`, `method_strict`, `damage_events`, `item_repository_id` (present on #4, #6 to #13; absent and `nil` on #2, #3, #5), `contract_session_id` (attempt 1's value on #2 to #13), `engine_timestamp_s`, `source: "engine_telemetry"`; and the three scene fields plus `game_session_id` on #1, #14 to #16. Protocol 1 / schema 1 on all. Raw Glacier field names were not compared; the normalizer is the boundary.

### Pacify → died, same actor

Two instances, both preserved as two ordered semantic occurrences with no collapse and no dedup: Ducloitre #2 → #3 (same `repository_id` `5dc7ede5-bb9d-4f93-a892-cb7fb2791b19`, same `engine_actor_id` 195054661, `pacify [Subdue]` → `kill [CoupDeGrace]`, both `murder`, 222 s apart) and Rousseau #5 → #6 (`28aaef75…`, 3951956299, `pacify [Subdue]` → `bloody_kill [Shoot]`, 78 s apart). The Ducloitre pair has the same `ActorId`, `ActorType 0`, `KillType 3 → 4`, `KillContext 4` as in B0 — consistent across two game processes.

### Conscious civilian, target, accident

- #4 Parker: one `actor.died`, the engine's `bloody_kill` preserved (a silenced pistol kill is not `kill` on this build), method and item carried.
- #11 Novikov: one outcome, `is_target: true`. **`actor_type` is `civilian`: target status and actor type are orthogonal engine facts and must never be derived from one another.** `ObjectiveCompleted` (index 134) was seen and ignored as unsupported; no mission outcome was inferred.
- #10 to #13: `death_context: accident`, `accident: true`, `kill_class: explosion`, `method_broad: accident`, `method_strict: accident_explosion`, `damage_events: [Shoot]`, item `a8a0c154-c36f-413e-8f29-b83a1b7a22f0` — the engine's classification carried unchanged.

### Attempt association

#1 to #14 → attempt 1; #15, #16 → attempt 2; `unattributed_outcomes: []`; attempt 2 "actor outcomes: none observed". Association was by stream order only. `contract_session_id` crossed the wire as payload on every actor outcome (it equalled the `game_session_id` of #1) and was used for nothing.

### Counters

| Edge | Counters line |
|---|---|
| attempt 1 ended (#14) | `seen 145, captured 12, unsupported 110, dont_send 23, unreadable 0, truncated 0; queue pushed 12, dropped 0; normalized 12, malformed 0, outside attempt 0` |
| attempt 2 ended (#16) | `seen 158, captured 12, unsupported 123, dont_send 23, unreadable 0, truncated 0; queue pushed 12, dropped 0; normalized 12, malformed 0, outside attempt 0` |

All three expected zeros held. No malformed or outside-attempt observation occurred.

### BEAM summary (`summary_text/0`, after the process exit)

```
adapter c307a12d-55e9-4085-ba47-b626d71f2bf2: 16 event(s), last sequence 16, gaps [], observation lost
  connection 127.0.0.1:46480: opened 03:57:07.166541Z, identified 04:00:55.344435Z, closed 04:25:26.714699Z (:peer_closed)
  attempt 1: Peacock (…/Paris/_Scene_FashionShowHit_01.entity): playing 04:00:55.310Z (#1), stopped 04:22:49.397Z (#14), duration 1314.1 s
    actor outcomes (engine telemetry): 10 died (1 target, 9 non-target; 9 civilian, 1 guard; context accident 4, murder 6);
                                        2 pacified (0 target, 2 non-target; 2 civilian; context murder 2)
    #2 pacified Jacqueline Ducloitre (civilian, non-target): pacify/murder melee unarmed [Subdue] @168.43s (engine_telemetry)
    … one line per outcome #3 to #13 …
  attempt 2: Peacock (…): playing 04:23:00.563Z (#15), stopped 04:25:00.876Z (#16), duration 120.3 s
    actor outcomes (engine telemetry): none observed
```

The counts match the operator's actions. The summary claims no unique-actor count, no attribution to Agent 47, no Silent Assassin, no score, no mission success, failure or outcome. Compared with Stage A's lifecycle-only summary (two bounded attempts with durations), the B1 summary says what happened inside each attempt while refusing every claim it has no evidence for: materially more useful.

### Performance

No perceptible performance degradation was observed by the operator during B1; no numeric FPS measurement was collected. (B0's ~115 FPS figure is not carried over; it was a different binary doing different work.) Native publish-to-BEAM latency was 1 to 2 ms after the first event, as in Stage A.

### Warnings, errors, faults, debugger

Native log: 245 lines, two threads (frame thread, sender thread), **0 `WARN`, 0 `ERROR`, 0 `FAULT`**. BEAM: 0 warnings, 0 rejected lines. No debugger break; normal exit; process gone at 04:25:27Z. The SDK log's `EOSSDK-Win64-Shipping.dll` hook line (error 126) is present in the M0 baseline log too and is unrelated.

### Cleanup and hash verification

BEAM stopped (`:init.stop/0` over RPC) after the final state was captured; `GlacierRelay.dll` removed; `mods.ini` restored from the pre-flight copy (`b90b4c5e…`); all 107 `Retail` hashes and the listing identical to this run's pre-flight; 26/26 M0 hashes OK; no relay, Hitmen or probe artifact under the game root; `Runtime` untouched; port 4747 free on both sides. Evidence in `%TEMP%\glacier-m0\hitmen\b1-run1\`: native log `relay-20261007-035647-91292.log` (SHA-256 `3ff9a9ab7d33783baebba4a5c388fcfff12d61037198616958d1b673078f0d8f`), `beam.log` (`bdbc743a…9b91`), `beam-final-state.txt` (`summary_text/0`, `summary/0`, `state/0`), `beam-events.ndjson`, `native-beam-compare.txt`, `s1-names.txt`, both `ZHMModLoader` logs, `mods.ini` before/relay/after, `Retail` listings and hashes before/installed/after, and the scripts used (`live_watch.exs`, `final_state.exs`, `compare.py`, `watch-b1.sh`).

### Findings (evidence; nothing acted on)

1. **Engine event indices skip.** The `eventIndex` argument reached the detour with 9 of 154 values missing by attempt 1's end (5, 20, 21, 106, 119, 130, 131, 143, 144; index 5 was also absent in B0). The intake's `seen` counter equals the number of indices actually delivered (154 − 9 = 145), so nothing was lost by the hook: **the engine advances its index on paths that never call `OnEventSent`.** Consequence, stated as policy: **`eventIndex` is not a Relay continuity or loss signal.** The hook reconciled every event delivered to it; Relay's own envelope `sequence` remains the continuity mechanism for normalized Relay events, and BEAM's `gaps` is computed from it alone.
2. **`ContractFailed` ordering depends on the transition path.** Restart: `ContractFailed` at 04:22:47.554Z, predicate fall (`mission.stopped #14`) at 04:22:49.397Z — **1.84 s before** the fall, inside the attempt. Exit to menu: predicate fall at 04:25:00.876Z, `ContractFailed` at 04:25:00.877Z — **after** the fall, logged after the counters line of the same frame. B0 shows the same shape (restart: 1.93 s before, frames 146010 → 146326; exit: same frame 158948, logged after the fall). This corrects section 19's "0.3 s before": the B0 figure measured from log timestamps is 1.9 s. Both `ContractFailed` events were unsupported in B1 and therefore consumed nothing; had they been supported, the B1 rule "publish only while `Playing()`" would have placed the restart one inside the attempt and the exit one outside it. This is the central input to B2 (section 27).
3. **`ContractStart` ordering also depends on the path.** Fresh load: `HeroSpawn_Location` 04:00:54.773Z → `ContractStart` 04:00:55.016Z → rise 04:00:55.310Z (before the rise). Restart: `HeroSpawn_Location` 04:23:00.111Z → rise 04:23:00.563Z → `ContractStart` 04:23:00.564Z (same frame, after the rise). B0: fresh load frames 39043 → 39047; restart both at frame 146568 with `ContractStart` logged after the rise.
4. **The frame-order contract was not exercised by a supported event.** No `Kill`/`Pacify` was captured in the frame of, or immediately before, either fall; the contract's test coverage remains the `RelayFrameTests` of B1-R4.
5. **Non-ASCII actor names arrive as `?`.** `Ad?le Rousseau`, `F?licien Bourque`, `Andr? Furchard` carry a literal `0x3F` where the display name has an accented character. The bytes are identical in B0's raw dump of the same actors, so the substitution happens at or before the engine's `ZString`; it is not a normalizer defect. Recorded as a known limitation of `actor_name` on this build.
6. **Engine emission time ≠ engine occurrence time.** The four explosion outcomes (#10 to #13) carry `engine_timestamp_s` 668.413, 668.438, 668.452, 668.465 — a span of about 50 ms of Glacier time — while their `OnEventSent` deliveries were observed at 04:19:25.124Z, 25.602Z, 26.624Z, 26.876Z, about 1.7 s of wall time, interleaved with `OpportunityEvents` and `AccidentBodyFound`. Relay preserved both: **`engine_timestamp_s` is Glacier's occurrence-time evidence (seconds since contract start); the envelope `timestamp` is Relay's observation/publication time.** No global timeline-sorting policy is established yet; consumers that need occurrence order within an attempt have the engine value, consumers that need the order Relay saw have the sequence. Both stay on the wire.
7. **Four names not in the B0 taxonomy**: `EvidenceHidden`, `BodyHidden`, `AllBodiesHidden`, `AllPacifiedHidden` (body-handling notifications after the operator hid bodies). Added to the taxonomy as B1-only observations (`research/B0_EVENT_TAXONOMY.md`).
8. Fall-edge `game_session_id`: on the restart fall (#14) the slot held the upcoming attempt's id (the value #15 then carried); on the exit fall (#16) it held the stopped attempt's own id — the two Stage A data points reproduced. Still not keyed on.
9. The first engine telemetry of the process arrived only with the mission load (`HeroSpawn_Location`, index 1); the frontend emitted nothing. One `_DONTSEND` event per challenge notification, as in B0.

### Architectural conclusion

**Engine-authored Glacier telemetry is a viable primary semantic occurrence source for M2 when Relay has an explicit normalizer entry for that occurrence.** The production boundary — `OnEventSent → owned observation → bounded queue → TelemetryNormalizer → Relay-owned semantic event → wire → BEAM` — is validated at runtime: no engine object crossed the detour, the detour did no serialization, logging of bodies or network work, the queue never filled, every supported occurrence became exactly one Relay event with Relay-owned names and types, and BEAM validated and modelled it without knowing Glacier's field names. **This does not mean arbitrary Glacier events may be forwarded.** 124 unsupported deliveries and 23 `_DONTSEND` deliveries were counted and discarded at the intake; only explicitly supported and validated normalization entries become Relay events, and adding a name is a normalizer-table decision with a schema, tests and a controlled run, not a configuration change.

### Actor-outcome conclusion

12 supported Glacier actor outcomes → 12 normalized Relay events, exactly one per controlled occurrence, zero native deduplication required, zero malformed, zero drops, zero outside-attempt outcomes, field-for-field native/BEAM agreement, correct attempt association by stream order. **`actor.died` v1 and `actor.pacified` v1 are accepted as validated M2 semantic vocabulary.** Their fields are the engine's classification, not Relay's inference; in particular `is_target` and `actor_type` are independent (Novikov: target, civilian) and neither is derived from the other.

### Pass criteria of section 25

All met: every `captured` `Kill`/`Pacify` appears exactly once in BEAM as the mapped event with values equal to the native `published` line, attached to the attempt open at the time; summary counts match the operator's actions; no gaps; `dropped = 0`; no `ERROR`/`FAULT`; no perceptible frame-rate effect reported; `dont_send` (23) equals the number of client-only challenge notifications seen; rollback verified by hash. Answers to the review questions: (A) the normalization boundary behaved exactly as designed; (B) every controlled engine-authored actor outcome became exactly one appropriate Relay semantic event; (C) BEAM associated them with the correct attempt without using `ContractSessionId` as identity; (D) the event-derived summary is materially more useful than Stage A's.

B2 was not started after the run. The B1 implementation is frozen as validated; section 27 is design only.

---

## 27. B2 design — contract lifecycle (design only; not authorized for implementation)

Status: **analysis for review. No native or BEAM production code changed; nothing deployed.** Inputs: the B0 raw corpus (full payloads), the B1 production run (names, ordering, timing), Stage A (process-exit behaviour), section 19 (now partly superseded by runtime evidence, as marked below).

### 27.1 Raw contract-event corpus

Everything Glacier emitted on `OnEventSent` that concerns the contract session, across B0 (two sessions, payloads) and B1 (two sessions, names). User and platform identifiers omitted. `Timestamp` is seconds on the contract clock.

| Glacier name | Direction | Count B0 / B1 | Payload (B0) | Position in a session |
|---|---|---|---|---|
| `HeroSpawn_Location` | sent | 2 / 2 | `{RepositoryId}`; `Timestamp 0.0` | first event of every session |
| `ContractStart` | sent | 2 / 2 | `{Loadout: [{RepositoryId, InstanceId, OnlineTraits[], Category: null}], Disguise: <outfit repository id>, LocationId: "LOCATION_PARIS", GameChangers: [], ContractType: "mission", DifficultyLevel: 2.0, IsVR: false, IsHitmanSuit: true, SelectedCharacterId: <null guid>}`; envelope `ContractSessionId`, `ContractId` (`…0200` for Paris), `Timestamp 0.0`; also `XboxGameMode 3.0`, `XboxDifficulty 0.0` | second event; then `Level_Setup_Events` ×3–4, `StartingSuit`, `IntroCutEnd` (`Timestamp` 2.3–13.0) |
| `ShotsFired`, `ShotsHit` | sent | 1+1 / 1+1 | `{Split: {<instance id>: n}, Total}` | once, immediately before `ContractFailed` on the restart path (B1 indices 152, 153 → 154); not seen on the exit path in B1 |
| `ContractFailed` | sent | 2 / 2 | `Value` is a **string**: `"Contract ended manually: OnRestartLevel"` (`Timestamp 907.95`), `"Contract ended manually: User pressed exit to Main menu"` (`Timestamp 105.09`); envelope `ContractSessionId` of the ending session | last event of the session |
| `ContractEnd` | sent | 0 / 0 | **never observed** (no completed mission has been run) | — |
| `ContractSessionMarker` | received (backend) | 2 / n.a. | `{Currency: {ContractPaymentAllowed: true, ContractPayment: null}}`, `ContractId` null-guid, `ContractSessionId` of the **new** session, `Origin: null` | arrives 3.5–6 s before `ContractStart` (`CreatedAt` during loading): the backend has already created the session |
| `SegmentClosing` | received (backend) | 3 / n.a. | `{SegmentIndex: 0, LastEventName, LastEventTime, CloseType: "GameRestart" \| "GameExit" \| "ContractFailed:OrphanedSession"}`, `ContractSessionId` of the **closed** session, `Origin: "ContractSessionService"` | 3–9 s after the client's `ContractFailed` (restart 9.2 s, exit 2.9 s); at the next launch for the orphan |
| `ContractFailed` | received (backend) | 1 / n.a. | `{FailType: "OrphanedSession"}`, `Origin: "ContractSessionService"`, `ContractSessionId` = Stage A's Sapienza session (the one quit from inside), `Timestamp 10.25` | first thing received at the next launch, 1 h 43 min after the quit |

`GlacierRelay` hooks `OnEventSent` only; the received rows are B0 evidence from the probe's `OnEventReceived` hook and are **not available to Relay** without a second detour, which B2 does not propose.

### 27.2 What Glacier states directly

| Fact | Evidence | Direct or inferred |
|---|---|---|
| A contract session began, identified by `ContractSessionId`, for contract `ContractId`, at location `LocationId`, of type `ContractType`, at `DifficultyLevel`, with this loadout (repository ids + online traits), this starting disguise (repository id) and whether it is the hitman suit | `ContractStart` | **direct** |
| A contract session ended by a manual action, and which action | `ContractFailed` string: `OnRestartLevel` / `User pressed exit to Main menu` | **direct** (the string is engine-authored; the prefix `Contract ended manually: ` is constant in both cases) |
| How long the contract ran on Glacier's clock | `ContractFailed.Timestamp` (907.95 s; 105.09 s) | direct |
| Which contract session an actor outcome belongs to | `ContractSessionId` on every `Kill`/`Pacify` | direct |
| Where 47 spawned | `HeroSpawn_Location.RepositoryId` | direct (resolution to a name is not) |
| The session was *failed* in the scoring sense | the name `ContractFailed` | **not stated**: Glacier uses `ContractFailed` for a manual restart; the backend closes the same session as `GameRestart`. "Failed" is the engine's event name, not a verdict about the attempt |
| A contract session completed | `ContractEnd` | **unobserved**; shape unknown |
| The player died | `Hero_Dead` or a `ContractFailed` reason | unobserved |
| Restart ≠ exit to menu | two distinct reason strings | direct, for these two strings; other strings are unknown |
| Difficulty name (Casual/Professional/Master) for `DifficultyLevel 2.0` | — | not stated; not to be mapped until the enum is evidenced |
| The old session is closed when a new one begins | ordering only | inferred |

### 27.3 Ordering relative to `mission.playing` / `mission.stopped`

Four sessions, two runs, two transition paths each, all consistent:

| Transition | Glacier order | Native log timing | Relay predicate |
|---|---|---|---|
| Fresh load (menu → mission) | `HeroSpawn_Location` → `ContractStart` → … | B1: 04:00:54.773 → 04:00:55.016 → rise 04:00:55.310. B0: frames 39041 → 39043 → rise 39047 | **`ContractStart` 0.15–0.3 s before the rise** |
| Restart (in mission) | `ShotsFired`/`ShotsHit` → `ContractFailed(OnRestartLevel)` → [scene unload/reload, stage 0 → 5 → 6 → 7 → 8] → `HeroSpawn_Location` → `ContractStart`(new) | B1: `ContractFailed` 04:22:47.554, **fall 04:22:49.397** (1.84 s later); `HeroSpawn` 04:23:00.111, **rise 04:23:00.563**, `ContractStart` 04:23:00.564 (same frame, after the rise). B0: 1.93 s; same-frame after the rise (frame 146568) | **`ContractFailed` ~1.9 s before the fall, inside the attempt; `ContractStart` same frame as the rise, after it** |
| Exit to menu | `ContractFailed(exit to Main menu)` | B1: **fall 04:25:00.876**, `ContractFailed` 04:25:00.877 (same frame, logged after the fall's counters line). B0: same frame 158948, logged after the fall | **`ContractFailed` after the fall, outside the attempt** |
| Quit to desktop from inside a mission | nothing sent before termination (Stage A: no hook; inferred from the backend's `OrphanedSession` — see 27.9) | — | no fall, no `mission.stopped` (Stage A outcome B) |

Registry slot (`game_session_id` on the predicate edges): on the restart fall it already holds the **new** session's id (the slot rotated between the old `ContractFailed` and the fall); on the exit fall it holds the stopped session's id; on every rise it holds the session that `ContractStart` names (B1: #1's `game_session_id` equals the `contract_session_id` on #2–#13; Stage A/B0 ids match the same way).

Correction to section 19: the restart `ContractFailed` precedes the fall by about 1.9 s, not 0.3 s.

Consequence for the B1 rule "publish supported telemetry only while `MissionObserver::Playing()`": applied to contract telemetry it would publish the restart `ContractFailed` and silently count the exit `ContractFailed` as *outside attempt*, and would publish the restart `ContractStart` but count the fresh-load `ContractStart` as outside attempt. **A valid contract semantic occurrence exists outside an open Relay attempt on both edges**, so the rule cannot be applied to contract lifecycle telemetry.

### 27.4 Contract session versus Relay attempt

| | Relay mission attempt | Glacier contract session |
|---|---|---|
| Bounded by | scene predicate rise/fall (observed runtime state) | `ContractStart` → `ContractFailed` / `ContractEnd` (engine-authored stream), closed server-side by `SegmentClosing` |
| Identity | `(adapter instance, attempt number)` — Relay's | `ContractSessionId` — Glacier's |
| Cardinality observed | 1 ↔ 1 in all 4 sessions (and in Stage A's 3 attempts by registry id) | |
| Boundary offset | session starts 0.3 s before / same frame as the rise; session ends 1.9 s before / 1 frame after the fall | |
| Lifetime beyond the process | ends with observation | continues on the backend; resolved as orphaned at the next launch |

`ContractSessionId` is Glacier's identity for Glacier's object. It is legitimate to use it **within the contract domain** (to say that a `ContractFailed` ends the session a `ContractStart` began) and as **consistency evidence** (the rise's `game_session_id` should equal the paired session's id). It is **not** Relay attempt identity, and attempt ↔ session pairing is a correlation that BEAM establishes from stream order and records as such, with the id equality as a check whose failure is a logged discrepancy, never a re-pairing. The one-to-one cardinality is an observation of two Paris scripts, not a rule: a session with no attempt (load aborted before the predicate rose) and an attempt with no session (telemetry not emitted, e.g. offline — section 24) must both be representable.

### 27.5 Semantic scope: two gating classes, no framework

Distinguish, per normalizer table entry, how the native plugin gates publication:

| Class | Members | Native rule | BEAM rule |
|---|---|---|---|
| **attempt-gated** | `Kill` → `actor.died`, `Pacify` → `actor.pacified` (validated in B1) | publish only while `Playing()`; otherwise count *outside attempt*, log, do not publish (unchanged) | attach to the open attempt; otherwise `unattributed_outcomes` (unchanged) |
| **ungated** | `ContractStart` → `contract.started`, `ContractFailed` → `contract.ended` | publish whenever captured and valid; the frame-order contract still applies (drained before this frame's edge), so the exit `ContractFailed` publishes after `mission.stopped` and the fresh-load `ContractStart` before `mission.playing` | contract-session model on the instance; correlated to attempts by the rules in 27.7 |

This is one enum field on an existing table row and two branches in `RelayFrame::Process`, not a scope framework: no `scope` field on the wire (the event type implies it), no generic "scoped event" abstraction in BEAM, no time windows. The native *outside attempt* counter keeps its B1 meaning for the attempt-gated class. Revisit only if a third class appears; `StartingSuit` (B3) will face the same question, which argues for deciding it per entry then rather than generalizing now. (Originally written here as "arrives at `Timestamp 0.0` on the fresh-load path"; corrected from the B0/B2 logs in sections 29 and 30: it arrives with `IntroCutEnd`, 2 to 30 s after the rise, inside the attempt.)

Rejected: widening the native attempt window by a grace period (a heuristic that would hide the real ordering), and attaching contract events to attempts natively (the plugin would have to guess on both edges).

### 27.6 Public `contract.*` events versus internal enrichment

Section 19 proposed Model B (`mission.contract` / `mission.contract_ended` as attempt enrichment, attached to the open attempt). The runtime evidence changes the assessment:

| Criterion | Model A — public `contract.started` / `contract.ended` | Model B — internal enrichment (`mission.contract*` attached to attempts) |
|---|---|---|
| Fidelity to observed ordering | states what Glacier said, when; both edges occur outside attempts and the events still mean something | the exit `ContractFailed` and the fresh-load `ContractStart` have no open attempt to enrich; either the plugin guesses or BEAM applies an adjacency heuristic |
| Composability | lifecycle (`mission.*`, observed state) and contract (`contract.*`, engine-authored) are two independent evidence streams any consumer can correlate the same way BEAM does | the correlation is baked into the event names; a consumer that disagrees with the pairing cannot undo it |
| Recorder (M4) | records engine-authored session boundaries verbatim, including sessions with no attempt | records only what BEAM paired |
| Dashboard (M3) | can show "contract ended by restart" the moment the event arrives, before/after the scene edge | same information, but mislabelled as a mission attribute on the exit path |
| Cross-scene correlation | natural: a session is an instance-level object | awkward: enrichment needs an attempt |
| Protocol clarity | two namespaces with documented meanings; requires the doc to say that `contract.ended` is **not** mission outcome and that `mission.stopped` is **not** contract end | one namespace that would have to carry two kinds of boundary |
| Reason semantics | first-class: `reason` and `reason_kind` are the only engine-authored restart/exit evidence Relay will have | second-class, inside an enrichment payload |
| Cost | two event types, two schemas, BEAM model + summary | the same two schemas under other names, plus the pairing heuristic |

Every event crosses the wire in both models; the difference is whether the names promise an attachment the evidence cannot always honour. **Recommendation: Model A.** Section 19's "do not introduce public `contract.*` events" is withdrawn on the evidence of 27.3. The names are `contract.*`, not `mission.*`, precisely so that nobody reads them as attempt lifecycle.

### 27.7 Proposed normalized events

Naming: Glacier's `ContractFailed` ends a session on a manual restart as well as on an exit, and the backend names the same closures `GameRestart`/`GameExit`; the engine's own vocabulary is not a verdict. Relay therefore names the Relay event by what it is in Relay's model — a contract session ended — and preserves the engine's event name as provenance. When `ContractEnd` is eventually observed it maps to the same Relay event with `engine_event: "ContractEnd"` (new schema version if its shape differs). Alternative considered: `contract.failed` mirroring Glacier; rejected because every consumer would have to learn that "failed" includes restarts.

**`contract.started` v1** (from `ContractStart`; ungated)

| Field | Source | Required | Type |
|---|---|---|---|
| `source` | — | yes | `"engine_telemetry"` |
| `engine_event` | `Name` | yes | `"ContractStart"` |
| `contract_session_id` | envelope `ContractSessionId` | **yes, non-empty** (it is the subject) | string |
| `contract_id` | envelope `ContractId` | yes | string |
| `location_id` | `LocationId` | yes | string (`LOCATION_PARIS`) |
| `contract_type` | `ContractType` | yes | string (`mission`; open-ended) |
| `difficulty_level` | `DifficultyLevel` | yes | integer (engine float with integral value; **not** mapped to a name) |
| `starting_disguise_repository_id` | `Disguise` | yes | string |
| `is_hitman_suit` | `IsHitmanSuit` | yes | bool |
| `loadout` | `Loadout[]` | yes | list of `{repository_id: string, online_traits: [string]}` (`InstanceId`, `Category` dropped) |
| `game_changers` | `GameChangers[]` | yes | list of strings (observed empty) |
| `engine_timestamp_s` | envelope `Timestamp` | optional | number (observed 0.0) |

Dropped: `IsVR`, `SelectedCharacterId`, `XboxGameMode`, `XboxDifficulty`, user/platform ids.

**`contract.ended` v1** (from `ContractFailed`; ungated)

| Field | Source | Required | Type |
|---|---|---|---|
| `source` | — | yes | `"engine_telemetry"` |
| `engine_event` | `Name` | yes | `"ContractFailed"` |
| `contract_session_id` | envelope | **yes, non-empty** | string |
| `contract_id` | envelope | yes | string |
| `reason` | `Value` (string) | yes, non-empty | verbatim engine string |
| `reason_kind` | mapped from `reason` | yes | `restart` (`…OnRestartLevel`), `exit_to_menu` (`…User pressed exit to Main menu`), `other` (anything else; the verbatim string is still in `reason`) |
| `engine_timestamp_s` | envelope `Timestamp` | optional | number (the session's duration on the contract clock) |

Malformed (not published, sequence not advanced, counted per name): `Value` not a string / not an object as expected, any required field missing or mistyped, `DifficultyLevel` non-integral, a loadout item without `RepositoryId`.

**`HeroSpawn_Location`** is not normalized in B2 (one repository id, no consumer yet). `ContractSessionMarker`, `SegmentClosing`, backend `ContractFailed` are not reachable and not proposed.

### 27.8 BEAM model

`Lifecycle` gains a contract-session object on the instance and a correlation to attempts; attempt identity and `Attempt.mission` are untouched.

```
ContractSession { contract_session_id, contract_id, location_id, contract_type, difficulty_level,
                  starting_disguise_repository_id, is_hitman_suit, loadout, game_changers,
                  started: Observation | nil, ended: Observation | nil, reason, reason_kind,
                  attempt_number: integer | nil, paired_by: :open_attempt | :next_rise | nil }
Instance.contract_sessions  — in stream order
Instance.pending_contract   — the most recent started session not yet paired (at most one)
Attempt.contract_session_id — nil until paired
Attempt.disposition         — :not_observed | :restarted | :exited_to_menu | {:ended, reason}
```

Correlation rules, all ordinal:

1. `contract.started` → new `ContractSession` (if a session with that id already exists, note "second `contract.started` for session" and update). If an attempt is open and has no session → pair it (`:open_attempt`; the restart path). Otherwise (no attempt open, or the open attempt already has a session — which would be the case if a restart's new `ContractStart` ever arrived before the old attempt's fall) it becomes `pending_contract`, replacing any previous pending one (noted as "contract session … superseded before any attempt opened").
2. `mission.playing` → opens the attempt as today; if `pending_contract` exists → pair it (`:next_rise`; the fresh-load path). Consistency check: the rise's `game_session_id`, when present, should equal the paired session's id; a mismatch is logged as a note on both objects and **the pairing stands** (it was made by order).
3. `contract.ended` → find the session by `contract_session_id` (Glacier identity within the contract domain). Found → record `ended`, `reason`, `reason_kind`; if the session is paired, set the attempt's `disposition` from `reason_kind` (`restart` → `:restarted`, `exit_to_menu` → `:exited_to_menu`, `other` → `{:ended, reason}`). Not found → `Instance.unmatched_contract_ends`, note logged, never attached by adjacency. Ordering is not consulted here because the id is sufficient and ordering would have to tolerate the exit path's "after the fall" case; the ordering evidence is still recorded (`ended.sequence` versus the attempt's `stopped.sequence`).
4. `mission.stopped`, connection close: unchanged. A closed attempt whose session has no `ended` keeps `disposition: :not_observed`; the summary says so.
5. Nothing is derived from `mission.stopped` alone, from the registry id rotation, or from TCP close.

`Events.validate` gains both types (Relay names only). `MissionSession` routes them to `Lifecycle` and notifies subscribers like any event.

### 27.9 Process exit

Stage A established `mission.playing → TCP close` with no `mission.stopped` on a quit from inside a mission; B0 showed the backend resolving that same session as `OrphanedSession` at the next launch. Does Glacier emit any contract evidence locally before termination? **Unknown — Stage A had no `OnEventSent` hook, and neither B0 nor B1 quit from inside a mission.** The backend's `OrphanedSession` (rather than `GameExit`) is strong but inferential evidence that the client sent no `ContractFailed`. B2 therefore assumes **no** local evidence: an attempt whose process ends in-mission stays "last known playing; observation lost" with `disposition: :not_observed`, and `tcp_closed` never becomes `contract.ended` or `mission.stopped`. The B2 controlled run should include one quit from inside a mission with the hook installed, to turn this unknown into evidence either way.

### 27.10 Summary changes

Per attempt, from engine evidence only:

```
attempt 1: Peacock (…): playing … (#1), stopped … (#14), duration 1314.1 s
  contract (engine telemetry): session 2516109551602439084-990fb6fe…, LOCATION_PARIS, mission, difficulty 2,
    started @0.0s (#k, paired by next rise); ended by restart ("Contract ended manually: OnRestartLevel")
    @907.95s on the contract clock (#m) — disposition: restarted
  actor outcomes (engine telemetry): …
attempt 2: … ended by exit to menu (…) — disposition: exited_to_menu
attempt 3: … stop not observed; last known playing; contract end not observed — disposition: not observed
```

Instance level: contract sessions paired to no attempt, unmatched contract ends, id-mismatch notes. Wording rules: never "failed" for a restart or an exit; never "completed"; "disposition" only when `ended` was observed; the contract clock duration is labelled as the engine's, distinct from the attempt's wall-clock duration.

### 27.11 Required tests

Native (`GlacierRelayTests`): the four B0 payloads normalize to the proposed shapes (exact JSON for both `ContractFailed` strings); `reason_kind` mapping including an unknown string → `other`; malformed variants (non-string `Value`, missing `LocationId`, non-integral difficulty, loadout item without id, empty `ContractSessionId`); ungated entries publish while not playing and do **not** increment *outside attempt*; attempt-gated entries unchanged (the B1 tests still pass); `RelayFrameTests`: `ContractFailed` captured after a processed fall publishes as `contract.ended` #N+1 after `mission.stopped` #N; `ContractStart` captured before the rise publishes before `mission.playing`; `ContractStart` captured in the rise frame publishes after it (drain-before-edge is the existing contract; the test pins the sequence numbers).

Elixir: validation of both types; `Lifecycle` on the four scripts (fresh load, restart, exit to menu, quit without stop) with the B1 ordering reproduced from the fixture, asserting `paired_by`, `disposition`, no fabricated end; second `contract.started` before any rise; `contract.ended` with no session → unmatched; id mismatch → note, pairing unchanged; `Summary` wording (the words failed/completed absent for restart/exit); listener end-to-end with the native envelopes.

Standalone wire: probe step `b2` replaying `ContractStart`/`ContractFailed` around the real observer timeline in B1's order; the native `published` lines become the committed fixture.

### 27.12 Is another runtime probe needed before implementation?

**No.** The two payload shapes are in the B0 corpus at full fidelity, and the ordering on both transition paths is replicated across two runs. What is *not* evidenced (`ContractEnd` shape, player-death reason strings, process-exit emission, offline emission) does not block B2's two entries; each is a documented gap with a planned observation. Note that `GlacierRelay` cannot capture a new shape (`telemetry_log` is `off | names`; the `raw` setting of section 17 was not implemented in B1), so a completion run would need either the B0 probe branch or `raw` logging; that is a separate decision.

### 27.13 Smallest B2 implementation plan (not authorized)

Native (`relay/m2`, from `f6190fb5`, one root cause per commit): **B2-R1** normalizer table gains the gating class and the two entries, `ContractStartedEvent`/`ContractEndedEvent`, serialization, adapter overloads, tests from the B0 payloads; **B2-R2** `RelayFrame::Process` publishes ungated events regardless of `Playing()` (gated path unchanged), frame-order tests; **B2-R3** wire probe `b2`. BEAM: **B2-R4** `Events` validation; **B2-R5** `Lifecycle.ContractSession`, pairing rules, `Attempt.disposition`, `Summary`, tests, fixture. Then clean build, inertness table (still one detour, no new imports), standalone wire run, and a controlled run under its own authorization: menu → Paris → restart → exit to menu → Paris → quit from inside (27.9). Pass: both `contract.*` events per session, ordering as 27.3 with Relay sequences contiguous, pairing `:next_rise` then `:open_attempt`, dispositions `restarted` and `exited_to_menu` from engine evidence only, attempt 3 `not_observed`, no fabricated end, B1 counters unchanged.

Stop here for architectural review.

---

## 28. B2 implementation record (2026-10-07) — built and validated without the game

Authorized as "M2 B2 — Contract Lifecycle Implementation" on the section 27 design with refinements: public `contract.started` / `contract.ended` (not `contract.failed`); the contract-start payload bounded to contract lifecycle; the normalizer's gating extended minimally (attempt-gated / ungated, no grace window, no native attachment); attempt and contract session kept as distinct identities with the relationship documented as a BEAM-derived temporal correlation; ambiguity reported rather than resolved; id disagreement preserved as an anomaly; disposition from normalized contract evidence only; both timestamps preserved and the Relay sequence never reordered; contract events kept as first-class instance evidence; hard stop before deployment. ADR 0006 moved to **Accepted** on the B1 runtime validation. **`GlacierRelay.dll` has not been deployed since the B1 run.**

### Architecture as built

The B1 pipeline unchanged, plus two table rows and one per-row fact:

```
TelemetryNormalizer table   Kill → actor.died (attempt-gated)    Pacify → actor.pacified (attempt-gated)
                            ContractStart → contract.started (ungated)   ContractFailed → contract.ended (ungated)
RelayFrame::Process         drain → normalize → attempt-gated: publish iff Playing(), else "outside attempt"
                                                ungated: publish (adapter present) → then this frame's edge
BEAM Lifecycle              ContractSession evidence on the instance; attempt ↔ session correlation by order;
                            Attempt.disposition from the paired session's contract.ended only
```

The intake is unchanged: `IsSupportedSourceName` now answers true for the two contract names, so the detour copies their `ContractSessionId`, `ContractId`, `Timestamp` and `Value` exactly as it does for `Kill`/`Pacify`. Same single detour, no S2, no S3, no engine writes, `TcpRelaySink.{h,cpp}` 0 lines changed, TCP ownership unchanged.

### Public events

**`contract.started` v1** — `source: "engine_telemetry"`, `engine_event: "ContractStart"` (provenance), `contract_session_id` (required, non-empty: the event's subject), `contract_id`, `location_id`, `contract_type`, `difficulty_level` (integer; the engine's number, not mapped to a name), `starting_disguise_repository_id`, `is_hitman_suit`, `engine_timestamp_s` (optional; observed 0). **Deferred on purpose** (present in the source event, not normalized): `Loadout` and its item traits (B4 inventory semantics are not defined inside B2), `GameChangers`, `IsVR`, `SelectedCharacterId`, `XboxGameMode`/`XboxDifficulty`, and `HeroSpawn_Location` as a whole. They remain available as raw observations in the B0 corpus and would need their own table decision.

**`contract.ended` v1** — `source`, `engine_event: "ContractFailed"`, `contract_session_id` (required), `contract_id`, `reason` (the engine's string verbatim, required non-empty), `reason_kind` (`restart` for `"Contract ended manually: OnRestartLevel"`, `exit_to_menu` for `"Contract ended manually: User pressed exit to Main menu"`, matched exactly; `other` for any other string, which is preserved), `engine_timestamp_s` (the session's duration on the contract clock). Nothing in this event is mission failure, success, completion or player death. Malformed (counted, logged, not published, no sequence consumed): `Value` not a string / empty; `Value` not an object for `ContractStart`; any required field missing or mistyped; non-integral difficulty; empty envelope `ContractSessionId`.

### Native changes (`relay/m2`, from `f6190fb5`)

| Commit | Change |
|---|---|
| `2bd1f4de` B2-R1 | `ContractStartedEvent`/`ContractEndedEvent`, serialization, adapter overloads; normalizer table rows with `Gating`, `NormalizeContractStarted/Ended`, `ReasonKind`; fixture `B0ContractLifecycle.h` (the four recorded B0 events, identifiers redacted) |
| `8f5087a8` B2-R2 | `RelayFrame::Process` publishes ungated events regardless of the predicate (attempt-gated path and drain-before-edge unchanged); `Result.ungated_published`; counters line gains `ungated published N`; `ContractLifecycleTests.cpp` |
| `9f746cad` B2-R3 | wire probe step `b2`: the observed fresh-load / restart / exit-to-menu order through `RelayFrame::Process` with the recorded payloads and the registry id seen on each edge |

### BEAM changes (`main`, from `98a42da`)

| Commit | Change |
|---|---|
| `a0ee5b7` B2-R4 | `Events.validate` for both types (Relay names only; `reason_kind` constrained; `contract.failed` unknown) |
| `890e572` B2-R5 | `Lifecycle.ContractSession` (full `started_payload`/`ended_payload` kept), `Instance.contract_sessions / pending_contracts / unmatched_contract_ends / anomalies`, `Attempt.contract_session_id / contract_paired_by / contract_candidates / disposition`; pairing rules; `MissionSession` log notes; `Summary` contract and disposition lines; fixture `b2_probe_envelopes.ndjson`; 23 tests |

Correlation rules as implemented: `contract.started` pairs with the open attempt if that attempt has no session yet (`:open_attempt`); otherwise it waits. `mission.playing` pairs with the single waiting session (`:next_rise`); with several waiting, none is paired, the ids are recorded as `contract_candidates` on the attempt and as a `:contract_pairing_ambiguous` anomaly, and the sessions stay unpaired evidence. `contract.ended` closes the open session with its id; with none it is kept in `unmatched_contract_ends` (never attached by adjacency); with several open sessions of that id it is kept unmatched with a `:contract_end_ambiguous` anomaly. The rise's `game_session_id` is compared to the paired session's id: a difference is a `:contract_session_id_mismatch` anomaly, the pairing stands, neither id is rewritten. `Attempt.disposition` ∈ `:not_observed | :restarted | :exited_to_menu | {:ended, reason}` from the paired session's `contract.ended` only; `mission.stopped`, registry rotation, TCP close, scene and timing derive nothing (the B1 and Stage A tests for those still pass). Every `contract.*` event reaches subscribers and stays on the instance with its payload whether or not it enriched an attempt.

Summary wording (two lines per attempt, observed then derived):

```
    contract (engine telemetry): session <id>, LOCATION_PARIS, mission, difficulty 2; started #1 @0s; ended #4 by restart ("Contract ended manually: OnRestartLevel") @907.95282s on the contract clock
    disposition (BEAM-derived, session paired by next_rise): restarted
```

or `contract (engine telemetry): not observed` / `disposition (BEAM-derived): not observed`, `… not observed; contract end not seen`, `N sessions started before this rise; none correlated (ambiguous)`, plus instance lines for unpaired sessions, unmatched ends and anomalies. The words "failed" and "completed" do not appear for a restart or an exit (tested).

### Tests

| Layer | Result |
|---|---|
| Native `GlacierRelayTests` | B1 suites unchanged and passing; `ContractLifecycleTests`: table and gating; both `ContractStart` payloads → exact `contract.started` JSON with the deferred fields absent; both `ContractFailed` payloads → `restart` / `exit_to_menu` with exact JSON; unknown reason → `other` with the string preserved; 9 malformed `ContractStart` variants + non-object `Value`; 3 malformed `ContractFailed` variants (backend object shape, empty reason, no session id); frame order for fresh load (`contract.started` before `mission.playing`, not outside-attempt), restart (`actor.died`, `contract.ended`, `mission.stopped`, `mission.playing`, `contract.started`), exit to menu (`mission.stopped`, `contract.ended`), attempt-gated outcome still outside-attempt beside an ungated publish, malformed ungated consumes no sequence, no adapter. Clean tree: pass, 0 relay warnings; **25/25 consecutive runs** on the clean binary. |
| Elixir | **87 tests, 5× stable** (64 + 23): validation (required/typed/constrained, `contract.failed` unknown, schema v2 rejected); the 9 B2 wire envelopes decode with every payload field equal to the native JSON (checked programmatically); the recorded run → attempt 1 `:next_rise`/`:restarted` (`ended_relative :during`), attempt 2 `:open_attempt`/`:exited_to_menu` (`:after_stop`), no anomalies; fresh load; restart same-frame and early-start variants; exit to menu after the stop; unknown reason → `{:ended, reason}`; unmatched start stays pending/unpaired; multiple pending starts → no pairing, candidates + anomaly, later end closes the session but derives no disposition; unmatched end kept, not attached; id mismatch → anomaly, pairing kept, nothing rewritten; rise without registry id → no check; TCP close fabricates nothing; process exit leaves `:not_observed`; duplicate start noted; ambiguous end → unmatched + anomaly; one shared sequence; summary wording; two listener tests over TCP (full run; orphan `contract.ended`). |
| Standalone wire | `GlacierRelayWireProbe 4747 sleep:1500,b2,sleep:800` → BEAM: 9 lines, 0 rejected, order `contract.started #1, mission.playing #2, actor.died #3, contract.ended #4, mission.stopped #5, mission.playing #6, contract.started #7, mission.stopped #8, contract.ended #9`; **9/9 native `published` envelopes equal to BEAM's reconstructed events, 0 field mismatches**; attempts 1–5 → 1, 6–9 → 2; dispositions `restarted`, `exited to menu`; no anomalies. Run on the incremental binary (fixture committed as `relay/test/b2_probe_envelopes.ndjson`; a second run reproduced identical payloads) and again on the clean binary (`relay-20261007-052433-90036.log`, SHA-256 `38f6173f…`). Evidence in `%TEMP%\glacier-m0\hitmen\wire-probe\b2\`. |

### Clean build and inertness

`_build/relay-x64-Debug` deleted; configure, build and tests at `9f746cad`: pass, 0 warnings from relay sources. **`GlacierRelay.dll` SHA-256 `0e10e2839c568ae86cb74cdef5fca78445b9c909405ea20da62b3876ea730e30`.**

| Check | Result |
|---|---|
| Detours | the one `ZAchievementManagerSimple_OnEventSent` detour of B1; `DEFINE_PLUGIN_DETOUR` sites unchanged |
| S2 / S3 / engine writes | none (`ActorManager`, `m_activatedActors`, `SignalOutputPin`, `ZActor_YouGotHit`, `SetProperty`, `SetWorldMatrix`, `SetObjectToWorld*` absent) |
| Imports / exports | **identical to the B1 DLL** (normalized `dumpbin` diff: only link addresses differ); `WS2_32` client set unchanged, no `listen`/`accept`/`bind`; the three SDK plugin exports |
| TCP | `TcpRelaySink.{h,cpp}` 0 lines changed; ownership unchanged |
| Intake / queue | `TelemetryIntake.cpp`, `TelemetryQueue.h` 0 lines changed |
| Boundary | SDK headers only in the three Glacier-facing files; `GlacierRelayTests` and the probe build every other source without the SDK include path |

### Proposed B2 controlled runtime experiment (NOT executed; requires explicit authorization)

Setup as B1 (section 26): BEAM first with the live subscriber, pre-flight hashes against the B1 post-cleanup baseline, install `GlacierRelay.dll` `0e10e283…730e30` + `[glacierrelay]`, no `glacierrelay.ini`, VS attached after the menu gate, rollback by hash. Script:

1. menu (gate as B1; expect no telemetry)
2. **fresh Paris load**, stand ~10 s — expect `contract.started #1` **before** `mission.playing #2`; BEAM attempt 1 paired `:next_rise`, id check passing (the rise's `game_session_id` equals the session id)
3. **Paris restart** — expect `contract.ended` (`restart`) ~1.9 s **before** `mission.stopped`, then `mission.playing`, then `contract.started` for the new session (same engine frame, after the rise); attempt 1 `disposition: restarted` with `ended_relative :during`; attempt 2 paired `:open_attempt`
4. **exit Paris to menu** — expect `mission.stopped` then `contract.ended` (`exit_to_menu`) one frame later; attempt 2 `disposition: exited_to_menu`, `ended_relative :after_stop`; counters line shows `outside attempt 0`, `ungated published 4`
5. **fresh mission load** (Paris or Sapienza) — a third session and attempt paired `:next_rise`
6. **direct quit to desktop from inside the mission** (pause menu) — determines whether Glacier emits any contract end before the process disappears. Either outcome is evidence: if a `contract.ended` arrives before the TCP close, attempt 3 gains a disposition from it; if not, attempt 3 stays "last known playing; observation lost", `disposition: not_observed`, and nothing is fabricated from the close.

Pass: every `ContractStart`/`ContractFailed` the native log shows as `captured` appears exactly once in BEAM as `contract.started`/`contract.ended` with values equal to the native `published` line; orderings as in section 27.3; attempts paired as above with no anomaly (an anomaly is a finding, not a failure); dispositions from contract evidence only; attempt 3 as the evidence dictates; `queue dropped = 0`, `malformed = 0`, `outside attempt = 0`; B1 actor outcomes unaffected if any occur; no `ERROR`/`FAULT`; rollback verified. Record: the exact frame offsets of each contract event from its predicate edge; the registry id on each edge versus the paired session; whether the quit emitted anything; any `other` reason string.

B3 (disguise) is not started.

---

## 29. B2 controlled runtime experiment (2026-10-08, 19:16Z to 19:36Z) — PASS; B2 accepted

Authorized explicitly as "M2 B2 Runtime Experiment" against the pre-runtime gate of section 28: ZHMModSDK `relay/m2` `9f746cad`, clean-built `GlacierRelay.dll` SHA-256 `0e10e2839c568ae86cb74cdef5fca78445b9c909405ea20da62b3876ea730e30` (the installed copy hashed identically in `retail-installed.sha256`), glacier-relay `e51deca`. No implementation change before, during or after the run. Objective: validate the first ungated normalizer entries — `ContractStart → contract.started` v1 and `ContractFailed → contract.ended` v1 published on both sides of the mission predicate's edges — and BEAM's correlation of Glacier contract sessions to Relay attempts by stream order, with attempt disposition derived from contract evidence only.

**Outcome: accepted** (architectural review of 2026-10-08). B2 is a validated M2 stage; `contract.started` v1 and `contract.ended` v1 are validated M2 semantic vocabulary; the two-class gating (attempt-gated / ungated) and the BEAM correlation rules of section 28 are validated at runtime.

This record was written from the saved evidence (`%TEMP%\glacier-m0\hitmen\b2-run1\`, 23 files) after the run, not from the live session; every timestamp, id and counter below is copied from those files.

### Setup and pre-flight

Game `3.280.0.0`, Steam build `24833614`; 107-file `Retail` listing and hashes identical to the B1 post-cleanup baseline (`retail-before.*`); `mods.ini` = M0 (`b90b4c5e0f6b…21b0b9`); no Hitmen, probe or Relay artifact under the game root; both repositories clean at the authorized commits; OTP 28.4.2 / Elixir 1.19.6; port 4747 free. BEAM first (`relay@VENGEANCE`, listening at 19:16:30.274Z) with the live subscriber script. Installed at 19:16:31Z; the full-tree diff against the pre-flight listing shows exactly two changes (`retail-installed.sha256`): `mods/GlacierRelay.dll` (hash above) and `mods.ini` with `[glacierrelay]` (`a66a44ed…`, byte-identical to the B1 relay variant). No `glacierrelay.ini` (defaults: `tcp`, 4747, `telemetry_log = names`). Operator attached Visual Studio after the menu gate and reported no disturbance.

### R1 — menu gate

Pass. Loader: `Successfully installed detour for hook 'ZAchievementManagerSimple_OnEventSent' at address 0x140b6fd50` (the B1 address; a build-specific observation, not a constant), `Mod glacierrelay successfully loaded`, durable log `%LOCALAPPDATA%\GlacierRelay\Relay\relay-20261008-192015-85348.log`. Native: `plugin constructed … SDK 4.1.1 (ABI 1)`, `Init: one detour registered (ZAchievementManagerSimple_OnEventSent, read-only); lifecycle is polled`, adapter instance **`0310e745-d651-435e-8184-d1a928196524`**, `TcpRelaySink`, protocol 1, queue 256, `telemetry_log names`; `tcp sink: connected to 127.0.0.1:4747` at 19:20:38.642Z; BEAM `CONNECTION opened` at 19:20:38.667Z (25 ms), unidentified. Menu scene 5 → 6 → 7 → 8 (19:20:38.655Z to 39.103Z): no event, no sequence consumed. **Zero Glacier telemetry at the frontend**, as in B1 (a result of this run, not a rule). 0 `WARN`/`ERROR`/`FAULT`.

### Complete Relay semantic sequence

One adapter instance, one TCP connection for the whole process, sequences 1 to 10 contiguous, BEAM `gaps []`, **10 lines received, 0 rejected**. "Native timestamp" is the envelope `timestamp` — Relay's observation/publication time on the frame thread, not Glacier's occurrence time; `engine_timestamp_s` is the contract clock. Contract sessions, in full:

- **A** `2516108132899378538-d153d3b7-f998-45fa-aad5-36ae9df0d444`
- **B** `2516108131754977057-1ef653a1-970e-4ff8-8fc8-cdf782572aa3`
- **C** `2516108128579619815-8d205c24-14ec-4f5a-b76b-87996dc247b0`

All three: `contract_id 00000000-0000-0000-0000-000000000200`, `LOCATION_PARIS`, `mission`, `difficulty_level 2`, `starting_disguise_repository_id 874c4c48-0a8b-49e9-883e-49fc5f1fb051`, `is_hitman_suit true`.

| # | Event | Payload (normalized) | Native timestamp | BEAM Δ | Contract session / registry id on the edge | Attempt |
|---|---|---|---|---|---|---|
| 1 | `contract.started` | session A, `engine_timestamp_s 0` | 19:25:25.812Z | +80 ms (first decode; connection identified 19:25:25.868Z) | A | pending → paired to attempt 1 at #2 (`:next_rise`) |
| 2 | `mission.playing` Paris / Peacock | — | 19:25:25.922Z | +3 ms | registry id = A | 1 opens |
| 3 | `contract.ended` | A, `reason "Contract ended manually: OnRestartLevel"`, `reason_kind restart`, `engine_timestamp_s 95.2977` | 19:27:03.891Z | +10 ms | A | 1 (`ended_relative :during`) |
| 4 | `mission.stopped` (restart fall: loaded false, stage 8) | — | 19:27:04.919Z | +2 ms | registry id **already B** | 1 closes, **99.0 s** |
| 5 | `mission.playing` Paris / Peacock | — | 19:27:16.072Z | +2 ms | registry id = B | 2 opens |
| 6 | `contract.started` | session B | 19:27:16.097Z | +1 ms | B | paired to the open attempt 2 (`:open_attempt`) |
| 7 | `mission.stopped` (exit-to-menu fall) | — | 19:29:08.164Z | +2 ms | registry id = B | 2 closes, **112.1 s** |
| 8 | `contract.ended` | B, `reason "Contract ended manually: User pressed exit to Main menu"`, `reason_kind exit_to_menu`, `engine_timestamp_s 110.1097` | 19:29:11.247Z | +2 ms | B | 2 (`ended_relative :after_stop`) |
| 9 | `contract.started` | session C | 19:32:36.496Z | +3 ms | C | pending → paired to attempt 3 at #10 (`:next_rise`) |
| 10 | `mission.playing` Paris / Peacock | — | 19:32:36.602Z | +2 ms | registry id = C | 3 opens |
| — | direct quit from inside the mission; TCP `:peer_closed` | | 19:34:52.403Z (BEAM) | | connection observation only | 3: observation lost; no stop, no end |

The TCP close is not an eleventh Relay event. The contract clock (95.30 s, 110.11 s) and the predicate-bounded attempt durations (99.0 s, 112.1 s) measure different boundaries and are both kept; they are not reconciled.

### Transition-specific ordering (native log, frame thread)

| Transition | Observed order | Offsets |
|---|---|---|
| **Fresh entry** (menu → Paris, ×2) | `HeroSpawn_Location` (19:25:25.374Z) → stage 7 (25.613Z) → `ContractStart` captured (25.793Z) → **`contract.started` #1 published (25.812Z)** → stage 8 / rise → **`mission.playing` #2 (25.922Z)** | `contract.started` **110 ms before** the rise. Second fresh entry: captured 19:32:36.480Z, #9 published 36.496Z, rise #10 36.602Z — **106 ms before**. Both published while `Playing()` was false: the ungated path did exactly what B2-R2 intended |
| **Restart** | `ContractFailed` captured 19:27:03.882Z → **`contract.ended` #3 (03.891Z)** → fall / **`mission.stopped` #4 (04.919Z)**, registry already B → stage 0 (04.928Z) → 5 (10.533Z) → 6 (12.539Z) → `HeroSpawn_Location` (15.610Z) → stage 7 (15.722Z) → rise / **`mission.playing` #5 (16.072Z)** → `ContractStart` captured (16.074Z) → **`contract.started` #6 (16.097Z)** | `contract.ended` **1.03 s before** the fall (B0: 1.93 s, B1: 1.84 s — the lead varies; no fixed timing rule). `ContractStart` captured 2 ms after the rise and published on the next frame, 25 ms after #5 |
| **Exit to menu** | fall / **`mission.stopped` #7 (19:29:08.164Z)**, counters line, then `ContractFailed` captured in the **same frame** (08.164Z, logged after the fall) → no frame updates while the scene unloaded → stage 2 (11.247Z) and **`contract.ended` #8 published in that first frame (11.247Z)** | published **3.08 s after capture** with `Playing()` false; `engine_timestamp_s 110.1097` preserved. The queue held the observation across the unload; nothing was lost or reordered |

Finding, accepted as a timing fact and not a defect: **during a scene unload the frame update does not run, so a telemetry observation captured in the fall frame is published on the first frame of the next scene** — here 3.08 s later. The Relay `sequence` records publication order; `engine_timestamp_s` records the engine's occurrence time; BEAM's receipt time is a third clock. None of the three is rewritten. The queue behaviour (bounded, drained on the frame thread, no timers) is unchanged by this record.

The edge ordering is therefore **transition-dependent**: `contract.started` precedes the rise on fresh entry and follows it on restart; `contract.ended` precedes the fall on restart and follows it on exit to menu. Neither "contract first" nor "mission first" is a rule; the correlation has to be made by BEAM from the order actually observed, which is what section 28's rules do.

`StartingSuit` (unsupported in B2) arrived at 19:25:49.163Z, 19:27:45.917Z and 19:32:42.454Z — 23.2 s, 29.8 s and 5.9 s after the respective rises, each in the same millisecond as `IntroCutEnd`. This corrects the parenthetical in section 27.5 ("`StartingSuit` arrives at `Timestamp 0.0` on the fresh-load path"): it arrives when the intro cut ends, inside the attempt (B0 contract clock 13.01 s and 2.28 s). See section 30.

### Correlations and dispositions (BEAM-derived)

| Attempt | Session | Paired by | `ended_relative` | Rise `game_session_id` = session id | Disposition | From |
|---|---|---|---|---|---|---|
| 1 | A | `:next_rise` | `:during` | yes | `:restarted` | #3 `reason_kind restart` |
| 2 | B | `:open_attempt` | `:after_stop` | yes | `:exited_to_menu` | #8 `reason_kind exit_to_menu` |
| 3 | C | `:next_rise` | — (no end observed) | yes | `:not_observed` | nothing |

`beam-final-correlation.txt`: `observation/unpaired/unmatched/anomalies/gaps: {:lost, 0, [], [], []}`. Both correlation rules of section 28 were exercised: `:next_rise` twice (attempts 1 and 3, both fresh entries) and `:open_attempt` once (attempt 2, the restart); the registry id on every rise equalled the paired session's id (consistency check passed three times); the registry's rotation to B before attempt 1's fall (#4) participated in nothing. Both dispositions came from paired `contract.ended` payloads only. Attempt and session identities stayed distinct throughout.

### Direct in-mission quit: outcome B, with the telemetry hook installed

The last `OnEventSent` delivery was index 45, `Level_Setup_Events`, at 19:33:18.893Z. The operator quit to desktop from inside attempt 3 at about 19:34:52Z. Between those times the native log has no line: **no `ContractFailed`, no predicate fall, no telemetry of any kind reached the detour before termination**, and BEAM saw only the TCP close (`:peer_closed` at 19:34:52.403Z, after 10 lines, 0 rejected). This answers section 27.9's open question for this build, mission and quit path: **Glacier sends no local contract-end evidence on a direct quit**, which is consistent with B0's backend `OrphanedSession` resolution for Stage A's quit. It is not evidence about crashes, other quit paths, other modes or other builds.

Final summary lines for attempt 3 (`beam-final-state.txt`):

```
attempt 3: Peacock (…): playing 2026-10-08T19:32:36.602Z (#10), stop not observed; last known playing; observation lost 2026-10-08T19:34:52.402712Z (:peer_closed)
  contract (engine telemetry): session 2516108128579619815-8d205c24-14ec-4f5a-b76b-87996dc247b0, LOCATION_PARIS, mission, difficulty 2; started #9 @0s; end not observed
  disposition (BEAM-derived, session paired by next_rise): not observed; contract end not seen
  actor outcomes (engine telemetry): none observed
```

Nothing was synthesized: no stop, no end, no disposition, no failure, no completion.

### Native ↔ BEAM comparison

Programmatic, over the Relay wire schema only (`compare.py` → `native-beam-compare.txt`): the 10 native `published` envelopes against BEAM's final `Lifecycle` state reconstructed as events (`beam-events.ndjson`, 10 lines). **10/10 present, 0 field mismatches**, attempt per sequence `{1..4 → 1, 5..8 → 2, 9..10 → 3}`, one adapter instance id. Compared contract fields: `source`, `engine_event`, `contract_session_id`, `contract_id`, `location_id`, `contract_type`, `difficulty_level`, `starting_disguise_repository_id`, `is_hitman_suit`, `engine_timestamp_s`, `reason`, `reason_kind`; and the scene fields plus `game_session_id` on #2, #4, #5, #7, #10. Protocol 1 / schema 1 on all. Raw Glacier member names were not compared; the normalizer is the boundary.

### Counters (native, verbatim)

| Checkpoint | Counters line |
|---|---|
| attempt 1 ended (#4) | `seen 14, captured 2, unsupported 12, dont_send 0, unreadable 0, truncated 0; queue pushed 2, dropped 0; normalized 2, malformed 0, outside attempt 0, ungated published 2` |
| attempt 2 ended (#7), before the delayed #8 | `seen 27, captured 3, unsupported 24, dont_send 0, unreadable 0, truncated 0; queue pushed 3, dropped 0; normalized 3, malformed 0, outside attempt 0, ungated published 3` |
| process (from the `seen` lines; no end-of-process counters line because no further fall occurred) | 41 deliveries: 5 captured (3 `ContractStart`, 2 `ContractFailed`), 36 unsupported across 7 names (`Level_Setup_Events` 15, `OpportunityStageEvent` 6, `StartingSuit` 3, `OpportunityEvents` 3, `IntroCutEnd` 3, `HeroSpawn_Location` 3, `AmbientChanged` 3), 0 `_DONTSEND` (no challenge fired in this run) |

5 captured → 5 normalized → 5 published (#1, #3, #6, #8, #9); `ungated published` reached 4 at #8 and 5 at #9. Engine indices **5, 20, 31, 36** never reached the detour (41 of 45); as established in B1 finding 1, `eventIndex` is not a Relay continuity signal and no Relay sequence was lost. The three expected zeros (`dropped`, `malformed`, `outside attempt`) held at every checkpoint.

### Performance, warnings, errors, faults, debugger

No perceptible performance effect was reported by the operator; **no numeric FPS measurement was collected** (as in B1). Native log: **116 lines, 0 `WARN`, 0 `ERROR`, 0 `FAULT`**; two threads (frame, sender); publish-to-BEAM 1 to 10 ms after the first event. BEAM: 0 rejected lines; its only warning is the expected `connection … closed (:peer_closed) while attempt 3 is last known playing; no mission.stopped observed`. No debugger break; the process ended by the operator's quit.

### Cleanup and hash verification

Final BEAM state captured first (`summary_text/0`, `summary/0`, `state/0` → `beam-final-state.txt`); BEAM stopped; `GlacierRelay.dll` removed; `mods.ini` restored from the pre-flight copy; `retail-after.sha256` and `retail-after.tsv` identical to `retail-before.*` (107 entries); 26/26 M0 hashes OK (reported at cleanup); no Relay, Hitmen or probe artifact under the game root; `Runtime` untouched; port 4747 free. Re-checked on 2026-10-08 while writing this record: the game's `mods.ini` hashes `b90b4c5e…`, and `mods/` holds no Relay, Hitmen or probe artifact. One procedural note from the cleanup: a broad `pkill -f` pattern matched the operator's own shell command line and killed that shell — a false alarm, not a game or BEAM fault. Stop BEAM by RPC (`:init.stop/0`) or by a positively identified pid, never by a broad name match.

Evidence in `%TEMP%\glacier-m0\hitmen\b2-run1\` (23 files): native log `relay-20261008-192015-85348.log` (SHA-256 `fc043698a1f11056db612e69f83e44f3570e0beabdfb2ae601e08c5630526490`), `beam.log` (`80f69559…3317`), `beam-final-state.txt` (`aad6c79e…b835`), `beam-final-correlation.txt`, `beam-events.ndjson` (`1b1a74dc…670f`), `native-beam-compare.txt`, both `ZHMModLoader` logs, `mods.ini` before/relay/after-run, `Retail` listings and hashes before/installed/after, `installed-at.txt`, and the scripts used (`live_watch.exs`, `final_state.exs`, `compare.py`, `watch-b2.sh`).

### Findings (evidence; nothing acted on)

1. **Edge ordering is transition-dependent** (table above). Fresh entry: `contract.started` 106 to 110 ms before the rise. Restart: `contract.ended` 1.03 s before the fall; `contract.started` after the rise (next frame). Exit to menu: `contract.ended` captured in the fall frame, after the fall.
2. **Unload stalls publication, not capture.** The exit-path `ContractFailed` was published 3.08 s after capture, on the first frame of the menu scene, with `engine_timestamp_s` intact. Consumers must not read Relay `timestamp` differences across a scene transition as engine timing.
3. **Direct quit emits nothing locally** on this build and path, hook installed (above). The attempt stays last known playing; the contract session stays open with no end; nothing is derived from the close.
4. **Registry rotation before the restart fall reproduced** (Stage A, B1, now B2): the fall's `game_session_id` was already B. Still keyed on nothing.
5. **No actor outcome, no `_DONTSEND`, no frontend telemetry** occurred in this run; the B1 attempt-gated path was present but not exercised by a supported event (its tests remain the coverage).
6. `StartingSuit` arrives with `IntroCutEnd`, inside the attempt, 6 to 30 s after the rise — not at contract clock 0 (correction to section 27.5; input to B3).
7. **Open timing question for later correlation validation (not a change request):** a queued event delayed across an unload, combined with rapid successive transitions (for example restart immediately after a fall, or a second `ContractStart` before a delayed `ContractFailed` drains), could produce an order in which the `:open_attempt` / `:next_rise` rules see more than one candidate. Section 28's rules would then report ambiguity rather than pair — which is the intended behaviour — but the case has not been produced at runtime. Record for the M4 recorder / correlation test plan; do not change the queue or the rules on this evidence.

### Pass criteria of section 28

All met: every `captured` `ContractStart`/`ContractFailed` appears exactly once in BEAM as `contract.started`/`contract.ended` with values equal to the native `published` line; orderings as section 27.3 predicted, Relay sequences contiguous; attempts paired `:next_rise`, `:open_attempt`, `:next_rise` with no anomaly; dispositions `restarted` and `exited_to_menu` from contract evidence only; attempt 3 as the evidence dictated (`not_observed`, nothing fabricated from the close); `queue dropped = 0`, `malformed = 0`, `outside attempt = 0`; no `ERROR`/`FAULT`; rollback verified by hash. Recorded as requested: the frame offsets of each contract event from its edge, the registry id on each edge versus the paired session, that the quit emitted nothing, and that no `other` reason string occurred.

B3 was not started after the run. The B2 implementation is frozen as validated; section 30 is design only.

---

## 30. B3 design — disguise telemetry (design only; not authorized for implementation)

Status: **archaeology and design for review. No native or BEAM production code changed; nothing deployed; no game run.** Revised 2026-10-08 on review of the first draft: compromise *history* (observed) is separated from any claim about compromise *persistence* across outfit changes (unknown, reported as such); the initial-outfit assertion and an outfit change are distinguished by a Relay-owned `kind` with `engine_event` kept as provenance; the frame-order guarantee and mid-attempt observation are stated as they actually are, with conservative handling of delayed initial assertions and incomplete history; the established abort policy is restored; synthetic robustness cases are added and labelled; the runtime proposal re-equips the compromised outfit before clearing it. Inputs: the B0 raw corpus (full payloads; `%TEMP%\glacier-m0\hitmen\b0-run1\relay-20261007-014849-93996.log`), the B1 and B2 production runs (names, ordering, timing only — `telemetry_log = names` records no bodies), the B2 `contract.started` payloads, the SDK headers at `relay/m2`, and Peacock's event handler as independently read prior art (ADR 0004: prior art, not a dependency; nothing is copied). Goal, as set: the **weakest defensible disguise semantics** before the normalized vocabulary grows.

### 30.1 Corpus inventory

Every engine-authored occurrence that concerns disguise, across the three runs. "Payload" is exact for B0; B1 and B2 contribute counts and ordering only.

| Glacier name | Count B0 / B1 / B2 | `Value` (B0, exact) | Envelope | Observed values (B0) | Contract clock (B0) |
|---|---|---|---|---|---|
| `StartingSuit` | 2 / 2 / 3 | **string**: outfit repository id | `ContractSessionId`, `ContractId`, `Timestamp`, `Origin "gameclient"`, `Id` | `874c4c48-0a8b-49e9-883e-49fc5f1fb051` both times — equal to `ContractStart.Disguise` of the same session | 13.012 (fresh entry), 2.280 (restart); in the same frame as `IntroCutEnd` in all 7 observations across the three runs |
| `Disguise` | 2 / 2 / 0 | **string**: outfit repository id | same | `2018db77-aa8a-4bf9-9afb-56bdaa161156` @202.104; `992cc7b6-4ccf-4ae8-a467-e9b2aabaeeb5` @497.756 | mid-mission; each followed 8 ms later by a `_DONTSEND` `ChallengeCompleted` `UI_CHALLENGES_GLOBAL_FRESH_DISGUISE_NAME` |
| `DisguiseBlown` | 2 / 1 / 0 | **string**: outfit repository id | same | `2018db77…` @222.863; `992cc7b6…` @615.013 — each equal to the most recent `Disguise` value | `Timestamp` identical to a `Spotted` emitted in the preceding frames |
| `BrokenDisguiseCleared` | 2 / 1 / 0 | **string**: outfit repository id | same | `2018db77…` @393.789; `992cc7b6…` @624.087 — each equal to the preceding `DisguiseBlown` value | 9 ms and 11 ms after a `Kill` |

Raw examples (B0, user and platform ids omitted):

```
{"Timestamp":13.011781,"Name":"StartingSuit","ContractSessionId":"2516109628137904204-c00b2d17-…","ContractId":"00000000-0000-0000-0000-000000000200","Value":"874c4c48-0a8b-49e9-883e-49fc5f1fb051","Origin":"gameclient","Id":"3b200548-…"}
{"Timestamp":202.104156,"Name":"Disguise","ContractSessionId":"…","ContractId":"…0200","Value":"2018db77-aa8a-4bf9-9afb-56bdaa161156","Origin":"gameclient","Id":"3d83fef5-…"}
{"Timestamp":222.863129,"Name":"DisguiseBlown","ContractSessionId":"…","ContractId":"…0200","Value":"2018db77-aa8a-4bf9-9afb-56bdaa161156","Origin":"gameclient","Id":"6209107e-…"}
{"Timestamp":393.788727,"Name":"BrokenDisguiseCleared","ContractSessionId":"…","ContractId":"…0200","Value":"2018db77-aa8a-4bf9-9afb-56bdaa161156","Origin":"gameclient","Id":"28a079c9-…"}
```

All four share one shape: the whole `Value` is a non-empty string holding an outfit repository id, with the standard envelope and no `_DONTSEND`, no `XboxGameMode`/`XboxDifficulty` twin (unlike `Spotted`), exactly one emission per occurrence (8 occurrences, 8 sends). This is the `ContractFailed` shape (`Value` is a string), already handled by the intake and by `NormalizeContractEnded`'s reader path.

Related evidence that is **not** a disguise event but constrains the semantics:

| Source | Field(s) | What it adds |
|---|---|---|
| `ContractStart` (B2 validated → `contract.started` v1) | `Disguise` (string), `IsHitmanSuit` (bool) | the outfit at session start and whether the engine classes it as the hitman suit; the only `IsHitmanSuit` statement in the corpus for the worn outfit. Observed `874c4c48…`, `true` in all five sessions (B0 ×2, B2 ×3) |
| `Kill` / `Pacify` (B1 validated; fields not normalized) | `OutfitRepositoryId`, `OutfitIsHitmanSuit` | the outfit 47 wore at each outcome. **All 16 B0 outcomes agree with the latest preceding `Disguise` value** (`2018db77…` for the 5 outcomes between 202.1 s and 497.8 s; `992cc7b6…` for the 11 after), `OutfitIsHitmanSuit false` throughout |
| `Spotted` | `[actor repository id]`, emitted twice per occurrence | the actor(s) who spotted 47; shares its `Timestamp` with `DisguiseBlown` in both B0 cases |
| `Witnesses` | `[actor repository id]` | the actor(s) the engine records as witnesses; in both B0 cases the `BrokenDisguiseCleared` followed the `Kill` of the last actor named in a `Witnesses` since the `DisguiseBlown` |
| `Trespassing` | `{IsTrespassing, RoomId}` | `Disguise` @202.104 was followed by `Trespassing {false}` @202.179 (B0) and by a `Trespassing` 227 ms later (B1): changing disguise altered the trespass evaluation |
| `ChallengeCompleted` `UI_CHALLENGES_GLOBAL_FRESH_DISGUISE_NAME` | `_DONTSEND` | client-local challenge fired 8 ms after each `Disguise`; policy of section 18 applies (not normalized) |
| `AmbientChanged` | `Ambient` string | both `DisguiseBlown` followed the ambient reaching `Arrest` (value 7) within the same contract-clock tick |

### 30.2 Observed ordering (B0 session 1, contract clock; B1 ordering by name agrees)

```
  0.000  ContractStart        Disguise=874c…  IsHitmanSuit=true
 13.012  StartingSuit         874c…                      (same frame as IntroCutEnd)
166.198  Trespassing          {true, room 6}
202.104  Disguise             2018db77…                  ← change 1
202.112  ChallengeCompleted   FRESH_DISGUISE  (_DONTSEND)
202.179  Trespassing          {false, room 3}
221.431  Spotted ×2           [28aaef75 Rousseau]
222.833  Spotted, Witnesses   [5dc7ede5 Ducloitre]
222.863  Spotted ×2           [5dc7ede5];  AmbientChanged → Arrest
222.863  DisguiseBlown        2018db77…                  ← compromise 1 (same tick as the Spotted)
223.6–232.0  Pacify Parker, Rousseau, Ducloitre; SituationContained; Ambient → Ambient   (NOT a clear)
393.780  Kill                 Ducloitre (the Witnesses actor), outfit 2018db77…
393.789  BrokenDisguiseCleared 2018db77…                 ← clear 1, 9 ms after that Kill
488.867  Kill                 Quiron (guard), outfit 2018db77…
497.756  Disguise             992cc7b6…                  ← change 2 (after killing the guard)
614.984  Witnesses            [43207611 Roux]
615.013  Spotted ×2           [43207611];  AmbientChanged → Arrest
615.013  DisguiseBlown        992cc7b6…                  ← compromise 2
619.902  Spotted ×2, Witnesses [a5cdd554 Bourque]
620.154  Kill                 Roux            (first witness; no clear)
624.076  Kill                 Bourque         (last witness)
624.087  BrokenDisguiseCleared 992cc7b6…                 ← clear 2, 11 ms after that Kill
656–764  10 more outcomes, all outfit 992cc7b6…
907.953  ContractFailed       (restart) — no disguise event on the way out
```

B1 (names only): `StartingSuit`+`IntroCutEnd` 2.3 s after the rise; `Trespassing` → `Disguise` → `Trespassing` (227 ms); `Disguise` again after `SituationContained`; `Spotted ×2` → `Witnesses` → `DisguiseBlown` (224 ms span); four `Kill` (the explosion) → `BrokenDisguiseCleared` 222 ms after the last; restart: `StartingSuit`+`IntroCutEnd` 2.5 s after the rise. B2: `StartingSuit`+`IntroCutEnd` only (no disguise change was made).

Never observed in any run: a `Disguise` whose value is the starting suit (the operator never changed back); a `Disguise` while a `DisguiseBlown` was outstanding; a second `DisguiseBlown` for an already-blown id; a `BrokenDisguiseCleared` without a preceding `Kill`; a `BrokenDisguiseCleared` for an id that was not the one worn; any disguise event outside the predicate window; any disguise event on the frontend; `ContractEnd`, player death, save/load, Freelancer, contracts mode, other locations.

### 30.3 The three semantic questions, kept separate

**Q1 — What is being worn?**

| Source | What Glacier states directly | Evidence that it is a completed transition, not an attempt | What it does not state |
|---|---|---|---|
| `ContractStart.Disguise` + `IsHitmanSuit` | the outfit (definition id) the session starts in; whether it is the suit | — | nothing about later changes |
| `StartingSuit.Value` | the outfit at the end of the intro cut | restates `ContractStart.Disguise` (2/2 with payloads) | not a change; carries no `IsHitmanSuit` |
| `Disguise.Value` | the player's outfit is now this definition id | the fresh-disguise challenge fires 8 ms later; trespass re-evaluates 75 ms later; **16/16 later outcomes carry the same `OutfitRepositoryId`** | whether it is the suit; which NPC/instance it was taken from; variation/charset; that *every* change emits one event (no counter-example in 4 changes, no S2 cross-check in production) |

Current-outfit reconstruction from the stream is therefore supported by the corpus: *latest of (`StartingSuit`, `Disguise`) in the attempt*, with `contract.started` as the pre-rise statement of the initial outfit. The gap that cannot be closed from existing evidence: a change that emits no `Disguise` (none seen; B0's "recovery without S1" finding is a reason to keep the question open, not evidence of a disguise gap).

**Q2 — What does compromised mean?**

Glacier states: *disguise definition X is blown* (`DisguiseBlown.Value` = the worn id, both cases). It does not state the scope — whether the compromise attaches to the definition for the rest of the session, to the current wear only, or to the witnesses — nor who blew it. The co-occurring `Spotted`/`Witnesses` (same `Timestamp`) and the ambient escalation to `Arrest` are correlations observable in the stream, not fields of the event. Prior art: Peacock keeps `disguisesRuined` as a set keyed by outfit id, added on `DisguiseBlown` and removed on `BrokenDisguiseCleared`; that is Peacock's reading of the stream, not evidence about the engine. The B0 evidence **cannot distinguish** per-definition from per-wear scope, because no disguise change happened while a compromise was outstanding, and nothing in this design assumes either.

Two things must therefore be kept apart. **Observed compromise history** — the ordered `DisguiseBlown`/`BrokenDisguiseCleared` occurrences with their ids — is fact and is always reported. **Current compromise of the worn outfit** is a derivation that is defensible only while the compromised id is still the worn id and no outfit change or clear has intervened; the moment an outfit change is observed, whether the earlier compromise persists (on that definition, on the next wear of it, or at all) is **unknown** and is reported as unknown — neither asserted nor cleared — until the engine says something (a further `DisguiseBlown`, a `BrokenDisguiseCleared`), or a controlled run supplies evidence (30.11, steps 5 to 7).

**Q3 — What does clearing mean?**

Glacier states: *disguise definition X is no longer blown* (`BrokenDisguiseCleared.Value` = the previously blown id, both cases). Observed mechanism, two cases plus B1's name-only match: the clear followed the `Kill` of the last actor named in `Witnesses` since the compromise, by 9 to 222 ms; pacifying those same actors — all three in case 1, with `SituationContained` — did **not** clear. That is a hypothesis about the engine's rule from three instances, recorded as such; the Relay event must carry only "cleared", not "cleared because the witnesses died". Unknown after a clear: whether the id can be blown again (same id twice — never seen), whether other clearing paths exist (witness loses track, time, scripted), whether changing disguise clears or hides the state.

Semantics matrix:

| Fact | Direct source | Safe normalization | Possible BEAM derivation (labelled derived) | Unsupported inference |
|---|---|---|---|---|
| outfit at session start, suit or not | `contract.started` (validated) | already on the wire | shown on its own evidence line beside the paired attempt; **never initializes `worn`** (the in-attempt `initial` assertion does that) | that the attempt's first worn outfit is this id (it was, in 7/7 observations, but `contract.started` is a session-level statement correlated by order) |
| outfit at intro end | `StartingSuit` | `disguise.equipped` with `kind: "initial"` (`engine_event: "StartingSuit"` as provenance) | in-attempt anchor for `worn` when no change has been seen yet; cross-check against the paired session's starting disguise (mismatch → anomaly) | that it is the suit (only `contract.started` says so) |
| outfit changed to X | `Disguise` | `disguise.equipped` with `kind: "change"` (`engine_event: "Disguise"`) | `worn := X` and a **new wearing interval** begins; `used` (distinct definition ids); change count. The previous interval's standing — compromised, cleared or none — does not carry over: the new interval starts `:unknown` if any compromise was observed earlier in the attempt, else `:not_observed` | source NPC, instance, variation; whether X is a suit (derive only as "equals the session's starting id *and* that was `is_hitman_suit`", labelled); that a change clears or preserves an earlier compromise |
| X compromised | `DisguiseBlown` | `disguise.compromised` | the occurrence is kept immutably; it opens a compromise episode for X or restates the open one; "the worn outfit is compromised" only when it is the latest such occurrence in a reliable current interval and X is the worn id | who blew it; that *any* compromise is outstanding when none was observed (absence ≠ clean); that the compromise persists across a later outfit change |
| X no longer compromised | `BrokenDisguiseCleared` | `disguise.compromise_cleared` | the occurrence is kept immutably; it closes the open episode for X; the worn outfit's standing becomes `cleared` only under the same interval rule | the reason (witness death is a hypothesis); that other disguises are clear; that a clear naming another id says anything about the worn outfit |
| current disguise at an outcome | `Kill`/`Pacify` `OutfitRepositoryId` (not normalized) | none in B3 | future consistency check if `actor.*` v2 ever carries it | — |

### 30.4 Identity and display names

**What the id is.** All four events carry a `ZRepositoryID` of an outfit *definition*. In the SDK (`relay/m2` headers, not read at runtime by Relay): `ZContentKitManager::m_repositoryGlobalOutfitKits` is `TMap<ZRepositoryID, TEntityRef<ZGlobalOutfitKit>>`; `ZGlobalOutfitKit` has `m_sCommonName`, `m_sTitle`, `m_rNameTextResource` (localized), `m_pParentOutfit`, `m_aCharSets` (variation collections), `m_bHeroDisguiseAvailable`; the player's state side is `ZHitman5::m_InitialOutfitId`, `m_rOutfitKit`, `m_nOutfitVariation`; NPCs carry `ZActor::m_OutfitRepositoryID` and `m_nOutfitVariation`; `ZPlayerRegistry::m_OutfitId` also exists. So the telemetry id names the definition (the "kit"); **charset/variation and the source instance are not in the telemetry.** Two NPCs wearing the same kit are indistinguishable by this id, and taking either produces the same `Disguise` value. Whether the engine's compromise bookkeeping is keyed by this definition id is not evidenced (30.3, Q2). Actor repository-id semantics (section 20: 30 generic collisions among 338 actors) do not transfer: for actors a shared id was a limitation on instance identity; for disguises the definition *is* the subject.

**Stability.** `874c4c48…` was the starting outfit in all five sessions across two game processes and two days (B0 ×2 payloads, B2 ×3 payloads); the two NPC outfits each recurred identically across their blown/cleared pair. Stable within a build; nothing is known about other builds, and no claim is made.

**Names.** No disguise event carries a readable name, and none of `Level_Setup_Events`, `ChallengeCompleted` or the challenge name string resolves an outfit id. Resolution would require an engine read: either the outfit kit map above (`m_sCommonName`/`m_sTitle`, or the localized `ZTextLine`), or the repository walk the Editor and Randomizer mods perform (`ZRepositoryItemEntity` dynamic objects with `Title`/`CommonName`/`Name` keys). Both are S2-class reads (section 21) on an engine object, requiring their own justification, boundary review and probe; neither is proposed for B3. **B3 carries ids only.** A BEAM-side display map (ids → names, explicitly non-authoritative, filled from a later probe or by hand) is an M3 presentation concern and not part of this design. The summary prints the id, abbreviated, exactly as it prints actor repository ids today.

### 30.5 Occurrence events versus BEAM-maintained state

| Criterion | A — explicit occurrence events only (`disguise.equipped` / `disguise.compromised` / `disguise.compromise_cleared`), no derived state | B — the same events plus a BEAM-derived per-attempt disguise view |
|---|---|---|
| Fidelity to the source | each Relay event = one engine occurrence with one id; nothing stronger than the payload | same events; the view adds *labelled* derivation |
| Replayability (M4) | complete: the history is the events | complete: the view is a fold over the events and can be rebuilt |
| Initial state | `contract.started` + `StartingSuit`: present as events | `worn` starts `:not_observed` until the first in-attempt assertion; the paired session's starting disguise is shown as a separate evidence line |
| Compromise scope | not represented | observed history as fact; the worn outfit's standing derived only while no change intervened; persistence across a change reported as `unknown` |
| Reconnect / observation loss / gaps | events stop | view freezes as "last known" and marks its history incomplete; the worn outfit's standing degrades to `unknown` |
| Unknowns | implicit | explicit: `not_observed`, `unknown`, "no compromise observed" (never "clean") |
| M2 exit criterion (summary from events) | the summary would list events | the summary can say "worn X from #k; compromised #m, cleared #n; last known worn Y; standing of the worn outfit: …" — the useful sentence, with its uncertainty attached |
| Cost | 4 table rows, 1 event struct, 3 Relay event types, BEAM validation | + one fold in `Lifecycle`, summary lines, tests |

**Recommendation: B**, as B1 did for outcomes (events first-class on the attempt; counts and state derived in BEAM and labelled). The events are the protocol; the view is BEAM's reading of them and never crosses back into the events. Native does nothing beyond mapping four string payloads.

### 30.6 Proposed events (all **proposed**; nothing accepted)

One event struct natively (`DisguiseEvent { kind, engine_event, disguise_repository_id, contract_session_id?, engine_timestamp_s? }`), three Relay event types, four table rows:

| Glacier name | Relay event | Relay `kind` | `engine_event` (provenance) | Gating |
|---|---|---|---|---|
| `StartingSuit` | `disguise.equipped` v1 | `"initial"` — the outfit the attempt began in, asserted by the engine at intro end | `"StartingSuit"` | attempt-gated |
| `Disguise` | `disguise.equipped` v1 | `"change"` — the worn outfit changed to this id | `"Disguise"` | attempt-gated |
| `DisguiseBlown` | `disguise.compromised` v1 | — | `"DisguiseBlown"` | attempt-gated |
| `BrokenDisguiseCleared` | `disguise.compromise_cleared` v1 | — | `"BrokenDisguiseCleared"` | attempt-gated |

Payload (all three types; `kind` on `disguise.equipped` only):

| Field | Source | Required | Type / rule |
|---|---|---|---|
| `source` | — | yes | `"engine_telemetry"` |
| `kind` | the table row (Relay-owned) | yes on `disguise.equipped`; absent on the other two | `"initial"` \| `"change"`. The semantic distinction is Relay's: an initial assertion restates the outfit the attempt started in and is not a change; a change is the engine's statement that the worn outfit is now X. A consumer reads this, not `engine_event`, to tell them apart |
| `engine_event` | `Name` | yes | one of the four names above; provenance only, as on `contract.*` |
| `disguise_repository_id` | `Value` | **yes, non-empty string** (the subject) | string, verbatim; not validated as a GUID (the engine's format is evidence, not a contract) |
| `contract_session_id` | envelope | optional (as on `actor.*`) | string |
| `engine_timestamp_s` | envelope `Timestamp` | optional | number |

Not carried: `is_hitman_suit` (no source states it for a change; deriving it from id equality is BEAM's labelled job), the challenge, `Spotted`/`Witnesses` ids, ambient, actor names, any compromise scope or persistence claim. Malformed (counted per name, logged, not published, no sequence consumed): `Value` not a string, empty string; any `Value` object/array/number for these names. `_DONTSEND` on any of the four names: the section 18 policy applies unchanged (none observed). No duplicate-emitter policy: one send per occurrence was observed for all four; if a run ever shows two sends with equal `(Name, Timestamp, Value)`, that is a finding to record, not something to suppress natively.

Naming: `disguise.equipped` says what Glacier asserts — the worn outfit is now X — without claiming the player "took" it from someone; `disguise.compromised` / `disguise.compromise_cleared` keep the engine's own blown/cleared pair without the word "blown" and without implying detection scope. Alternatives considered: `disguise.changed` (rejected: a generic name invites folding the three facts into one); `disguise.blown` / `disguise.cleared` (rejected: "cleared" alone reads as "disguise removed"); normalizing `StartingSuit` to a separate `disguise.initial` type (rejected: same subject and shape as `equipped`; the Relay-owned `kind` carries the distinction with one fewer schema); distinguishing the two by `engine_event` alone (rejected: provenance is not semantics; a consumer should not need Glacier's names to read Relay's). Deferring `StartingSuit` entirely was also considered and is the fallback if review prefers three rows: the cost is that the in-attempt `worn` state would depend on the contract pairing for its initial value, which is a cross-domain derivation the `StartingSuit` row makes unnecessary.

### 30.7 Gating and timing, per event

Evidence: all 17 disguise-event deliveries across the three runs (B0 8, B1 6, B2 3) occurred strictly inside the predicate window — `StartingSuit` 2.3 to 29.8 s after the rise (contract clock 2.28 to 13.0 s), the others mid-mission — none on the frontend, none in a fall frame, none during an unload, none between `ContractFailed` and the fall. The B1 rule "publish only while `Playing()`, otherwise count *outside attempt* and log" therefore discards nothing the corpus contains, and the counter is the instrument that would reveal a surprise. Contrast with B2: contract events were ungated because the corpus showed them outside the window on both edges; the disguise corpus shows the opposite. **All four rows attempt-gated**; no grace window, no native attachment, no queue change.

**What the frame-order contract does and does not guarantee.** `RelayFrame::Process` drains the queue once per frame and judges each drained observation against the attempt state that was authoritative *before* this frame's edge; it then processes the edge. So: an observation already queued when the drain runs is published before that frame's edge (a `Disguise` emitted before the drain in a fall frame publishes before `mission.stopped`). An occurrence the engine emits *later in the same frame*, after the drain — exactly what the exit-path `ContractFailed` did in section 29 — is drained on the **next processed frame**, after the edge, and across a scene unload that frame comes seconds later. For an attempt-gated row that means *outside attempt*: counted, logged with its name and index, not published, no sequence consumed — the B1 policy, unchanged. Consequence stated plainly: **a disguise occurrence emitted in the fall frame after the drain does not reach the wire**; the native counter is the only evidence of it, and BEAM must not assume that the last disguise event it holds for an attempt was the engine's last disguise occurrence. No disguise event has been observed in a fall frame on either side of the drain; this is the guarantee's edge, not an observed loss.

**Mid-attempt observation is possible and must be handled.** The adapter is an outbound client that reconnects after TCP loss (1 to 30 s backoff) and continues the same sequence; events published while disconnected are dropped and appear to BEAM as a sequence gap; a BEAM restart loses its state while the native stream continues; and the Stage A model already keeps an attempt open across an interruption. BEAM may therefore see an attempt whose disguise history begins in the middle (first disguise event is a `change` or a `compromised`), has a gap after its last disguise event, or has no `initial` at all. The derived view handles each conservatively:

| Situation | Handling |
|---|---|
| No `equipped` yet on the attempt (the 2 to 30 s before `StartingSuit`, or ever) | `initial: :not_observed`, `worn: :not_observed`. The paired contract session's `starting_disguise_repository_id` is shown on its own evidence line ("contract.started says 874c…") and is **never promoted into `worn`** |
| First disguise event is a `change` (no `initial` seen) | `worn := X`; `initial` stays `:not_observed` |
| An `initial` arrives after a `change` (never observed; possible only through a delayed drain or a replay) | recorded; anomaly `:initial_after_change`; `worn` is **not** overwritten (the change is the later engine statement by stream order; `engine_timestamp_s`, when present, is recorded beside the anomaly but not used to reorder). A second `initial` before any change is a restatement: note `:initial_restated`, `worn` unchanged, and an anomaly `:initial_conflict` if its id differs |
| A `compromised` arrives with `worn` unknown or for an id ≠ `worn` | kept; episode opened or restated; note `:compromised_not_worn`. As the latest occurrence in the interval it makes the worn outfit's standing `:unknown` (the engine spoke about an outfit Relay does not think is worn; `worn` may be stale) |
| A `compromise_cleared` with no open episode for that id | kept; anomaly `:cleared_without_compromise`; no episode is created; standing follows the interval rule (a clear naming the worn id with no open episode is still that interval's latest statement and yields `:cleared`; naming another id yields `:unknown`) |
| Sequence gap or interruption **inside the current wearing interval** (after the `equipped` that started it) | the interval is unreliable: `worn_standing := :unknown` for the rest of that interval whatever arrives — a later compromise or clear naming the stale worn id cannot re-establish standing. The standing the interval had before the cut is reported beside the cut, labelled, not asserted. A gap or interruption *before* the interval started marks the attempt's `history` incomplete but does not make a fresh `equipped` unreliable |
| Observation lost (`:peer_closed`, process gone) while the attempt is open | an interruption, handled as above: facts frozen; `worn` "last known"; standing `:unknown` with the pre-cut standing shown; nothing is cleared or asserted |

Restart resets the view with the attempt, since the view is per attempt; nothing carries across sessions (a new `ContractSessionId` and a fresh `StartingSuit` were observed on every restart). That is an observation about the stream, not a claim that the engine's compromise state resets.

### 30.8 Proposed BEAM model and summary — the fold contract (reconciled for implementation)

Facts and derivations are different objects. The facts are the events; everything else is a pure function of them plus the attempt's existing gap and interruption evidence, rebuilt on demand and never stored on its own.

```
Lifecycle.Attempt.disguise_events  — ordered disguise occurrences {type, kind, sequence, timestamp, received_at, payload}
                                     (immutable facts; type ∈ :equipped | :compromised | :compromise_cleared; kind ∈ :initial | :change | nil)
Disguise.derive(attempt, instance) — a pure fold over disguise_events + instance.gaps + attempt.interruptions:
  initial:            :not_observed | %{repository_id, sequence}                     — the first equipped/initial
  worn:               :not_observed | %{repository_id, since_sequence, kind}          — the current WEARING INTERVAL, started by
                                                                                        every change and by an initial seen before any change
  compromise_episodes: [%{repository_id, compromised_sequences: [..], cleared_sequence: nil | n}]
                      — DERIVED GROUPING of the compromised/cleared occurrences, in order of first compromise:
                        a compromised X with no open episode for X opens one; while one is open, further compromised X
                        are appended to it as restatements; a cleared X closes the open episode for X; a cleared X with
                        none open creates no episode (anomaly). The occurrences themselves stay in disguise_events.
  worn_standing:      :not_observed | :compromised | :cleared | :unknown                — for the current interval ONLY
  standing_cut:       nil | %{kind: :gap | :interruption, at, standing_before}        — why the interval is unreliable, and what it
                                                                                        said before the cut (shown, not asserted)
  used:               [repository_id]  (distinct, first-seen order; definitions, not "disguises taken")
  changes:            count of kind == :change
  history:            :complete | {:incomplete, [{:gap, expected, got} | {:interruption, at, reason} | :superseded]}   — attempt-level
  notes:              [{:compromised_not_worn, id, seq}, {:compromised_restated, id, seq}, {:initial_restated, seq}]  — benign, recorded
  anomalies:          [{:initial_conflict, seq, id, first_id}, {:initial_after_change, seq, id},
                       {:initial_differs_from_contract, seq, id, contract_starting_id}, {:cleared_without_compromise, id, seq}]  — recorded, nothing rewritten
Instance.unattributed_disguise_events — disguise events received with no open attempt (never attached by adjacency)
```

`worn_standing`, evaluated in this order and only for the current wearing interval:

1. **Unreliable interval → `:unknown`.** A sequence gap whose first missing sequence is after the interval's `since_sequence`, or an interruption after the `equipped` that started the interval (by receipt time; an interruption with no receipt time to compare against counts), makes the interval unreliable for the rest of its life. Whatever arrives afterwards — including a compromise or clear naming the stale worn id — cannot re-establish standing. `standing_cut` records the cut and the standing the interval had just before it.
2. **Otherwise, the latest compromised/cleared occurrence inside the interval decides.** If it names the worn id: `:compromised` or `:cleared`. If it names another id: `:unknown` (the engine spoke about an outfit Relay does not think is worn).
3. **Otherwise, if any compromise occurrence exists earlier on the attempt — open or cleared, any id → `:unknown`.** This is the "every change invalidates the previous interval's standing" rule: A → compromised A → cleared A → B leaves B `:unknown`, not `:cleared` and not `:not_observed`.
4. **Otherwise `:not_observed`.**

Rules for the other fields, in stream order: `equipped/initial` sets `initial` (first one) and, if no change has been seen yet, starts the interval; a later `initial` before any change is `:initial_restated` (and `:initial_conflict` if its id differs); an `initial` after a change is `:initial_after_change` and does not touch `worn`. `equipped/change` always starts a new interval. `compromised`/`compromise_cleared` only ever append facts and update the episodes; they never write `worn`. Nothing is derived from `mission.stopped`, TCP close, outcomes, `Spotted`, ambient or time. The B0 session itself is the regression case for rule 3: `initial S; change A; compromised A; cleared A; change B` → `:unknown` at that point, then `compromised B` → `:compromised`, `cleared B` → `:cleared`.

`Events.validate` accepts the three types at v1 with the fields of 30.6 (Relay names only). `MissionSession` routes them like outcomes. Summary, per attempt — observed facts, then the derivation with its uncertainty on the same line:

```
    disguises (engine telemetry): contract.started says 874c4c48… (hitman suit); initial 874c4c48… #k @13.0s;
      change → 2018db77… #p @202.1s; compromised 2018db77… #q @222.9s; cleared 2018db77… #r @393.8s;
      change → 992cc7b6… #s @497.8s; compromised 992cc7b6… #t @615.0s; cleared 992cc7b6… #u @624.1s
    disguise state (BEAM-derived): worn 992cc7b6… since #s; worn outfit: cleared (#u); 2 changes, 3 definitions used; history complete
```

Other forms, all tested: after `change B` with A's episode open (30.10, synthetic): `worn <B> since #s; worn outfit: unknown (compromise observed earlier in this attempt: <A> #q, episode open; not evidenced for this wear)`; after `change B` with A cleared: `… unknown (compromise observed earlier in this attempt: <A> #q, cleared #r; not evidenced for this wear)`; after a cut: `worn <A> since #p (last known); worn outfit: unknown (gap at #k inside this wear; before it: compromised #q)` / `(observation lost 2026-…Z inside this wear; before it: none)`; `disguises (engine telemetry): none observed` / `disguise state (BEAM-derived): not observed`; `history incomplete: gap 12→15, observation lost …`. Wording rules: never "clean", "undetected", "safe" or "Silent Assassin"; never "suit" for a changed disguise unless the id equals the paired session's starting id and `is_hitman_suit` was true, and then as "(equals the starting suit id)"; the compromise reason is never stated; an earlier episode is described with its own facts ("episode open" / "cleared #r"), never as the worn outfit's standing.

### 30.9 Bounded implementation plan (not authorized)

Native (`relay/m2`, from `9f746cad`, one root cause per commit): **B3-R1** `DisguiseEvent` in `RelayEvent.h`, serialization, one `RelayAdapter::Publish(const DisguiseEvent&)` overload choosing the event type from the native kind (`Initial`/`Change` → `disguise.equipped` with the wire `kind`; `Compromised`; `CompromiseCleared`), four `k_Sources` rows (AttemptGated, new `Family::Disguise…` values), `NormalizeDisguise` using the existing string-`Value` reader (non-empty string, envelope passthrough), `Result.disguise` member, fixture `B0Disguise.h` (the 8 recorded payloads, identifiers redacted), `DisguiseTelemetryTests.cpp`. **B3-R2** `RelayFrame::Process`: publish `s_Normalized.disguise` on the attempt-gated branch beside `event` (no new branch logic; the gate is the existing one), `RelayFrameTests` additions. **B3-R3** wire probe step `b3` replaying B0 session 1's order (`ContractStart`, rise, `StartingSuit`, `Disguise`, `DisguiseBlown`, three `Pacify`, `Kill`, `BrokenDisguiseCleared`, `Disguise`, `DisguiseBlown`, two `Kill`, `BrokenDisguiseCleared`, `ContractFailed`, fall) through the real normalizer and adapter. Expected zero-line changes: `TelemetryIntake.cpp` (its name gate already defers to `IsSupportedSourceName`), `TelemetryQueue.h`, `TcpRelaySink.*`, `MissionObserver.*`; same single detour; inertness table as B2.

BEAM (`main`, from `a86e649`): **B3-R4** `Events.validate` for the three types. **B3-R5** `Lifecycle` records `disguise_events` (facts only); a new pure module `GlacierRelay.Disguise` implements `derive/2` exactly as 30.8 states it; `Summary` lines; `MissionSession` log notes; fixture `b3_probe_envelopes.ndjson`; tests including the SYN table and replay equivalence. Gate as B2: clean build, 0 relay warnings, 25/25 native, 5× Elixir, standalone wire native↔BEAM 0 mismatches, inertness table, new DLL hash recorded — then stop for runtime authorization.

### 30.10 Test plan (real captured payloads; cases needing new evidence marked)

Two kinds of case, kept apart. **Evidence cases** use the 8 recorded B0 payloads and the observed orderings; their expected results are what the engine did. **Synthetic cases** (marked **SYN**) use those same payloads rearranged, or with one field altered, to pin the model's *conservative behaviour* in situations the engine has not been observed to produce; their expected results are design decisions about uncertainty, not claims about engine semantics, and a later run that contradicts one is a reason to revise the design, not the test.

Native (evidence): the 8 B0 payloads → exact Relay JSON (two `equipped/initial` from `StartingSuit`, two `equipped/change` from `Disguise`, two `compromised`, two `compromise_cleared`); envelope session id and timestamp carried; malformed: `Value` object (the `ContractStart` payload under a disguise name), array (`Spotted`'s), number, empty string, missing `Value`; `_DONTSEND` set on a disguise name → counted, not normalized (synthetic flag on a real payload); unsupported neighbour names (`Spotted`, `Witnesses`, `Trespassing`) still counted and never published; repeated valid occurrence (the same `Disguise` payload twice) → two events (no dedup); ungated contract rows unaffected (B2 tests pass unchanged). Native (**SYN**, `RelayFrameTests`, both fall-frame orderings): (a) a `Disguise` observation queued **before** the drain of the fall frame → published as `disguise.equipped` #N before `mission.stopped` #N+1; (b) the same observation queued **after** that frame's drain (i.e. presented on the next `Process` call together with a scene that is no longer playing) → *outside attempt* +1, warning logged, nothing published, sequence unchanged — and the counters line shows it. **New evidence needed, no fixture invented:** a `Disguise` carrying the suit id; the engine's behaviour on re-equipping a compromised outfit.

Elixir (evidence): validation (required/typed, `kind` constrained to `initial`/`change` on `equipped` and absent elsewhere, unknown version rejected, `disguise.changed` unknown); the B0 session-1 script → `initial`, `worn` after each step, two episodes each opened then closed, `worn_standing` `:not_observed → :compromised → :cleared → (change B) :unknown → :compromised → :cleared`, `used` = 3 ids, `changes` = 2, `history :complete`; listener end-to-end with the native `b3` envelopes; **replay equivalence**: `Disguise.derive/2` of the attempt folded through `Lifecycle.apply_event` equals `derive` of an attempt rebuilt from the bare facts (the same `disguise_events`, gaps and interruptions), on the fixture **and on every incomplete-history case below**; deriving after each prefix of the stream never contradicts a fact already folded (facts are append-only).

Elixir (**SYN**, each expected result is the conservative decision of 30.7/30.8; rule numbers refer to 30.8):

| Case | Script (ids from the B0 payloads) | Expected derived view |
|---|---|---|
| **A → compromised A → cleared A → B** (regression for rule 3) | initial S; change A; compromised A; cleared A; change B | after B: `worn B`, `worn_standing :unknown` (not `:cleared`, not `:not_observed`), A's episode closed; summary "compromise observed earlier in this attempt: A, cleared; not evidenced for this wear" |
| **A → compromised A → B → A** (re-equip) | initial S; change A; compromised A; change B; change A | after B: `worn B`, `:unknown`, A's episode open; after re-equipping A: `worn A`, **still `:unknown`** (rule 3; no engine statement in the new interval); then `compromised A` → appended to A's open episode as a restatement (note `:compromised_restated`), `:compromised` (rule 2); then `cleared A` → episode closed, `:cleared` |
| **Repeated compromises before one clear** | change A; compromised A; compromised A; compromised A; cleared A | one episode with three `compromised_sequences` and one `cleared_sequence`; three occurrences in `disguise_events`; two `:compromised_restated` notes; `:cleared` |
| **Repeated compromise/clear cycles** | change A; compromised A; cleared A; compromised A; cleared A | two closed episodes, no anomaly, `:cleared`; a third `compromised A` left open → `:compromised` |
| **Clear while wearing another outfit** | change A; compromised A; change B; cleared A | A's episode closed; `worn B`; the latest occurrence in B's interval names A → `:unknown` (rule 2) |
| **Delayed / missing initial** | (i) change A with no initial → `initial :not_observed`, `worn A`; (ii) initial S after change A → anomaly `:initial_after_change`, `worn A` unchanged, `initial S` recorded; (iii) initial whose id ≠ the paired session's `starting_disguise_repository_id` → anomaly `:initial_differs_from_contract` (both facts shown, neither rewritten; no anomaly when the attempt has no paired session); (iv) attempt with no disguise event at all → `not_observed` throughout, `contract.started`'s id on its own line only; (v) a second initial S before any change → `:initial_restated`, nothing changes; with a different id → `:initial_conflict` | as stated |
| **Observation gaps** | (i) initial S; change A; compromised A; **gap**; actor outcome → `history {:incomplete, [{:gap, …}]}`, `worn A (last known)`, `:unknown`, `standing_cut.standing_before :compromised` (rule 1); (ii) **gap before** any disguise event, then change A → `history` incomplete, `worn A`, `:not_observed` (a cut before the interval does not make the fresh `equipped` unreliable); (iii) change A; compromised A; **gap**; cleared A → episode closed, standing **stays `:unknown`** (rule 1: the stale worn id cannot be re-established by a later clear naming it); (iv) change A; **gap**; compromised A → `:unknown`, not `:compromised` (same) | as stated |
| **Interruption** | change A; compromised A; connection closed (`:peer_closed`); reconnect, identified; cleared A | `history` incomplete (`{:interruption, at, :peer_closed}`); A's episode closed; `:unknown` with `standing_before :compromised`; a subsequent `change A` after the reconnect starts a reliable interval → rule 3 → `:unknown` until the engine speaks about it |
| **Fall-frame orderings (wire level)** | (a) `disguise.equipped` #N then `mission.stopped` #N+1 → attached to the attempt; (b) `disguise.equipped` arriving after the attempt's `mission.stopped` with no attempt open → `Instance.unattributed_disguise_events`, never attached by adjacency, no anomaly on the closed attempt | as stated |
| **Compromise with worn unknown** | compromised A as the first disguise event of the attempt | episode open; note `:compromised_not_worn`; `worn :not_observed`; `worn_standing :not_observed` (there is no interval); a following `change A` → rule 3 → `:unknown` |
| Restart | attempt 1 with open episodes; `mission.stopped`; `mission.playing` | attempt 2 starts `not_observed`; attempt 1's view unchanged |
| TCP close | any state, then `:peer_closed` with no reconnect | facts frozen; `worn` last known; standing `:unknown` with the pre-cut standing shown; nothing cleared or asserted; summary says "observation lost … inside this wear" |
| Summary wording | all of the above | the words "clean", "undetected", "safe", "Silent Assassin" never appear; "suit" only as "(equals the starting suit id)"; an earlier episode renders with its own facts, never as the worn outfit's standing |

### 30.11 Standalone and controlled runtime validation (proposed; the run requires its own authorization)

Standalone: `GlacierRelayWireProbe 4747 sleep:1500,b3,sleep:800` → BEAM receives the full session-1 order with contiguous sequences; native `published` lines equal BEAM's reconstructed events field for field; the fixture is committed.

Controlled run (setup as B2, same pre-flight, hash rollback; BEAM first; VS after the menu gate). The script is built so that the persistence question is actually exercised: switching away from a compromised outfit alone cannot answer it, so the compromised outfit is **re-equipped** before anything clears it.

1. menu — no telemetry expected.
2. fresh Paris; wait for the intro cut to end — expect `disguise.equipped` `kind initial` (`874c…`) a few seconds after `mission.playing`, inside attempt 1; BEAM's cross-check against `contract.started` passing.
3. take NPC disguise **A** — expect one `disguise.equipped` `kind change`.
4. get spotted in A until the ambient escalates — expect `disguise.compromised` A; BEAM `worn_standing :compromised`. Keep the witness(es) alive and un-pacified.
5. **change to a second NPC disguise B while A's compromise is outstanding** — expect `disguise.equipped` `change` B; BEAM `:unknown` with A's entry open. New evidence: whether anything else is emitted at the change (a clear? a second compromise?).
6. **re-equip A** (return to where it was dropped, or a second NPC in the same outfit) — expect `disguise.equipped` `change` A. **New evidence, the decisive step:** whether the engine emits a second `DisguiseBlown` A on re-equip (→ it restates compromise per wear), emits nothing (→ either persisted silently or lapsed — the operator notes the HUD's compromised indicator and NPC reaction as *observations outside the stream*), or emits `BrokenDisguiseCleared` A somewhere in steps 5 to 6 (→ the change cleared it). Until this is seen, the model stays `:unknown` by design.
7. with A worn, eliminate the witness(es) by a kill — expect `disguise.compromise_cleared` A (and record whether it arrives at all if the engine never restated the compromise in step 6).
8. optionally repeat 3 to 4 with B, then clear while wearing a *different* outfit, to see which id the clear names.
9. if a wardrobe or the dropped suit is reachable, return to the suit — new evidence: a `Disguise` carrying the suit id, or nothing.
10. restart — expect attempt 2 to begin `not_observed`, then `initial`; 11. exit to menu; 12. quit.

Record for each disguise event: frame offset from the nearest `Spotted`/`Witnesses`/`Kill`, the ambient value, the ids, and the operator's HUD/NPC observations at steps 5 to 7 (labelled as such). Pass: every `captured` disguise name appears exactly once in BEAM as the mapped event with the native values, attached to the attempt open at the time; the derived view after each step is consistent with what the operator did *and with the uncertainty the design assigns*; B1/B2 behaviour unchanged (contract pairing, actor outcomes); no `ERROR`/`FAULT`; rollback by hash.

Expected but not safety-relevant, as clarified for B1 and B2: `outside attempt 0`, `malformed 0`, `queue dropped 0`. A nonzero value in any of them, a change with no `Disguise`, a `Disguise` with an unexpected id, a compromise whose id is not the worn one, a clear with no preceding compromise, two sends per occurrence, or any surprise at steps 5 to 7 is a **semantic or engineering discrepancy**: it is recorded with its evidence, validation is not loosened, nothing is fixed forward, and the run continues. **Abort conditions stay as established:** native fault, unexpected debugger break, game instability, severe performance impact, unsafe memory behaviour, hook install failure or other safety-relevant behaviour — stop, capture, roll back.

### 30.12 Open questions, probe need, smallest next stage

| Question | Blocks B3 implementation? | How it is answered |
|---|---|---|
| Does a compromise persist across an outfit change, and on re-equipping the same outfit? | no — the model reports `:unknown` after a change and asserts nothing until the engine speaks | steps 5 to 7 of the controlled run (re-equip before clearing); no probe needed to *choose* the conservative model |
| Does returning to the suit emit `Disguise` with the suit id? | no — the normalizer maps whatever arrives | step 9 |
| Other clearing paths (witness escapes, time, scripted)? | no — only "cleared" is carried | later runs; recorded as unknown |
| Can the same id be blown twice, or restated on re-equip? | no — a second compromise is a recorded note, not an error | step 6; later runs |
| Outfit display names | no — ids only in B3 | a separately justified S2 read or an M3 map |
| Does every change emit exactly one `Disguise`? | no | the production counters plus operator notes in the run; an S2 cross-read is not proposed |

**Is another research probe required before implementation? No.** All four shapes are in the B0 corpus at full fidelity; the ordering is replicated in B1; the only unknowns are transition cases the normalizer does not need to understand, which the B3 controlled run itself can produce. No probe is needed merely to *choose* the conservative model: `:unknown` after a change is the correct output under every persistence reading, and evidence can only narrow it later. The production adapter still cannot capture a new raw shape (`telemetry_log = raw` is not implemented); if a disguise event ever arrives malformed, the `malformed_by_name` counter and the logged detail will say which field, and a probe-branch capture can follow.

**Smallest next implementation stage, if approved:** B3-R1 through B3-R5 above — four attempt-gated table rows mapping string payloads to `disguise.equipped` / `disguise.compromised` / `disguise.compromise_cleared` v1, BEAM validation, the per-attempt derived disguise view and summary lines, fixtures from the 8 B0 payloads, the `b3` wire step — followed by the gate, and only then a controlled run under its own authorization. B4 (items), B5 (objectives), B6 (player state; `Trespassing` and `HoldingIllegalWeapon` remain there), detection/witness events, and any name resolution are out of scope and untouched.

Stop here for architectural review. **B3 implementation and runtime await review.**

---

## 31. B3 implementation record (2026-10-08) — built and validated without the game

Authorized as "bounded B3 implementation, B3-R1 through B3-R5, followed by standalone validation" on the section 30 design as reconciled in 30.8 (commit `ad1f476`). Deployment and a HITMAN runtime experiment were explicitly outside the authorization. **`GlacierRelay.dll` has not been deployed since the B2 run.** The implementation review (2026-10-08) found one reproducible BEAM defect, fixed in `63184c4` before any deployment (BEAM-only; the native checkpoint `e9001ee4` and its DLL are unchanged).

### Architecture as built

The B1/B2 pipeline unchanged, plus four attempt-gated table rows, one event struct and one pure BEAM fold:

```
TelemetryNormalizer table   StartingSuit → disguise.equipped (kind initial)   Disguise → disguise.equipped (kind change)
                            DisguiseBlown → disguise.compromised              BrokenDisguiseCleared → disguise.compromise_cleared
                            (all attempt-gated; Kill/Pacify and ContractStart/ContractFailed rows unchanged)
RelayFrame::Process         drain → normalize → attempt-gated: publish iff Playing(), else "outside attempt" (unchanged gate)
BEAM Lifecycle              Attempt.disguise_events (immutable facts, by stream order); Instance.unattributed_disguise_events
BEAM Disguise.derive/2      the fold of section 30.8, computed on demand from the facts + gaps + interruptions, never stored
```

The intake is unchanged: `IsSupportedSourceName` answers true for the four names, so the detour copies their string `Value`, `ContractSessionId` and `Timestamp` exactly as for `ContractFailed`. Same single detour, no S2, no S3, no engine writes, no name resolution; ids only.

### Public events (all v1)

`disguise.equipped` — `source`, **`kind`** (`initial` | `change`, Relay-owned, required), `engine_event` (`StartingSuit` | `Disguise`, provenance), `disguise_repository_id` (required, non-empty, verbatim), optional `contract_session_id`, `engine_timestamp_s`. `disguise.compromised` / `disguise.compromise_cleared` — the same without `kind` (`engine_event` `DisguiseBlown` | `BrokenDisguiseCleared`). Malformed (counted per name, logged, not published, no sequence consumed): `Value` not a string, empty or absent. `_DONTSEND` policy unchanged. No deduplication.

### Native changes (`relay/m2`, from `9f746cad`)

| Commit | Change |
|---|---|
| `ddc9987f` B3-R1 | `DisguiseEvent` (`Kind` Initial/Change/Compromised/CompromiseCleared), `DisguisePayloadJson`, adapter overload selecting the event type from the kind, four `k_Sources` rows, `NormalizeDisguise` (string-`Value` reader), fixture `B0Disguise.h` (the 8 recorded B0 payloads, user/platform ids removed), `DisguiseTelemetryTests.cpp` |
| `0a62c03c` B3-R2 | `RelayFrame::Process` publishes `Result.disguise` on the existing attempt-gated branch; frame-order tests for both sides of a fall frame's drain |
| `e9001ee4` B3-R3 | wire probe step `b3`: B0 session 1's disguise order interleaved with its actor outcomes, restart, second session's `StartingSuit`, exit to menu |

Files with **zero** changed lines: `GlacierRelay.{cpp,h}`, `SceneObservation.cpp`, `TelemetryIntake.{cpp,h}`, `TelemetryQueue.h`, `TcpRelaySink.{cpp,h}`, `MissionObserver.cpp`. 14 files changed in all (+673/−2), of which 515 lines are tests, fixture and probe.

### BEAM changes (`main`, from `a86e649`)

| Commit | Change |
|---|---|
| `ad1f476` | section 30 fold contract reconciled (docs only) |
| `b04ff57` B3-R4 | `Events.validate` for the three types; `kind` required and constrained on `equipped`, rejected elsewhere; 7 tests |
| `e7620e7` B3-R5 | `Lifecycle.DisguiseOccurrence` facts on attempts (unattributed with no open attempt; never by adjacency); interruptions gain `after_sequence`; `GlacierRelay.Disguise.derive/2`; `Summary` observed + derived lines; `MissionSession` note; 25 tests |
| `5c4d332` | fixture `relay/test/b3_probe_envelopes.ndjson` (the 22 native envelopes of the standalone run), fixture decode/fold tests, two listener tests over TCP |
| `63184c4` review fix | `Disguise.gaps_in_attempt/2` bounded history only by `attempt.stopped`, so a **superseded** attempt (no stop) acquired every later gap on the instance and its standing could change as later attempts progressed (reproduction: `mission.playing #1; equipped A #2; compromised A #3; mission.playing #5` with gap 4→5; `equipped B #6; compromised B #9` with gap 7→9 — attempt 1 reported both gaps). `Lifecycle` now records `superseded_at`, the superseding rise's sequence, as boundary evidence on the superseded attempt (no stop is fabricated; `stopped` stays nil); `derive` bounds gaps by the stop or by that rise; `history` carries `{:superseded, by, at}`. A gap detected at the superseding rise is the superseded attempt's (it was still open); a gap detected at a rise after a proper stop lies between attempts and is instance-level evidence only. 5 regressions: the reproduction, supersession with and without a boundary gap, chained supersessions, ordinary stopped attempts, and extending later attempts leaving earlier views unchanged. |

`Disguise.derive/2` as implemented, in the order of 30.8: `initial` = first `equipped/initial` (a later one before any change is `:initial_restated`, `:initial_conflict` if the id differs; after a change it is `:initial_after_change` and leaves `worn` alone); `worn` = the current wearing interval, started by every `change` and by an `initial` seen before any change; `compromise_episodes` = derived grouping (open episode restated by further `compromised X`, closed by `cleared X`; a stray clear is `:cleared_without_compromise` and creates nothing); `worn_standing` with `standing_reason` — (1) a gap whose first missing sequence, or an interruption whose `after_sequence + 1`, is after the interval's start → `:unknown` (`:cut`, with `standing_cut.standing_before`); (2) else the latest compromised/cleared occurrence in the interval → `:compromised`/`:cleared` if it names the worn id (`:latest_names_worn`), `:unknown` if another (`:latest_names_other`); (3) else any compromise occurrence before the interval → `:unknown` (`:earlier_compromise`); (4) else `:not_observed`. `history` lists the attempt's gaps (bounded by its stop or its `superseded_at`), interruptions and supersession. `contract.started` never initializes `worn`; an `initial` differing from the paired session's starting disguise is `:initial_differs_from_contract`. The summary says "history intact / history broken: …" because "complete" is reserved.

### Tests

| Layer | Result |
|---|---|
| Native `GlacierRelayTests` | B1/B2 suites unchanged and passing; `DisguiseTelemetryTests`: table (four names; `Spotted`, `Witnesses`, `Trespassing` not supported); the 8 B0 payloads → kind, provenance, id, session, timestamp; exact wire JSON for all three types (`kind` only on `equipped`); adapter type mapping and one shared sequence; malformed (object, array, number, empty, absent) counted per name; optional provenance absent not empty; `_DONTSEND`; repeated occurrence → two events; B1/B2 classes unchanged; B0 session order through `RelayFrame::Process` interleaved with actor outcomes; fall-frame (a) queued before the drain → published before `mission.stopped`; (b) emitted after it → outside attempt, not published, no sequence; ungated contract event beside an outside-attempt disguise event; malformed consumes no sequence. Clean tree: pass, 0 relay warnings; **25/25 consecutive runs** on the clean binary. |
| Elixir | **128 tests, 5× stable** at `63184c4` (baseline: 87 before B3; 94 after B3-R4's seven validation tests; 119 after B3-R5; 123 with the fixture and listener tests; 128 with the review-fix regressions): validation; the B0 session (standings `:not_observed → :compromised → :cleared → :unknown → :compromised → :cleared`, episodes, used, changes, wording); the SYN table of 30.10 — A → compromised A → cleared A → B (`:unknown`), re-equip (still `:unknown`, then `:compromised` on restatement, `:cleared`), three compromises before one clear (one episode, three sequences, every occurrence kept), cycles, clear naming another outfit, delayed/missing/restated/conflicting initial, no disguise event at all, gap inside the wear (`standing_before` shown), gap before the wear, stale id not re-established by a later clear or compromise, new equipped after the gap, interruption cut and reconnect, interruption before the wear, TCP close, superseded attempt (bounded by the superseding rise; the five review-fix regressions), unattributed after the stop, restart from nothing; **replay equivalence**: `derive` from the folded attempt equals `derive` from the bare facts on six streams including every incomplete-history case, and every prefix's facts are a prefix of the final facts; wording never "clean", "undetected", "safe", "Silent Assassin" or "complete"; the 22-envelope fixture decodes field for field against the native JSON and folds to the recorded view; two listener tests over TCP (full run; unattributed `disguise.compromised`). |
| Standalone wire | `GlacierRelayWireProbe 4747 sleep:1500,b3,sleep:800` → BEAM: **22 lines, 0 rejected**, order `contract.started #1, mission.playing #2, disguise.equipped #3 (initial), disguise.equipped #4 (change), disguise.compromised #5, actor.pacified #6–#8, actor.died #9, disguise.compromise_cleared #10, disguise.equipped #11, disguise.compromised #12, actor.died #13–#14, disguise.compromise_cleared #15, contract.ended #16, mission.stopped #17, mission.playing #18, contract.started #19, disguise.equipped #20 (initial), mission.stopped #21, contract.ended #22`; **22/22 native `published` envelopes equal to BEAM's reconstructed events, 0 field mismatches**; attempts 1–17 → 1, 18–22 → 2; attempt 1 `worn 992cc7b6… since #11; worn outfit: cleared; 2 changes, 3 definitions used; history intact`, attempt 2 `worn 874c4c48… (equals the starting suit id) since #20; worn outfit: no compromise observed`; no unattributed, no anomaly. Run on the incremental binary (`relay-20261008-215826-99284.log`, SHA-256 `824f16c1b734f974cf5aa76a97abe303125afe950e8bf2f6bed3c16ef4142c23`; its `published` lines are the committed fixture), again on the clean binary (`relay-20261008-220613-99920.log`, `ec6c9bc6…`; sequence, type, schema and payload identical to the first run; 22/22, 0 mismatches), and again on the same clean binary against the corrected BEAM at `63184c4` (`relay-20261008-223950-86296.log`, `e9139ccd…`; 22/22, 0 mismatches, derived views unchanged — the fix concerns superseded attempts, which the run does not contain). Evidence in `%TEMP%\glacier-m0\hitmen\wire-probe\b3\` (`beam-b3.log`, `beam-b3-clean.log`, `beam-final-state.txt`, `beam-events.ndjson`, `native-beam-compare*.txt`, `clean/`, the scripts). |

### Clean build and inertness

`_build/relay-x64-Debug` deleted; configure, build and tests at `e9001ee4`: pass, 0 warnings from relay sources (`b3-clean.log`). **`GlacierRelay.dll` SHA-256 `c045f92a813ef70d5b92fe8f06d38c999af41fda7cc9c7552044117d0043ef1b`** (10,060,800 bytes); `GlacierRelayWireProbe.exe` `f18e375d…`.

| Check | Result |
|---|---|
| Detours | the one `ZAchievementManagerSimple_OnEventSent` detour; `DEFINE_PLUGIN_DETOUR` / `DECLARE_PLUGIN_DETOUR` sites unchanged (one each) |
| S2 / S3 / engine writes / name resolution | none (`ActorManager`, `m_activatedActors`, `SignalOutputPin`, `ZActor_YouGotHit`, `SetProperty`, `SetWorldMatrix`, `SetObjectToWorld*`, `SetOutfit`, `ZContentKitManager`, `m_rOutfitKit`, `m_OutfitRepositoryID`, `ZGlobalOutfitKit` absent from `Src/`) |
| Imports / exports | set-compared against the saved Stage A dump (`m2-imports.txt`; B1 and B2 each reported identical imports to their predecessor, so this is the transitive comparison): the only import not in Stage A is the `OnEventSent` hook B1 added; nothing removed; exports identical (`CompiledSdkAbiVersion`, `CompiledSdkVersion`, `GetPluginInterface`); `WS2_32` ordinal set identical (14 ordinals + `inet_pton`), no `accept`/`bind`/`listen` (ordinals 1/2/13 absent) |
| TCP / intake / queue / observer | 0 lines changed |
| Boundary | SDK headers only in `GlacierRelay.{cpp,h}`, `SceneObservation.cpp`, `TelemetryIntake.cpp`; `GlacierRelayTests` and the probe build every other source without the SDK include path |

### What this does and does not establish

Established without the game: the four shapes normalize exactly as the B0 corpus has them; the frame-order guarantee holds at both sides of a fall frame; the fold reproduces its view from bare facts on complete and incomplete histories; the wire carries the three types unchanged end to end. Not established, by design: anything about the engine's behaviour on transitions the corpus lacks — a `Disguise` carrying the suit id, a change while a compromise is outstanding, re-equipping a compromised outfit, other clearing paths. The model answers all of those with `:unknown` until a controlled run (section 30.11) supplies evidence. **The B3 controlled runtime experiment requires its own authorization; nothing has been deployed.**

---

## 32. B3 controlled runtime experiment (2026-10-08, 22:46Z to 23:35Z) — pipeline PASS; disguise vocabulary NOT validated

Authorized explicitly as "one controlled B3 runtime experiment under §30.11" on the frozen artifacts: ZHMModSDK `relay/m2` `e9001ee4`, clean-built `GlacierRelay.dll` SHA-256 `c045f92a813ef70d5b92fe8f06d38c999af41fda7cc9c7552044117d0043ef1b` (the installed copy hashed identically in `retail-installed.sha256`), glacier-relay `d5a343c` (containing the BEAM correction `63184c4`). Refs, working trees and the DLL hash were verified before deployment; no implementation change or rebuild before, during or after the run. Objective: validate the four attempt-gated disguise rows at runtime, the re-equip-before-clearing transition the design left `:unknown`, and B1/B2 behaviour beside them.

**Verdict, from the evidence: the relay pipeline passed and the disguise vocabulary did not validate.** Every one of the nine disguise occurrences the engine emitted was captured by the detour and **rejected by the normalizer as malformed — `Value is not a string`**; zero `disguise.*` events crossed the wire. Qualified precisely (review of 2026-10-08): **confirmed** — all nine copied `Value`s failed the normalizer's String requirement (`TelemetryValue::Kind != String`); **unconfirmed** — what kind the intake copied for each (`Null`, `Unsupported`, `Object`, `Array`, …), the exact engine type(s), and whether all four source names use the same type. The run's log does not contain that information (section 33 adds it). The malformed path behaved exactly as designed (counted per name, warned with name and index, nothing published, no sequence consumed, run continued). The B1 actor rows (23 `Kill`, 1 `Pacify`) and the B2 contract rows (2 `ContractStart`, 1 `ContractFailed`) normalized and published correctly beside them: **30/30 envelopes, 0 field mismatches, 0 drops, 0 outside attempt, 0 ERROR/FAULT.** B3 is therefore **not accepted**; `disguise.equipped` / `disguise.compromised` / `disguise.compromise_cleared` remain unvalidated vocabulary. Root cause is identified below and is not fixed here.

### Setup and pre-flight

Game `3.280.0.0`; 107-file `Retail` listing and hashes identical to the B2 post-cleanup baseline; 26/26 M0 hashes OK; `mods.ini` = M0 (`b90b4c5e…`); no Relay, Hitmen or probe artifact; both repositories clean at the frozen commits; HITMAN not running; port 4747 free on both sides. BEAM first (`relay@VENGEANCE`, listening 22:46:15Z) with the live subscriber. Installed 22:46:31Z; full-tree diff = exactly `mods/GlacierRelay.dll` (`c045f92a…`) and `mods.ini` (`a66a44ed…`, the B1/B2 relay variant). No `glacierrelay.ini`. Operator attached Visual Studio after the menu gate; no effect on the log.

### R1 — menu gate

Pass. Loader: `Successfully installed detour for hook 'ZAchievementManagerSimple_OnEventSent' at address 0x140b6fd50`, `Mod glacierrelay successfully loaded`, 0 errors. Native: DLL built `Oct 8 2026 15:02:35`, `SDK 4.1.1 (ABI 1)`, `Init: one detour registered (…, read-only); lifecycle is polled`, adapter **`1365917c-6918-4adc-91c0-0383d53c6897`**, `telemetry_log names`, queue 256, `tcp sink: connected` 22:48:52.175Z; BEAM accepted 16 ms later. Menu 5→6→7→8: no event; **zero frontend telemetry**; 0 WARN/ERROR/FAULT.

### Script as executed (deviations in bold)

| § 30.11 step | Executed | Engine (native capture) | Wire / BEAM | Operator (HUD/NPC) |
|---|---|---|---|---|
| 2 fresh Paris | yes | `ContractStart` 22:52:29.407Z (stage 7) → rise 22:52:29.696Z; `StartingSuit` + `IntroCutEnd` 22:53:00.762Z (31 s after the rise) | `contract.started #1` 123 ms before `mission.playing #2`; **`StartingSuit` captured, not normalized** | in control in the suit |
| 3 take disguise A | yes — **from a locker, no NPC** | `ItemDropped` → **`Disguise` captured, not normalized** (22:55:35.101Z) → `Trespassing` same ms → `ChallengeCompleted` `_DONTSEND` +242 ms | nothing | wearing A (waiter) |
| 4 compromise A, keep witnesses alive | compromised; **then the operator killed one NPC** | `Spotted`×2 → `Witnesses` → **`DisguiseBlown` captured, not normalized** (23:00:28.525Z, +220 ms); `Kill` Parker 23:00:34.778Z; **`BrokenDisguiseCleared` captured, not normalized, 244 ms after that `Kill`** | `actor.died #3` | HUD compromised; two others ran for a guard |
| 4 (redo) compromise A again, witnesses alive | yes | `Spotted` → `Witnesses` → **`DisguiseBlown` (23:03:01.513Z)**, second `Witnesses` +234 ms; no clear | nothing | HUD compromised, 2 NPCs |
| 5 change to B | **operator returned to the previously worn suit (reported as "the other suit I was originally in"), not a third outfit** | `ItemDropped` → **`Disguise` and `BrokenDisguiseCleared` in the same millisecond** (23:05:03.727Z) → `Trespassing` +219 ms; **no kill involved** | nothing | — |
| 6 re-equip A | yes | `ItemDropped` → **`Disguise` only** (23:07:59.349Z) → `Trespassing`; **no `DisguiseBlown` restated** | nothing | **HUD: compromised** |
| 7 kill the witnesses wearing A | yes — 2 witnesses + the guard they alerted | `Kill` ×3 (23:10:00.661Z, 23:10:04.839Z, 23:11:21.780Z), `SituationContained` after the second and third; **no `BrokenDisguiseCleared` at any point afterwards** (observed through 23:27Z) | `actor.died #4–#6` | **HUD: not compromised** after the kills |
| 8 optional clear-while-wearing-other | **not performed separately** (step 5 already produced a clear at a change) | — | — | — |
| 9 restart | yes | `ShotsFired/Hit` → `ContractFailed` 23:27:24.620Z → fall 23:27:25.967Z (1.35 s); reload; `ContractStart` captured during stage 7 (23:27:36.854Z) → rise 23:27:37.080Z; `StartingSuit` + `IntroCutEnd` 23:27:38.934Z (**not normalized**) | `contract.ended #7` (restart) → `mission.stopped #8` → **`contract.started #9` → `mission.playing #10` in the same millisecond** | — |
| 10 exit to menu, 11 fresh load, 12 quit from inside | **not performed as scripted**: attempt 2 became an unscripted combat sequence (19 `Kill`, 1 `Pacify`, `Hero_Health` ×5, 47 shot once), then the operator **quit to desktop from inside the mission** | last delivery index 363 (`Hero_Health`, 23:31:54.102Z); nothing further | `actor.died #11–#29`, `actor.pacified #30`; TCP `:peer_closed` 23:32:00.827Z; no stop, no end | quit |

Suit return (step 9 of 30.11) is covered only by the operator-reported return at 23:05:03; whether that outfit was 47's suit is operator wording, not stream evidence (the ids were not normalized).

### Complete Relay semantic sequence

One adapter instance, one connection, sequences 1–30 contiguous, `gaps []`, 30 lines received, 0 rejected. `#1 contract.started (A) · #2 mission.playing · #3–#6 actor.died · #7 contract.ended (A, restart, contract clock 1848.12 s) · #8 mission.stopped (attempt 1, 2096.3 s) · #9 contract.started (B) · #10 mission.playing · #11–#29 actor.died · #30 actor.pacified · — TCP :peer_closed`. Sessions: A `2516108008655457205-92d4207f-a8ce-49a8-af11-813ea1cb6cfb`, B `2516107987544791131-dd336787-fd88-4716-ab7c-9f39e3d2072d`; both `LOCATION_PARIS`, `mission`, difficulty 2, starting disguise `874c4c48…`, `is_hitman_suit true`. Attempt 1: paired `:next_rise`, `ended_relative :during`, disposition `:restarted`; 4 died (3 civilian, 1 guard; all murder). Attempt 2: paired `:next_rise` (see finding 6), end not observed, disposition `:not_observed`, last known playing, observation lost; 19 died (8 civilian, 11 guard), 1 pacified. `unattributed_outcomes []`, `unattributed_disguise_events []`, anomalies `[]`. Disguise lines on both attempts: `disguises (engine telemetry): contract.started says 874c4c48… (hitman suit); none observed in the attempt` / `disguise state (BEAM-derived): worn: not observed; worn outfit: not observed …` — correct, because nothing reached the wire.

### Native ↔ BEAM comparison

Programmatic (`compare.py` → `native-beam-compare.txt`): **30/30 present, 0 field mismatches** on event type, sequence, timestamp and every payload field; attempts 1–8 → 1, 9–30 → 2; one adapter id. Publish-to-BEAM 1 to 12 ms after the first event.

### Counters (reconciled)

| Checkpoint | Values |
|---|---|
| attempt 1 ended (#8), verbatim | `seen 157, captured 14, unsupported 137, dont_send 6, unreadable 0, truncated 0; queue pushed 14, dropped 0; normalized 6, malformed 8, outside attempt 0, ungated published 2` → 14 captured = 6 normalized (ContractStart, Kill ×4, ContractFailed) + 8 malformed (StartingSuit, Disguise ×3, DisguiseBlown ×2, BrokenDisguiseCleared ×2) |
| process, from the `seen` lines (no end-of-process counters line: no further fall) | seen 353; captured 36 = normalized 27 (2 ContractStart, 1 ContractFailed, 23 Kill, 1 Pacify) + malformed 9 (2 StartingSuit, 3 Disguise, 2 DisguiseBlown, 2 BrokenDisguiseCleared); unsupported 280 across 31 names; `_DONTSEND` 37 (all `ChallengeCompleted`); unreadable 0; truncated 0; queue dropped 0 (no `queue full` warning); outside attempt 0; published 30 = 27 normalized + 3 predicate edges |

Engine indices never delivered to the detour: 6, 36, 79, 166, 188, 232, 243, 247, 320, 354 (10 of 363); as established, not a Relay continuity signal.

### Root cause of the malformed disguise occurrences (identified, not fixed)

`TelemetryIntake::Copy` converts `ZString`, `bool`, `float32/64`, integer types, objects and arrays; a value whose reflection type name is empty, whose data pointer is null or whose type is `void` becomes `Kind::Null`; any other engine type is kept as `Kind::Unsupported` carrying the type name. `NormalizeDisguise` reports `Value is not a string` for every non-String kind without distinguishing them. What is **confirmed** is therefore only that the copied `Value` was not a `ZString`. **Hypothesis, not evidence:** the id travels as `ZRepositoryID` (static support: `ZRepositoryID` derives from `ZGuid`, a 16-byte GUID; both are registered reflection types whose `pszTypeName` the SDK's Editor looks up by exactly those strings; the B0 probe serialized events with the engine's own `ZDynamicObject_ToString`, which renders typed values as JSON and would print such a GUID as a string; the B2 `ContractStart.Disguise` *field* normalized fine and is therefore a `ZString`, which says nothing about the top-level `Value` of these four names). Alternatives the log cannot exclude: a different registered type, a `Null` copy (empty type name or null data), or an object/array wrapper. The design's "exact payload shape" (30.1) was exact at the JSON level, which is what the fixture and the normalizer tests exercise; the engine-type dimension was never covered by any test and could not be without the engine. Any correction is an intake change at the Glacier-facing boundary with its own design review, tests and run — not a validation relaxation — and it waits for the type to be read at runtime (section 33).

### Findings (event-name chronology from capture order, and operator HUD observations, kept apart; nothing acted on)

Because no disguise payload was normalized, every finding below is about **event names and their order**; which outfit id any of them carried is unknown. Persistence and causation conclusions drawn in the first version of this section are withdrawn to what the evidence supports.

1. **Chronology at the change away from A:** `ItemDropped` → `Disguise` and `BrokenDisguiseCleared` captured in the same millisecond (23:05:03.727Z) → `Trespassing`; no `Kill` in the preceding minutes. **Which outfit id the `BrokenDisguiseCleared` named is unknown.** It is therefore not established whether the engine cleared A, cleared the outfit being put on, or emitted a clear for another reason; only that a clear-named event co-occurs with a change on this transition.
2. **Chronology at the re-equip of A:** `ItemDropped` → `Disguise` → `Trespassing` (23:07:59.349Z); no `DisguiseBlown` restated. **Operator observation, separate:** the HUD showed the outfit compromised at that moment. The stream was silent on the compromise at re-equip; what the engine's internal state was is not evidenced by the stream.
3. **Chronology after the witness kills while wearing A:** three `Kill` (23:10:00.661Z, 23:10:04.839Z, 23:11:21.780Z), `SituationContained` twice, no `BrokenDisguiseCleared` through the end of the attempt. **Operator observation, separate:** the HUD later showed the outfit not compromised. Whether the kills, the earlier change-time clear, time, or something else accounts for the HUD state is not evidenced. Contrast, as chronology only: the first compromise's `BrokenDisguiseCleared` was captured 244 ms after a `Kill` (23:00:35.033Z), the B0/B1 shape; no causal reading is made.
4. `DisguiseBlown` again followed `Spotted`/`Witnesses` by ~220 ms, both times; `Disguise` was again followed by `Trespassing` within the same frame (3/3) — the B0/B1 ordering shape reproduced on the names.
5. **Direct quit from inside the mission with the B3 binary: outcome B** — nothing at the hook after `Hero_Health` (23:31:54.102Z); BEAM saw only `:peer_closed`; attempt 2 last known playing, end not observed; nothing synthesized. Third consecutive observation of this path.
6. **Restart path, third ordering variant for `ContractStart`:** captured during stage 7, 226 ms before the rise, so it drained before the edge — `contract.started #9` then `mission.playing #10` in the same millisecond. B1 and B2 had it after the rise (`:open_attempt`); here BEAM paired `:next_rise`. Both rules handle it; the restart path has no fixed order.
7. **New names (production, names only):** `ItemDropped` (7), `ItemDestroyed` (1), `Hero_Health` (5). `Hero_Health` was listed as unobserved in section 24; `Hero_Dead` still unobserved (47 was shot but did not die).
8. `contract.ended` led the restart fall by 1.35 s (B0 1.93, B1 1.84, B2 1.03, B3 1.35: no fixed lead).
9. No actor outcome, contract or lifecycle regression: B1 and B2 rows behaved as in their accepted runs beside nine malformed disguise observations, including in the same drains.

### Performance, warnings, errors, faults, debugger

Operator: **no perceivable frame-rate effect**; no numeric measurement. Native log: **482 lines; 9 WARN, all the "not normalized" disguise lines; 0 ERROR; 0 FAULT**; two threads. BEAM: 0 rejected lines; the expected close-while-playing warning only. No debugger break; the process ended by the operator's quit.

### Cleanup and hash verification

Final BEAM state captured (`beam-final-state.txt`, `beam-events.ndjson`), BEAM stopped by RPC, `GlacierRelay.dll` removed, `mods.ini` restored from the pre-flight copy; `retail-after.*` identical to `retail-before.*` (107 files); 26/26 M0 hashes OK; no Relay, Hitmen or probe artifact; port 4747 free; process gone. One procedural repeat of the section 29 false alarm: a `pkill -f` on the watcher's script name matched the operator shell's own command line and killed that shell before the cleanup ran; the cleanup was then rerun without any broad kill (the watcher had already exited on the process exit). Evidence in `%TEMP%\glacier-m0\hitmen\b3-run1\` (23 files): native log `relay-20261008-224830-83392.log` (SHA-256 `ce60de92…`), `beam.log` (`c10dd510…`), `beam-final-state.txt` (`65abd8fb…`), `beam-events.ndjson` (`010e3dd3…`), `native-beam-compare.txt`, both loader logs, `mods.ini` before/relay/after-run, `Retail` listings and hashes before/installed/after, `installed-at.txt`, and the scripts (`live_watch.exs`, `final_state.exs`, `compare.py`, `watch-b3.sh`).

### Unresolved

- The engine type of the disguise `Value` (needs the type name, available from the intake's `Unsupported` record, before any change).
- Which id the change-time `BrokenDisguiseCleared` names; whether the HUD-visible clearing after the witness kills has any stream counterpart; whether a second `DisguiseBlown` ever occurs for an already-blown id.
- Exit-to-menu, second fresh load and the optional clear-while-wearing-other case were not executed in this run.

**Conclusion.** The B3 code is safe and inert at runtime and left B1/B2 behaviour intact, but it validated nothing of the disguise vocabulary because the copied `Value` of these four names is not a `ZString`; what it is remains to be read. The run produced event-name chronology for the transitions the design asked about, with the outfit ids unknown; that chronology is consistent with the conservative fold (`:unknown` after a change) and inconsistent with any model that would have derived a definite standing from the change-time clear, but it does not establish the engine's persistence semantics either way. Next step, for review: a type-discovery run with the diagnostic of section 33, then a bounded intake change under its own design and gate. **M2 remains incomplete; the B3 vocabulary is not accepted.**

---

## 33. B3 diagnostic preparation (2026-10-08) — type discovery; no production fix, nothing deployed

Authorized as a "bounded diagnostic preparation pass" after the section 32 verdict was accepted: no production type conversion, no deployment, no HITMAN run. Starting point verified: glacier-relay `b94b627`, ZHMModSDK `relay/m2` `e9001ee4`, both trees clean, DLL `c045f92a…` in the build tree, game at M0.

### What the existing observation can and cannot supply

The intake already copies, for every captured event, a `TelemetryValue` whose `kind` is one of `Null | Bool | Number | String | Array | Object | Unsupported`, and for `Unsupported` the engine's reflection type name (`pszTypeName`) in `text`. That is the whole of the type evidence available without touching the engine, and it is sufficient to answer the section 32 question in every case but one: a `Null` copy means the intake saw an empty type name, a null data pointer, an empty `ZObjectRef` or `void`, and which of those it was is not recorded. If the run below reports `kind=Null` for any name, the smallest additional metadata copy — for review, not made here — is a one-byte reason code on `TelemetryValue` for the Null branch (`no_type | no_data | empty | void`), set only in `TelemetryIntake::Copy`. No `ToString`, no JSON round trip, no new hook, no engine scan, no retained pointer is proposed.

### The diagnostic change (`relay/m2` `4a616cf9`)

`NormalizeDisguise`'s malformed detail for a non-String `Value` now reads `Value is not a string (kind=<Kind>[ type='<escaped, ≤64 bytes>'])` — `kind=String bytes=N`, `kind=Array items=N`, `kind=Object fields=N`, `kind=Unsupported type='…'`, `kind=Null`, `kind=Bool`, `kind=Number`. The type text is escaped (`\xNN` for quotes, backslashes, control and non-ASCII bytes) and bounded to 64 bytes plus `...`. It travels through the existing frame-thread warning (`telemetry '<name>' (index <n>) not normalized: <detail>`) to the durable log; the rejection outcome, counters (`malformed`, per-name), publication and sequence semantics are unchanged; only disguise rows are affected. Diff: `TelemetryNormalizer.cpp` +47/−1, `DisguiseTelemetryTests.cpp` +78.

Tests added: each kind's detail (Unsupported `ZRepositoryID`, Null, Number, Bool, Array, Object, the intake's `<truncated>` marker, an empty type name); escaping of a hostile type name (`Z'\\\n\x01\xC3\xA9Q` → `Z\x27\x5C\x0A\x01\xC3\xA9Q`); bounding of a 100-byte name; counters still counted per name, nothing published; a valid string unaffected; and the warning line through `RelayFrame::Process` with name and index while the next valid event in the same drain still publishes as sequence 2.

### Gate

Clean build at `4a616cf9`: pass, 0 relay warnings; **25/25** consecutive runs. **`GlacierRelay.dll` SHA-256 `ac6b784ae18299c4d4724c3129525c9fe8ed5113886c946c0f154d28258a4a4e`**; `GlacierRelayWireProbe.exe` `b37313db…`. Imports and exports identical to the B3 DLL (set comparison, ordinals included). Standalone wire `b3` step against BEAM at `b94b627`: **22/22, 0 field mismatches**, derived views unchanged (`relay-20261008-235040-97576.log`, `d49e284d…`; evidence `wire-probe\b3\diag\`); the fixture's string values take the unchanged path. BEAM was started with its launcher PID retained and stopped by RPC only; the launcher exited on its own.

### Static research on the hypothesis (not runtime confirmation)

`ZRepositoryID : ZGuid` (`ZPrimitives.h`), a 16-byte GUID with `FromString`/`ToString(GuidFormat)`; both `ZRepositoryID` and `ZGuid` are registered reflection types — the SDK's Editor resolves `GetTypeID("ZRepositoryID")` / `("ZGuid")` and branches on those exact `pszTypeName` strings. The B0 probe serialized events with `Functions::ZDynamicObject_ToString` (the engine's JSON writer), which is why a typed GUID appeared as a JSON string in the corpus. None of this says what the four disguise events carry at runtime; the diagnostic run does.

### Proposed type-discovery run (NOT executed; requires its own authorization)

Purpose: read the copied kind and type name for each of `StartingSuit`, `Disguise`, `DisguiseBlown`, `BrokenDisguiseCleared`. **Not** a disguise-persistence validation; no transition script beyond what produces one of each name. Artifacts to freeze: `relay/m2` `4a616cf9`, DLL `ac6b784a…`, glacier-relay at the commit recording this section (BEAM unchanged since `63184c4`).

1. Pre-flight as sections 29/32 (hash baseline against `b3-run1/retail-after.*`, 26 M0 hashes, trees clean, DLL hash). BEAM first; **record the launcher PID** in `<evidence>/beam.pid` and the watcher's in `<evidence>/watcher.pid`.
2. Menu gate as before; VS attach after it.
3. Fresh Paris; wait for the intro cut → one `StartingSuit` warning with its kind/type.
4. Take any disguise (locker is fine) → one `Disguise` warning.
5. Get spotted until the HUD shows compromised → one `DisguiseBlown` warning. Witness handling is irrelevant to this run.
6. Change outfit (the change-time path produced a `BrokenDisguiseCleared` in section 32) or kill the witness → one `BrokenDisguiseCleared` warning. If neither path produces it, record that; one of the two did in every run so far.
7. Exit to menu; quit. (Restart optional: a second `StartingSuit` sample.)

Pass: each of the four names has at least one `not normalized: Value is not a string (kind=…)` line; the kinds and type names are recorded per name; B1/B2 behaviour unchanged (contract and any actor events published and matched); `dropped 0`, `outside attempt 0`; no ERROR/FAULT. Expected but not safety-relevant: the four `malformed` counts. Abort conditions as established. Discrepancies (e.g. different kinds across the four names, `kind=Null`, an unexpected type) are the result, recorded, not acted on.

Cleanup is mechanical: `%TEMP%\glacier-m0\hitmen\run-cleanup.sh <evidence-dir>` — RPC `:init.stop`, then only a PID read from `beam.pid`/`watcher.pid` and matched against its own `/proc/<pid>/cmdline` may be signalled, and only if the RPC stop left it running; the game-file steps refuse to run while `HITMAN3.exe` is alive; restoration is verified by the 107-file listing/hashes and the 26 M0 hashes. **No `pkill -f` or any name-pattern kill anywhere in the procedure** (it killed the operator shell in sections 29 and 32).

### After the run

With the kinds known, the smallest production change is a single new branch in `TelemetryIntake::Copy` for the observed type (for a GUID type: read the 16 bytes and render the dashed form through the SDK's own `ZGuid::ToString` or an engine-independent formatter, yielding `Kind::String`), plus a fixture whose values are built from that type rather than from the JSON corpus, plus the normal gate and a further controlled run. That is a separate proposal; nothing of it exists.

**B3 remains unaccepted; M2 remains incomplete.**

---

## 34. B3 type-discovery experiment (2026-10-09, 00:01Z to 00:16Z) — result: `ZRepositoryID` for all four names

Authorized explicitly as "one bounded type-discovery experiment under §33" on the frozen artifacts: ZHMModSDK `relay/m2` `4a616cf9`, diagnostic `GlacierRelay.dll` SHA-256 `ac6b784ae18299c4d4724c3129525c9fe8ed5113886c946c0f154d28258a4a4e` (verified in the build tree and again on the installed copy — distinct from the B3 DLL `c045f92a…`), glacier-relay `2145594`. No implementation change or rebuild. Purpose: read the copied kind and engine type of the rejected disguise `Value` for each of the four names; not a persistence validation. **This experiment authorizes no intake conversion, no rerun and no B3 acceptance.**

### Result

| Source name | Samples | Event index | Copied kind | Engine type name (untruncated) | Exact diagnostic line |
|---|---|---|---|---|---|
| `StartingSuit` | 1 | 9 | `Unsupported` | `ZRepositoryID` | `2026-10-09T00:08:02.627Z WARN telemetry 'StartingSuit' (index 9) not normalized: Value is not a string (kind=Unsupported type='ZRepositoryID')` |
| `Disguise` | 2 | 18, 37 | `Unsupported` | `ZRepositoryID` | `2026-10-09T00:11:37.715Z WARN telemetry 'Disguise' (index 18) not normalized: Value is not a string (kind=Unsupported type='ZRepositoryID')` (and index 37 at 00:13:25.139Z, identical detail) |
| `DisguiseBlown` | 2 | 33, 39 | `Unsupported` | `ZRepositoryID` | `2026-10-09T00:12:35.559Z WARN telemetry 'DisguiseBlown' (index 33) not normalized: Value is not a string (kind=Unsupported type='ZRepositoryID')` (and index 39 at 00:13:25.367Z, identical detail) |
| `BrokenDisguiseCleared` | 1 | 38 | `Unsupported` | `ZRepositoryID` | `2026-10-09T00:13:25.367Z WARN telemetry 'BrokenDisguiseCleared' (index 38) not normalized: Value is not a string (kind=Unsupported type='ZRepositoryID')` |

Six diagnostic lines, six rejections, 6/6 `kind=Unsupported type='ZRepositoryID'` (13 bytes, no escaping or truncation applied). **No occurrence normalized unexpectedly.** The section 32/33 hypothesis is now runtime-confirmed on this build for all four names: the engine passes the outfit definition id as the reflection type `ZRepositoryID` (a 16-byte `ZGuid`-derived value), which the intake records by type name and the normalizer rejects. What remains unconfirmed: whether the 16 bytes rendered in dashed form equal the ids the B0 corpus shows (expected, since `ZDynamicObject_ToString` produced those strings from the same values, but not yet observed through Relay's own path), and the byte order/format the SDK's `ZGuid::ToString(GuidFormat::Dashes)` applies versus the engine's JSON writer.

### Setup, gate, sequence

Pre-flight: 107-file listing/hashes identical to the B3 post-cleanup baseline, 26/26 M0, both trees clean, game at M0, port free. BEAM first (00:01:04Z), its `beam.smp` PID 131578 retained in `beam.pid`; watcher PID 131681 in `watcher.pid`. Installed 00:01:12Z; full-tree diff exactly `mods/GlacierRelay.dll` (`ac6b784a…`) and `mods.ini` (`a66a44ed…`). Menu gate: detour at `0x140b6fd50`, `Mod glacierrelay successfully loaded`, adapter **`1355a1fd-035a-4216-8382-f6105563532d`**, TCP connected 00:03:12.518Z, BEAM accepted 00:03:12.558Z, menu to stage 8 with no event, zero frontend telemetry, 0 WARN/ERROR/FAULT; VS attached after the gate.

Relay sequence: `mission.playing #1` (00:07:54.896Z) → `contract.started #2` (00:07:54.926Z; `ContractStart` captured 2 ms after the rise, published next frame — a **fresh-entry** ordering variant: B1/B2/B3 had it before the rise; BEAM paired `:open_attempt`) → nothing further → TCP `:peer_closed` 00:14:31.791Z. **Native↔BEAM 2/2, 0 field mismatches.** Attempt 1 last known playing, end not observed, disposition `:not_observed`; `disguises: none observed in the attempt` (correct: nothing reached the wire).

Script as executed: fresh Paris (sample 1 at intro end, 7.7 s after the rise) → locker disguise ("palace staff", operator) (sample 2) → compromised by three NPCs (sample 3; `Spotted` ×7 → `Witnesses` → `DisguiseBlown` +238 ms) → changed back to the suit (sample 4 at the change; see chronology) → operator was spotted once more accidentally (`Spotted`/`Witnesses` ×3, no further disguise event) → **deviation: quit to desktop from inside the mission instead of exit-to-menu, then quit.** No combat, no kills, no persistence steps.

Chronology at the change-away (ids unknown, recorded as names only): `Disguise` (index 37, 00:13:25.119Z) → `BrokenDisguiseCleared` (38, 00:13:25.357Z) → `DisguiseBlown` (39, 00:13:25.359Z) → `Trespassing` (40, +226 ms). A clear followed two milliseconds later by a blown, both at the change, is new chronology (section 32 saw `Disguise` + `BrokenDisguiseCleared` only). Nothing is concluded about which outfits they name or what the engine's state was.

### Counters and health

No counters line (no predicate fall occurred). From the `seen` lines: seen 51; captured 7 = normalized 1 (`ContractStart`) + malformed 6 (the six diagnostic rejections); unsupported 43 across 12 names; `_DONTSEND` 1 (`ChallengeCompleted`); unreadable 0; truncated 0; queue dropped 0 (no `queue full` warning); outside attempt 0; published 2. Engine indices never delivered: 4, 50 (2 of 53). Native log: 84 lines, **6 WARN (all six diagnostic lines), 0 ERROR, 0 FAULT**; BEAM 0 rejected, the expected close-while-playing warning only. Direct quit: outcome B (fourth observation). Operator: no perceivable performance effect.

### Cleanup (mechanical)

`run-cleanup.sh b3diag-run1`: RPC `:init.stop` sent; `beam.pid` 131578 (`beam.smp`) had already exited; `watcher.pid` 131681 had already exited on the process exit; HITMAN3.exe confirmed gone before any game-file step; `GlacierRelay.dll` removed; `mods.ini` restored from the saved M0 copy (`b90b4c5e…`); 107-file listing and hashes identical to pre-flight; 26/26 M0 hashes; no Relay, Hitmen or probe artifact; port 4747 free. No process was signalled. Evidence (25 files) in `%TEMP%\glacier-m0\hitmen\b3diag-run1\`: native log `relay-20261009-000251-87268.log` (SHA-256 `2b960a9b…`), `beam.log` (`8f078661…`), `beam-final-state.txt` (`534d8192…`), `beam-events.ndjson`, `native-beam-compare.txt`, both loader logs, `mods.ini` before/relay/after-run, `Retail` listings and hashes before/installed/after, `installed-at.txt`, `beam.pid`, `watcher.pid`, the scripts.

### Proposed smallest correction (for review; nothing of it exists)

One branch in `TelemetryIntake::Copy`, Glacier-facing only: when `TypeNameOf(p_Value) == "ZRepositoryID"` (and, if review agrees, `"ZGuid"`), read the 16 bytes at `GetData()` and emit `Kind::String` with the dashed lowercase GUID text. Rendering should be an engine-independent formatter over the four GUID fields (`data1`/`data2`/`data3` little-endian, `data4` bytes) so that the normalizer's tests can cover it without the SDK; the SDK's `ZGuid::ToString(GuidFormat::Dashes)` is the reference for the expected form and can be compared in a native test that builds a `ZGuid` from one of the B0 strings. Then: a native fixture whose disguise `Value`s are built from the 16-byte representation rather than from the JSON corpus (the four B0 ids as GUIDs), the existing normalizer and frame tests unchanged, the gate (clean build, 25/25, wire `b3`), and a controlled run whose pass criterion is that each disguise occurrence publishes with `disguise_repository_id` equal to the id the B0 corpus shows for the same outfit. `Kill`/`Pacify` and `ContractStart` fields are `ZString` and are not touched. Until that is reviewed and run, **B3 remains unaccepted and M2 remains incomplete.**

---

## 35. B3 intake correction (2026-10-09) — `ZRepositoryID` rendered at the boundary; built and validated without the game

Authorized as "a bounded production correction plus standalone validation" on the accepted section 34 result (six samples, four names, `Unsupported` / `ZRepositoryID`). Deployment and a HITMAN run are outside the authorization. Starting point: glacier-relay `main` `1bfcb5e`, ZHMModSDK `relay/m2` `4a616cf9`, both trees clean apart from this section's own files (verified with `git status` before the gate; the implementation was written in an earlier session whose shell was unavailable, see "Session note").

### Scope decided against the proposal of section 34

Taken: one branch for the **exact** reflection name `ZRepositoryID`. Rejected, as the authorization requires: a `ZGuid` branch, any name-pattern or size-based GUID coercion, `ZGuid::ToString` (an engine `ZString` allocation on the game thread), a JSON round trip, a new hook, a scan or an engine write. `Kill`/`Pacify` and `ContractStart` fields remain `ZString` reads and are untouched. Normalizer schemas, gating, the queue, ownership, the diagnostic detail of section 33 and every BEAM module are unchanged: the normalizer still requires `Kind::String`, and a value that still arrived as `Unsupported`/`ZRepositoryID` would still be rejected with the section 33 detail (tested).

### The change (ZHMModSDK `relay/m2`, one commit on `4a616cf9`: "relay: intake renders ZRepositoryID as the dashed repository id")

| File | Change |
|---|---|
| `Src/RepositoryId.{h,cpp}` (new, engine-independent) | `RepositoryId { uint32 data1; uint16 data2; uint16 data3; uint8[8] data4 }` — the owned value; `FromLittleEndianBytes(array<uint8,16>)` (data1 at 0..3, data2 at 4..5, data3 at 6..7, least significant byte first; data4 at 8..15 in order); `ToDashedLowercase()` — exactly 36 characters, `data1-data2-data3-data4[0..1]-data4[2..7]`, each integer field printed most significant digit first, lowercase hex, leading zeros kept. It is not a hex dump of the memory image. No `fmt`, no SDK include; built into `GlacierRelayTests` and the wire probe without the SDK path, so the boundary is compiler-enforced as before |
| `Src/TelemetryIntake.cpp` (Glacier-facing) | includes `Glacier/ZPrimitives.h`; eight `static_assert`s pin the SDK declaration the branch relies on (`sizeof(ZGuid) == 16`, `sizeof(ZRepositoryID) == 16`, `ZRepositoryID` derives from `ZGuid`, not polymorphic, `data1` `uint32`, `data2`/`data3` `uint16`, `data4` `uint8[8]`); `CopyRepositoryId(const ZRepositoryID&)` copies the four fields **by name** into a `RepositoryId` (the only SDK access of the branch; no byte-order assumption is made at the boundary — the SDK's field declaration is what is read); in `Copy`, after the `ZString` branch: `if (s_TypeName == "ZRepositoryID") { kind = String; text = CopyRepositoryId(*static_cast<const ZRepositoryID*>(s_Data)).ToDashedLowercase(); }`. The `Null` branch (empty type name, null data, empty ref, `void`), the node/depth budget, truncation, and the `Unsupported` fallthrough for every other type are unchanged and precede/follow exactly as before |
| `Tests/Fixtures/B0DisguiseBytes.h` (new) | the three B0 outfit ids as 16-byte little-endian images with their B0 text (`874c4c48…` suit, `2018db77…` A, `992cc7b6…` B), derived by hand from the dashed strings; a per-event table mapping the 8 recorded disguise events to their image |
| `Tests/RepositoryIdTests.cpp` (new), registered in `Tests/Main.cpp` and `CMakeLists.txt` | see Tests |
| `Tests/WireProbe.cpp` | the `b3` step now builds each disguise `Value` from the 16-byte image through `RepositoryId` (envelope fields still from the recorded JSON), so the established standalone wire comparison against the committed BEAM fixture `relay/test/b3_probe_envelopes.ndjson` (B0 strings) checks the rendering end to end; expected result unchanged: 22/22, 0 mismatches |

Byte-order statement, explicit: on the x64 engine a `ZGuid` stores `data1`, `data2`, `data3` least significant byte first, so the raw image of `00112233-4455-6677-8899-aabbccddeeff` is `33 22 11 00 55 44 77 66 88 99 aa bb cc dd ee ff`. The boundary never reads bytes; it reads fields. `FromLittleEndianBytes` exists so that tests and fixtures can start from the memory image the engine holds and prove that the field semantics, not the byte order, drive the text.

### Tests (what is covered offline, precisely)

`RunRepositoryIdTests` (engine-independent, no SDK):

- **Independent known-answer vector**: raw `33 22 11 00 55 44 77 66 88 99 aa bb cc dd ee ff` → `00112233-4455-6677-8899-aabbccddeeff`; the typed construction `{0x00112233, 0x4455, 0x6677, {88 99 aa bb cc dd ee ff}}` renders identically and compares equal to the raw decode; the in-order hex dump `33221100-5544-7766-…` is explicitly **not** the output.
- **Leading zeros**: `01 00 00 00 02 00 03 00 00 04 00 00 00 00 00 05` → `00000001-0002-0003-0004-000000000005`; all-zero image and default `RepositoryId` → the nil GUID.
- **High-bit bytes**: all `ff` → `ffffffff-…`; `80000000-8000-8000-8000-800000000080` from its image (no sign extension); typed `deadbeef-cafe-f00d-fedc-ba9876543210`.
- **B0 ids**: each of the three images renders to the corpus text, 36 characters, lowercase, dashes at 8/13/18/23; typed suit fields equal the raw decode; each of the 8 recorded events' image renders to that event's recorded JSON `Value`.
- **Normalizer path with converted input**: for all 8 events, an observation whose `Value` is the byte-converted string (the JSON `Value` discarded) normalizes to a `DisguiseEvent` equal to the JSON-corpus observation's, attempt-gated, `malformed 0`; the wire payload carries the rendered id.
- **No relaxation**: `Unsupported`/`ZRepositoryID` and `Unsupported`/`ZGuid` values are still `Malformed`.
- **Frame path**: B0 session 1's seven disguise events with byte-built values through `RelayFrame::Process` publish `disguise.equipped ×2, compromised, compromise_cleared, equipped, compromised, compromise_cleared` as sequences 2–8 after `mission.playing #1`, no warnings, each payload with its image's id.

Existing suites (`DisguiseTelemetryTests` incl. the section 33 diagnostic cases, B1, B2, frame, queue, adapter, sink) are untouched.

**Tested offline:** everything after the SDK field read — the field-to-text rendering, the image-to-field decoding, their agreement, the normalizer and frame behaviour on the rendered string, and the wire end to end against the BEAM fixture (gate below). **Pinned at compile time, not tested:** the SDK's declaration of `ZGuid`/`ZRepositoryID` (size, inheritance, field types). **Requires runtime evidence:** (1) that the engine's `ZRepositoryID` value behind `ZDynamicObject::GetData()` has the layout the SDK declares — the `static_assert`s pin the SDK header, not the engine; (2) that the engine's own JSON writer (which produced the B0 strings) renders the same field semantics, i.e. that Relay's text equals the B0 id for the same outfit; (3) that `GetData()` points at the 16-byte value inline for this type, as it does for `ZString` (the existing branch reads `ZString` the same way). The correction to the section 32/HANDOFF statement "no test can exercise the engine-type dimension without the engine" is therefore: the *conversion* dimension is now exercised offline from the engine's byte image; only the three engine-side facts above are not.

### Gate (2026-10-09, 00:47Z to 00:53Z; all observed)

| Step | Result |
|---|---|
| Diagnostic artifacts preserved before any build | `_build/relay-x64-Debug/Mods/GlacierRelay/{GlacierRelay.dll,GlacierRelay.pdb,GlacierRelayWireProbe.exe,GlacierRelayTests.exe}` copied to `%TEMP%\glacier-m0\hitmen\b3diag-artifacts\` with `sha256.txt` and `origin.txt`; the DLL hashed **`ac6b784ae18299c4d4724c3129525c9fe8ed5113886c946c0f154d28258a4a4e`** both in the build tree and in the copy (the section 33/34 value); probe `b37313db…`, tests `9b208b5c…` |
| Clean build (`_build/relay-x64-Debug` deleted; `build-relay-clean.cmd`; log `b3fix-clean.log`) | configure 00:47:34Z, build 00:48:07Z, done 00:49:13Z, exit 0; all eight `static_assert`s compiled as written (no syntax change was needed); **0 warnings from relay sources** — the only warning in the log is the pre-existing C4244 from `_deps/zhmtools-build/…/ZHMEnums.cpp` (one occurrence, same as `b3diag-clean.log`); `GlacierRelayTests: all checks passed` |
| `tests25.cmd` | **`PASSED_RUNS=25`** |
| New artifacts (`b3fix-sha256.txt`) | **`GlacierRelay.dll` SHA-256 `61fe553859667c22145cbfd353e8a3a7717384e056dfa78beee6120cf494bdbc`** (10,069,504 bytes; +4,096 over `ac6b784a…`); `GlacierRelayWireProbe.exe` `cd13ef1042376219c6e115e0f3cc255ee00559a925f8a530015960bf9ba61d18`; `GlacierRelayTests.exe` `60eaa9b2…` |
| Imports / exports (`imports-m2.cmd` → `b3fix-imports.txt` vs `b3diag-imports.txt`) | 295 lines each; with addresses normalized the dumps differ only in the `.text` section size (`0x772000` → `0x773000`, one page); import name set, imported-DLL set and `WS2_32` ordinals identical; exports identical (`CompiledSdkAbiVersion`, `CompiledSdkVersion`, `GetPluginInterface`; only their RVAs moved). The branch added no import, as expected from a field read and an engine-independent formatter |
| Elixir `mix test` ×5 (no BEAM change) | **128/128 ×5** |
| Standalone wire (`GlacierRelayWireProbe 4747 sleep:1500,b3,sleep:800`, evidence `wire-probe\b3\fix2\`) | BEAM started first (`relay@VENGEANCE`, listening 00:51:33Z, launcher PID 137485 in `beam.pid`); probe adapter `da38b233-fab9-4b07-9f13-1a639c95f02f`; **22 published / 22 expected; BEAM 22 lines, 0 rejected; `compare.py` 22/22, 0 field mismatches**; attempts 1–17 → 1, 18–22 → 2; the eight `disguise.*` payloads carry **byte-built** ids — `#3 874c4c48-0a8b-49e9-883e-49fc5f1fb051`, `#4/#5/#10 2018db77-aa8a-4bf9-9afb-56bdaa161156`, `#11/#12/#15 992cc7b6-4ccf-4ae8-a467-e9b2aabaeeb5`, `#20 874c4c48…` — each 36 characters, lowercase, and **equal field for field (event type, schema, payload) to the committed fixture `relay/test/b3_probe_envelopes.ndjson`, 0 differences**; derived views identical to section 31 (attempt 1 `worn 992cc7b6… since #11; worn outfit: cleared; 2 changes, 3 definitions used; history intact`; attempt 2 `worn 874c4c48… (equals the starting suit id) since #20; worn outfit: no compromise observed`). Native log `relay-20261009-005145-100560.log` (SHA-256 `3dab6e09…`), `beam.log` (`c20917c3…`), `beam-final-state.txt` (`1fccfce8…`), `beam-events.ndjson` (`3dabf206…`), `native-beam-compare.txt` (`818f2dca…`), `sha256.txt`. BEAM stopped by RPC `:init.stop`; launcher PID exited on its own; port free; no process signalled |
| Inertness | one `DEFINE_PLUGIN_DETOUR` / one `DECLARE_PLUGIN_DETOUR`; none of `ActorManager`, `m_activatedActors`, `SignalOutputPin`, `ZActor_YouGotHit`, `SetProperty`, `SetWorldMatrix`, `SetObjectToWorld*`, `SetOutfit`, `ZContentKitManager`, `m_rOutfitKit`, `m_OutfitRepositoryID`, `ZGlobalOutfitKit`, `ToString(`, `FromString(` in `Src/`; SDK headers only in `GlacierRelay.cpp`, `SceneObservation.cpp`, `TelemetryIntake.cpp`; `ZGuid` appears in `Src/` only inside the `static_assert`s and comments of `TelemetryIntake.cpp` |

### Session note

The implementation was written in a session whose shell and subagent tools were refused by the Claude Code auto-mode classifier for the whole conversation; that session recorded the gate as pending and verified refs by reading `.git` directly. The gate above was run in the following session after `git status` confirmed the working trees held exactly this section's files on the recorded refs. Nothing in this section claims a result that was not observed.

### Proposed subsequent runtime experiment (requires its own authorization; not scheduled)

Artifacts to freeze: the correction commit on `relay/m2` and its clean DLL `61fe5538…` (the build-tree copy; re-hash before install), glacier-relay at the commit recording this section. Script as section 33 (fresh Paris, locker disguise, compromise, change away, exit, quit; restart optional), with the pass criteria:

1. **`StartingSuit` ↔ `contract.started`:** the `disguise.equipped` `kind initial` id equals the paired session's `starting_disguise_repository_id` (`874c4c48…` on this build in 5/5 sessions), and BEAM raises no `:initial_differs_from_contract`.
2. **All four names cross the typed intake:** every captured `StartingSuit`, `Disguise`, `DisguiseBlown`, `BrokenDisguiseCleared` normalizes (`malformed 0` for the four names; no section 33 warning line) and publishes inside its attempt.
3. **Fidelity and conservative derivation:** native `published` ↔ BEAM 0 field mismatches; the derived view after each step follows section 30.8 exactly: a change starts a new wearing interval and invalidates the previous interval's standing (`:unknown` by rule 3 when any compromise was observed earlier, `:not_observed` by rule 4 when none was); a later compromise or clear naming the worn id inside an uninterrupted interval establishes `:compromised` / `:cleared` by rule 2; nothing is ever derived as "clean"; B1/B2 rows unchanged beside them.
4. **Change-time ids captured, not interpreted:** the ids carried by the change-time `BrokenDisguiseCleared` and the `DisguiseBlown` 2 ms after it (section 34 chronology) are recorded verbatim with their frame offsets and the operator's HUD note; no claim about which outfit they "should" name is made before the run, and the result is recorded as evidence whichever id appears.

Discrepancies are recorded, not fixed forward; abort conditions and the mechanical cleanup are as established. **B3 remains unaccepted and M2 remains incomplete.**

---

## 36. B3 intake-correction runtime experiment (2026-10-09, 01:05Z to 01:17Z) — all four disguise names crossed the typed intake; PASS on its five criteria

Authorized explicitly as "one bounded §35 runtime experiment to validate the ZRepositoryID intake correction" on the frozen artifacts: ZHMModSDK `relay/m2` `84b93778f58c136a36382df6bc08d60a99d6650b`, clean `GlacierRelay.dll` SHA-256 `61fe553859667c22145cbfd353e8a3a7717384e056dfa78beee6120cf494bdbc` (10,069,504 bytes), glacier-relay `b84a1ce5c1e62ada1fce5de42650aad2e472834b`. No implementation change or rebuild before, during or after the run. Purpose: the five criteria below; not a persistence experiment. **This authorization accepts nothing: B3 remains unaccepted and M2 incomplete pending review of this record.**

### Verdict, from the evidence

**Pass on all five criteria.** Nine envelopes, sequences 1–9 contiguous, native↔BEAM 9/9 with 0 field mismatches; the five disguise occurrences the engine emitted (one `StartingSuit`, two `Disguise`, one `DisguiseBlown`, one `BrokenDisguiseCleared`) were captured, normalized and published with 36-character dashed lowercase ids; `malformed 0`, `dropped 0`, `outside attempt 0`; 0 WARN/ERROR/FAULT; the `initial` id equals the paired session's live `starting_disguise_repository_id`; the derived view follows section 30.8 rule for rule. First run in which any `disguise.*` event crossed the wire from the game.

### Setup and pre-flight (all observed)

Refs and working trees verified clean at the frozen commits; build-tree DLL hashed `61fe5538…`; the section 34 diagnostic artifacts re-verified intact in `b3diag-artifacts\` (`sha256sum -c`: 3/3 OK). Game: HITMAN3.exe not running; port 4747 free; 107-file `Retail` listing and hashes identical to the section 34 post-cleanup baseline; 26/26 M0 hashes; `mods.ini` = M0 (`b90b4c5e…`); no Relay, Hitmen or probe artifact; pre-run loader log and newest native log name saved. BEAM first (`relay@VENGEANCE` listening 01:05:22Z; `beam.smp` PID 138432 in `beam.pid`); watcher PID 138509 in `watcher.pid`. Installed 01:05:42Z: installed copy hashed `61fe5538…` again; full-tree diff exactly `mods/GlacierRelay.dll` and `mods.ini` (`a66a44ed…`, the relay variant); no `glacierrelay.ini`.

### Menu gate

Pass. Game started 01:08:40Z; module attached (built Oct 8 2026, SDK 4.1.1 ABI 1); `Init: one detour registered (ZAchievementManagerSimple_OnEventSent, read-only)`; loader `Successfully installed detour for hook 'ZAchievementManagerSimple_OnEventSent' at address 0x140b6fd50` (same as sections 32/34), `Mod glacierrelay successfully loaded`; adapter **`ea63802c-1dee-4f50-9c2e-c5b08732f953`**, `telemetry_log names`, queue 256; `tcp sink: connected` 01:08:55.397Z, BEAM accepted 01:08:55.415Z; menu 5→6→7→8 with **zero frontend telemetry**; 0 WARN/ERROR/FAULT. Visual Studio attached by the operator after the gate; no effect on the log.

### Script as executed (deviations in bold)

| Step | Executed | Engine (native capture, `telemetry seen` index) | Wire / BEAM | Operator (kept separate) |
|---|---|---|---|---|
| fresh Paris | yes | `ContractStart` captured 01:12:42.483Z (index 3, stage 7, **299 ms before the rise** — the fresh-entry order of B1/B2/B3, not section 34's); rise 01:12:42.782Z | `contract.started #1` → `mission.playing #2`, 1 ms apart; session `2516107924542813208-61d0c2a2-de2b-472a-8d77-6e20775a5ad5`; **live `starting_disguise_repository_id` `874c4c48-0a8b-49e9-883e-49fc5f1fb051`, `is_hitman_suit true`** | — |
| wait for the intro cut | yes | `StartingSuit` + `IntroCutEnd` 01:12:54.716Z (indices 11–12; 11.9 s after the rise; contract clock 11.909 s) | **`disguise.equipped #3` `kind initial` `874c4c48-0a8b-49e9-883e-49fc5f1fb051`** | in control in the suit |
| locker disguise | yes | `ItemDropped` 01:14:09.224Z → `Disguise` 01:14:09.518Z (24) → `Trespassing` same ms (25) | **`disguise.equipped #4` `kind change` `2018db77-aa8a-4bf9-9afb-56bdaa161156`** (contract clock 83.213 s) | wearing the locker outfit |
| get compromised | yes | `Spotted` ×8 (01:14:31–49), `Witnesses` ×2 (01:14:49.616Z, .846Z), `AmbientChanged` → `DisguiseBlown` 01:14:50.055Z (42; **+209 ms after the last `Witnesses`**) | **`disguise.compromised #5` `2018db77…`** (123.620 s) | the witness ran to fetch security |
| change back to the starting suit | yes | `ItemDropped` 01:15:01.702Z (43) → `Disguise` 01:15:01.930Z (44) → `BrokenDisguiseCleared` 01:15:01.931Z (45) → `Trespassing` +229 ms (48); **no `DisguiseBlown` after the clear** (contrast section 34); indices 46–47 never delivered | **`disguise.equipped #6` `kind change` `874c4c48…`** (135.720 s) and **`disguise.compromise_cleared #7` `874c4c48…`** (135.746 s), same drain | suit put on while hiding from the search; **no further compromise or kill** |
| exit to menu | yes | fall 01:16:32.108Z; `ContractFailed` captured 01:16:32.109Z (54, same ms as the fall, after the drain) → published next processed frame at stage 2 | `mission.stopped #8` → `contract.ended #9` (`exit_to_menu`, contract clock 223.914 s, **3.31 s after the fall**: the section 29 unload stall) | — |
| quit | yes, from the menu | last line 01:16:36.256Z (menu stage 8); process exited 01:16:58Z | TCP `:peer_closed` 01:16:52.860Z; BEAM "disconnected after 9 line(s), 0 rejected" | — |

No restart, no combat, no persistence steps; no deviation from the script. Optional samples not taken: a second `StartingSuit` (restart not scripted), a second `DisguiseBlown`, a clear by witness elimination.

### Criterion 1 — initial outfit versus the paired session

`disguise.equipped #3` (`initial`, `StartingSuit`) carries `874c4c48-0a8b-49e9-883e-49fc5f1fb051`; the paired `contract.started #1` (BEAM pairing `:next_rise`) carries `starting_disguise_repository_id` `874c4c48-0a8b-49e9-883e-49fc5f1fb051` with `is_hitman_suit true`. **Equal, byte for byte, on the live values**; BEAM raised no `:initial_differs_from_contract`. Recorded separately: the historical B0 corpus id for the starting suit is also `874c4c48-0a8b-49e9-883e-49fc5f1fb051` (B0 ×2, B2 ×3, B3 ×2, now this run), and the locker outfit id `2018db77-aa8a-4bf9-9afb-56bdaa161156` equals the B0 corpus's first NPC outfit. The comparison that passes the criterion is the live one; the historical equality is a consistency observation about this build.

### Criterion 2 — all four names across the typed intake, counts reconciled

| Name | Captured | Normalized | Published as |
|---|---|---|---|
| `StartingSuit` | 1 (index 11) | 1 | `disguise.equipped` #3 (`initial`) |
| `Disguise` | 2 (24, 44) | 2 | `disguise.equipped` #4, #6 (`change`) |
| `DisguiseBlown` | 1 (42) | 1 | `disguise.compromised` #5 |
| `BrokenDisguiseCleared` | 1 (45) | 1 | `disguise.compromise_cleared` #7 |

Counters line at the fall (verbatim): `seen 50, captured 6, unsupported 43, dont_send 1, unreadable 0, truncated 0; queue pushed 6, dropped 0; normalized 6, malformed 0, outside attempt 0, ungated published 1`. Reconciliation: captured 6 = `ContractStart` 1 + the five disguise occurrences; normalized 6 = captured 6; malformed 0 (no section 33 warning line anywhere in the log); pushed 6 = captured 6, dropped 0 (no `queue full`); outside attempt 0; published at the fall = 5 attempt-gated disguise events + 1 ungated `contract.started` + 2 predicate edges = 8, then `contract.ended` #9 after the fall (captured after the counters line: process total captured 7, normalized 7, published 9). `seen` lines 51 over indices 3–54; indices 5, 46, 47 never delivered to the detour (as established, engine-side). Unsupported 43 across 14 names (`Spotted` 8, `Level_Setup_Events` 6, `ItemPickedUp` 5, `AmbientChanged` 5, `Trespassing` 3, `ItemDropped` 3, `setpieces` 2, `Witnesses` 2, `OpportunityStageEvent` 2, `Investigate_Curious` 2, `HoldingIllegalWeapon` 2, `OpportunityEvents` 1, `IntroCutEnd` 1, `HeroSpawn_Location` 1); `_DONTSEND` 1 (`ChallengeCompleted`). No unexpected normalization, no `Kill`/`Pacify`.

### Criterion 3 — native ↔ BEAM fidelity

`compare.py` → `native-beam-compare.txt`: **9 published, 9 reconstructed, sequences 1–9 on both sides, 0 field mismatches** on event type, timestamp and every payload field (ids included); attempts 1–9 → 1; one adapter id; BEAM `gaps []`, 0 rejected. Publish-to-receipt 1 to 12 ms.

### Criterion 4 — derived view against section 30.8

BEAM summary, verbatim: `disguises (engine telemetry): contract.started says 874c4c48… (hitman suit); initial 874c4c48… #3 @11.9s; change → 2018db77… #4 @83.2s; compromised 2018db77… #5 @123.6s; change → 874c4c48… #6 @135.7s; cleared 874c4c48… #7 @135.7s` / `disguise state (BEAM-derived): worn 874c4c48… (equals the starting suit id) since #6; worn outfit: cleared; 2 changes, 2 definitions used; history intact; anomalies: {:cleared_without_compromise, "874c4c48-…", 7}`.

Rule by rule: after #3 the interval started by the initial has no compromise evidence → `:not_observed` (rule 4); after #4 a new interval for `2018db77…`, no earlier compromise → `:not_observed` (rule 4); after #5 the latest occurrence in the interval names the worn id → `:compromised` (rule 2); after #6 a new interval for `874c4c48…` with a compromise observed earlier on the attempt → `:unknown` (rule 3) — the change invalidated the previous interval's standing; after #7 the latest occurrence in the new, uninterrupted interval names the worn id → `:cleared` (rule 2), with the stray-clear anomaly recorded because no episode was open for `874c4c48…` (section 30.7: "a clear naming the worn id with no open episode is still that interval's latest statement and yields `:cleared`"). `2018db77…`'s episode (`compromised_sequences [5]`) stays open: nothing cleared it. `used` = 2 definitions (the suit counted once), `changes` = 2, history intact, no gap or interruption, `initial` consistent with the contract. Wording: no "clean", "undetected", "safe", "Silent Assassin" or "complete"; "suit" appears only as "(equals the starting suit id)". This is section 30.8 exactly, including the correction stated in section 35's runtime proposal: a change invalidates prior standing, no compromise evidence yields `:not_observed`, and matching evidence inside an uninterrupted interval re-establishes `:compromised`/`:cleared`. Nothing here says the engine considers the suit clear or `2018db77…` still compromised; the engine's state is not evidenced beyond the five occurrences.

### Criterion 5 — change-time ids and ordering, verbatim

At the single outfit change away from the compromised outfit (01:15:01Z, contract clock 135.7 s), the engine emitted, in capture order: `Disguise` → **`874c4c48-0a8b-49e9-883e-49fc5f1fb051`** (index 44, 135.720 s) then `BrokenDisguiseCleared` → **`874c4c48-0a8b-49e9-883e-49fc5f1fb051`** (index 45, 135.746 s, +26 ms engine time, +1 ms capture time), both drained in the same frame as #6 and #7; then `Trespassing` 229 ms later. **The change-time clear named the outfit being put on (the suit), not the compromised outfit (`2018db77…`).** No `DisguiseBlown` followed (section 34 saw one 2 ms after its change-time clear; which ids those named remains unknown, since section 34's values were not normalized). This answers the section 32/34 question of *which id* the change-time clear names on this transition, for this run: the newly equipped id. Not answered, and not claimed: why the engine emits a clear for an outfit it never reported as blown; whether `2018db77…` is still considered compromised by the engine; whether re-equipping it would restate anything. Also observed: a `Disguise` *can* carry the suit id (section 30.11 step 9 / 30.12, previously unobserved).

Operator observations, separate from the stream: the witness ran to fetch security after the compromise; the suit was put on while hiding; no HUD compromise state was reported for the suit. None of this is used in any derivation.

### Performance, warnings, errors, faults, debugger

Operator: no perceivable frame-rate effect; no numeric measurement. Native log: **107 lines; 0 WARN, 0 ERROR, 0 FAULT**; two threads (game thread, sender). BEAM: 0 rejected; the expected `:peer_closed` only, after the attempt had stopped (no close-while-playing warning this time). No debugger break; the process ended by the operator's quit from the menu.

### Cleanup (mechanical, nothing signalled)

`run-cleanup.sh b3fix-run1`: RPC `:init.stop` sent; `beam.pid` 138432 had already exited; `watcher.pid` 138509 had already exited on the process exit; HITMAN3.exe confirmed gone before any game-file step; `GlacierRelay.dll` removed; `mods.ini` restored from the pre-flight copy (`b90b4c5e…`); 107-file listing and hashes identical to pre-flight; 26/26 M0 hashes; no Relay, Hitmen or probe artifact; port 4747 free. Evidence (26 files) in `%TEMP%\glacier-m0\hitmen\b3fix-run1\`: native log `relay-20261009-010834-99116.log` (SHA-256 `56b319c8…`), `beam.log` (`4e36412e…`), `beam-final-state.txt` (`cded8baf…`), `beam-events.ndjson` (`4d564da9…`), `native-beam-compare.txt` (`39302b8b…`), `ZHMModLoader.{prerun,b3fix-run1}.log` (`07d33a6f…`), `mods.ini` before/relay/after-run, `Retail` listings and hashes before/installed/after, `installed-at.txt`, `beam.pid`, `watcher.pid`, `sha256.txt`, the scripts.

### Findings (recorded, not acted on)

1. The engine passes outfit definition ids as `ZRepositoryID` and Relay's field-semantic rendering reproduces the engine JSON writer's text exactly (all five ids match the B0/B2 strings for the same outfits; the suit id matches the live `ContractStart.Disguise` string, which is a `ZString` written by the same engine).
2. The change-time `BrokenDisguiseCleared` names the **newly equipped** outfit (one observation).
3. A `Disguise` with the suit id exists; `StartingSuit` and `Disguise` can carry the same id in one attempt, and the fold counts the definition once in `used`.
4. `DisguiseBlown` followed the last `Witnesses` by 209 ms (B0/B1/B3/§34: ~220–240 ms).
5. Fresh-entry `ContractStart` was captured 299 ms before the rise (B1/B2/B3 shape; section 34's after-the-rise variant did not recur).
6. Exit-to-menu: `ContractFailed` captured in the fall's millisecond after the drain and published 3.31 s later at stage 2 (section 29: 3.08 s).
7. Indices 5, 46, 47 (3 of 54) never reached the detour.

### What this does and does not establish

Established at runtime on this build: the section 35 conversion renders the engine's `ZRepositoryID` values to the ids the B0 corpus shows; the four rows normalize and publish inside the attempt; the pipeline, counters and BEAM correlation behave as designed beside them; the derived view follows the fold contract. Not established: engine persistence semantics (no re-equip, no witness elimination, no second compromise in this run), other clearing paths, why a clear names the newly equipped outfit, any outfit display name. **B3 acceptance and the M2 exit are decisions for review, not made here.**

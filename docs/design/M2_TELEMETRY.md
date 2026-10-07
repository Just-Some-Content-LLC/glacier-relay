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

This is one enum field on an existing table row and two branches in `RelayFrame::Process`, not a scope framework: no `scope` field on the wire (the event type implies it), no generic "scoped event" abstraction in BEAM, no time windows. The native *outside attempt* counter keeps its B1 meaning for the attempt-gated class. Revisit only if a third class appears; `StartingSuit` (B3) arrives at `Timestamp 0.0` on the fresh-load path and will face the same question, which argues for deciding it per entry then rather than generalizing now.

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

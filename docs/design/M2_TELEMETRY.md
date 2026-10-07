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
| Observed relationship (Stage A + B0) | restart: the registry already held the *next* session id at the fall frame; `ContractFailed("…OnRestartLevel")` came 0.3 s **before** the fall; `ContractStart` of the new session came in the same frame as the next rise | exit to menu: `ContractFailed("…exit to Main menu")` in the **same frame** as the fall; the registry kept the old id |
| Quit from inside a mission | attempt stays "last known playing; observation lost" | nothing sent; the backend resolves `OrphanedSession` on the next launch |

So: one attempt ↔ one contract session in every case seen, but the boundaries differ by up to a few hundred milliseconds and in a different direction per path, and the session id changes before the scene does on restart. They must not be merged. What can now be stated **directly from engine evidence**: that a contract session started (`ContractStart`, with loadout, location, difficulty, type); that it ended, and whether by restart or by exit to menu (`ContractFailed` reason); which session an actor outcome belongs to (`ContractSessionId` on every event). What remains **correlation**: the attempt ↔ session pairing itself, done by BEAM by order within the adapter stream (a `ContractStart` observed between an attempt's `mission.playing` and `mission.stopped` is that attempt's session), and never by the session id.

Proposal: do **not** introduce public `contract.started` / `contract.failed` Relay events in the first stage. Normalize `ContractStart` and `ContractFailed` into **attempt enrichment**: a `mission.contract` observation (Relay event, schema v1, carrying `contract_session_id`, `contract_id`, `location_id`, `contract_type`, `difficulty`, `loadout` summary) and a `mission.contract_ended` observation (`reason` as the engine string plus a mapped `kind: restart | exit_to_menu | other`). BEAM attaches them to the open attempt; the summary gains "ended by restart / by exit / not observed" from engine evidence; `Attempt.mission` stays `:playing | :stopped | :superseded`, bounded by the predicate. Whether these later become public lifecycle events is decided when a consumer needs them.

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

# M5 — Command Channel: design investigation (2026-10-13)

**Status: proposal for architectural review. Read-only research; nothing implemented.** The roadmap's M5 goal is "BEAM -> adapter -> Glacier" and its exit criterion "one safe, reversible semantic command changes observable game state" (both as originally written). M4 closed the evidence-preserving observer (`M4_MISSION_RECORDER.md` section 23). M5 must introduce strictly bounded action without compromising that observer's integrity, so this document treats M5 as an architectural research milestone, not a telemetry expansion: the first success is one narrowly defined, demonstrably reversible semantic operation, not a remote-control capability.

Sources read for this investigation (all read-only): the native adapter (`Mods/GlacierRelay/Src/*`: `GlacierRelay.cpp/.h`, `RelayAdapter`, `TcpRelaySink`, `TelemetryQueue`, `TelemetryIntake`, `TelemetryNormalizer`, `RelayFrame`), the SDK (`ZHMModSDK/Include/IPluginInterface.h`, `IModSDK.h`, `Hooks.h`, `Hook.h`, `EventDispatcher.h`, `Functions.h`, `Globals.h`, `Glacier/ZGameLoopManager.h`, `ZGameTime.h`, `ZHitman5.h`, `ZEntity.h`; `Src/ModSDK.cpp`, `ModLoader.cpp`, `HookImpl.h`, `Functions.cpp`, `GlobalsImpl.h`), the SDK mods that change game state (`NoPause`, `Noclip`, `FreeCam`, `Player`, `Outfits`, `WakingUpNpcs`, `QuickSave`, `World`, `TitaniumBullets`, `Clumsy`, `DebugMod`, `Editor`), the BEAM wire and session (`Wire.Listener`, `Wire.Connection`, `Wire.Framing`, `MissionSession`, `Session.Fold`, `Application`, the configs), ADRs 0001–0008, the research records (`M0_BASELINE.md`, `HITMEN_*.md`, `ZHM_HITMEN_ANALYSIS.md`, `ACTOR_OUTCOME_ARCHAEOLOGY.md`, `B0_EVENT_TAXONOMY.md`), the M1–M4 designs, and the run and rollback tooling under `%TEMP%\glacier-m0\hitmen\`.

---

## 1. Verified existing architecture (what M5 builds beside, not on)

### 1.1 Native adapter (`GlacierRelay.dll`, ZHMModSDK `relay/m2` `c5152848`, DLL `6047a9a3…`)

- **One outbound client, no inbound protocol.** `TcpRelaySink` is "an outbound TCP client … Native never listens … Nothing is ever read as protocol: bytes the peer sends are discarded and counted" (`TcpRelaySink.h:12–19`); `DiscardInbound` reads and throws away (`TcpRelaySink.cpp:329–380`); `ws2_32` imports are client calls only (M1 §14). The `IRelaySink` interface "must not grow toward `IHitmenTransport` (no listen, no connection handles, no inbound bytes)" (ADR 0005).
- **Thread model.** `Publish()` is called on the frame thread and only appends to a bounded queue (256, drop oldest) (`TcpRelaySink.h:52–53`, `.cpp:60–94`); one sender thread owns the socket, connects with a 2 s timeout and backoff 1→30 s, drops while disconnected, discards the queue on disconnect, never retransmits. The socket thread never touches the engine.
- **Engine access is frame-thread only.** `OnFrameUpdate` is registered in `OnEngineInitialized` via `Globals::GameLoopManager->RegisterFrameUpdate(delegate, 1, eUpdateAlways)` and unregistered in the destructor (`GlacierRelay.cpp:33–39, 89–91`); `ObserveFrame` reads scene state and drains the telemetry queue through `RelayFrame::Process` (drain-before-edge contract, `RelayFrame.h`). The one detour (`ZAchievementManagerSimple_OnEventSent`) is read-only, log-and-continue, inside a fault guard, and in every run so far ran on the same thread as the frame update (`GlacierRelay.h:55–56`; `HITMEN_COMPILE_ARCHAEOLOGY.md` experiment 4: "all ran on one thread").
- **Engine writes: none.** No assignment through any `Globals::` pointer, no `SetProperty`, no transform setter, no `Functions::` call (M1 Stage 1 and M2 B1 gates). Settings come from `Retail\mods\glacierrelay.ini` (`[relay] sink`, `port`, `telemetry_log`), read once in `OnEngineInitialized` (`GlacierRelay.cpp:53–79`); there is no settings-change callback in the SDK.
- **Telemetry vocabulary the adapter already maps** (`TelemetryNormalizer.cpp:43–70`): Kill/Pacify → `actor.died`/`actor.pacified`; ContractStart/ContractFailed → `contract.started`/`contract.ended`; StartingSuit/Disguise → `disguise.equipped` (initial/change, with the outfit's repository id); DisguiseBlown/BrokenDisguiseCleared → `disguise.compromised`/`compromise_cleared`; ItemPickedUp/Thrown/RemovedFromInventory → `item.*`; ObjectiveCompleted; Trespassing → `player.trespassing`; HoldingIllegalWeapon → `player.illegal_weapon`. Nothing in it reports pause, time scale, invincibility, invisibility, ammo or revive.

### 1.2 SDK facts that constrain a command path (file references are into ZHMModSDK)

- **Callbacks and threads.** `Init`/`OnEngineInitialized` are documented as game-thread but `Init` actually runs inside `DllMain` at startup (`Main.cpp:13` → `ModLoader::LoadAllMods` → `ModSDK::OnModLoaded`, `ModSDK.cpp:1039–1044`) or on the render/console thread on a live load; `OnDrawUI/OnDrawMenu/OnDraw3D` run on the render thread from Present (`ImGuiRenderer.cpp:618`, `DirectXTKRenderer.cpp:271`). `IPluginInterface` has no `OnFrameUpdate`, `OnEvent` or settings callback; frame updates are the engine's own update container (`ZGameLoopManager.h:17–29` → `Hooks::ZUpdateEventContainer_AddDelegate`), with modes `eUpdatePlayMode = 0`, `eUpdatePaused = 1`, `eUpdateAlways = 2` (`EUpdateMode.h`). Which thread runs frame updates is stated nowhere in the SDK; the only evidence is ours (one thread in every run).
- **Everything engine-facing is pattern-scanned.** All `Functions::` entries (79 `PATTERN_FUNCTION`, 3 relative, 2 vtable; `Src/Functions.cpp`) and all 71 `Globals::` (`GlobalsImpl.h:10–41`) are byte-pattern lookups; a failed lookup makes `EngineFunction::Call` return a default and do nothing (`EngineFunction.h:15–24, 41–46`) and a global `nullptr`; `Exists()` is the check; three or more failures make the SDK strip its hooks and stop loading mods (`ModSDK.cpp:756–789`). A game update can therefore silently disable a command's engine function — a command path must check `Exists()` and report "unavailable", never assume.
- **Entity references do not track lifetime.** `ZEntityRef` is a raw pointer whose `operator bool` only checks non-null (`ZEntity.h:276–297`); `TEntityRef<T>` adds an interface pointer (599–611). A cached reference goes stale silently; every mod that caches one clears it in `ZEntitySceneContext_ClearScene`/`LoadScene` detours (`QuickSave.cpp:102–110`, `Noclip.cpp:247–257`, `Player.cpp:615–634`). A local player can exist on the main menu (`IModSDK.h:234–239`); `IsEngineInitialized()` only checks for a non-empty scene resource string (`ZModule.h:36–41`); mods check `m_pEntitySceneContext->m_pScene` before acting (`QuickSave.cpp:71–76`, `Player.cpp:534–540`). A mission restart does not go through `LoadScene` (archaeology F2).
- **Hooks are installed when the SDK loads**, mods only add detours under an SRW lock (`HookImpl.h:196–249`, `Hook.h:71–108`); hot reload is unsafe ("TODO: Suspend all threads … crashes when hot-reloading", `HookImpl.h:16–17`); registering a listener from a listener deadlocks (`EventDispatcher.h:28`); frame delegates are not removed on unload (the destructor's job, `ModLoader.cpp:333–364`).
- **The one existing inbound path is an anti-pattern for us.** The Editor mod runs a uWebSockets server on `127.0.0.1:46735` on its own thread (`Mods/Editor/Src/EditorServer.cpp:20–103`, enabled by default) and its handlers mutate engine state directly on the socket thread (`Components/EditorAPI.cpp:700–890`); only one task kind is marshalled through `Plugin()->QueueTask`, a mutex-protected vector drained at the start of `Editor::OnFrameUpdate` (`Editor.cpp:434–435, 570–589`). That queue, and FreeCam's `volatile` flag consumed in its frame update (`FreeCam.cpp:178–185`), are the only "marshal to the frame thread" mechanisms in the repository. The SDK console (`Events::OnConsoleCommand`, render thread or a debug stdin thread) is the other external input; no mod reads a pipe or a file.
- **State-changing mods and how they revert** (the candidate inventory of section 2): Player sets outfits with `Functions::ZHitman5_SetOutfit` from the render thread (`Player.cpp:452–454`, prior state readable from `ZHitman5::m_rOutfitKit/m_nOutfitCharset/m_nOutfitVariation`, `ZHitman5.h:490–492`), toggles invincible/invisible through a spawned `ZAICrippleEntity` and input pins (`Player.cpp:471–572`); FreeCam pauses through `Globals::GameTimeManager->m_bPaused` (`FreeCam.cpp:195, 256, 280`; `ZGameTime.h:107`) and restores it; World writes `m_fGameTimeMultiplier` (`World.cpp:40, 55, 69`; `ZGameTime.h:101`) and never resets it on unload; WakingUpNpcs revives pacified actors with `Functions::ZActor_ReviveActor` (`WakingUpNpcs.cpp:61`), which has no reversal; `ZActor_KillActor` cannot be undone; `ZTimeOfDayManager_SetTime` is declared and used by nobody; `ZGameLoopManager_ReleasePause` exists as a hook used by nobody. Several mods write engine state off the frame thread with no marshalling and several leak or mis-revert (the DebugCheckKeyEntityEnabler restore bug, World's multiplier, TitaniumBullets' destructor, Clumsy's NPC ragdolls, Player's shared kit flags). None of this is a template to copy; it is the hazard list.

### 1.3 BEAM (glacier-relay `main`, M4 checkpoint)

- `Wire.Listener` owns the loopback listen socket (`127.0.0.1:4747`, backlog 8) and starts one `Wire.Connection` per accepted client; the connection frames NDJSON (64 KiB limit), validates each envelope with `Wire.Envelope.decode/1` and casts it to `MissionSession` with its receipt time; it reports open and close as transport evidence; "nothing is ever sent back; there is no inbound protocol on the native side" and the listener tests assert the listener never writes.
- `MissionSession` owns the connection pids and monitors, the session-assigned connection and record numbers, the subscribers and the recording-grade notifications; the folding is the pure `Session.Fold`, shared with the replay. "No gameplay authority, no persistence."
- Optional subtrees are appended under one-for-one supervision only when enabled by configuration: the dashboard (`GLACIER_RELAY_DASHBOARD=1`; ADR 0007: Phoenix is a read-only consumer, no path from the browser to the wire, enforced by a boundary test) and the recorder (`GLACIER_RELAY_RECORD=1`; ADR 0008: append-only evidence, replay never opens a socket). When both are disabled the tree is exactly `[MissionSession, Wire.ConnectionSupervisor, Wire.Listener]` (an invariance test).
- **ADR constraints that bind M5.** 0001: raw pointers, vtables, addresses and engine layouts never become protocol fields; 0002: Glacier keeps simulation, OTP coordinates meaning and authority ("make authority explicit"); 0003: a versioned semantic event/command protocol, "commands travel in the opposite direction", with explicit versions, identity, timestamps, validation and a forward-compatible extension strategy; 0005: the native boundary is relay-designed, "the native side is an outbound client and never listens"; 0006, 0007, 0008 each state they do not authorize a command channel. The protocol README already names "Commands — requested changes applied through the adapter" as a channel distinct from events, replication and snapshots.
- **The Hitmen lesson.** The 2023 experiment wrote untrusted bytes straight into engine memory (`memcpy` over the input state, `SetWorldMatrix` on actors by array index, no version, length, sequence or checksum, unreliable GNS on port 6969); the archaeology records the hazards and the "keep/replace" verdict (replace raw blobs with semantic versioned messages; networking belongs to BEAM; keep `ROOM_DYNAMIC` for an externally moved Hitman). M5 inherits the verdict, not the code.

### 1.4 Run and rollback tooling (unchanged, reused)

Pre-flight (repos, tags, DLL hash, M0 26/26, listing, `mods.ini`, no stale DLL, ports, empty recording root), BEAM first, operator readiness asked, install of the accepted DLL plus the `mods.ini` variant, operator-directed R-steps, RPC captures, `final_state.exs`, `compare3.py`, and `run-cleanup.sh <evidence-dir>` (RPC stop, exact PIDs, DLL removal, `mods.ini` restore, listing and hash diff, M0 26/26; never a name-pattern kill). M5 adds a native settings file variant (section 10) to the install and restore steps; nothing else changes.

---

## 2. Candidate command operations (evidence-based)

The criteria of the authorization: explicit name and version; strictly bounded parameters; malformed or unsupported requests rejected; clear preconditions; a documented reversal; observable confirmation; no arbitrary memory writes, scripting or generic invocation; not chosen merely because an address is known.

| Candidate | Engine mechanism (evidence) | Reversal | Preconditions | Observable confirmation | Assessment |
|---|---|---|---|---|---|
| **A. Player outfit (disguise) change** — `player.outfit.set` | `Functions::ZHitman5_SetOutfit(ZHitman5*, TEntityRef<ZGlobalOutfitKit>, charset, variation, enableModifiers, ignoreOutfitChange)` (`Functions.h:98–101`), used live by the Player mod (`Player.cpp:452–454`, render thread); the prior tuple is readable from `ZHitman5::m_rOutfitKit/m_nOutfitCharset/m_nOutfitVariation` (`ZHitman5.h:490–492`) | exact: `SetOutfit` back to the read prior tuple (BEAM also holds the prior repository id from the last `disguise.equipped`) | mission playing (MissionObserver predicate, the same evidence that gates telemetry), scene loaded (`m_pScene` non-null), local player resolved this frame, the target kit resolvable and valid for the player type (the Player mod validates kit/charset, `Player.cpp:396–413`), `Functions::ZHitman5_SetOutfit->Exists()` | **through the validated vocabulary**: the engine's `Disguise` telemetry → `disguise.equipped (change)` with the new repository id, then another for the reversal; and native read-back of the tuple in the reply | **Preferred semantic target.** Two research questions before M5-C (section 2.1): (1) resolving the Relay's `disguise_repository_id` to an outfit kit tuple natively; (2) whether an SDK-triggered `SetOutfit` emits the engine's `Disguise` telemetry (the source does not show it; the live `change` events of B3 came from gameplay). Side effects are gameplay-visible and bounded: a new outfit may be illegal where the player stands (trespassing / compromise follow by the engine's own rules and are themselves observed). The Player mod's temporary rewrite of the shared kit table for non-HeroA types is excluded: only kits that need no table rewrite are allowed. |
| **B. Game-time multiplier** — `game.time_scale.set` | `Globals::GameTimeManager->m_fGameTimeMultiplier` (`ZGameTime.h:101`), written by the World mod on the frame update (`World.cpp:67–71`); `SGameUpdateEvent.m_fGameTimeMultiplier` echoes it each frame | exact: restore the value read before the write (bounded to [0.25, 1.0]; 1.0 is the known default) | scene loaded, mission playing, `Globals::GameTimeManager` non-null | native read-back only (the multiplier is not in the telemetry vocabulary); the operator sees slow motion; engine timestamps on later telemetry drift relative to the Relay clock, which the report would show as a clock observation, not a confirmation | **Fallback.** Smallest write, exact reversal, a frame-thread precedent; but a direct field write and not a semantic fact the observer can confirm. Not chosen for its address; kept as the alternative if A's research fails. |
| C. Pause / unpause — `game.pause.set` | `GameTimeManager->m_bPaused` (`ZGameTime.h:107`) as FreeCam does (`FreeCam.cpp:195, 280`); or the `ZGameLoopManager_ReleasePause` hook (unused) | exact (restore the read flag) | as B | native read-back; not in the vocabulary; `eUpdatePaused` frame mode changes | Reversible and visible, but pausing interacts with the engine's own pause menu and focus handling (NoPause's concerns); the semantics of "paused by whom" are unclear. Not first. |
| D. Revive a pacified actor — `actor.revive` | `Functions::ZActor_ReviveActor` (`Functions.h:68`), WakingUpNpcs (`WakingUpNpcs.cpp:39–61`) | **none** (re-pacifying is not a safe operation) | pacified, not hidden/dumped/dragged | no revive event in the vocabulary (B0 read the flags from memory only) | Rejected for M5: irreversible. |
| E. Invincible / invisible — `player.invincible.set` | `ZAICrippleEntity` spawn + `SignalInputPin` `SetHeroInvincible/Vulnerable`, `SetHeroHidden/Visible` (`Player.cpp:471–572`) | the opposite pin; entity deleted on scene clear | scene loaded | not in the vocabulary; no read-back of the pin's effect | Rejected: requires spawning an entity, no confirmation path, a cheat with no semantic meaning in the observer's model. |
| F. Teleport / transform — `player.transform.set` | `SetObjectToWorldMatrixFromEditor` (Noclip, FreeCam) | store and restore the matrix | — | not in the vocabulary (no movement data, M4 §13) | Rejected: the archaeology left the editor-path setter's runtime suitability open; M6/M7 territory. |
| G. Kill actor, quick save/load, outfit brick loading, ragdoll, ammo, repository patches | `ZActor_KillActor`, `ZLevelControlEntity` pins, Outfits' resource mounts, Clumsy's ragdolls, TitaniumBullets' repo rewrites | none or partial | — | — | Rejected: irreversible, resource-level, or documented as leaking. |

### 2.1 Research questions that gate candidate A (answered by reading, a native probe or the M5-D run — each under its own authorization)

1. **Id to kit.** The Relay's disguise id is the engine's `ZRepositoryID` as rendered by the B3 intake. The engine's `Disguise` telemetry carries that id for the outfit it equips, so the engine owns the mapping; where it resolves a repository id to a `ZGlobalOutfitKit` (ContentKitManager? the kit's own repository id field?) is to be established from the headers and the Outfits/Player mods' kit enumeration. Until then the command may take the kit tuple only through a native allowlist built at mission start from the kits the engine lists for the player — never a raw kit pointer from the wire (ADR 0001).
2. **Telemetry emission.** Whether `ZHitman5_SetOutfit` fires the `Disguise` telemetry event (observable confirmation through the vocabulary) or only changes the outfit silently (confirmation by native read-back plus the next gameplay-emitted event). The B3 live `change` events came from gameplay changes; the SDK path is unobserved. M5-D answers it; the design is correct either way because the status ladder (section 9) separates "applied" from "observed".
3. **Character type.** The Player mod's kit-table rewrite for non-HeroA types is excluded; the allowlist covers HeroA kits only until the engine's behaviour for the others is understood.

---

## 3. Transport: preferred choice and alternatives

**Preferred: a separate, native-initiated, explicitly duplex command link on its own loopback port.** The native adapter opens a second outbound TCP client to a second BEAM listener (`127.0.0.1:4749`, the "command link") only when `[command] enabled = true` in `glacierrelay.ini` (default `false`); BEAM listens on it only when `GLACIER_RELAY_COMMAND=1` (default off). On that link BEAM writes command lines and native writes result lines (NDJSON both ways, 4 KiB line limit). The telemetry connection is untouched: it stays one-way, best-effort, and keeps discarding inbound bytes.

| Option | Failure modes | Ownership | Operational complexity | Verdict |
|---|---|---|---|---|
| Separate native-initiated duplex link (preferred) | a lost link loses only in-flight command state (observed effects remain observable through telemetry); the telemetry stream is unaffected by command traffic or command-side parsing bugs; a second port to keep free | native: one `CommandLink` client thread (connect/backoff like the sink) owning its socket; BEAM: a `Command.Listener` accepting one link at a time and a `Command.Link` process owning the accepted socket | one more port, one more flag on each side, one more connection to pre-flight; mechanically the same as the proven sink | **chosen**: preserves "native never listens" (ADR 0005), loopback only, double opt-in, isolates the observer |
| Make the telemetry connection duplex | command parsing on the sink's sender thread; the sink's drop-on-disconnect and backoff policies now govern command availability; a parsing bug or a slow reply path can stall telemetry delivery; the `IRelaySink` contract and the "listener never writes" tests reverse | the sink's thread and the `Wire.Connection` process gain a second role | fewer ports, more coupling | rejected: couples the observer to the actor; violates the sink's documented contract |
| Native listens (a command server, as the Editor mod does) | a listening socket inside the game process; any local process can connect; the Editor's own handlers mutate engine state on the socket thread | native owns accept, connection lifetimes and auth | firewall and listening-port posture inside HITMAN | rejected: ADR 0005; the Editor is the anti-pattern |
| Windows named pipe / WSL2 interop file drop | WSL2-to-Windows pipe access is indirect; file polling is laggy, unbounded and leaves state on disk | split | high | rejected |
| In-process (NIF/port driver) | an unsafe engine manipulation inside the BEAM (ARCHITECTURE: avoid) | — | — | rejected |

Framing and limits on the command link: one JSON object per line, UTF-8, at most 4,096 bytes; a line over the limit or not parseable as a JSON object closes the link on the side that read it (the conservative failure, as `Wire.Connection` does for `line_too_long`); unknown fields are ignored; unknown `kind`, `name` or `version` are rejected with a result, never applied.

---

## 4. Command authority and ownership (BEAM)

- **One issuer.** `GlacierRelay.Command.Authority`, a GenServer in an optional `GlacierRelay.Command.Supervisor` subtree appended last (after the recorder, before or after the web subtree, both one-for-one), started only under `GLACIER_RELAY_COMMAND=1`. It is the only module that may write a command to the link, and the only one that holds command state. `Command.issue/3` (name, version, params) returns `{:ok, command_ref}` or a typed refusal; nothing else can transmit.
- **Arming.** Issuing is refused until the operator arms the authority for the session from an operator context (`Command.arm/0` over RPC or IEx, logged with the node and time) and after `Command.disarm/0` or any link loss (which disarms automatically). Arming is a per-boot, per-link state, never persisted.
- **Leak prevention.** The web and dashboard namespaces, `GlacierRelay.Recording.*`, `Recording.Replay`, the fixture player and every test support module may not reference `GlacierRelay.Command.*`, `Command.Link` or port 4749 — a compile-time boundary test in the style of ADR 0007's; `MissionSession`, `Session.Fold` and `Wire.*` do not reference the command subtree either (the observer never knows a command exists). The HTTP endpoint serves no command route; `POST` and friends keep returning 405. Replay never opens a socket (ADR 0008). A recording replays into `Lifecycle` state, never into a command. Fixture playback writes to 4747 only.
- **Authority is explicit and single-valued** (ADR 0002): at most one link is accepted at a time (a second connection attempt is refused and logged), at most one command is in flight, and the authority records its own decisions.
- **Command journal.** The authority appends every state transition of every command (section 9) to its own append-only NDJSON journal under the recordings root (`commands-<node-boot-id>.ndjson`; separate from any recording, never written by the recorder); the journal is evidence of what BEAM asked and what native answered. Whether command transitions also become session records (a format-2 record kind) is a decision for M5-A review, not assumed here: in the first slice the observer's recording format stays format 1 and untouched.

---

## 5. Versioned request and reply schema (proposal; `command_protocol_version` 1, independent of the Relay envelope's `protocol_version`)

Request (BEAM → native):

```json
{"command_protocol_version":1,"kind":"command","command_id":"<uuid4>","issued_at":"<ISO-8601 UTC ms>",
 "ttl_ms":5000,"name":"player.outfit.set","version":1,"params":{"disguise_repository_id":"<uuid>","expect_current":"<uuid>|null"}}
```

Result (native → BEAM), two per command at most — a `received` result from the link thread after validation, then one terminal result from the frame thread:

```json
{"command_protocol_version":1,"kind":"command.result","command_id":"<uuid4>","adapter_instance_id":"<uuid>",
 "status":"received|rejected|busy|duplicate|expired|precondition_failed|unavailable|applied|failed",
 "reason":"<short text or null>","native_at":"<ISO-8601 UTC ms>","frame":<n>,
 "observed":{"previous":{...},"current":{...}}|null}
```

Rules: `command_id` is a client-generated UUID v4 and the idempotency key; `name` and `version` select one allowlist entry and its parameter schema (an unknown pair is `rejected`); parameters are strictly typed and bounded per entry (strings are ids of a fixed form, numbers have closed ranges; no free text, no arrays of arbitrary length, no nested objects beyond the schema); `ttl_ms` is bounded (100–10,000); `issued_at` is informational — expiry is computed natively from the link's own receipt time plus `ttl_ms`, so no cross-host clock comparison decides anything; `adapter_instance_id` in every result ties the command to the telemetry stream's instance; `observed` carries the native read-back of the targeted state before and after the write, in semantic terms only (repository ids, booleans, bounded numbers; never pointers or offsets, ADR 0001). The initial allowlist is two entries: `relay.probe` v1 (no parameters; applied on the frame thread; changes nothing; its `observed` block reports scene state and the mission predicate — the path validator) and the one reversible command of section 2 once its research closes. Adding an entry is a schema version change on the entry, never a free-form extension.

---

## 6. Native validation and scheduling design

```
command link thread (owns the socket; never touches the engine)
  connect/backoff as the sink → read lines (≤ 4 KiB) → parse JSON → CommandRegistry.Validate (name, version, params bounds)
  → dedup ring (last 64 ids) → CommandQueue.Push (bounded, capacity 8) → write "received"
  → on any rejection: write the terminal result immediately (rejected / busy / duplicate)
frame thread (OnFrameUpdate, after ObserveFrame)
  at most ONE command per frame: pop → check TTL against the link's receipt clock (expired?) → check preconditions against
  THIS frame's SceneState and MissionObserver (scene available, mission playing, local player resolved now) → check
  Functions::X->Exists() (unavailable?) → read the current state (observed.previous) → apply through the SDK wrapper →
  read back (observed.current) → ResultQueue.Push (applied | failed | precondition_failed) → the link thread writes it
link loss / disable
  the queue is cleared; nothing pending is ever applied afterwards; in-flight state is reported to nobody (BEAM marks it unknown)
```

- **No engine operation on the socket thread, ever.** The link thread only parses, validates, counts and queues — the TcpRelaySink/TelemetryQueue pattern in the opposite direction; the FreeCam-flag and Editor `QueueTask` precedents show the marshalling, our design adds bounds, validation and results.
- **The registry is compiled in.** Each entry has a name, a version, a parameter validator, a precondition function and an apply function; there is no generic "call function X" entry, no property setter by name, no script.
- **Fresh resolution every time.** Engine objects (the player, the kit, the time manager) are resolved on the frame that applies the command and discarded afterwards; nothing engine-side is cached across frames; a scene clear or load between receipt and application fails the precondition check rather than dereferencing a stale reference (`ZEntity.h` lifetime facts, section 1.2).
- **Fault guard.** The apply step runs inside the existing `RelayLog::Guard` like the detour and the frame observation; a fault is logged and the command reported `failed` where that is still possible.
- **Bounded cost.** One command per frame, a queue of 8, a 4 KiB line, a 64-entry dedup ring; the command path adds one queue check per frame when idle.
- **Native kill switch.** `[command] enabled = false` by default: the link thread is not started at all; with `true`, closing the link (BEAM disarms, BEAM stops, or the operator stops BEAM) clears the queue and halts all application; no setting can be changed at runtime (the SDK has no settings callback), so disabling is a restart with the setting off, and the run's `mods.ini` and `glacierrelay.ini` variants are restored by the cleanup.

---

## 7. Game-thread and engine-lifetime constraints (what the evidence allows us to rely on)

- The frame update delegate (`eUpdateAlways`) is where the adapter already reads engine state; every engine write of M5 happens there and nowhere else. The SDK does not document the frame thread; our runs show one thread for the detour and the update. M5-D must log the thread id of the apply step beside the detour's and the update's (as experiment 4 did) and treat a difference as a finding.
- `eUpdateAlways` runs while paused; a command whose precondition is "mission playing" must additionally refuse to apply while the game is paused or loading (a frame observed with `scene_loaded` false), to avoid acting on a scene that is being torn down.
- Entity and kit references are valid only within the frame they were resolved; a `TEntityRef` must be checked with its own `operator bool` and the scene checked (`m_pScene` non-null) before use; a mission restart does not pass through `LoadScene` (F2), so "same scene resource" is not "same entities" — the command never carries an entity reference across frames.
- Pattern-resolved functions may be absent on another build: `Exists()` before every use; a missing function is `unavailable`, logged once, and the native side reports it in every result so BEAM's allowlist can mark the entry unavailable for the session.
- Shutdown is not observable from inside the DLL (F9): an in-flight command at game exit is simply lost; BEAM's journal keeps it `unknown`.
- Hot reload of the mod is excluded (the SDK's own TODO): the command-enabled DLL is installed and removed with the game closed, as today.

---

## 8. Duplicate, retry and timeout policies

- **No exactly-once claim.** The protocol establishes at-most-once application per `command_id` on one native instance (the dedup ring) and lets BEAM observe the outcome; it does not establish delivery of the result. A command may be applied and its result lost (link loss after application); BEAM then holds `unknown` and relies on observation (telemetry or a later `relay.probe` read-back) — it never retries an `unknown` command automatically.
- **Retries are operator decisions in the first slices**: the authority refuses a second issue while one is in flight (`busy` locally, never transmitted), and refuses to re-issue a `command_id`; a new attempt is a new id and a new decision.
- **Timeouts.** BEAM: a `received` result must arrive within the link timeout (2 s), else the command is `unknown` and the link is considered suspect (closed and disarmed); a terminal result must arrive within `ttl_ms` plus a grace (1 s) else `unknown`. Native: a queued command past its TTL is `expired` without application (checked on the frame that would apply it).
- **Stale and delayed commands.** The TTL bounds staleness; preconditions re-checked on the applying frame (mission still playing, same adapter instance) bound the rest; a command issued for one mission attempt but applied after a restart is prevented by the mission predicate and by BEAM including `expect_current` (compare-and-set on the targeted state) where the entry supports it.
- **Duplicate delivery** (a resent line, a reconnect replay): the dedup ring answers `duplicate` with the known terminal status if it has one, `received` otherwise.
- **Native queue overflow**: `busy`, immediately, never a drop without a result.

---

## 9. Confirmation and reversal semantics (the status ladder)

| Stage | Who establishes it | Evidence | What it does not mean |
|---|---|---|---|
| `accepted` | BEAM authority (armed, allowlisted, validated, link up, nothing in flight) | journal entry | not transmitted |
| `transmitted` | the link process wrote the line | journal entry with the byte count | not received |
| `received` | native link thread after validation | `received` result | not applied |
| `applied` / `failed` / `rejected` / `expired` / `precondition_failed` / `unavailable` / `busy` / `duplicate` | native frame thread (or link thread for the last three) | terminal result with `observed.previous`/`current` and the frame number | **applied ≠ observed**: the engine accepted the write; the semantic effect is not yet confirmed |
| `observed` | BEAM, by correlating evidence the observer already holds: for `player.outfit.set`, a `disguise.equipped (change)` envelope from the same adapter instance, after the command's `native_at`, naming the requested id; for commands without a vocabulary event, the native read-back only, reported as `observed_native` (weaker, labelled) | the correlated envelope's sequence and receipt time in the journal | a transport acknowledgement is never confirmation; a `received` result is never an effect |
| `unknown` | BEAM, when a stage times out or the link is lost in between | journal entry | not a failure; the effect may exist and may be observed later |

**Reversal.** Every allowlisted command with an effect names its reversal and the state needed for it: for `player.outfit.set` the reversal is `player.outfit.set` with the previous id (from the command's `observed.previous` and from BEAM's own last `disguise.equipped`), issued by the operator as its own command with its own ladder; the design never auto-reverts (an automatic revert on a lost link would itself be an unconfirmed action). `relay.probe` has no effect and no reversal. The experiment's success requires both the effect and its reversal to reach `observed`.

---

## 10. Native safety and rollback gates

- **Default disabled on both sides**; the command link exists only with `[command] enabled = true` (a run-specific `glacierrelay.ini.command` variant installed beside `mods.ini.relay` and restored byte-identically by the cleanup) and `GLACIER_RELAY_COMMAND=1`.
- **Allowlist only**, compiled in; two entries in the first slices; no generic invocation, scripting, memory writes, property setters by name, or entity references on the wire.
- **Loopback only** on both ports; one accepted link; arming per session; no browser path; the HTTP endpoint unchanged.
- **The observer stays whole**: the telemetry connection, `Wire.*`, `MissionSession`, `Session.Fold`, the recorder and the replay are not modified by the first slices; the invariance test (tree identical when disabled) extends to the command subtree; the native gate keeps "engine writes: none" for every code path except the registry's apply functions, which are listed by name in the gate.
- **Hard kill switch**: BEAM `Command.disarm/0` (refuses further issues, closes the link), stopping BEAM (the link closes, native clears its queue), or the native setting off at the next start. The operator's run script has an explicit "disarm" step before every R-step that does not issue.
- **Rollback**: the existing `run-cleanup.sh` plus the restore of `glacierrelay.ini`; M0 26/26 verified; the accepted M2 DLL is never rebuilt to establish a checkpoint — M5's native stages produce their own build and hash, gated like B3–B6 (clean build, native tests, imports dump, wire probe, hash preserved).
- **Abort conditions** as in every runtime experiment (native fault, instability, unexpected writes, evidence integrity), plus: any engine write outside the applying frame, any result without a matching request, any `applied` without the expected read-back, and a thread id for the apply step different from the frame update's.

---

## 11. Offline testing strategy

- **BEAM (M5-A)**: schema tests (every field, bounds, unknown name/version/kind, malformed lines, 4 KiB limit); authority tests (disarmed refusal, single in-flight, idempotent ids, the full status ladder with a fake native on 4749, `unknown` on timeout and link loss, the journal's append-only lines); the boundary test (no reference to `Command.*` from web, dashboard, recording, replay, fixture or test-support namespaces; `MissionSession`/`Wire`/`Fold` unchanged); the invariance test (tree identical with the flag off); the observed-stage correlation test (a fixture `disguise.equipped` envelope after an `applied` result marks `observed`, a wrong id or an earlier sequence does not); the existing 437 tests unchanged, byte-identical report snapshots.
- **Native (M5-B, M5-C)**: unit tests in the existing harness for the registry (validation, bounds, unknown entries), the dedup ring, the queue bounds and `busy`, the TTL check with an injected clock, the frame-thread drain of one command per frame with a fake engine (the apply function replaced by a recorder of calls), the result queue; a command probe executable in the style of `GlacierRelayWireProbe` that plays commands at the DLL's link code over a real loopback socket without the game; the inert gate: with `[command] enabled = false` the DLL's imports and behaviour are unchanged from `6047a9a3…` except the new code's presence (imports dump diffed).
- **End to end without the game**: BEAM with the command subtree against the native link code hosted by the probe executable (no engine): `relay.probe` round-trips through every ladder stage; `player.outfit.set` reaches `precondition_failed` (no scene) and never calls the apply function.

---

## 12. Controlled runtime experiment proposal (M5-D; its own authorization; not started)

Pre-flight as M4 run 1 plus the command port free and the `glacierrelay.ini.command` variant staged. BEAM first with `GLACIER_RELAY_RECORD=1` and `GLACIER_RELAY_COMMAND=1` (dashboard off); verify the command listener bound and the subtree present; install the M5-C DLL (its own accepted hash) and both ini variants; operator launches HITMAN. **R1** menu: the telemetry connection opens and identifies; the command link connects; the authority is disarmed; a `relay.probe` is refused (disarmed) — nothing transmitted. **R2** Paris: `mission.playing`; arm; issue `relay.probe` → `received`, `applied` with scene state, `observed_native`; disarm. **R3** the one command: arm; issue `player.outfit.set` for an allowlisted kit → ladder to `applied` with the read-back; expect `disguise.equipped (change)` within the window → `observed` (or, if the engine does not emit it, `observed_native` only — a finding, not a failure of the protocol); the operator confirms the visible outfit. **R4** reversal: issue `player.outfit.set` with the previous id → ladder → `observed`; disarm. **R5** exit to menu, quit: the command link closes (`peer_closed`), the authority disarms, the journal closes; the recording closes cleanly. Captures: the command journal, the native log (thread ids per apply), the recording, RPC state at the boundary; fresh-node replay unchanged by commands (the observer's equality checks of M4 must still hold — the commands' effects are ordinary engine-authored evidence to it). Cleanup: `run-cleanup.sh` plus the ini restore; M0 26/26. Verdicts: the ladder recorded for every command; one effect and its reversal observed; no engine write outside the applying frame; the observer's replay equality intact; no native WARN/ERROR/FAULT; M0 restored.

---

## 13. Proposed M5 exit refinement

The roadmap's exit stays as written. Proposed refinement for the acceptance decision: "one safe, reversible semantic command, issued by the armed authority over the command link, is validated and applied by the native adapter on the frame thread, and both its effect and its reversal are confirmed as `observed` — through engine-authored Relay evidence where the vocabulary carries it, otherwise through the native read-back labelled as such — with every stage of each command's status ladder journaled, the observer's recording and replay unchanged and equal, and the game restored to M0." It adds the ladder, the reversal and the observer-integrity condition to the original sentence without widening it.

---

## 14. ADR proposal

`docs/adr/0009-commands-cross-a-separate-bounded-link.md` (proposed): commands travel on a separate, native-initiated, explicitly duplex loopback link with a compiled allowlist and a versioned command protocol; engine writes happen only on the applying frame through SDK wrappers; a single armed BEAM authority issues and journals; applied is distinct from observed; the observer path (telemetry connection, session, fold, recorder, replay, dashboard) is not modified and may not reference the command path.

---

## 15. Proposed stages and the smallest safe first authorization

| Stage | Content | Native change | Runtime |
|---|---|---|---|
| **M5-A — command boundary and offline protocol** | `GlacierRelay.Command.{Supervisor, Listener, Link, Authority, Schema, Journal}` behind `GLACIER_RELAY_COMMAND=1`; the versioned schema (section 5); the allowlist with `relay.probe` and the outfit entry's schema; the status ladder and journal; boundary and invariance tests; a fake native for tests; protocol document | none | none |
| **M5-B — native command acceptance and scheduling** | `CommandLink` (client thread), `CommandRegistry` (compiled allowlist with `relay.probe` only), `CommandQueue`, `ResultQueue`, the one-per-frame drain in `OnFrameUpdate`, dedup, TTL, kill switch, native tests and the command probe executable; inert gate with the setting off | yes, behind `[command] enabled = false` | none (offline gate only) |
| **M5-C — one reversible command** | the research of 2.1 closed by reading or a separately authorized probe; `player.outfit.set` v1 (or the fallback `game.time_scale.set` v1 if 2.1 fails) with preconditions, apply through the SDK wrapper, read-back, reversal documented; BEAM correlation to `disguise.equipped`; end-to-end offline against the probe host | yes | none |
| **M5-D — controlled runtime validation** | the experiment of section 12 with an accepted M5-C artifact, pre-flight, operator-in-the-loop, rollback | the accepted M5-C DLL installed for the run only | one HITMAN session |

Every stage requires its own architectural review; nothing in a later stage is implied by an earlier one.

**The smallest safe first implementation authorization is M5-A**: BEAM-only, offline, default-off, no native change, no DLL, no game; it fixes the command protocol, the authority model, the journal and the boundary tests, and it can be reviewed against this document before any native code is written.

---

## 16. What this investigation did not do

No native code, wire or protocol change; no DLL built or installed; no HITMAN launch; no command sent; no browser control; no spatial work; no analytics expansion; M6–M9 untouched. The native repository stays at `c5152848` with its M2 tag; glacier-relay at the M4 checkpoint plus this document and the ADR proposal.

---

## 17. M5-A — offline command boundary: implementation and validation record (2026-10-14; BEAM only; nothing native; M5 not complete)

Authorized after the approval in principle of this design and ADR 0009 (reconciled in `3fed21d`): the smallest BEAM-only command subsystem behind an explicit flag, validated against a fake native peer. No native code, no DLL, no game, no engine effect; the only issuable command has no effect. Evidence: `%TEMP%\glacier-m0\hitmen\m5a-offline\` (`validate-command.sh`, `validate.log`, `mix-run-1..5.txt`, `fresh-vm-ladder.txt`, `fresh-vm-journal.ndjson`, `sha256.txt`).

### 17.1 Commits

| Commit | Content |
|---|---|
| `3fed21d` | ADR 0009 reconciliation: the five explicit limits (local arming is not peer authentication; a claimed `adapter_instance_id` establishes nothing; TTL is not a mission-generation check; native read-back is not independent observation; restoring a value is not a complete reversal) and the M5-A refinements |
| `eef7654` | `GlacierRelay.Command.{Supervisor, Journal, Authority, Listener, Link, Schema}`, the operator API `GlacierRelay.Command`, configuration and the runtime flags, the fake native peer, the tests, the headless-invariance and boundary extensions |
| `3003191` | one test assertion made structural (the observer-isolation check compares `MissionSession.state/0` before and after) |
| `4482fba` | **found by the gate's fresh-VM run**: a result's status was converted with `String.to_existing_atom/1`, which fails in a VM where the test suite has not created the atom; the status is now mapped through the schema's compile-time status table (no atom is ever created dynamically) |
| `b5966cf` | the observer-isolation text check inspects only the test's own instance section (other tests' instance ids carry fixture names such as `probe`, which made the first full-suite batch fail on this assertion alone, five times out of five) |

### 17.2 Supervisor structure

`GlacierRelay.Command.Supervisor` is appended **last** under `GlacierRelay.Supervisor` only when `config :glacier_relay, :command, enabled: true` (`GLACIER_RELAY_COMMAND=1`; `GLACIER_RELAY_COMMAND_JOURNAL_DIR` for the journal directory). Its children, `rest_for_one`: `Command.Journal` → `Command.Authority` → `Command.LinkSupervisor` (a `DynamicSupervisor` for the one link) → `Command.Listener`. A journal failure restarts the authority (disarmed, no link) and drops the link; a listener failure rebinds without touching the authority. With the flag off nothing of it starts: the tree is exactly M4's, no process of the subtree is registered, and port 4749 refuses connections (`HeadlessTest`, M5-A invariance). The operator API (`GlacierRelay.Command.arm/0`, `disarm/0`, `probe/1`, `status/0`, `command/1`, `enabled?/0`) answers `{:error, :command_disabled}` whenever the subtree is not running; it is meant for an explicitly controlled local IEx or RPC context and has no Phoenix route (a boundary test checks the router).

### 17.3 Transport, handshake and trust policy

- **Transport**: `127.0.0.1:4749` (the listener refuses any non-loopback bind at start), separate from the telemetry listener (4747, untouched) and the dashboard (4748, untouched); `backlog 2`; **one accepted link at a time** — a second connection receives `{"kind":"refused","reason":"busy"}` and is closed, journaled as `link.refused`. Newline-delimited UTF-8 JSON, 4,096 bytes per line at most (reusing the pure `Wire.Framing` as a library; the telemetry connection is not shared).
- **Handshake**: the peer must send `hello` within `hello_timeout_ms` (2 s) of the accept; BEAM answers `welcome` with the BEAM-assigned **link generation** (an integer, monotonically increasing per accepted link within one node boot) and the issuable allowlist. States, kept distinct and never equated (`Command.status().trust`): `transport` (`:none` | `:connected`), `protocol` (`:none` | `:not_negotiated` | `:negotiated`), `peer` (`:none` | `:unidentified` | `:identified`), `authenticated` (always `false` in M5-A), `armed`, `ready` (identified and armed with nothing in flight and the journal open).
- **Identity and trust**: the hello's `adapter_instance_id` is accepted as a **claim**; the link is labelled `identified`, never `authenticated`; the journal entry says `identified (claimed; not authenticated)`. Every effectful allowlist entry requires an `authenticated` peer, a state no peer can reach in M5-A, so no effectful command is issuable by construction (`:peer_not_authenticated` would be the refusal even if an entry were marked issuable). **Credential research** (section 5 of the authorization): a persistent shared secret would have to live in `Retail\mods\glacierrelay.ini` beside the game, in plaintext, readable by any process on the Windows host — rejected. An ephemeral per-boot secret could be generated by BEAM and handed to the native adapter only through a file the game process can read (a `\\wsl$` path or a Windows temp file), which is again plaintext at rest for the session's duration and does not bind the secret to the game process; a corroboration-based identification (the same `adapter_instance_id` delivering valid envelopes on the telemetry connection within a window) establishes that *some* process speaking both protocols claims the id, not that it is the game. Decision: M5-A implements identification only and labels it so; whether authentication is worth the plaintext exposure, or whether corroboration plus the loopback and operator-in-the-loop controls are the accepted trust basis for the one controlled M5-D experiment, is an M5-B/M5-C review question (17.9).
- **Link generation and reconnect**: every command carries `link_generation`; every result must echo it and, when it states an adapter identity, the identity of the current link. A result with another generation is `anomaly.stale_result`; another adapter id `anomaly.foreign_result`; an unknown command id `anomaly.unmatched_result`; a result for a command that already ended `anomaly.late_result` — all journaled, counted and ignored. A link loss disarms the authority and marks any in-flight command `unknown`; a reconnected peer gets the next generation and the operator must arm again.
- **Mission generation**: the hello and every result may carry an opaque `mission_generation` (≤ 64 bytes) that the native side would derive from its own source; the authority stores and journals it; the reserved `player.outfit.set` entry declares a `mission_generation` precondition; M5-A invents nothing from telemetry and M5-B must establish the native source before effectful scheduling can be approved.

### 17.4 Protocol schemas (`command_protocol_version` 1; `Command.Schema`)

Peer → BEAM: `hello` (`adapter_instance_id` uuid4 required; `native_at` ≤ 64; `mission_generation` ≤ 64 or null; `capabilities` ≤ 16 strings ≤ 64) and `command.result` (`command_id` uuid4; `link_generation` positive integer; `adapter_instance_id` uuid4 or null; `status` one of `received rejected busy duplicate expired precondition_failed unavailable applied failed`; `reason` ≤ 200 or null; `native_at` ≤ 64 or null; `frame` non-negative integer or null; `observed` an object of ≤ 16 scalar entries or one-level objects of ≤ 16 scalars, strings ≤ 128; `mission_generation`). BEAM → peer: `welcome`, `command` (`command_id`, `link_generation`, `issued_at`, `ttl_ms` 100–10,000, `name`, `version`, `params`, `preconditions`) and `refused`. Decoding is strict: the version must be 1; the kind must be known; **every field must be known** (an unknown field rejects the line); types and bounds are exact; a non-object, invalid JSON, invalid UTF-8 or an oversized line is an error. Unknown kinds, names, versions, fields or parameters never result in execution. The allowlist: `relay.probe` v1 (no parameters, no effect, no reversal, trust `identified`, issuable) and `player.outfit.set` v1 (`disguise_repository_id` uuid4 required, `expect_current` uuid4 optional; effect outfit; trust `authenticated`; precondition `mission_generation`; reversal documented; **not issuable**). No field in any schema is a function, address, pointer, engine type or script (the sources and the encoded lines are checked for such tokens).

### 17.5 Status ladder and correlation

`accepted` (journaled before anything is sent; the issue is refused if the entry cannot be persisted) → `transmitted` (the line was written; an ack timer of `ack_timeout_ms` starts) → `received` (the peer's `received` result; ack timer cancelled) → terminal (`applied` | `rejected` | `busy` | `duplicate` | `expired` | `precondition_failed` | `unavailable` | `failed`, as the peer said it; the terminal timer, `ttl_ms + grace_ms`, cancelled) or `unknown` (`ack_timeout`, `terminal_timeout`, `link_lost`, `send_failed`). Observation: `observed` is `:none` or `:native` (the result carried a read-back; the peer's own report, labelled so in the journal as `observed_label`); `independent_observation` is `:not_available` on every command — M5-A has no source for an independently observed semantic effect and never sets it, so a fake peer echoing a requested value is recorded as native observation only. A socket accepting the bytes is `transmitted`, never `applied`. Every stage carries its monotonic offset from issuance. Results are correlated by command id **and** link generation **and** (when stated) adapter identity; anything else is an anomaly (17.3). An unknown outcome stays unknown: there is no retry and no reversal, automatic or otherwise.

### 17.6 Journal format and durability

`glacier-relay.command-journal/1`: one JSON object per line in `commands-<journal_id>.ndjson` under the configured directory or `~/.local/state/glacier-relay/commands/` (ext4; never the game installation); the directory is created `0700`, the file `0600`, opened exclusively; the first line is `journal.opened` (node, OS pid, OTP release) and a clean stop writes `journal.closed`. Every line carries `journal`, `journal_id`, `seq`, `at` (UTC) and `mono_ms` (monotonic offset from the open). Entries: `link.connected`, `link.refused`, `peer.identified`, `authority.armed`, `authority.disarmed` (by operator or by link loss), `command.accepted`, `command.transmitted`, `command.received`, `command.terminal`, `command.unknown`, `command.refused`, `anomaly.*`, `link.closed` (with the reason, protocol violations included), `link.closed_late`, `journal.closed`. **Durability contract**: `append/2` returns `:ok` only after the write and `datasync` succeeded; on any write or sync failure the journal is `degraded`, the failed and every later append return an error, and the authority refuses to arm and to issue (`{:error, {:journal_unavailable, reason}}`); it never assumes an action was audited. A degraded journal recovers only by a restart of the subtree, which opens a new journal with a new identity (the `rest_for_one` order makes the authority restart disarmed with no link). A journal that ends without `journal.closed` was not closed cleanly and its last line may be partial. Nothing in the observer path calls the journal, so its I/O never touches telemetry ingestion.

### 17.7 Timeout, duplicate and reconnect behaviour

All timeouts use the monotonic clock (`System.monotonic_time/1`, `Process.send_after/3`); the command's `issued_at` and the peer's `native_at` are audit text only and are never subtracted. Duplicate command ids are refused at issuance for the whole boot; one command in flight (`{:in_flight, id}` otherwise); TTL bounded 100–10,000 ms. The tested cases: duplicate request id; delayed acknowledgement (after the terminal result: an anomaly); terminal result lost (`unknown`, `terminal_timeout`); link closed after transmission (`unknown`, `link_lost`, disarm); a stale result after reconnect (anomaly, the old command stays `unknown`); a peer reporting `applied` with an echoed observation but no independent observation (`observed :native`, `independent_observation :not_available`); a command reported `expired` by the peer (recorded as the peer said); two peers (the second refused); an in-flight command followed by disarm (no new issue; the result of the in-flight command still correlated and recorded); an unknown command, version or protocol version (refused or the line rejected); hello twice, a result before hello, an oversized line, malformed JSON, invalid UTF-8, an unknown field, a hello timeout (the link closes, `link.closed` with `protocol_violation`).

### 17.8 Boundaries

Unchanged: `Wire.Listener`, `Wire.Connection`, `Wire.Envelope`, `MissionSession`, `Session.Fold`, `Lifecycle`, `Recording.*`, `Statistics`, `Dashboard.Projection`, the LiveViews, every M2–M4 schema and report. Compiled-code boundary tests (`BoundaryTest`): no web or dashboard module calls any `GlacierRelay.Command.*` module (added to the forbidden list) or mentions `Command.` or `4749`; no observer, web, recording, replay, fixture or test-support module has a remote call into `GlacierRelay.Command*` (checked over the compiled import tables, with the observer sources checked for the token); no command module calls `MissionSession`, `Lifecycle`, `Session.Fold`, the recorder, the telemetry listener or connection, `Wire.Envelope` or `Events`; the router has no route matching command, arm or probe. The fake native peer is test tooling for the command tests only and is never evidence of native execution.

### 17.9 Test evidence and the gate

468 tests (437 before plus 31 new: `Command.SchemaTest` 10, `Command.JournalTest` 5, `Command.AuthorityTest` 13, `HeadlessTest` +1, `BoundaryTest` +2) green in five consecutive full runs at `b5966cf` (seeds 920554, 576961, 613912, 560419, 765140; `m5a-offline\mix5.txt`)

`validate-command.sh` at `b5966cf` (`validate.log`):

| Check | Result |
|---|---|
| `mix compile --warnings-as-errors` (dev and test) | clean |
| `mix format --check-formatted` on the sixteen changed files | ok |
| The accepted M4 recording (committed copy and the ext4 original) | unchanged by hash |
| Five consecutive full runs | 468 tests, 0 failures ×5 (seeds 920554, 576961, 613912, 560419, 765140) — the existing 437 retained (M3 LiveView, M4 recorder, reader, replay and statistics among them), 31 new |
| Fresh VM, `GLACIER_RELAY_COMMAND=1`, the fake peer driving the ladder (no native, no game) | children `[MissionSession, Wire.ConnectionSupervisor, Wire.Listener, Command.Supervisor]`; listener `127.0.0.1:4749`; trust `none → identified → armed/ready`; ladder `accepted, transmitted, received, applied`, observed `native`, independent `not_available`; after the close `transport none, armed false`; journal `seq 10`, events `journal.opened, link.connected, peer.identified, authority.armed, command.accepted, command.transmitted, command.received, command.terminal, authority.disarmed, link.closed, journal.closed`; file `0600`, directory `0700` on ext4 (`fresh-vm-ladder.txt`, `fresh-vm-journal.ndjson`) |
| Leftovers | no `beam.smp`; ports 4747, 4748 and 4749 free; `mix.lock` unchanged; ZHMModSDK `c5152848` clean; DLL `6047a9a3…`; 17 evidence files hashed |

Reported in full: the **first** batch at `3003191` failed one test five times out of five (the isolation check matched the word `probe` in other tests' instance ids — a polluted assertion, fixed in `b5966cf`) and its fresh-VM run crashed the authority on the first terminal result (`String.to_existing_atom("applied")` in a VM where no test had created the atom — a real defect, fixed in `4482fba`); nothing else failed. The second batch is the one above. Permissions are enforced on the ext4 filesystem the journal is meant for; a journal placed under `/mnt/c` (drvfs) reports `777` whatever is requested, which is one more reason the journal never lives beside the game.

### 17.10 Unresolved risks (carried to M5-B review)

1. **Peer trust.** Identification is a claim; the credential options are each plaintext at rest on the Windows side (17.3). M5-B/M5-C must decide the trust basis for the controlled experiment (corroboration by the telemetry connection, an ephemeral secret, or operator-in-the-loop controls alone) before any effectful entry can be marked issuable.
2. **Mission generation source.** The protocol carries `mission_generation` but nothing supplies it; the native side must derive it from an engine source that changes on a mission restart that keeps the scene resource (the archaeology's F2), and M5-B must establish and test that source before effectful scheduling.
3. **Native thread of application.** The frame-update thread is undocumented by the SDK; M5-B's native tests and M5-D must log the apply thread beside the detour's.
4. **Result delivery on link loss.** At-most-once application per command id is designed, not yet exercised natively; `unknown` is the honest outcome and the native dedup ring is M5-B's.
5. **Journal and recordings.** Command transitions are journaled separately; whether a future recording format should carry a reference to the journal (never the transitions themselves) is an open design question for M5-C.
6. **Observation of an effect** needs a vocabulary event or a labelled native read-back (17.5); for `relay.probe` neither exists by design, so M5-A proves the state machine and nothing about Glacier.

### 17.11 M5-B prerequisites (proposed minimal native acceptance and scheduling stage)

Scope for review: a `CommandLink` client thread in `GlacierRelay.dll` behind `[command] enabled = false`, connecting to 4749 only when enabled, speaking exactly the M5-A protocol (hello with the adapter instance id, the welcome, result lines), a compiled `CommandRegistry` holding **`relay.probe` only**, a bounded `CommandQueue` (8) drained one command per frame in `OnFrameUpdate` after `ObserveFrame`, a dedup ring (64 ids), TTL checked against the link's own monotonic receipt time, `received` from the link thread and the terminal result from the frame thread with the read-back (`scene_loaded`, `mission_playing`, the frame counter, the apply thread id in the native log), queue cleared and nothing applied after a link loss; the native source of `mission_generation` established and reported in hello and results; native unit tests with a fake socket and a command probe executable; the inert gate (setting off: imports and behaviour unchanged from `6047a9a3…` except the new code's presence); the existing BEAM tests driving the real native link code hosted by the probe executable. No engine write of any kind in M5-B; `player.outfit.set` stays non-issuable until M5-C.

**Stop here. M5-A is implemented and validated offline; no native code, DLL, HITMAN launch, outfit or time-scale command, browser control, telemetry, recording or replay change; M5-B, M5-C, M5-D not started; M5 not complete.**

---

## 18. M5-B — native command-link acceptance and frame scheduling: implementation and offline validation record (2026-10-14; inert; nothing installed; M5 not complete)

Authorized after the acceptance of M5-A: one BEAM journal-hardening checkpoint, then the native command transport and frame-scheduling boundary without any gameplay mutation, validated offline with native tests, a command probe executable hosting the real native code, and the real BEAM command subsystem driven end to end against it. No DLL was installed, no game launched, no engine state read or written by the command path. Evidence: `%TEMP%\glacier-m0\hitmen\m5b-offline\` (`build-clean.log`, `tests25.txt` with per-run logs, `validate-m5b.sh`, `validate.log`, the end-to-end transcripts and journals, `m5b-imports.txt`, `imports-diff.txt`, `artifacts.sha256`, `mix-run-1..5.txt`, `sha256.txt`) and the preliminary runs kept beside them (`m5b-incr1..N.log`, `m5b-tests25-a/b/c.txt`).

### 18.1 Commits and artifacts

| Repository | Commit | Content |
|---|---|---|
| glacier-relay | `d0a7eac` | **checkpoint 1 — journal failure hardening** (18.2) |
| ZHMModSDK `relay/m2` | `82511c04` | the native command path: `CommandJson`, `CommandProtocol`, `CommandQueue`, `CommandScheduler`, `CommandLink` (engine-independent), the plugin integration behind `[command] enabled = false`, four native test files, `TestListener.h`, the `GlacierRelayCommandProbe` executable, CMake |
| glacier-relay | `the commit that adds this section` | this record, roadmap, HANDOFF |

Build artifacts (clean build `build-m5b-clean.cmd` at `82511c04`, `_build/relay-x64-Debug` deleted first; hashes in `artifacts.sha256`): `GlacierRelay.dll` ``15dd58e336cd1a34836f5abca6cc2a91bc7c490dca95452fa7d3018e00a8f51b` (10,403,840 B)`, `GlacierRelayTests.exe` ``74d7e719…``, `GlacierRelayCommandProbe.exe` ``7fb22348…``, `GlacierRelayWireProbe.exe` ``15e095d5…``. **None of them is an accepted artifact and none was installed**: the accepted M2 DLL stays `6047a9a3…` in `b6-accepted-artifacts\`, the game stays at M0 (26/26 verified during the gate, no relay/hitmen/probe file under `mods/`). The M5-B DLL is preserved with its PDB and the gate files in `m5b-offline\` only as the build of record for review.

### 18.2 Checkpoint 1 — BEAM journal failure hardening (`d0a7eac`)

Every `Command.Authority` transition now goes through one audit path (`audit/2`), and the behaviour at each failure point is defined and tested (`AuditHardeningTest`, a counting writer that fails the n-th sync):

| Failure point | Behaviour |
|---|---|
| Before acceptance (the `authority.armed` entry) | arming refused; the authority is disarmed and degraded |
| On acceptance, before any transmission (`command.accepted`) | the command is refused and nothing is sent; degraded, disarmed |
| After transmission (`command.transmitted`) | the bytes are out and cannot be recalled: the command stays in flight, its record carries `audit: {:gap, [:transmitted]}`, the authority degrades and disarms; the peer's result still correlates and the command ends in the state the evidence says — never reported as unapplied |
| On the native acknowledgement, on the terminal result, on an `unknown` transition | applied in memory as the evidence says, the stage added to the command's `audit` gap, degraded, disarmed |
| During a disarm | disarmed anyway (the fail-closed direction never waits for the journal), degraded |
| During a link loss | the in-flight command becomes `unknown` (`:link_lost`) with its gap recorded, the link is dropped, disarmed, degraded |
| Journal process down | a failed append (`{:journal_unavailable, _}`), never a crash of the authority; under `rest_for_one` the authority restarts disarmed with an intact audit state and a new journal |

Once degraded, the authority refuses to arm and to issue (`{:error, {:audit_degraded, failed_event}}`) for the rest of its life: a reconnecting peer identifies normally and still cannot be armed; only a restart of the subtree (a new journal identity) restores readiness. `status/0` exposes `audit` (`:intact` or the failed event and reason) and `ready` requires it intact. **Ordering, stated and not claimed otherwise**: `command.accepted` is persisted before the send; `command.transmitted` after it; the journal cannot atomically commit a TCP send and its audit record, so an `accepted` entry without a `transmitted` one means transmission may have occurred, and a `transmitted` entry whose sync failed may still sit in the file unsynced (the journal's degraded status, not the file's tail, is the truth about durability). The observer's ingestion and recording are unaffected (tested with a fixture played during a degraded exchange). This changed no protocol field and needed no decision outside ADR 0009.

### 18.3 Native architecture

```
BEAM Command.Authority → Command.Link → TCP 127.0.0.1:4749 → CommandLink (network thread)
  → CommandProtocol::DecodeCommand (strict, bounded) → CommandQueue (8; dedup ring 64; receipt on the native monotonic clock)
  → GlacierRelay::ObserveFrame → ScheduleCommand → CommandScheduler::Tick (one command per frame)
  → relay.probe (no engine write; the frame's SceneState / predicate / attempt session id as plain values)
  → CommandLink::PushResult (results queue) → network thread writes command.result → BEAM status ladder and journal
```

- **Transport** (`CommandLink`): a second outbound loopback client, constructed only when `[command] enabled = true` in `glacierrelay.ini` (`[command] port`, default 4749; the host is not configurable). Connect with a 2 s timeout and backoff 1→30 s like the sink; hello (adapter instance id, native wall-clock text, the attempt's session id when known, capabilities `relay.probe/1`) → welcome within 2 s (a refusal or an invalid welcome disconnects and backs off) → every later command bound to the welcome's link generation. Lines at most 4,096 bytes; a line that cannot be answered (unparseable, wrong version, unknown kind, no valid id/generation, oversized) is a protocol violation and the link closes; a lost link clears the queue (invalidated ids remembered as expired), discards unsent results, resets the generation to 0 and reconnects; a new welcome is a new generation. The network thread parses, validates, deduplicates, queues and writes; it never reads or writes engine state. With the setting off: no thread, no socket, no queue, nothing constructed; the telemetry sink and the detour are untouched either way.
- **Schema** (`CommandProtocol`, `CommandJson`): the adapter had no parser before M5-B because it read nothing; the command link needs one, so `CommandJson` is a strict reader (objects, arrays, strings, numbers, literals; depth ≤ 4, ≤ 256 values, strings ≤ 1,024 bytes; duplicate keys, control characters, bad escapes, lone surrogates, leading zeros, trailing characters and invalid UTF-8 rejected). `DecodeCommand` requires version 1, kind `command`, a lowercase UUID v4 `command_id` (version nibble 1–5, variant 8–b), a positive `link_generation`, exactly the known fields, `issued_at` text, `ttl_ms` 100–10,000, a name of ≤ 64 bytes and a version, `params` and `preconditions` objects; the only precondition is `mission_generation` (≤ 64 bytes); parameters are typed per entry. The allowlist is compiled: `relay.probe/1` (no parameters) is the only executable entry; `player.outfit.set/1` decodes its two UUID parameters and is **rejected as reserved**; anything else is unknown. Results carry the closed nine-word status vocabulary, a reason ≤ 200 bytes, `native_at` text, the frame number, a read-back of ≤ 16 scalar entries (strings ≤ 128 bytes) and the attempt's session id, in a fixed field order (deterministic encoding; the encoded line decodes as an 11-field object; the M5-A fake peer's and BEAM's tests accept it). Nothing in the schema is a pointer, offset, engine object, function name or script; the tests check the sources and the encoded lines for such tokens.
- **Queue and dedup** (`CommandQueue`): capacity 8 (`busy` beyond it, nothing dropped silently); a ring of the last 64 command ids with their state (queued; done with status; invalidated as expired on link loss) so a duplicate is answered `duplicate` with the prior state and generation — while queued, after completion, after a reconnect (the ring survives the link; the reason names the earlier generation) — and `relay.probe` never executes twice for one remembered id. **A bounded cache is not exactly-once forever**: an id older than the 64-id window is not recognized (tested: after 64 further ids the same id is accepted again), and the protocol says so in every duplicate reason.
- **Scheduler** (`CommandScheduler`): on each frame, after the frame's own observation and publication (so a command never reorders the telemetry sequence): pop at most one; drop without a result a command from a link that is gone or not the current generation (its issuer was told the link was lost; the id is remembered as expired); `expired` when the native monotonic age exceeds the TTL (never applied; remembered); dispatch `relay.probe` → `applied` with the read-back `scene_available`, `mission_playing`, `frame`, `receipt_to_frame_ms` and, when the scene was readable, `scene_loaded`, `loading_stage`, `scene_type`, `codename_hint`; an unreadable scene is reported as unavailable in the read-back and the reason, never guessed; a reserved or unknown entry that somehow reached the queue is `rejected`. Stats: frames, executed, expired, stale-generation drops, rejected, the first and last invoking thread id and whether it changed, receipt-to-execution latency.
- **Plugin integration** (`GlacierRelay.cpp`): the frame counter, the attempt's session id held while an attempt is open (set on the rise from the registry read the adapter already makes, cleared on the fall; given to the link for its hello and to every result), `ScheduleCommand` after `RelayFrame::Process`, the first scheduler frame logged with its thread id beside the network thread's. No new detour, no new engine read (the session-id slot was already read on edge frames), no engine write, no change to the telemetry path.

### 18.4 Mission-generation research

Required: a native source that distinguishes mission attempts across restarts, including restarts that keep the scene resource. Candidates and findings (from the SDK headers, the adapter's own history and the M2 runtime records):

| Candidate | Finding | Verdict |
|---|---|---|
| Scene resource string | the same across a restart (archaeology F2: a restart does not go through `LoadScene`; M2 Stage A: the same resource on every restart edge) | insufficient, as the authorization states |
| Adapter instance UUID | one per game process | identifies the process, not the attempt |
| Relay sequence number | the adapter's publication counter | not an engine generation |
| Mission predicate | a boolean | identifies nothing |
| `ZEntitySceneContext::m_pScene` or any entity pointer | changes per scene load, but a pointer never crosses the wire (ADR 0001) and whether a restart keeps it is unknown | rejected |
| **The player registry's inline slot-0 session id** (`ZPlayerRegistry::m_aPlayerData[0].m_Controller.s_sSessionId`, read by `SceneObservation::ObserveGameSessionId` on edge frames since M2 Stage A) | promoted to the backend's `ContractSessionId` in M2 §20 (three independent matches); "changed on every mission entry observed, including restarts" (M2 §97); on the B2 restart the fall frame already carried the *upcoming* attempt's id and the rise carried its own (M2 §29, three restart variants); persists at the menu after an attempt | **the candidate**: Glacier's own identity for a contract session, one per attempt in every observation so far, the same value BEAM already receives in `contract.started` and `mission.playing` payloads |

Implemented in M5-B as a *reported, opaque* value only: the adapter holds the id observed on the rise while the attempt is open (`m_AttemptSessionId`), clears it on the fall, sends it in the hello (`mission_generation`) and in every result; outside an attempt it is absent (`null`), never invented. BEAM stores and journals it and compares nothing. **What is not established and keeps effectful commands disabled**: whether an engine path exists that replaces entities while Glacier keeps the same contract session (every observed restart created a new session, but the engine's own restart implementation was never inspected); the registry slot's semantics beyond the three matches of M2 §20; the value's availability on every frame of an attempt (it is read on edge frames only, by design, to keep the registry read off the per-frame path); and whether the "restart fall already carries the next id" ordering can make a command issued on the last frame of an attempt target the next one — a precondition compare on the applying frame (the design of M5 §6) closes that window only if the compare is against the rise value, which is what the adapter holds. M5-D must observe a live restart with the command path on before M5-C's effectful scheduling can rely on it; until then `mission_generation` is reported, not trusted.

### 18.5 Thread boundaries established offline

- Native unit tests: the scheduler records the thread that invokes `Tick`; a push from another thread is a queue operation only; invoking the scheduler from a second thread is recorded as `thread_changed` (so the DLL's own log can show it in M5-D).
- The command probe: three threads — the main thread, the fake frame thread (which invokes the scheduler) and the link's network thread — all logged with their ids; across every run `first_thread_id == last_thread_id`, `thread_changed = 0`, and the network thread id differs from the frame thread id (mission run: main 45628, frame 33532, network 40704; unavailable run: 45612 / 44052 / 44576; journal run: 41948 / 16160 / 44200).
- The DLL: `ScheduleCommand` logs the first frame's thread id beside the network thread's. **The actual HITMAN relationship between the frame-update thread, the detour's thread and the network thread stays unverified until M5-D**; nothing here claims thread affinity because a callback is named frame update.

### 18.6 Native tests and the gate

Clean build at `82511c04` (`build-clean.log`: `_build/relay-x64-Debug` deleted, configure, build of `GlacierRelay`, `GlacierRelayTests`, `GlacierRelayWireProbe` and the new `GlacierRelayCommandProbe`, **0 warnings in relay sources**, `GlacierRelayTests: all checks passed`), then **25 of 25** runs green (`tests25.txt`, per-run logs in `tests25\`). The harness reports pass/fail per `CHECK`, not a count; the sources hold 1,179 `CHECK` statements, 1,002 in the twelve M2 test files (unchanged) and 177 in the four new ones: `CommandProtocolTests` 60 (the JSON reader's strictness and bounds, UUID and lookup, a valid probe, answerable rejections — unknown name/version, the reserved outfit entry, unknown parameters and fields, TTL bounds, unknown and invalid preconditions — violations without an answerable identity — malformed JSON, non-objects, invalid UTF-8, wrong version, unknown kind, bad id or generation, oversize — welcome and refusal decoding, deterministic bounded encoding of hello and result, the closed status vocabulary), `CommandQueueTests` 15 (capacity eight and `busy`, pop order, duplicate while queued / after completion / after reconnect / beyond the 64-id window, link-loss clearing remembered as expired), `CommandSchedulerTests` 42 (one command per frame in order with the frame's read-back, the unavailable scene stated not guessed, TTL on the native monotonic clock with exactly-at-TTL still in time and an expired id remembered, stale and absent generations dropped without a result, a reserved entry rejected, the invoking thread recorded and a second thread detected), `CommandLinkTests` 60 (no listener: backoff; the handshake; received then applied; duplicates; rejections for an unknown command, the reserved entry and a generation mismatch; busy on the ninth; exactly one per frame across eight frames; a 100 ms TTL probe expiring before its frame; a malformed line and an oversized line closing the link; reconnect with a new generation, an old-generation command rejected and an old id a duplicate; link loss clearing a queued command without a result; a BEAM refusal; clean shutdown with and without a connection). **Preliminary runs, kept in `preliminary\`**: the first incremental build's loop passed 21/25, the second 24/25, the third 25/25; every failure was in `CommandLinkTests` and test-side — Windows loopback completes a `connect` the link had already abandoned into the listener's backlog, so the test listener could accept a dead connection and fall behind the link's welcome timeout, and three waits read the link's `connected` flag at an instant the immediate reconnect had already set it again; the test helper now skips dead connections at once and the waits use the counters that move exactly once. No native production code changed for those fixes.

### 18.7 End-to-end offline gate: the real BEAM command subsystem against the native probe

`validate-m5b.sh` ran the real BEAM command subsystem (`e2e.exs`, `--no-start`, the subtree configured with a counting journal writer, `GLACIER_RELAY_COMMAND=1`, listener `127.0.0.1:4749`) against `GlacierRelayCommandProbe.exe` on Windows (through WSL2's localhost forwarding, as the DLL reaches 4747), with the fake frame source advancing every **2,000 ms** for 20 s so that frame scheduling is visible:

| Scenario | What happened |
|---|---|
| `ladder` / `mission` | the probe connected and was welcomed (generation 1) within 1.3 s; the hello carried the fake attempt's `mission_generation`; the peer was labelled `identified` (not authenticated); the operator armed; **probe-1** `accepted → transmitted → received → applied` on fake frame 2 with the read-back `scene_available true, scene_loaded true, loading_stage 8, scene_type "mission", codename_hint "Peacock", mission_playing true, frame 2, receipt_to_frame_ms 942`, `mission_generation "fake-session-…"`, observed `native`, independent `not_available`; **probe-2** issued with `ttl_ms 100`: `received` at once, then — the next fake frame being 2 s away — BEAM's terminal timeout (TTL + 1 s grace) ended it `unknown (terminal_timeout)` at 1.1 s, and the native scheduler reported it **`expired` on frame 3, never applied** (`scheduler expired 1`); that late result reached BEAM as `anomaly.late_result` (journaled, counted, nothing changed); **probe-3** applied on frame 4; the probe exited after 20 s: `link.closed`, `authority.disarmed (link_loss)`, `arm` without a link refused. Native counters: `connects 1, disconnects 0, refusals 0, lines 3, queued 3, results_sent 6, violations 0; scheduler frames 10, executed 2, expired 1, stale 0; first thread 33532 = last thread, changed 0; max receipt-to-execution latency 2,831 ms` |
| `ladder` / `unavailable` | the same ladder with the scene unreadable: probe-1 and probe-3 `applied` with `scene_available false`, no scene fields, reason "scene state unavailable this frame", `mission_generation nil`; probe-2 as above |
| `journal` / `menu` | probe-1 applied; the journal's sync then failed on probe-2's `transmitted` entry after the line was out: the authority degraded (`failed_event command.transmitted`) and disarmed at once with the command still in flight (`audit {:gap, [:transmitted, :received]}`), the native `applied` result still correlated and the command ended `applied` with `audit {:gap, [:transmitted, :received, :applied]}` — never reported unapplied; `arm` and `probe` refused with `{:audit_degraded, "command.transmitted"}`; the journal file ends at the last durable entry (`command.transmitted` of probe-2 present but after a failed sync); `audit_failures 5` |

**Finding (reported, not hidden):** when the peer's frame interval exceeds a command's TTL plus BEAM's grace, the two sides reach different honest verdicts — BEAM `unknown`, native `expired` — and the native verdict arrives as a late result. Both are correct under ADR 0009 (no exactly-once, `unknown` stays unknown until evidence resolves it) but BEAM does not currently promote a late `expired` result into the command's record; whether it should (resolving `unknown` to `expired` when the late result is for the same id and generation) is a question for M5-C review. At HITMAN frame rates the window is tens of milliseconds and the grace covers it; the slow fake frame made it visible. Both sides' logs are kept (`e2e-*-beam.txt`, `e2e-*-probe.txt`, `nativelogs\`, `journal-*.ndjson`).

### 18.8 Native safety gate: the diff against the frozen M2 adapter

`git diff c5152848 82511c04`: 19 files, +3,292 / −1. Outside the new command sources and tests only `GlacierRelay.cpp` (+72: the settings read, the construction behind the flag, `ScheduleCommand`, the attempt-session-id bookkeeping), `GlacierRelay.h` (+25/−1), `CMakeLists.txt` and `Tests/Main.cpp` changed; `RelayAdapter`, `TcpRelaySink`, `TelemetryIntake`, `TelemetryNormalizer`, `RelayFrame`, `MissionObserver`, `SceneObservation`, `RelayEnvelope`, `RelayEvent` and every fixture are byte-identical to the M2 checkpoint. Checks: still exactly one `AddDetour` (`ZAchievementManagerSimple_OnEventSent`); no `Functions::` call, no `SetProperty`, no transform setter, no assignment through a `Globals::` pointer anywhere in the command path (grep over `Src/Command*`: no `Globals`, no `Functions`, no SDK include — the files build into the tests without the SDK on the include path, which the compiler enforces); no new engine read (the registry session-id slot was already read on edge frames); the fifteen supported events and the telemetry wire untouched; no command handling on the telemetry connection (`TcpRelaySink` unchanged, still discarding inbound bytes); no listening socket (**imports/exports identical to the accepted M2 dump**: `imports-diff.txt` empty, the same seven imported DLLs — IMM32, KERNEL32, SHELL32, USER32, WS2_32, ZHMModSDK, kernel32 — and the same three exports; no `listen`, `accept` or `bind` in the `WS2_32` imports). Shutdown ordering: the destructor unregisters the frame delegate first; then the members destruct scheduler → link (sets stop, wakes and joins its thread, which checks the flag every 50 ms select slice and closes the socket) → queue. Resource lifetime: the link owns its socket and thread; the results deque is cleared on disconnect and otherwise bounded by one result per frame plus one answer per received line; the queue and ring are bounded by construction. Thread review: every shared field of the link is under one mutex; the scheduler reads the generation once per frame and the queue's own mutex orders push/pop/mark; a generation change between the scheduler's read and its result is answered by BEAM's stale-result rule. **Compilation is not taken as evidence of thread or lifetime safety**: the native tests exercise shutdown with and without a connection, the loops, and the two-thread scheduler case; the HITMAN threads remain M5-D's.

### 18.9 Elixir gate

At `d0a7eac`: `mix compile --warnings-as-errors` clean (dev and test); `mix format --check-formatted` on the changed files; the accepted M4 recording unchanged by hash; **five consecutive full runs green at 477 tests** (468 after M5-A plus the 9 journal-hardening tests; seeds 783916, 921646, 139949, 833934, 737747; `mix5.txt`), the M3 LiveView tests, the M4 recorder, reader, replay and statistics tests and the headless invariance (no command subtree without the flag) among them; `mix.lock` unchanged; no `beam.smp`, no probe process and no bound port left; 98 evidence files hashed.

### 18.10 Inert / default-disabled invariance

With `[command] enabled` absent or false (the default), `OnEngineInitialized` constructs no queue, link or scheduler and logs "command link disabled"; `ObserveFrame` runs exactly as before plus a frame counter and the attempt-session-id bookkeeping (two assignments on edge frames); no socket, no thread, no inbound listener (there is no `listen`/`accept`/`bind` in the adapter's imports, before or after). The telemetry sink, the detour, the normalizer and the fifteen supported events are untouched; the M2 native tests are unchanged and still pass; the BEAM headless invariance (no command subtree without `GLACIER_RELAY_COMMAND=1`) is unchanged.

### 18.11 Unresolved risks

1. The mission-generation source is a candidate, not a validated precondition (18.4).
2. The HITMAN frame-update thread and the network thread's relationship are unverified until M5-D (18.5).
3. The dedup ring bounds duplicate suppression to 64 ids; a stale resend outside the window on the same native instance would execute again — acceptable for `relay.probe`, not for an effectful command without a stronger rule (an effectful entry will need the `mission_generation` precondition and BEAM's own id registry, which is unbounded for a boot).
4. The link's test suite had timing races against Windows loopback backlog behaviour (abandoned connects completing in the kernel); they were test-side and fixed, but the same behaviour will exist against BEAM's listener: the native link tolerates it by timing out the welcome and reconnecting, and BEAM's listener refuses or times out the dead connection (hello timeout 2 s) — the end-to-end run shows the real listener's behaviour (against the real listener every end-to-end run shows `connects 1, disconnects 0, refusals 0`: BEAM accepted at once and no abandoned connection occurred).
5. Peer trust is still identification only (M5-A 17.3); nothing in M5-B changes that.
6. The command path adds one queue mutex acquisition per frame when idle; the cost was not measured in HITMAN.

### 18.12 Recommended M5-C candidate and remaining prerequisites

`player.outfit.set` v1 remains the recommended first effectful command (M5 design section 2), now with its native entry already decoded and rejected as reserved, its parameter schema fixed on both sides and its precondition slot (`mission_generation`) carried end to end. Prerequisites before M5-C can be authorized: the id-to-kit resolution research (M5 §2.1, by reading the outfit kit headers and the engine's kit enumeration, not by a runtime probe); the decision on peer trust for an effectful entry (M5-A 17.10); confirmation of the mission-generation source and the thread relationship in a controlled run (M5-D can be the inert run that establishes both before any effectful entry exists — a decomposition the operator may prefer: M5-D-inert first, then M5-C); the apply path's fault guard and read-back contract for the outfit tuple; and the reversal command's own ladder.

**Stop here. M5-B is implemented and validated offline; no DLL installed, no game, no effectful command, no outfit or time-scale entry enabled, no browser control, no telemetry or recording change; M5-C and M5-D not started; M5 not complete.**


## 19. M5-B controlled inert runtime experiment: record (2026-10-14; one HITMAN run with the M5-B DLL; `relay.probe` only; nothing effectful; M5 not complete)

The authorization ("M5-B Acceptance and Controlled Inert Runtime") accepted the M5-B offline record (section 18) for its scope and authorized one controlled HITMAN experiment with the M5-B DLL to validate the command-link integration, the thread ownership, the mission-generation observations and the inert `relay.probe` command, with ten independent verdicts. Nothing in this run changed game state through the command channel; no effectful command exists in the build. All times UTC; evidence `%TEMP%\glacier-m0\hitmen\m5b-run1\` (222 files hashed in its `sha256.txt`).

### 19.1 Provenance and pre-flight (01:39:45Z; `preflight.txt`, 0 failures)

- Source: glacier-relay `main` `ecd064a790ae882600dfc5f013aff0f81fd3313f`, ZHMModSDK `relay/m2` `82511c045ad3e7e5bd72d77f1d563beb5e53a866` (on the frozen M2 checkpoint `c5152848`); both clean and equal to their remotes, re-fetched before the run.
- Binary: the M5-B DLL `15dd58e336cd1a34836f5abca6cc2a91bc7c490dca95452fa7d3018e00a8f51b` (10,403,840 B), identical in the build of record (`m5b-offline\`), the build tree and, later, the installed file; listed in the M5-B gate's `artifacts.sha256`; module banner "built Oct 13 2026 18:12:56"; PDB `824c7ebc…`; configuration `relay-x64-Debug`. The accepted M2 DLL `6047a9a3…` preserved separately, untouched.
- Native gates re-run on the same bytes: import/export names 0 differing from the accepted M2 dump (`imports-diff.txt` empty; the same seven DLLs, no `listen`/`accept`/`bind`); one `AddDetour` call site in `GlacierRelay.cpp`; `k_ProtocolVersion = 1` and `"command_protocol_version":1` on both sides; the BEAM allowlist exactly `relay.probe/1` and `player.outfit.set/1`; one reserved-rejected site in the scheduler; zero engine-write calls on the command path.
- Game: HITMAN not running; `mods.ini` `b90b4c5e…` (114 B, the M4 baseline, so the M4 `mods.ini.relay` applies); 107 retail files listed and hashed (`retail-before.{tsv,sha256}`); M0 hashes 26/26; no relay/hitmen/probe entry under `mods/`; no `mods/GlacierRelay.ini`.
- Host: ports 4747/4748/4749 unbound on WSL and on Windows; no `beam.smp`; no probe executable; state root `~/.local/state/glacier-relay-m5b-run1` on ext4, mode 0700, `rec/` and `commands/` empty; 222 GB free; 16 CPUs, 62 GB available.
- Tooling (in the evidence directory): `preflight.sh`, `install.sh`, `start-beam.sh`, `m5b_watch.exs` (the M4 in-node watcher plus the command listener/status/journal lines), `watch-m5b.sh` (the M4 native-log watcher plus every `command` line), `cmd.exs` (the operator actions over RPC: `status`, `arm`, `disarm`, `probe [ttl_ms]`, `journal` — only `GlacierRelay.Command`'s own functions; each action appends to `operator-actions.log` and dumps the status and the command record), `capture_boundary.exs` (M4's plus the command status and the journal status), `final_state.exs` / `compare3.py` / `compare_replay.exs` (M4 verbatim), `analyze.py`; `..\run-cleanup.sh` extended mechanically (ports 4748/4749 checked; `mods/GlacierRelay.ini` copied to evidence and removed). An offline dry run of the whole chain against `GlacierRelayCommandProbe.exe` (`tooling-dry-run\`) held: refusal while disarmed, applied probe with read-back, probe expired by TTL on the native clock, disarm, link loss, clean stop, replay comparison; the first dry attempt exposed a tooling path error in `start-beam.sh` (the watcher script resolved under the evidence directory), fixed in the tooling before the run.
- Operator gate: readiness confirmed with the statement that this was the first game installation of the M5-B build.

### 19.2 Installation and configuration

BEAM started first (01:45:06Z): `GLACIER_RELAY_RECORD=1 GLACIER_RELAY_RECORD_DIR=…/rec GLACIER_RELAY_COMMAND=1 GLACIER_RELAY_COMMAND_JOURNAL_DIR=…/commands elixir --sname relay -S mix run --no-halt m5b_watch.exs`, `GLACIER_RELAY_DASHBOARD` unset. Verified: application children `[MissionSession, Wire.ConnectionSupervisor, Wire.Listener, Recording.Recorder, Command.Supervisor]`; command children `[Journal, Authority, LinkSupervisor, Listener]`; 4747 and 4749 listening on 127.0.0.1 (seen from WSL and from Windows `netstat`), 4748 not bound; web supervisor, endpoint and pubsub not registered; recorder recording `2388acc6-4924-423c-8398-d770b8ec4a12`; journal `commands-5200f868-2694-47d1-8811-94932ecc1c49.ndjson` (directory 0700, file 0600); authority disarmed, no link, audit intact, journal open.

Installed 01:45:10Z (`install.sh`, which re-checks the pre-flight result, the DLL hash and the untouched `mods.ini`): `mods/GlacierRelay.dll` (`15dd58e3…`), `mods/GlacierRelay.ini` = `[command]␍␊enabled = true␍␊port = 4749␍␊` (`07d7182d…`), `mods.ini` with the `[glacierrelay]` section (`a66a44ed…`, the M4 relay variant). The listing delta against the baseline was exactly the two added files; `retail-installed.{tsv,sha256}` recorded.

### 19.3 Runtime timeline

| Time (UTC) | Event |
|---|---|
| 01:46:14 | `HITMAN3.exe` running. |
| 01:46:19.161–.281 | Module attached, `FreeLibrary`, re-attached (the SDK loader's probe, identical to M4), plugin constructed (SDK 4.1.1, ABI 1), `Init: one detour registered` — all on thread 28096. |
| 01:46:29.019–.021 | `OnEngineInitialized` on 28096: telemetry sink client, adapter instance `78f4b136-bfb9-4dd4-b40c-1fbe727cabd3`, frame update registered (priority 1, `eUpdateAlways`), command link client created, `command link enabled: port 4749, allowlist relay.probe/1 only, one command per frame, no engine write`; sink connected (thread 41408). |
| 01:46:29.022 | `command link: connected to 127.0.0.1:4749` (thread 44156). BEAM: `link.connected` generation 1, peer 127.0.0.1:45140. |
| 01:46:29.029 | First frame: `command scheduler: first frame on thread 28096 (network thread 44156)`; scene MainMenu stage 5. |
| 01:46:29.039 | Telemetry connection opened on 4747 (identified only with the first envelope, 01:48:43.148, as in M4). |
| 01:46:29.059 | `welcomed by relay@VENGEANCE; link generation 1; 1 allowlisted entr(y/ies)`. BEAM `peer.identified` 15 ms after `link.connected`: trust `identified (claimed; not authenticated)`, hello `mission_generation` null, capabilities `["relay.probe/1"]`. |
| 01:47:08–14 (R1) | Status: transport connected, protocol negotiated, peer identified, armed false, ready false, link generation 1, `mission_generation: nil`. `Command.probe()` while disarmed → `{:error, :disarmed}` locally; journal `command.refused` (`:disarmed`); no native line; counters refused 1, issued 0. Capture `r1`. |
| 01:48:28–43 (R2) | Paris loaded (MainMenu stages 8, 0, 2; Paris stages 5, 6, 7, 8); `mission playing: false -> true` 01:48:43.129; envelopes #1 `contract.started` (session `2516103582917844185-a105ec5f-3a75-46a3-8ecd-e72fd15b176c`), #2 `mission.playing` (same `game_session_id`), #3 `disguise.equipped`. |
| 01:49:11–17 (R2) | `arm` → ready true. Probe `74934808-3eea-4c64-9bc1-12c4f5d76556` (TTL 5,000): accepted +0, transmitted +2, received +3, **applied +59 ms** (BEAM monotonic, including the 25 ms RPC poll); native `received` 01:49:14.665 (thread 44156) → `applied on frame 23055` 01:49:14.666 (thread 28096); read-back `scene_available true, scene_loaded true, loading_stage 8, scene_type "mission", codename_hint "Peacock", mission_playing true, receipt_to_frame_ms 0`, `mission_generation` `…a105ec5f…` = the contract session id; observed `native`, independent `not_available`, audit intact. `disarm` → ok. Capture `r2`. |
| 01:49:56–01:50:15 (R3) | Restart (pause menu): #4 `contract.ended` 01:49:56.704 (`OnRestartLevel`, `reason_kind` restart, session `…a105ec5f…`); #5 `mission.stopped` 01:49:57.628 carrying `game_session_id` `2516103582027577704-30ccebb9-8138-4c72-9eb9-1a289b4fba33` — **the next attempt's id, read on the fall edge**; `mission playing: true -> false`; counters (attempt ended) dropped 0; Paris stages 0, 5, 6, 7, 8; #6 `mission.playing` 01:50:08.715 (`…30ccebb9…`), #7 `contract.started` .738 (same), #8 `disguise.equipped`; BEAM disposition of attempt 1 `restarted` (paired by next rise). No command issued during the transition. |
| 01:50:39–45 (R3) | `arm`; probe `d03dc3c4-53f0-479e-b1b8-3d6e3774eb3d`: +0/+2/+4/**+53 ms**; frame 30771; `receipt_to_frame_ms 2`; `mission_generation` `…30ccebb9…` = attempt 2's contract session id; `disarm`. Capture `r3`. |
| 01:51:50–53 (R4a) | Exit to menu: #9 `mission.stopped` 01:51:50.028 (`…30ccebb9…`), `mission playing: true -> false`, counters dropped 0; #10 `contract.ended` 01:51:53.035 (`exit_to_menu`); disposition `exited_to_menu` (after stop); MainMenu stages 5, 6, 7, 8 by 01:51:53.851. |
| 01:52:14–18 (R4a) | `arm`; probe `22723736-b293-4f02-9b53-b55ad6008986` at the menu: +0/+2/+3/**+52 ms**; frame 41370; `receipt_to_frame_ms 3`; `mission_playing false`, `scene_type ""`, `codename_hint ""`, **`mission_generation` null**; `disarm`. Capture `r4a`. |
| 01:52:44.425 / .427 (R4b) | HITMAN quit from the menu: BEAM telemetry connection `peer_closed` (r=13 `connection.closed`), command link `peer_closed` 2 ms later (journal `link.closed`); the native log ends at the last command line (the process exits without unloading the plugin — no destructor or "disconnected" lines, exactly as in M4). Authority already disarmed, nothing in flight, nothing queued; status: link nil, trust all `:none`. No mission stop derived from the close (attempt 2 was stopped at #9; the last record is the connection close). Explicit `disarm` (section 15) → ok, journaled. Final capture; a second capture equal to it (state, report text, command status). |
| 01:54:47 | Cleanup (`run-cleanup.sh`, 8.9 s): `init.stop` by RPC → recorder `closed (shutdown); boundary r=13`, `CLOSED`, `sha256.txt` OK; journal `journal.closed` seq 25 (`:shutdown`); launcher and watcher already exited; DLL removed; `GlacierRelay.ini` removed (after-run bytes identical to the installed bytes — the SDK did not rewrite it); `mods.ini` restored byte-identical (`b90b4c5e…`); listing identical (107 files), hashes identical, M0 26/26; 4747/4748/4749 free on WSL and Windows; no `beam.smp`, no probe executable. |

### 19.4 Verdicts

| | Verdict | Evidence |
|---|---|---|
| A. Handshake and generation binding | **PASS** | connect 1 ms after creation, welcome 37 ms after connect, generation 1 bound; every command and result carried `link_generation 1`; BEAM `peer.identified` with the claimed identity; hello generation null at the menu. |
| B. Default-disarmed and operator arming | **PASS** | disarmed at start and after every step; the disarmed probe refused locally and journaled, nothing transmitted (no native `received` line); `arm` only through the RPC API; `ready` true only while armed with an identified link. |
| C. Inert probe's full status ladder | **PASS** | three ladders accepted → transmitted → received → applied in 59 / 53 / 52 ms with native read-backs; no busy, duplicate, expired, unknown or anomaly. |
| D. Scheduler on the intended frame callback | **PASS** | every `command: … applied on frame N` line and the `first frame` statement on thread 28096, the thread of every `scene:`, `mission playing`, `published` and `tcp sink: queued` line (the frame-update path `OnFrameUpdate → ObserveFrame → ScheduleCommand`); the network thread 44156 wrote only `command link:` lines; see 19.5. |
| E. No engine mutation by the command subsystem | **PASS** | by source (no engine write on the command path; `relay.probe` reports plain frame values) and by run: 0 WARN/ERROR/FAULT, the only telemetry is the operator's restart and exit, the read-backs are observations. |
| F. Mission generation through restart and exit | **PASS with findings** | changed at the expected boundaries (`…a105ec5f…` → `…30ccebb9…`), absent at the menu before and after; but the edge-cached value lagged the registry for ≈0.92 s during the restart (19.6) — not yet a defensible effectful precondition. |
| G. Command link and telemetry transport independent | **PASS** | two sockets, two threads (44156 / 41408), two BEAM listeners; each closed on its own `peer_closed`; the command path produced no envelope and the telemetry path carried no command. |
| H. Telemetry reconciliation and M4 recording/replay invariance | **PASS** | native 10 = BEAM 10 = recorder 10, 0 field mismatches, no drops, no new event type or schema; fresh-node replay term-equal and byte-equal on all six comparisons; recorder authoritative (19.7). |
| I. Journal completeness and uncertainty handling | **PASS** | 25 entries, contiguous, monotonic, opened→closed; every stage of every command persisted with the read-back labelled native; 0 anomalies, 0 unknown, 0 audit failures; late-result policy untouched (no late result occurred). |
| J. Game stability and M0 restoration | **PASS** | load, restart and exit without instability or native warning; listing and hashes identical, M0 26/26, `mods.ini` byte-identical, both relay files removed, ports free, no leftover process. |

### 19.5 Thread and execution evidence

Per native line class (`analyze.py`): thread **28096** carried module attach, plugin construction, `Init`, `OnEngineInitialized`, all 28 `telemetry seen` lines (the detour), all 39 `scene:` / `mission playing` / `published` lines and the 10 `tcp sink: queued` lines (the frame update), the 3 `command: … applied` lines (the scheduler's emit) and the `first frame` statement; thread **44156** carried only the 5 `command link:` lines (connected, welcomed, received ×3); thread **41408** only the 10 `tcp sink: sent` lines. So in HITMAN the telemetry detour, the frame update and the command scheduler all run on the engine's main thread (the same relationship the M2–M4 logs showed for the detour and the frame update), the command network thread is a separate thread that never logged from an engine path, and the sink thread is a third. The scheduler's invocation path is, by source, `OnFrameUpdate` (registered with `RegisterFrameUpdate(…, 1, eUpdateAlways)`) → `ObserveFrame` → `RelayFrame::Process` → `ScheduleCommand` → `CommandScheduler::Tick`, after the frame's observation and publication; the run shows no other thread emitting a result. The distinct thread ids are therefore the expected ones, not a finding. `CommandScheduler::Stats` (`thread_changed`, latencies) is not logged by the plugin; the per-line thread ids are the evidence.

### 19.6 Mission-generation verdict (the five points)

| Point | Value | Source |
|---|---|---|
| 1. Menu, before any attempt | null | hello at 01:46:29; the only command at that time was the refused one |
| 2. First attempt | `2516103582917844185-a105ec5f-3a75-46a3-8ecd-e72fd15b176c` | probe `74934808` (frame 23055) = `contract.started` #1 = `mission.playing` #2 |
| 3. Restart transition | no command issued; see below | telemetry #4, #5, #6, #7 |
| 4. Second attempt | `2516103582027577704-30ccebb9-8138-4c72-9eb9-1a289b4fba33` | probe `d03dc3c4` (frame 30771) = `contract.started` #7 = `mission.playing` #6 |
| 5. After exit | null | probe `22723736` (frame 41370), `mission_playing false` |

Findings on the transition. `contract.ended` #4 at 01:49:56.704 still named the old session; the fall edge frame at 01:49:57.628 (`mission.stopped` #5) already read the **new** session id from the registry; the native command path's cached generation is set on the rise and cleared on the fall, so for ≈0.92 s the mission predicate was still true, the cached generation was the old id and the registry already named the next attempt. Between the fall (01:49:57.628) and the rise (01:50:08.715) the cached value is absent by construction (11.1 s), not observed through a result since no command was issued. The scene resource was identical across the restart (same assembly path), as expected. Consequently: the generation does change at the expected boundaries and the exited attempt's generation is never presented afterwards, but the **edge-cached value lags the engine during a restart**, so it is not, on its own, a defensible precondition for an effectful command. An effectful entry must compare its precondition against the registry session id read on the applying frame together with the mission predicate (or invalidate the cached generation on the earlier `contract.ended` signal), and BEAM's status should carry the current value: `status.link.mission_generation` is the hello-time value only (null for the whole run) while every result carried the current one — a reading rule for now, a candidate change for M5-C.

### 19.7 Telemetry invariance

`compare3.py`: native published 10 (queued 10, sent 10), BEAM reconstructed 10, recorder envelope records 10; 0 field mismatches native vs recorder and native vs BEAM; sequences 1..10 on all three; records 13 (`connection.opened`, `connection.identified`, 10 envelopes, `connection.closed`), no discontinuity, envelope order monotonic; native counters `dropped 0` on both attempt-end lines (seen 14/27, captured 3/5, unsupported 11/22, malformed 0, outside attempt 0); native severities INFO 107, WARN 0, ERROR 0, FAULT 0; BEAM rejected 0, warning 0, error 0; attempts 1–5 → attempt 1, 6–10 → attempt 2; the event types are exactly the M2 ones (`contract.started/ended`, `mission.playing/stopped`, `disguise.equipped`); protocol and schema 1; one adapter instance on both sides. `compare_replay.exs` on the closed recording against the `final` capture: instances, unidentified, summary and report term-equal, summary and report text byte-equal; finalization clean, `CLOSED`, footer `shutdown` @ 13, 13 records resolved and verified, 0 duplicates/conflicts, close reason exact, evidence authoritative, `recorder_authoritative? true` (the standing limitation: native drops are known from the native counters, not from the recording). The command path produced no telemetry envelope and the probe results travelled only on 4749; `MissionSession`, the recorder and the replay are unchanged code.

### 19.8 Journal and status consistency

`journal-5200f868….ndjson`, 25 entries, seq 1..25 contiguous, `mono_ms` monotonic: `journal.opened`; `link.connected` (generation 1, peer); `peer.identified` (adapter `78f4b136…`, trust `identified (claimed; not authenticated)`, `mission_generation` null, capabilities); `command.refused` (`:disarmed`); then three times `authority.armed`, `command.accepted`, `command.transmitted`, `command.received`, `command.terminal` (status applied, frame, the full observed map, `mission_generation`, `independent_observation not_available`), `authority.disarmed`; `link.closed` (`:peer_closed`); `authority.disarmed` (the explicit section-15 disarm — journaled although already disarmed, harmless); `journal.closed` (`:shutdown`). Counters at the end: links 1, issued 3, refused 1, unknown 0, anomalies 0, audit_failures 0; audit intact throughout. The late-result reconciliation policy was not changed and was not exercised (every probe applied on the next frame).

### 19.9 Performance and stability

| Measure | Value |
|---|---|
| Command link: client created → connected | 1 ms (native clock) |
| Command link: connected → welcomed (handshake) | 37 ms native; `link.connected` → `peer.identified` 15 ms on BEAM |
| Telemetry sink: client created → connected | 2 ms |
| Issue → applied (BEAM monotonic, incl. a 25 ms poll) | 59 / 53 / 52 ms |
| Native receipt → scheduled frame (native monotonic) | 0 / 2 / 3 ms |
| Native log `received` → `applied` | 1 / 1 / 3 ms (ms resolution) |
| Frames at apply | 23055 (01:49:14), 30771 (01:50:41), 41370 (01:52:16); first frame 01:46:29.029 |
| Queue occupancy | not instrumented natively; bounded to one in flight by BEAM and one per frame natively; no busy or duplicate |
| Journal write/sync latency | not exposed by `Journal.status` (not available) |
| Telemetry ingestion (native publish → BEAM receipt) | 0.709–20.744 ms, median 1.580 ms (the max on #1/#2 includes identification; M4: 0.95–20.88, median 2.03) |
| Recorder | 11 flushes, write max 193 µs, sync max 4,142 µs (total 27,429 µs), mailbox max 0, write errors 0 |
| BEAM | node memory 72.7 MB, 176 processes; authority 29.6 KB, recorder 34.6 KB, session 68.9 KB |
| Native | 0 WARN / 0 ERROR / 0 FAULT; no instability during load, restart or exit |

The offline fake frame was 2 s; the real game applied every probe on the next frame, so no TTL condition arose. Not measured: the idle per-frame cost of the command path.

### 19.10 Operational limitations and observations

1. At a real game exit the native side writes nothing (the process exits without unloading the plugin), so the native "disconnected / queued invalidated / unsent discarded" accounting exists only in the offline probe runs; BEAM's `peer_closed` is the record of the loss. Queued commands not executing after link loss is shown by construction (nothing was queued at exit) and by the offline tests, not by a live queued command.
2. `status.link.mission_generation` is hello-time only; results carry the current value (19.6).
3. `disarm` while disarmed journals another `authority.disarmed`.
4. One inert probe was issued at the menu after the exit (R4a) to obtain the fifth generation point; it is within section 2's scope.
5. `CommandScheduler::Stats` are not logged by the plugin; a later inert run could log them at attempt end to show `thread_changed false` directly.
6. The M4 attach-probe sequence (attach, `FreeLibrary`, re-attach) recurs; it is the SDK loader's behaviour.

### 19.11 Cleanup and preservation

Evidence `m5b-run1\` (222 files, `sha256.txt`): `preflight.txt`, `imports.txt` and the name diffs, `retail-before/installed/after.{tsv,sha256}`, `installed.sha256`, `glacierrelay.ini.installed/after-run`, `mods.ini.before/relay/after-run`, `beam.log`, `watch-native.out`, the native log `relay-20261014-014609-33996.log` (107 lines, `edd180e893a1bd77e91c45b26bc2f0c9424c9fefb6cbca3edee3e887e345374e`), the captures `r1`, `r2`, `r3`, `r4a`, `final`, `final2` (`.bin`/`.txt` incl. command and journal status), `r1/r2/r3/r4a/r4b-check.txt`, `operator-actions.log`, the command records, `recording-2388acc6-…` (closed, `CLOSED`, `sha256.txt`), `journal-5200f868-….ndjson`, `beam-events.ndjson`, `native-beam-recorder-compare.txt`, `compare-replay.out`, `timing-and-performance.txt`, `cleanup.out`, the tooling and `tooling-dry-run\`. The M5-B DLL stays preserved in `m5b-offline\` as the build of record (it ran once, in this experiment; it is removed from the game); the accepted M2 DLL `6047a9a3…` is unchanged; the committed M4 recording and the `m4-run1` and `m5b-offline` evidence verify against their hashes. The game is at M0.

### 19.12 Recommendation

The real game hosts the inert command boundary safely: the link, the handshake, the disarmed default, the frame-scheduled inert command, the independent transports and the telemetry invariance all held, and the game was restored. **M5-C research may begin** — the id-to-kit resolution research and the precondition contract — with one requirement from 19.6 carried into its design: the effectful entry's precondition must be judged against the registry session id read on the applying frame together with the mission predicate (the edge-cached generation alone lags the engine during a restart), and BEAM's status must expose the current generation. This experiment does not authorize any gameplay modification; `player.outfit.set` stays reserved and non-issuable; the time-scale fallback is not implemented; M5-D (an effectful runtime run) remains gated on M5-C and its own authorization.

**Stop here. One controlled inert experiment done, restored and recorded; no effectful command, no outfit or time-scale entry, no new detour, no rebuild, no browser control, no change to `MissionSession` or the recorder; M5-C and M6–M9 not started; M5 not complete.**


## 20. M5-B runtime acceptance record (2026-10-14; the section 19 experiment accepted for its documented scope; M5 not complete)

The authorization "M5-B Runtime Acceptance and M5-C Research" accepted the controlled inert HITMAN experiment of section 19 for its documented scope. What the run validated and what still rests on source reading are kept apart below; the mission-generation race stays an unresolved safety finding.

### 20.1 Validated at runtime (one run, HITMAN 3 at the M0 baseline, M5-B DLL `15dd58e3…`, ZHMModSDK `82511c04`, glacier-relay `ecd064a`)

| Statement | Evidence (section 19) |
|---|---|
| The native and BEAM command handshake succeeded. | `command link: connected` 1 ms after creation, `welcomed by relay@VENGEANCE; link generation 1` 37 ms later; BEAM `link.connected` → `peer.identified` 15 ms, trust `identified (claimed; not authenticated)`. |
| The authority remained disarmed until operator arming. | status `armed false, ready false` at every boundary before `arm`; the disarmed `relay.probe` refused locally (`{:error, :disarmed}`, journal `command.refused`), no native `received` line; `arm` only through the RPC operator API; disarmed again after each probe. |
| Three inert probes completed their status ladders. | `74934808`, `d03dc3c4`, `22723736`: accepted → transmitted → received → applied in 59 / 53 / 52 ms, each with a native read-back; no busy, duplicate, expired, unknown or anomaly. |
| The scheduler executed on the engine frame callback thread. | every `command: … applied on frame N` line and the `first frame` statement on thread 28096, the thread of every `scene:`, `mission playing`, `published` and `tcp sink: queued` line. |
| The command network thread was separate from the engine callback. | thread 44156 wrote only the `command link:` lines (connected, welcomed, received ×3); it never appears on an engine-path line. |
| All ten telemetry envelopes reconciled across native publication, BEAM receipt and recorder persistence. | `compare3.py`: 10 = 10 = 10, 0 field mismatches, sequences 1..10 on all three, native `dropped 0`. |
| M4 replay invariance held. | `compare_replay.exs` on the closed recording vs the `final` capture: six comparisons PASS; finalization clean; recorder authoritative. |
| The journal finalized with 25 contiguous entries and no anomalies. | seq 1..25, `mono_ms` monotonic, `journal.opened` → `journal.closed (:shutdown)`; counters anomalies 0, unknown 0, audit_failures 0. |
| Game restoration verified M0 26/26. | `cleanup.out`: DLL and `GlacierRelay.ini` removed, `mods.ini` byte-identical, listing and hashes identical (107 files), M0 26/26, ports free, no leftover process. |

Also validated at runtime: the mission generation reported in results changed across the restart (`…a105ec5f…` → `…30ccebb9…`) and was absent at the menu before and after; the telemetry and command transports closed independently at game exit (`peer_closed` 2 ms apart) with nothing queued and no mission stop derived from the close.

### 20.2 Established by source, not by the run

- The scheduler's invocation path `OnFrameUpdate → ObserveFrame → RelayFrame::Process → ScheduleCommand → CommandScheduler::Tick` (the run shows the thread, not the call chain).
- The network thread touches only the socket, the queue, the codec and the log (by reading `CommandLink.cpp`; the run shows it logged nothing from an engine path, which is consistent but weaker).
- No engine write exists on the command path (by reading; the run exercised only `relay.probe`).
- Queued commands do not execute after link loss (offline link tests and the queue-clear code; at the real exit nothing was queued).
- At a real game exit the native side writes nothing (the process exits without unloading the plugin), so native-side loss accounting exists only in the offline probe runs.

### 20.3 Unresolved safety finding (preserved)

On the restart the registry already named the next attempt's session id on the fall-edge frame, while the native edge-cached generation still held the old id for ≈0.92 s after `contract.ended`. The edge-cached generation alone is therefore **not** a defensible precondition for an effectful command. `status.link.mission_generation` on BEAM is hello-time only; results carry the current value. Both are carried into the M5-C research record (`docs/design/M5C_EFFECTFUL_COMMAND_RESEARCH.md`, sections 3 and 7).

### 20.4 Remaining limitations

The thread relationship is an observation of one build (HITMAN 3.280.0.0, SDK 4.1.1) and one run, not a guarantee across versions; `CommandScheduler::Stats` are not logged by the plugin; queue occupancy and journal write latencies were not instrumented; the idle per-frame cost of the command path was not measured; the M5-B DLL remains a build of record, removed from the game, not an accepted artifact beyond this experiment; the accepted native artifact is still the M2 DLL `6047a9a3…`.

---

## 21. M5-C research record (pointer)

The bounded, read-only M5-C investigation (outfit kit resolution, the frame-validated mission-generation contract, the native thread and lifetime contract, peer trust, effect and reversal analysis, the status and observation contract, the late-result policy, the candidate decision table, the minimal implementation proposal and its gates) is recorded in **`docs/design/M5C_EFFECTFUL_COMMAND_RESEARCH.md`**. It changes no code, enables no command and authorizes nothing; its recommendation is an inert read-back stage before any effectful entry.

**M5-B accepted for its scope; M5-C researched (section 21), then C-1 implemented and validated offline (section 22).**


## 22. M5 C-1 — inert outfit inspection and precondition instrumentation: implementation and offline validation record (2026-10-14; nothing installed; no game; no effectful command; M5 not complete)

Authorized by "M5-C Research Acceptance and C-1 Offline Implementation Authorization": a bounded, inert `relay.inspect.outfit` v1 command and the precondition instrumentation, implemented natively and on BEAM, validated offline only. `relay.probe` is unchanged; `player.outfit.set` stays reserved and rejected on both sides; `game.time_scale.set` is not implemented; no DLL was installed and HITMAN was not launched. Checkpoint verified before the work: glacier-relay `main` `90d722d`, ZHMModSDK `relay/m2` `82511c04`, both clean and equal to their remotes, tags unchanged; the M5-B DLL `15dd58e3…` and the accepted M2 DLL `6047a9a3…` verify; `m5b-run1`, `m5b-offline` and `m4-run1` evidence verify; the committed M4 recording verifies; game at M0 26/26.

### 22.1 Commits and artifacts

| What | Where | Ref / hash |
|---|---|---|
| Native C-1 (inspection, reader, evaluator, tee, snapshot, tests, probe) | ZHMModSDK `relay/m2` | **`c1bfe0c502675b6f47bc32ff59c01957ce5991b6`** on `82511c04` |
| BEAM C-1 (schema entry, facade, preconditions in the issue path, tests) | glacier-relay `main` | **`d7cace515b0100d6f28408a369de933872bf3018`** |
| This record, roadmap, handoff, README | glacier-relay `main` | the commit that adds this section |
| C-1 DLL, build of record (not accepted, not installed) | `%TEMP%\glacier-m0\hitmen\c1-offline\GlacierRelay.dll` (+ `.pdb`) | SHA-256 `7fecf31ad477891ddaac62c935cbde7df99100a8935fcc6bf7add02b7783e639` (10,522,112 B); clean build 2026-10-14 03:00Z, `relay-x64-Debug` |
| C-1 command probe, build of record | `c1-offline\GlacierRelayCommandProbe.exe` | `33444370ceb4c78ccb8dc8d18e848301775fe7d18aa8c3ab7fecde1ca8511295` |
| Native tests executable | build tree | `7445ea87747a38f561cdfff48c15235697f7c3c3920860610f766e638d7b8231` |
| Accepted native artifact | unchanged | the M2 DLL `6047a9a3…`; the M5-B DLL `15dd58e3…` stays the M5-B build of record |

### 22.2 The command and its result contract

`relay.inspect.outfit` v1 is compiled into both allowlists (native `CommandProtocol::Entry::RelayInspectOutfit1`, hello capability `relay.inspect.outfit/1`; BEAM `Command.Schema` entry, issuable, trust `identified`, effect none, no reversal). Its one parameter, `disguise_repository_id`, is optional and validated as a UUID on both sides; any other parameter or any other shape is rejected before the queue. The command may carry the protocol's existing `mission_generation` precondition (the operator's expected generation, `Command.inspect_outfit/2`'s `:expected_generation`, validated as text of 1–64 bytes); the authority now journals the preconditions it sends in `command.accepted`. Protocol version stays 1; the result envelope is unchanged; the read-back bound was raised from 16 to 48 entries on both sides (native `k_MaxObservedEntries`, BEAM `Schema.max_observed_entries/0`) and a per-field reason is bounded at 40 bytes.

Every inspection field is an object `{"status": s, "value": v, "reason": r}` with `s` ∈ observed / unavailable / unsupported / inconsistent / precondition_failed, `v` present only when observed, `r` only when given. Nothing is defaulted: a missing kit, hero or registry value is a status with a reason, never a zero id or an assumed generation; no pointer, entity reference or resource id is ever a field. The fields, in the result's fixed order: `scene_available`, `scene_loaded`, `loading_stage`, `scene_type`, `mission_playing`, `prev_frame_playing`, `frame`, `receipt_to_frame_ms`, `rise_age_ms`, `rise_age_frames`, `scene_same_as_rise`; `generation_expected`, `generation_at_receipt`, `generation_cached`, `generation_fresh`, `relay_transition_epoch`, `epoch_at_receipt`, `contract_started_seen`, `contract_ended_seen`; `hero_outfit_id`, `hero_charset`, `hero_variation`, `hero_charset_count`, `hero_heroa_vars`, `hero_heroa_valid`, `hero_suit`; when a candidate was named `candidate_id`, `candidate_found`, `candidate_charsets`, `candidate_heroa_vars`, `candidate_heroa_usable`, `candidate_suit`, `kits_scanned`; `set_outfit_available`, `kit_map`, `reads_on_frame`; `precondition_ok`, `precondition_reasons`. Measured through the scheduler with every text at its bound: 2,972 bytes with everything observed and 3,503 bytes with every engine-derived field unavailable, against the 4,096-byte line bound; an inspection that would still not fit is reduced deterministically to its first nineteen entries (frame, scene, generations, transition) with `observed_reduced: true` and a reason, counted in the scheduler's `reduced` statistic — the protocol's bound is never raised.

Example (the probe's FAKE data, from the offline gate; the generation and ids are the probe's fabrications, not HITMAN state):

```
{
 "command_id": "e221dcb5-1ba7-45a2-9dcd-e722924c5ecd",
 "status": "applied",
 "frame": 3,
 "mission_generation": "fake-session-28c9c548-1",
 "observed": {
  "rise_age_ms": {
   "status": "observed",
   "value": 4014
  },
  "contract_ended_seen": {
   "reason": "none observed",
   "status": "unavailable"
  },
  "scene_available": {
   "status": "observed",
   "value": true
  },
  "generation_fresh": {
   "status": "observed",
   "value": "fake-session-28c9c548-1"
  },
  "generation_expected": {
   "status": "observed",
   "value": "fake-session-28c9c548-1"
  },
  "hero_charset_count": {
   "status": "observed",
   "value": 1
  },
  "scene_same_as_rise": {
   "status": "observed",
   "value": true
  },
  "prev_frame_playing": {
   "status": "observed",
   "value": true
  },
  "kits_scanned": {
   "status": "observed",
   "value": 3
  },
  "precondition_ok": {
   "status": "observed",
   "value": false
  },
  "hero_heroa_vars": {
   "status": "observed",
   "value": 1
  },
  "precondition_reasons": {
   "status": "observed",
   "value": "stable_interval_too_short,stable_frames_too_few"
  },
  "hero_outfit_id": {
   "status": "observed",
   "value": "874c4c48-0a8b-49e9-883e-49fc5f1fb051"
  },
  "kit_map": {
   "status": "observed",
   "value": true
  },
  "candidate_charsets": {
   "status": "observed",
   "value": 1
  },
  "epoch_at_receipt": {
   "status": "observed",
   "value": 1
  },
  "candidate_found": {
   "status": "observed",
   "value": true
  },
  "candidate_id": {
   "status": "observed",
   "value": "874c4c48-0a8b-49e9-883e-49fc5f1fb051"
  },
  "contract_started_seen": {
   "status": "observed",
   "value": "fake-session-28c9c548-1"
  },
  "generation_at_receipt": {
   "status": "observed",
   "value": "fake-session-28c9c548-1"
  },
  "hero_variation": {
   "status": "observed",
   "value": 0
  },
  "candidate_heroa_usable": {
   "status": "observed",
   "value": true
  },
  "set_outfit_available": {
   "status": "observed",
   "value": true
  },
  "reads_on_frame": {
   "status": "observed",
   "value": true
  },
  "scene_type": {
   "status": "observed",
   "value": "mission"
  },
  "rise_age_frames": {
   "status": "observed",
   "value": 2
  },
  "candidate_heroa_vars": {
   "status": "observed",
   "value": 1
  },
  "hero_suit": {
   "status": "observed",
   "value": true
  },
  "mission_playing": {
   "status": "observed",
   "value": true
  },
  "hero_charset": {
   "status": "observed",
   "value": 0
  },
  "loading_stage": {
   "status": "observed",
   "value": 8
  },
  "scene_loaded": {
   "status": "observed",
   "value": true
  },
  "generation_cached": {
   "status": "observed",
   "value": "fake-session-28c9c548-1"
  },
  "relay_transition_epoch": {
   "status": "observed",
   "value": 1
  },
  "frame": {
   "status": "observed",
   "value": 3
  },
  "candidate_suit": {
   "status": "observed",
   "value": true
  },
  "hero_heroa_valid": {
   "status": "observed",
   "value": true
  },
  "receipt_to_frame_ms": {
   "status": "observed",
   "value": 1968
  }
 }
}
```

### 22.3 Native outfit observation (`SceneObservation::ObserveOutfit`, the only new engine reads)

Called by the scheduler through the plugin's inspector only when a `relay.inspect.outfit` is the command taken on a frame — never on an idle frame (`CommandQueue::Waiting`-free by construction: the inspector is invoked from inside the dispatch) — and wrapped in its own `RelayLog::Guard` scope so a fault inside a read is logged with the command's context and reported as unavailable. Every dereference, in order: `Globals::PlayerRegistry` null-checked; the slot-0 `s_sSessionId` read twice with the adapter's existing guards (non-empty, ≤ 256 bytes, non-null buffer) — two empty reads are unavailable, two different reads are **inconsistent** (a possible torn read is an explicit failure mode, never averaged); slot-0 `m_HitmanEntity` (`ZEntityRef`, null-checked) resolved to `TEntityRef<ZHitman5>` through the SDK's `QueryInterface` and its interface pointer null-checked (the SDK's `GetLocalPlayer()` is not used: it walks the registry's `TArray` model the adapter's archaeology found unreliable); the hero's `m_rOutfitKit` reference and interface null-checked; the kit's `m_sId` copied out byte-wise and rendered exactly as the telemetry intake renders disguise ids; `m_aCharSets.size()` bounds-checked before every indexed read, the charset collection reference and interface null-checked, `m_aCharacters.size() > ECSCT_HeroA (2)` checked, the HeroA type reference and interface null-checked, `m_aVariations.size()` read; at most sixteen charsets read per kit; `Globals::ContentKitManager` null-checked and the candidate id, parsed by the Relay's own `RepositoryId::FromDashedLowercase`, matched against each map entry's 16-byte key by `memcmp` over a bounded scan (4,096 entries; the engine's comparator is not relied on), the matched entry's reference and interface null-checked; `Functions::ZHitman5_SetOutfit` null- and `Exists()`-checked, never called. The HeroA validity rules (charset within bounds, HeroA count readable, variation within bounds; a candidate usable when charset 0 has at least one HeroA variation) live in the engine-free `OutfitObservation::DescribeHeroOutfit` / `DescribeCandidate` over a plain `KitShape` extracted by the reader, so the tests exercise exactly the rules the DLL applies. The Player mod's shared-kit resource rewrite is not used; nothing is written; nothing is retained across frames; the kit definition (the global kit entity) is what is inspected, never an outfit instance.

### 22.4 Mission generation, the Relay transition epoch and the receipt snapshot

Three generations are now kept apart and reported: `generation_cached` (the edge-cached attempt session id, set on the rise and cleared on the fall, as since M2), `generation_at_receipt` (the value the frame thread had published when the network thread received the command — a copy stamped under the queue lock, never an engine read on the network thread, never presented as fresh), and `generation_fresh` (the registry read on the inspection frame, twice). `relay_transition_epoch` is a Relay-owned `uint64` advanced on exactly these observations: a mission predicate rise; a fall; a `contract.ended` observed for the active generation (through `LifecycleTee`, a sink decorator that forwards every envelope unchanged and reads the two contract envelopes' session ids after the fact on the frame thread — the intake, normalizer, frame sequencer and adapter are untouched); the scene becoming unavailable during an attempt (once per attempt); a registry generation read on an inspection frame that differs from the cached one (once per attempt; the inspecting result reports the two values directly, the epoch advances for the frames after it). Every advance is logged with its reason and frame. It is not an engine value and does not claim to see every engine transition. The frame thread publishes `{generation_cached, epoch}` to the queue in the same lock as its pop, so a command received afterwards is stamped with that frame's values and nothing older; the result carries `epoch_at_receipt` beside the current epoch.

### 22.5 The hypothetical precondition evaluator (`PreconditionEvaluator`, pure)

Over a copied `Input`, collecting every failed rule rather than the first: expected, at-receipt and cached generations present and the fresh one observed (inconsistent is its own reason), all equal to the expected; the predicate true now and on the previous frame; at least 1,000 ms and 60 frames since the rise (the research proposal's numbers, `Rules` constants, documented as such — the probe scales them to its fake frame rate and says so); a `contract.started` observed for the expected generation and no `contract.ended` for it; scene available, loaded, stage 8, type mission, resource equal to the rise's; epoch unchanged since receipt; the player resolved and the outfit readable; HeroA valid; a candidate named, resolved and HeroA-usable; the optional expected-current outfit id equal to the hero's; the setter available. Thirty reason codes (`expected_generation_missing` … `setter_unavailable`). It performs no action, and the inspection command does not depend on it: a failing frame is inspected and reported with `precondition_ok: false` and its reasons, which is what makes the evaluator checkable. A missing contract start, a changed generation or an active transition fails regardless of elapsed time (tested).

### 22.6 Thread and resource boundaries

The network thread copies only the published snapshot (under the queue mutex) and never dereferences the registry or any engine object; the scheduler takes one command per frame; the inspector runs on the frame thread inside the frame's dispatch and reports its own thread id (`reads_on_frame`); no engine write exists on the command path (no assignment to any engine member in the command sources; `SetOutfit` is referenced only for `Exists()`); exactly one detour (`AddDetour` once in `GlacierRelay.cpp`); the telemetry socket, the normalizer and the event vocabulary are unchanged; the sink chain gains the tee only with `[command] enabled = true`; no listening socket; no idle-frame scan (the kit map is scanned only for a named candidate, bounded). With the setting off, nothing of C-1 is constructed and the telemetry path is the M2 one.

### 22.7 Native tests and the gate

`OutfitInspectionTests.cpp` (new) covers: the repository-id parser round trip and its rejections; the kit shape rules (current hero tuple, invalid charset, invalid variation, missing HeroA collection, candidate found and usable, zero HeroA variations, no charset); the evaluator (every rule satisfied; fresh and receipt generation mismatch; each missing value; inconsistent fresh read; epoch changed; missing and mismatching contract start regardless of elapsed time; contract end observed; the stable interval and frame boundaries just below and exactly at the rule, and scaled rules; the rise frame; not playing; scene unavailable, loading / teardown, wrong type; a restart with the scene resource unchanged caught by the generation and contract rules; missing hero, unreadable outfit, HeroA invalid; candidate missing / unresolved / not usable; expected-current match and mismatch; setter unavailable; every reason code distinct); the lifecycle tee (ids observed, everything forwarded unchanged, unreadable payload counted); the receipt snapshot stamping; scheduling with a fake inspector (an idle frame never inspects; the full read-back; the restart race; unknown and absent candidates; null global, missing hero, torn read, no inspector); decoding of the entry and its parameter (uppercase id, unknown parameter, the reserved entry still rejected); the two measured encodings; deterministic truncation beyond 48 entries and the 40-byte reason cut; the reduction path; and that the reserved effectful entry reaching the queue is rejected without an inspector call — the test executable links the whole command path without the SDK, so no engine function can be referenced from it. Clean build: 0 warnings in relay sources (the three warning lines of `build-clean.log` are binrw's two Rust notices and the MSVC `utility(274)` C4244, as in M5-B); native tests: first loop **24/25** (`tests25\`: run 24 failed `TcpRelaySinkTests.cpp:274 s_Stats.sent == 4`, an M2 sink test's statistics read racing the sink thread's increment after the reader saw the line — unchanged code, a test-side timing window, reported as found), second loop **25/25** (`tests25b\`); the two loops and both logs are kept.

### 22.8 Offline native probe

`GlacierRelayCommandProbe` now hosts the real link, queue and scheduler with a FAKE frame source and a FAKE inspection source (a three-kit table: the suit id as a HeroA-usable kit, a kit with zero HeroA variations, a kit without a HeroA type; a fake hero; a fake registry), with the stable rule scaled to its frame rate and stated in its output. Modes: `menu`, `mission`, `unavailable`, and `restart` (from fake frame 8 the fake registry names the next generation while the predicate still holds, a contract end is observed for the active generation, the predicate falls at 12 and rises at 16 with the new generation). It maintains the same transition instrumentation the plugin does over its script. Its data is labelled fake in every log line and is never HITMAN state; the DLL's reader is not linked into it.

### 22.9 Offline end-to-end gate (the real BEAM subsystem against the probe; `c1-offline\`)

Three scenarios; every value below is the probe's FAKE data (ids and generations fabricated by the probe), reported here as what the two implementations exchanged, never as HITMAN state.

- **`inspect` / mission mode (2 s fake frames, 32 s).** Handshake welcomed with both entries. `relay.probe` applied (unchanged). `inspect-1` (suit candidate, expected = the hello's fake generation): applied on fake frame 3; 38 fields, 37 observed and 1 unavailable (`contract_ended_seen`, "none observed"); hero `874c4c48…` charset 0 variation 0, HeroA valid, suit; candidate found, HeroA-usable, 3 kits scanned; setter and kit map available; reads on the frame thread; `precondition_ok false` with `stable_interval_too_short,stable_frames_too_few` (the scaled rule, 2 frames after the rise). `inspect-2` (a kit with zero HeroA variations): `candidate_not_heroa_usable`. `inspect-3` (an id not in the table): `candidate_found false`, `candidate_unresolved`, the five dependent candidate fields unavailable. `inspect-4` (no candidate, no expected generation): 31 fields; `expected_generation_missing,candidate_missing`. `inspect-5` (TTL 100 ms on 2 s frames): BEAM `unknown (terminal_timeout)` at +1,102 ms, native `expired` on the next fake frame, the late result journaled as `anomaly.late_result` — the unchanged policy. `inspect-6`: applied with `precondition_ok true` on fake frame 8 (the scaled stable rule satisfied). The same command line re-sent to native through the link process: native answered `duplicate` (probe: `duplicate 1`), BEAM journaled the extra result as a second `anomaly.late_result`, the command's status stayed `applied`. Probe exit → link loss, authority disarmed, `arm` refused `no_identified_link`. Counters: links 1, issued 7, unknown 1, anomalies 2, refused 0, audit intact. Probe: lines 8, queued 7, busy 0, duplicate 1, violations 0, results sent 15; scheduler frames 16, executed 1, inspected 5, reduced 0, expired 1, stale 0; one frame thread throughout (`changed 0`), network thread distinct.
- **`restart` / restart mode (1 s fake frames, 30 s; one inspection per tick with the suit candidate, the expected generation following the last observed fresh value).** The fake epoch advanced exactly as designed: 1 rise (frame 1), 2 contract end for the active generation (frame 8), 3 registry differs from the cached generation on an inspection frame (frame 8), 4 fall (frame 12), 5 rise (frame 16). Tick 1 (frame 2): all four generations G-1, `stable_*_too_short`. Ticks 2–3 (frames 4, 6): **`precondition_ok true`**. Tick 4 (frame 8, the race): expected/at-receipt/cached G-1, **fresh G-2**, epoch 2 vs 1 at receipt, `contract_ended_seen` G-1 → `generation_mismatch_fresh,contract_end_observed,epoch_changed`. Tick 5 (frame 10, expected now G-2): `generation_mismatch_receipt,generation_mismatch_cached,contract_start_mismatch`. Ticks 6–7 (frames 12, 14, after the fall): `cached_generation_missing` / `receipt_generation_missing`, `mission_not_playing`, `scene_not_loaded`, `loading_stage_not_playing`, 11–12 fields unavailable. Tick 8 (frame 16, the rise frame): at-receipt absent, `previous_frame_not_playing`, `stable_*`, `epoch_changed` (5 vs 4). Tick 9 (frame 18): only the stable rule. Ticks 10–15 (frames 20–30): **`precondition_ok true`** with G-2 everywhere and `contract_started_seen` G-2. Ticks 16–22: refused locally (`:disarmed`) after the probe's 30 s exit dropped the link — the driver outlived the probe by design. Counters: issued 15, unknown 0, anomalies 0, refused 7.
- **`unavailable` / unavailable mode.** One inspection: 19 fields observed, 19 unavailable — scene fields and the registry/hero reads unavailable with their reasons, the candidate still resolved against the fake kit map (independent of the scene), `precondition_ok false` with every scene and generation reason. Link loss disarmed.

Journals: `journal-inspect-mission.ndjson`, `journal-restart-restart.ndjson`, `journal-unavailable-unavailable.ndjson` (inspect/mission 37 entries: anomaly.late_result 2, authority.armed 1, authority.disarmed 1, command.accepted 7, command.received 7, command.terminal 6, command.transmitted 7, command.unknown 1, journal.closed 1, journal.opened 1, link.closed 1, link.connected 1, peer.identified 1; restart 74 entries: authority.armed 1, authority.disarmed 1, command.accepted 15, command.received 15, command.refused 7, command.terminal 15, command.transmitted 15, journal.closed 1, journal.opened 1, link.closed 1, link.connected 1, peer.identified 1; unavailable 11 entries: authority.armed 1, authority.disarmed 1, command.accepted 1, command.received 1, command.terminal 1, command.transmitted 1, journal.closed 1, journal.opened 1, link.closed 1, link.connected 1, peer.identified 1). Command and observer isolation: the command path produced no telemetry, `MissionSession` and the recorder were not started in the driver and are untouched in code.

### 22.10 BEAM regression gate

Compile with warnings as errors (dev and test): ok. Format check on the changed files: ok. Five consecutive full runs: 483 tests, 0 failures in each (seeds 942139, 760985, 494221, 763040, 922792); the suite grew from 477 to 483 (the six inspection tests). The accepted M4 recording verifies; no browser route was added; the headless tree is unchanged; the journal format version is unchanged (the `command.accepted` entry gains the `preconditions` field it sends).

### 22.11 Imports and hooks

Raw import-symbol diff of the C-1 DLL against the M5-B artifact's dump and against the accepted M2 dump (`imports-symbol-diff-vs-m5b.txt`, `imports-symbol-diff-vs-b6.txt`; 194 → 197 names): exactly three names added, no name removed, all data imports from `ZHMModSDK.dll` —

1. `?ContentKitManager@Globals@@2PEAVZContentKitManager@@EA` — `Globals::ContentKitManager`, the engine's kit map, read (null-checked) to resolve a named candidate.
2. `?TypeRegistry@Globals@@2PEAPEAVZTypeRegistry@@EA` — `Globals::TypeRegistry`, used by the SDK's inline `ZEntityRef::QueryInterface` when the reader resolves `TEntityRef<ZHitman5>` from the slot-0 hitman reference (an SDK-internal dereference the record counts as an unresolved runtime assumption).
3. `?ZHitman5_SetOutfit@Functions@@2PEAV?$EngineFunction@…@@EA` — `Functions::ZHitman5_SetOutfit`, read for `Exists()` only; no call site exists.

The same seven DLLs (`IMM32`, `KERNEL32`, `SHELL32`, `USER32`, `WS2_32`, `ZHMModSDK`, `kernel32`); exports unchanged (`CompiledSdkAbiVersion`, `CompiledSdkVersion`, `GetPluginInterface`); no `listen`/`accept`/`bind`. Hooks: exactly one detour (`ZAchievementManagerSimple_OnEventSent`), unchanged; the lifecycle tee is a sink decorator, not a hook. A correction to the gate tooling's own claim: the name normalization inherited from the M5-B gate does not match mangled C++ names, so its "0 differing names" lines count only unmangled names; the raw symbol diff is the authoritative comparison and, re-run on the M5-B dump, confirms the M5-B artifact added no symbol over the M2 dump (consistent with the M5-B record).

### 22.12 Unresolved runtime assumptions

1. The registry's slot-0 session id can be read twice without a torn read on the real engine — the inconsistent status exists precisely because this is unverified.
2. `TEntityRef<ZHitman5>` resolves from slot-0 `m_HitmanEntity` through the SDK's `QueryInterface` on this build; the DLL has never done it. The SDK's own `GetLocalPlayer` does the same resolution from the other registry model.
3. The kit map is populated and iterable on the frame thread while a mission plays; its size (hundreds in the Player mod's experience) is within the scan bound.
4. `m_rOutfitKit->m_sId` equals the id the engine's `Disguise`/`StartingSuit` telemetry reports (the research chain says so; the inspection is what will show it).
5. `Functions::ZHitman5_SetOutfit->Exists()` on HITMAN 3.280.0.0 — read, never called.
6. The tee's contract ids reach the epoch logic before the fall edge in the real restart (the M5-B timeline says the end precedes the fall by ≈0.9 s).
7. The per-frame cost of publishing the snapshot (one extra assignment inside the existing pop lock) is negligible — not measured in the game.

### 22.13 Proposed controlled C-1 HITMAN experiment (its own authorization; not performed)

Pre-flight as §19 with the C-1 DLL `7fecf31a…` and `[command] enabled = true`; BEAM with the recorder and the command subtree. R1 menu: handshake with both capabilities; one `relay.inspect.outfit` without a candidate — expect `mission_playing false`, the hero unavailable or resolved at the menu (both are findings), `set_outfit_available` and `kit_map` read for the first time on this build, `generation_fresh` unavailable or the menu's value. R2 Paris, stable: `inspect_outfit(%{"disguise_repository_id" => "874c4c48-…"}, expected_generation: <the contract session id from telemetry>)` — expect the hero tuple equal to the telemetry's disguise id, `candidate_found true`, `candidate_heroa_usable`, `precondition_ok true` (or the reasons that fail, each a finding); a second inspection with a non-suit kit id from the same attempt's `disguise.equipped` history if any. R3 restart: one inspection within the first second after the rise (expect `stable_interval_too_short` / `stable_frames_too_few`), one after the contract end is observed but before the fall if the operator's timing allows (expect `generation_mismatch_fresh`, `contract_end_observed`, the epoch advanced), one in the stable second attempt. R4 exit and quit as §19. Verdicts: resolution, tuple agreement with telemetry, fresh-versus-cached generation at each point, epoch advances at the expected observations, thread identity of the reads, no WARN/ERROR/FAULT, telemetry invariance (10 = 10 = 10 again), journal completeness, M0 restoration. Abort conditions as §19 plus any fault inside the inspection guard.

**C-1 implemented and validated offline (section 22), then run once in the game under its own authorization (section 23).**


## 23. M5 C-1 controlled inert runtime experiment: record (2026-10-14; one HITMAN run with the C-1 DLL; `relay.inspect.outfit` only; read-only; M5 not complete)

Authorized by "M5 C-1 Offline Acceptance and Controlled Inert Runtime Authorization": one controlled HITMAN experiment with the frozen C-1 build to validate `relay.inspect.outfit` against real engine state. Read-only; nothing effectful implemented, enabled or issued; no source or binary changed. All times UTC; evidence `%TEMP%\glacier-m0\hitmen\c1-run1\` (228 files hashed in its `sha256.txt`).

### 23.1 Provenance and pre-flight (03:28Z; `preflight.txt`, 0 failures)

glacier-relay `main` `59fa95df7840a30b26ac14d3ab01dc7cfc55e392` (the BEAM C-1 commit `d7cace51…` in its history) and ZHMModSDK `relay/m2` `c1bfe0c502675b6f47bc32ff59c01957ce5991b6`, both clean and equal to their remotes; the five research tags unchanged (`research/m0-baseline` → `2d675792…`, `m1` → `53d43461…`, `m2` → `135d6da3…`, `m3` → `54bcc4f2…`, `m4` → `491ef141…`; ZHMModSDK `research/m2-telemetry` → `c5152848…`). C-1 DLL `7fecf31ad477891ddaac62c935cbde7df99100a8935fcc6bf7add02b7783e639` (10,522,112 B) identical in the build of record, the build tree and, later, the installed file; command probe `33444370…`; M5-B DLL `15dd58e3…` and accepted M2 DLL `6047a9a3…` preserved; `c1-offline`, `m5b-run1`, `m5b-offline`, `m4-run1` evidence and the committed M4 recording verify. Native gates on the same bytes: the **raw import-symbol diff** against the M5-B dump exactly the three explained names (`Globals::ContentKitManager`, `Globals::TypeRegistry`, `Functions::ZHitman5_SetOutfit`), 0 removed, identical to the C-1 gate's dump, no `listen`/`accept`/`bind`; one `AddDetour`; 0 `SetOutfit->Call` sites (1 `Exists()` read); hello capabilities `relay.probe/1`, `relay.inspect.outfit/1`; BEAM issuable `relay.inspect.outfit/1 relay.probe/1`, `player.outfit.set` reserved on both sides. Game: M0 26/26, 107 retail files hashed, `mods.ini` `b90b4c5e…`, no relay file, no `GlacierRelay.ini`; HITMAN not running; ports free on WSL and Windows; no BEAM or probe process; state root ext4 0700 empty; 222 GB free. Tooling (M5-B run tooling extended with `cmd.exs inspect [candidate|-] [expected|-] [ttl]`, which logs every read-back field with its status, value and reason; `watch-c1.sh` adds the epoch and inspection lines): dry run against the C-1 probe's FAKE data (`tooling-dry-run\`) held — disarmed refusal, arm, inspections with and without a candidate, the expected generation carried, per-field statuses captured, clean stop, replay held. Operator readiness confirmed for the first installation of the C-1 DLL.

### 23.2 Installation and configuration

BEAM 03:31:11Z (`GLACIER_RELAY_RECORD=1`, `GLACIER_RELAY_COMMAND=1`, dashboard unset): children `[MissionSession, Wire.ConnectionSupervisor, Wire.Listener, Recording.Recorder, Command.Supervisor]`, 4747 and 4749 listening on both sides, 4748 unbound, no web process; recording `13c12d60-8327-4249-b997-e9677dcf03d4`; journal `86f8a2d7-c92d-43c3-a7b7-03310b9d3719` (0700/0600); authority disarmed. Installed 03:31:14Z: `mods/GlacierRelay.dll` (`7fecf31a…`), `mods/GlacierRelay.ini` = `[command] enabled = true, port = 4749` (`07d7182d…`; no effectful setting, no credential), `mods.ini` with `[glacierrelay]` (`a66a44ed…`); listing delta exactly the two files.

### 23.3 Runtime timeline

| Time (UTC) | Event |
|---|---|
| 03:31:45 | `HITMAN3.exe` running. 03:31:53.567–.690 module attached, `FreeLibrary`, re-attached (the loader's probe, as always), plugin constructed (SDK 4.1.1), `Init: one detour registered` — thread 46608. |
| 03:32:03.372–.403 | `OnEngineInitialized`: adapter `aaf540dd-c6df-4429-8fa5-84bc8933a13e`, sink client and connection (thread 45812), command link client, `allowlist relay.probe/1 and relay.inspect.outfit/1 (read-only)`; first frame `command scheduler: first frame on thread 46608 (network thread 14160)`; link connected 12 ms after creation, welcomed 19 ms later with `2 allowlisted entr(y/ies)`, generation 1; BEAM `peer.identified` 13 ms after `link.connected`, capabilities both entries, trust `identified (claimed; not authenticated)`, hello generation null. |
| 03:32:49–57 (R1) | `inspect_outfit` while disarmed → `{:error, :disarmed}`, journal `command.refused`, nothing on the native side. `arm`; **menu inspection** `a52dc353` (no candidate, no expected generation): applied on frame 8191, +55 ms, receipt→frame 2 ms; 31 fields, 22 observed / 9 unavailable (`generation_expected` "not supplied", `generation_at_receipt` and `generation_cached` "no open attempt", `generation_fresh` "registry session id empty or implausible", `rise_age_*` and `scene_same_as_rise` "not playing", `contract_*_seen` "none observed"); `mission_playing false`, `scene_type ""`, stage 8, loaded; **the hero resolved at the menu**: `hero_outfit_id 4fc9396e-2619-4e66-a51e-2bd366230da7`, charset 0, variation 0, 1 charset, 1 HeroA variation, HeroA valid, `hero_suit true`; `kit_map true`; **`set_outfit_available true`** (first observation of `ZHitman5_SetOutfit` resolved on this build; read only); `reads_on_frame true`; epoch 0/0; `precondition_ok false` with `expected_generation_missing, receipt_generation_missing, cached_generation_missing, fresh_generation_unavailable, mission_not_playing, …`. `disarm`. Capture `r1`. |
| 03:33:28–51 (R2) | Paris loaded (MainMenu 8, 0, 2; Paris 5, 6, 7, 8); rise 03:33:42.732 (`relay transition epoch 1: mission predicate rise (frame 14369)`), #1 `mission.playing` and #2 `contract.started` session `2516103519921974492-5fd4f3e1-0fa5-408f-bce8-b58923581360`, #3 `disguise.equipped (initial) 874c4c48…` at 03:33:51.058. |
| 03:34:19–28 (R2) | `arm`; **stable inspection** `cb9e8d6d` (candidate `874c4c48…`, expected = that session id), 40 s after the rise: applied on frame 18066, +57 ms, receipt→frame 2 ms; 38 fields, 37 observed / 1 unavailable (`contract_ended_seen` "none observed"); **`hero_outfit_id 874c4c48-0a8b-49e9-883e-49fc5f1fb051`** = the telemetry's disguise id, charset 0, variation 0, HeroA valid, suit; **candidate found** (`kits_scanned 153`), 1 charset, 1 HeroA variation, usable, suit; `set_outfit_available true`, `kit_map true`, `reads_on_frame true`; `generation_expected` = `generation_at_receipt` = `generation_cached` = `generation_fresh` = `…5fd4f3e1…`; epoch 1/1; `contract_started_seen` = the same id; `rise_age 39,683 ms / 3,696 frames`; `scene_same_as_rise true`; **`precondition_ok true`**. `disarm`. Capture `r2`. |
| 03:37:01–23 (R3) | Restart: #4 `contract.ended` (`OnRestartLevel`, session `…5fd4f3e1…`) 03:37:01.835 → `relay transition epoch 2: contract end observed for the active generation (frame 34001)`; #5 `mission.stopped` 03:37:02.806 carrying `game_session_id 2516103517775032266-1d02b337-fc7b-4e4d-8839-7988bca9aead` — **the next attempt's id on the fall-edge frame, 0.97 s after the contract end, as in M5-B** → `epoch 3: mission predicate fall (frame 34102)`, counters dropped 0; Paris 0, 5, 6, 7, 8; #6 `mission.playing` 03:37:13.840 → `epoch 4: mission predicate rise (frame 34354)`; #7 `contract.started` `…1d02b337…` .865; #8 `disguise.equipped (initial) 874c4c48…` 03:37:23.762. BEAM disposition of attempt 1 `restarted`. No command during the transition. |
| 03:37:57–03:38:20 (R3) | `arm`; `05fab718` (candidate, expected `…1d02b337…`), issued when the operator reported control — 47 s after the rise, so the stable window had passed and was not retried: applied on frame 38743, +53 ms, receipt→frame 6 ms; 38/38 observed; hero `874c4c48…` 0/0 valid suit; candidate found, 153 scanned, usable; all four generations `…1d02b337…`; epoch 4/4; `contract_started_seen …1d02b337…`, **`contract_ended_seen …5fd4f3e1…`** (the previous generation's end, correctly not this one's); `rise_age 46,952 ms / 4,388 frames`; `precondition_ok true`. `c1f65faa` 13 s later: applied on frame 40012, +55 ms, receipt→frame 3 ms; identical values; `rise_age 60,081 ms / 5,657 frames`; `precondition_ok true`. `disarm`. Capture `r3`. |
| 03:39:03–07 (R4a) | Exit to menu: #9 `mission.stopped` 03:39:03.308 → `epoch 5: mission predicate fall (frame 44884)`; #10 `contract.ended` (`exit_to_menu`) 03:39:06.275; MainMenu 5, 6, 7, 8 by 03:39:07.085; disposition `exited_to_menu`. |
| 03:39:25–32 (R4a) | `arm`; **final menu inspection** `a6e7b8d9` (no candidate): applied on frame 48420, +53 ms, receipt→frame 0 ms; 31 fields, 25 observed / 6 unavailable; `mission_playing false`, `scene_type ""`; `generation_cached` and `generation_at_receipt` unavailable ("no open attempt"); **`generation_fresh` observed `…1d02b337…` — the exited attempt's id still in the registry at the menu**; hero again `4fc9396e…` 0/0 valid suit; `set_outfit_available true`; epoch 5/5; `contract_started_seen` and `contract_ended_seen` both `…1d02b337…`; `precondition_ok false` (`expected_generation_missing, receipt_generation_missing, cached_generation_missing, mission_not_playing, scene_type_not_mission, …`). `disarm`. Capture `r4a`. |
| 03:39:50.008 (R4b) | HITMAN quit from the menu: telemetry connection `peer_closed` and command link `peer_closed` in the same millisecond (r=13 `connection.closed`; journal `link.closed`); native log ends at the last command line (process exit, as always); authority already disarmed, nothing in flight; status link nil, trust all `:none`; no mission stop derived from the close (attempt 2 stopped at #9). Explicit `disarm` ok, journaled. Final capture; second capture equal (state, report text, command status). |
| 03:42:16 | Cleanup (8.7 s): `init.stop` → recorder `closed (shutdown); boundary r=13`, `CLOSED`, `sha256.txt` OK; journal `journal.closed` seq 35; launcher and watcher exited; DLL removed; `GlacierRelay.ini` removed (after-run bytes identical to the installed bytes); `mods.ini` restored byte-identical (`b90b4c5e…`); listing identical (107), hashes identical, M0 26/26; 4747/4748/4749 free on WSL and Windows; no BEAM, HITMAN or probe process. |

### 23.4 Verdicts

| | Verdict | Evidence basis |
|---|---|---|
| A. C-1 binary and source provenance | **PASS** | 23.1: frozen commits, tags, DLL hash identical in the three places, raw symbol diff exactly the three names, one detour, no setter call site. |
| B. Handshake and default-disarmed behaviour | **PASS** | welcome with both entries 31 ms after link creation; disarmed at start and after every step; the disarmed inspection refused locally and journaled, nothing transmitted. |
| C. Menu inspection without invented state | **PASS (with findings)** | 9 fields reported unavailable with their reasons, none defaulted; the hero resolved at the menu with a real kit `4fc9396e…` — a finding, not an invention; the registry id reported empty before any mission and, after the exit, the exited attempt's id. |
| D. Stable Paris hero outfit tuple readable | **PASS** | `874c4c48…` / 0 / 0, 1 charset, 1 HeroA variation, HeroA valid, suit — on three inspections across two attempts. |
| E. Hero outfit id agrees with observed disguise telemetry | **PASS** | equals `contract.started.starting_disguise_repository_id` and `disguise.equipped (initial)` of both attempts (`874c4c48-0a8b-49e9-883e-49fc5f1fb051`). |
| F. Candidate kit resolution and HeroA validity | **PASS** | found by the bounded byte scan on every mission inspection (153 kits scanned — the map's population under Paris), 1 charset, 1 HeroA variation, usable, suit. |
| G. Setter availability through `Exists()` without invocation | **PASS** | `set_outfit_available true` on all five inspections; 0 call sites by source; no engine write. |
| H. Fresh, cached and at-receipt generation observations | **PASS (with findings)** | the three kept apart and equal during stable attempts; absent/unavailable at the first menu; after the exit the fresh registry value persists while the cached and at-receipt values are absent — the fresh value alone is not an "attempt active" signal (23.6). |
| I. Transition epoch and hypothetical precondition across the restart | **PASS; the two narrow-window inspections INCONCLUSIVE (not attempted)** | the epoch advanced on exactly the documented observations (rise 1, contract end 2, fall 3, rise 4, fall 5), the contract end preceding the fall by 0.97 s as in M5-B; the evaluator held on stable frames and failed with explicit reasons at both menus; an inspection inside the first second after a rise and one inside the contract-end-to-fall window were not attempted (operator timing, by the authorization's rule), so the live `stable_*` and race reasons rest on the offline gate only. |
| J. Engine reads on the frame thread without fault or mutation | **PASS** | every `command: … applied` line and `reads_on_frame true` on thread 46608 (the thread of every scene, telemetry-seen and publish line); network thread 14160 logged only link lines; 0 WARN/ERROR/FAULT in 116 native lines; no write by source. |
| K. Native/BEAM/recorder envelope reconciliation | **PASS** | 10 = 10 = 10, 0 field mismatches, native `dropped 0`, no new event type; the five inspections produced no envelope. |
| L. Fresh-node replay and command-journal consistency | **PASS** | six comparisons hold, finalization clean, recorder authoritative; journal 35 entries contiguous and monotonic, 0 anomalies, 0 unknown, 0 audit failures, every stage correlated to its id and generation 1. |
| M. Stable game operation and full M0 restoration | **PASS** | load, restart, exit and quit without instability; listing and hashes identical, M0 26/26, `mods.ini` byte-identical, both relay files removed, ports free, no leftover process. |

### 23.5 Safety, thread and schema checks

Threads: 46608 carried module attach, `Init`, `OnEngineInitialized`, all 28 `telemetry seen` (detour), all scene / mission-playing / published / `tcp sink: queued` lines, all five `command: … applied` lines and all five epoch lines; 14160 only the `command link:` lines (connected, welcomed, received ×5); 45812 only `tcp sink: sent`. The inspector ran inside the frame dispatch (`reads_on_frame true` on every result). No engine write, no `SetOutfit` call, one detour, no listener, no pointer or address in any result (every text field is an id or a reason), bounded scan (153 entries, under the 4,096 bound). Result lines: five, all accepted by BEAM's strict decoder, re-encoded sizes ≈2,253 / 2,681 / 2,720 / 2,720 / 2,345 B against the 4,096-byte bound; no reduction (`observed_reduced` absent, scheduler `reduced` would have logged); every field a valid status object; the journal's terminal entries equal the BEAM-parsed results; ladder and journal correlate to the command ids on link generation 1.

### 23.6 Findings for C-2 design

1. **The registry session id persists past the attempt.** At the menu after the exit, `generation_fresh` still read `…1d02b337…` while `generation_cached` was absent and the predicate false. Before any mission it was empty. The fresh value is a comparator against the expected and cached values, never a signal that an attempt is active; the precondition's conjunction with the predicate and the cached generation is what refused it (it did).
2. **The hero resolves at the main menu** (`4fc9396e…`, a suit kit with one HeroA variation). A C-2 precondition must not take "hero resolved" as "in a mission".
3. **The restart race recurred exactly** (contract end 0.97 s before the fall, the next id on the fall-edge frame), and the epoch advanced at the contract end — the signal C-2 needs — but no inspection landed inside the window; the race reasons were shown live only through the telemetry and epoch logs, and through the probe offline.
4. **The kit map holds 153 entries under Paris** and the suit was found by the bounded scan every time; the setter resolves on this build.
5. The two narrow-window inspections remain the open live observations (I).

### 23.7 Performance

| Measure | Value |
|---|---|
| Command link created → connected → welcomed | 12 ms, +19 ms (31 ms); BEAM `link.connected` → `peer.identified` 13 ms |
| Inspection issue → applied (BEAM monotonic, incl. the 25 ms poll) | 55 / 57 / 53 / 55 / 53 ms |
| Native receipt → scheduled frame (native monotonic) | 2 / 2 / 6 / 3 / 0 ms |
| Native log received → applied | 3 / 3 / 6 / 3 / 0 ms |
| Time inside the frame-local reads | not instrumented (bounded by the receipt→applied figures above, which include it) |
| Kit-map scan | 153 entries per candidate inspection (3 inspections); no scan without a candidate |
| Result serialization | ≈2.3–2.7 KB per inspection; no reduction |
| Journal write/sync latency | not exposed (not available) |
| Telemetry ingestion (native publish → BEAM receipt) | 1.46–20.97 ms, median 1.87 ms (M5-B: 1.58 median) |
| Recorder | 11 flushes, write max 130 µs, sync max 4,337 µs, mailbox max 0, errors 0 |
| Frames | 8,191 at 03:32:53 → 48,420 at 03:39:28 (≈ 100 fps average across menu, loading and mission) |
| Native | 116 INFO lines, 0 WARN / ERROR / FAULT; no instability |

### 23.8 Evidence and preservation

`c1-run1\` (228 files, `sha256.txt`): `preflight.txt`, `imports.txt`, `import-symbols.txt`, `imports-symbol-diff-vs-m5b.txt`, retail listings and hashes before/installed/after, `installed.sha256`, `glacierrelay.ini.installed/after-run`, `mods.ini.before/relay/after-run`, `beam.log`, `watch-native.out`, native log `relay-20261014-033143-46604.log` (116 lines, `dc526c149cc6d31cde267fadd1d2373db474d244af6fa1727f1aa900ad6de7ad`), captures `r1`/`r2`/`r3`/`r4a`/`final`/`final2`, `r*-check.txt`, `operator-actions.log`, every inspection's `*-command-record.txt` and `*-observed.json`, `inspection-summary.txt`, `recording-13c12d60-…` (closed), `journal-86f8a2d7-….ndjson`, `beam-events.ndjson`, `native-beam-recorder-compare.txt`, `compare-replay.out`, `timing-and-performance.txt`, `cleanup.out`, the tooling, `tooling-dry-run\`. The C-1 DLL stays the build of record in `c1-offline\` (ran once; removed from the game); M5-B DLL, accepted M2 DLL, the committed M4 recording and the earlier evidence directories unchanged. Game at M0.

### 23.9 Limitations

Single build (HITMAN 3.280.0.0, SDK 4.1.1) and single run; the thread relationship is an observation, not a guarantee. The narrow-window inspections (first second after a rise; contract end to fall) were not attempted. Journal write latencies and the time inside the reads are not instrumented. The hero-at-menu finding and the persisting registry id are observations of this build's frontend, not engine documentation. Nothing in this run establishes that an effectful command is safe: it establishes what the engine exposes to a frame-local observer, as the authorization states.

**Stop here. One controlled inert C-1 experiment done, restored and recorded; no effectful command, no native change, no rebuild, no token, no detour; C-2 and C-3 not started; M5 not complete.**

---

## 24. M5 C-1 runtime acceptance record (2026-10-14; the section 23 experiment accepted for its demonstrated scope; M5 not complete)

Authorized by "C-1 Runtime Acceptance and C-2 Design Authorization". The controlled C-1 HITMAN experiment of section 23 is **accepted for its demonstrated scope**. Nothing was rebuilt or installed for this record; the checkpoint was re-verified first: glacier-relay `main` `555df5413af0966b210b578907f215056649ae7d` = origin, clean; ZHMModSDK `relay/m2` `c1bfe0c502675b6f47bc32ff59c01957ce5991b6` = origin, clean; the five glacier-relay research tags unchanged (`m0` → `2d675792…`, `m1` → `53d43461…`, `m2` → `135d6da3…`, `m3` → `54bcc4f2…`, `m4` → `491ef141…`); C-1 DLL `7fecf31ad477891ddaac62c935cbde7df99100a8935fcc6bf7add02b7783e639` (`c1-offline\`), M5-B DLL `15dd58e3…` (`m5b-offline\`) and the accepted M2 observer DLL `6047a9a3278fdd725c55bdc16ac47f832436afb2f5a6f2260488a436a6009d65` (`b6-accepted-artifacts\`) preserved with their recorded hashes; `c1-run1\` 228/228 and `c1-offline\` 5/5 verify; game at M0 26/26, no relay file under `mods/`, `mods.ini` `b90b4c5e…`, no HITMAN or relay process, 4747–4749 free on WSL and Windows.

### 24.1 Demonstrated facts (what the acceptance rests on; each from section 23's evidence)

1. **Five live inspections** (`a52dc353`, `cb9e8d6d`, `05fab718`, `c1f65faa`, `a6e7b8d9`) reached `applied` on frames 8191, 18066, 38743, 40012 and 48420, 53–57 ms after issue and 0–6 ms after native receipt.
2. **Frame-thread execution**: every inspection's reads and emit on thread 46608, the thread of the detour, the frame update and every publish line; the network thread 14160 carried only link lines.
3. **The current hero outfit id equals the initial disguise telemetry**: `hero_outfit_id 874c4c48-0a8b-49e9-883e-49fc5f1fb051` on all three mission inspections = `contract.started.starting_disguise_repository_id` = `disguise.equipped (initial)` of both attempts.
4. **A HeroA-compatible current kit, charset 0 and variation 0**: one charset, one HeroA variation, `hero_heroa_valid true`, `hero_suit true`, on all three mission inspections.
5. **A bounded kit-map scan of 153 entries** found the candidate on each of the three candidate inspections (`candidate_found true`, `candidate_heroa_usable true`, `candidate_suit true`, `kits_scanned 153`, under the 4,096 bound).
6. **`ZHitman5_SetOutfit` available on this build**: `set_outfit_available true` on all five inspections, through `Exists()` only; 0 call sites by source.
7. **Stable mission-generation comparisons**: `generation_expected` = `generation_at_receipt` = `generation_cached` = `generation_fresh` on the three mission inspections (`…5fd4f3e1…`, then `…1d02b337…` twice); absent or unavailable, with reasons, at both menus.
8. **The transition epoch advanced on the restart evidence**: 1 at the first rise, 2 at the contract end for the active generation (0.97 s before the fall), 3 at the fall, 4 at the second rise, 5 at the exit's fall; the hypothetical precondition true on stable frames and false with explicit reasons at both menus.
9. **10 / 10 / 10 matching semantic envelopes** (native log = BEAM = recorder, 0 field mismatches, native `dropped 0`); the inspections produced no envelope.
10. **Six successful replay comparisons** on a fresh node (instances, unidentified, summary, report term-equal; summary and report texts byte-identical), finalization clean, recorder authoritative.
11. **35 contiguous command-journal entries**, monotonic, 0 anomalies, 0 unknown, 0 audit failures, every stage correlated to its id on link generation 1.
12. **Zero native warnings, errors or faults** in 116 native lines across load, restart, exit and quit.
13. **M0 restoration**: 26/26 hashes, listing (107) and hashes identical, `mods.ini` byte-identical, both relay files removed, ports free, no leftover process.

### 24.2 Findings preserved (not weakened by the acceptance)

- **The hero resolves at the main menu** (`4fc9396e-2619-4e66-a51e-2bd366230da7`, a kit with `hero_suit true`, one charset, one HeroA variation), on both menu inspections. Hero resolution is not evidence of a mission.
- **The registry session id persists after mission exit**: at the menu after the exit `generation_fresh` still read `…1d02b337…` while the cached and at-receipt generations were absent. The fresh value is a comparator only; the precondition's conjunction with the predicate and the cached generation refused that frame.
- The restart race recurred exactly (contract end 0.97 s before the fall; the next attempt's id on the fall-edge frame).

### 24.3 Not performed (recorded as such, not as validated)

- An inspection inside the first second after a rise (the `stable_interval_too_short` / `stable_frames_too_few` reasons live).
- An inspection inside the contract-end-to-fall window (the `contract_end_observed` / `epoch_changed` / `generation_mismatch_*` reasons live).

Both reasons families rest on the offline gate and the probe's scripted restart only. They are **not validated** by this acceptance and remain open items for a later inert run (section 25's prerequisite run can carry them).

### 24.4 Scope of the acceptance

Accepted: that the frozen C-1 build can be hosted by the real game for one session without fault; that a frame-local observer can read the hero's outfit tuple, resolve a kit by id in the engine's map, read the setter's availability and compare the three generations on the applying frame; that the Relay transition epoch moves on the documented observations; and that the inert ladder, journal, telemetry invariance and restoration hold. Not accepted and not claimed: that any engine mutation is safe, that the setter emits any telemetry, that a kit other than the Paris starting suit is resolvable under Paris, or anything about another build, route or location. The C-1 DLL remains a build of record; the accepted native artifact remains the M2 DLL `6047a9a3…`.

---

## 25. M5 C-2 design record (pointer)

The effectful `player.outfit.set` design — target selection, the mandatory apply gate and transition-race analysis, the native apply and tuple-restoration contract, the trust basis, the observation and ambiguous-outcome semantics, the failure containment, the stages C-2A / C-2B / C-2C / C-3, the gates and the first runtime proposal — is `docs/design/M5C2_EFFECTFUL_OUTFIT_DESIGN.md` (design and read-only source investigation; nothing implemented). Its outcome: a second suit kit cannot be established from source; target discovery is an inert prerequisite (C-1b, no code change); the reserved v1 wire schema cannot carry the prior tuple and must be revised before implementation; the smallest safe next implementation authorization is C-2A (BEAM-only, offline).

**Stop here. C-1 accepted for its scope; C-2 designed, not implemented; no native or BEAM runtime change, no token, no detour, no rebuild, no game; C-2A/B/C and C-3 not started; M5 not complete.**

---

## 26. C-2A design reconciliation: three decisions (2026-10-14; before implementation; ADR 0009's isolation and default-disabled principles preserved)

Authorized by "C-2 Design Acceptance and C-2A Offline Authorization", which accepts the section 25 design as the architectural baseline subject to refinements and asks for three decisions to be documented and committed before any code. Checkpoint re-verified: glacier-relay `main` `c06bc4cae05b63bc690acd3e31f646bb190c8a83` = origin, clean; ZHMModSDK `relay/m2` `c1bfe0c502675b6f47bc32ff59c01957ce5991b6` = origin, clean; tags unchanged; C-1 DLL `7fecf31a…`, M5-B DLL `15dd58e3…`, accepted M2 DLL `6047a9a3…` as recorded; `c1-run1` 228/228; M0 26/26; no relay file, process or port.

### 26.1 Telemetry corroboration without crossing the command/observer boundary

**Decision:** the command authority never reads the observer. Corroboration is an **operator-supplied attestation** — a bounded structure the operator (or the run tooling acting for the operator, out of band, by reading `MissionSession.state/0` over RPC exactly as the run tooling already does) hands to `GlacierRelay.Command.attest_telemetry/1`: `{adapter_instance_id (uuid), observed_at (ISO-8601 text), basis (bounded text naming where it was read), evidence_ref (bounded text, e.g. the capture file or envelope sequence), max_age_ms (bounded integer)}`. The authority validates the schema, that the adapter id equals the current link's hello id (the hello is the claim being corroborated; the attestation is the second, independently sourced statement), and freshness — the attestation is usable for effectful arming only within `max_age_ms` of its receipt on the authority's monotonic clock and only for the link generation it was received on. The journal records `operator.telemetry_attested` with the evidence reference and the conclusion (`matches_link_identity` true/false). The attestation is labelled **operator-provided corroboration**, never an observation the authority made; it is never derived from the command peer's own hello or result. Consequence: no new remote call from any `GlacierRelay.Command.*` module into `MissionSession`, `Wire`, `Recording`, `Replay` or `Dashboard` (the compiled-import boundary test stays as it is), and the observer gains no reference to the command path. If the operator cannot supply a fresh attestation, effectful arming is refused with `:telemetry_corroboration_missing` (or `_stale`), and that refusal is the reported blocker — the boundary is not changed to obtain corroboration.

The same rule covers engine-consistent telemetry after an effect (design section 8): the correlation rule is a **pure function** in the command namespace over plain maps (`GlacierRelay.Command.Correlation.consistent?/2`), applied by the operator tooling to an envelope it fetched from the observer side, and recorded through an operator observation of type `engine_consistent` carrying the envelope's identifying fields; the authority performs no correlation on its own and never reads an envelope.

### 26.2 Protocol v1/v2 interoperability and downgrade

**Decision: explicit v1 compatibility restricted to inert commands.** The peer's hello chooses the version (1 or 2); the authority records it on the link for the link's life.

- **v1 hello** (the frozen C-1 native, `c1bfe0c5`): the welcome is the v1 line exactly as today (no nonce, no new field; the C-1 decoder's strict key set is honoured), the link is `identified`, its `protocol_version` is 1, `token_verified` is false and cannot become true (no attest exists in v1; an `attest` line on a v1 link is a protocol violation and closes the link), and the welcome's allowlist is the inert issuable set only. An effectful entry is never advertised to a v1 peer and never issuable on a v1 link, whatever the arming state.
- **v2 hello**: the welcome is v2 with a fresh 16-byte random `nonce` (hex) and `attest_required: true`; the allowlist lists the inert entries plus `player.outfit.set` v2 **only when** the authority's `effectful` configuration is on (default off) **and** the hello's capabilities include `player.outfit.set/2`. The peer must answer with one `attest` whose MAC is HMAC-SHA256 over `nonce ‖ link_generation ‖ adapter_instance_id` with the run token; the authority verifies with a constant-time comparison. Success → `token_verified` (journal `peer.token_verified`); any failure (no token configured on BEAM, wrong MAC, wrong generation, wrong adapter id, a second attest, an attest before the hello or on a v1 link) → journal `peer.attest_failed` and the link closes as a protocol violation. **No fallback**: a link that failed attestation is closed, not demoted to v1; a reconnecting peer starts a new generation, chooses its version again in its hello, and a v1 hello there is an explicit inert-only link, not a downgrade of the failed v2 link. Once a link negotiated a version, every later line must carry that version; a different version is a violation (`version_mismatch`) — a v2 link cannot be walked down to v1 by sending v1 lines, and a v1 link cannot be walked up.
- The command and result line shapes are unchanged between versions; only the version field differs (BEAM encodes commands with the link's negotiated version). The reserved `player.outfit.set` **v1** stays exactly as published, non-issuable against every peer; the complete-tuple entry is **v2** (the authorization's preference; nothing published changes silently).

### 26.3 Reversal construction from verified, durable command evidence

**Decision:** the reversal planner (`GlacierRelay.Command.Reversal.plan/3`) derives the prior tuple from the **journal file**, never from the authority's in-memory record alone. It reads and verifies the journal (`Command.Journal.read/1`: every line parses, one `journal_id`, `seq` contiguous from 1, the header first), locates for the command id the `command.accepted` (name `player.outfit.set`, version 2, the params with the original `expect_current` tuple, the `mission_generation` precondition, the link generation), `command.transmitted`, `command.received` and exactly one `command.terminal`, and the `peer.identified` entry of that link generation for the adapter identity. It establishes: the original command id, the adapter identity, the link generation, the mission generation, the original expected-current tuple, the reported previous and current tuples (all six fields `observed`), the applied/effect classification (`status applied`, `effect changed`; `unchanged` is nothing to reverse, `uncertain` needs a journaled later-frame read-back observation for the same id before planning is allowed), audit continuity (the four stage entries in order; no `command.unknown` for the id; when the in-memory record is supplied it must be `audit: :intact` and agree with the journal on status, result and generation — any disagreement fails closed), and any unknown or ambiguous stage. A missing, degraded (journal status not `:open`, or the authority's audit degraded), conflicting (two terminals, a refinement contradicting a terminal) or unaudited terminal fails closed with a named reason. The plan carries `expect_current = the reported current tuple` and the target `= the reported previous tuple`; issuing it (`Command.reverse/2`) additionally requires the operator to supply a **fresh** confirmed current tuple (from an inspection just made) equal to the plan's `expect_current` and the live expected mission generation equal to the plan's — the journal proves what was reported then, never the game state now. No automatic reversal exists; the planner performs no native command.

**Stop point for this reconciliation commit:** nothing implemented yet; C-2A implementation follows in its own commits under the same authorization.

---

## 27. M5 C-2A — BEAM effectful authorization and trust model: implementation and offline validation record (2026-10-14; BEAM only; fake peers; nothing native; no DLL; no game; `player.outfit.set` non-issuable against every real native build; M5 not complete)

Authorized by "C-2 Design Acceptance and C-2A Offline Authorization" after the section 26 reconciliation (`117cd1d`). Implementation commit: **`4be5cbaf4c53c52973fe96f70da6a994996ce217`** on glacier-relay `main`; ZHMModSDK unchanged at `c1bfe0c5` (0 modified files, verified before and after the gate). Evidence `%TEMP%\glacier-m0\hitmen\c2a-offline\`.

### 27.1 What was built (`relay/`)

| Area | Change |
|---|---|
| `Command.Schema` | protocol versions 1 and 2 accepted at decode (the line's version travels with every decoded message); the `attest` kind (version 2 only: `link_generation`, `adapter_instance_id`, `mac` as 64 lowercase hex); the version-2 welcome (`nonce` 16 random bytes as hex, `attest_required: true`, the per-peer allowlist); the version-1 welcome unchanged byte for byte; `issuable/0` (inert entries, unchanged) and `issuable_for/3` (an `:effectful` entry only for a version-2 peer that advertised `name/version` while the effectful configuration is on); `attest_mac/4` (HMAC-SHA256 over `nonce\|link_generation\|adapter_instance_id`, the single definition shared by the verifier and the fake peer) and `mac_equal?/2` (`:crypto.hash_equals/2` over decoded bytes); the `player.outfit.set` **v2** entry (`disguise_repository_id` uuid, `charset` 0..15, `variation` 0..63, `expect_current` a required object of the same three, `preconditions [:mission_generation]`, `trust :token_verified`, `issuable :effectful`); **v1 kept exactly as published**, `issuable: false`, `trust :authenticated`; parameter types `{:integer, min, max}` and `{:object, spec}` with exact validation; `nonapplication_statuses/0`; `observed_value/1` and `observed_tuple/2` over read-back field objects. |
| `Command.Link` | the negotiated version pinned per link; an `attest` only on a version-2 link after its hello, handed to the authority, whose refusal is a protocol violation (`attest_failed`) that closes the link; `attest_on_version_1_link`, `attest_before_handshake`, `version_mismatch` violations. |
| `Command.Authority` | link state `protocol_version`, `nonce`, `token_verified`, `attest_attempts`, `advertised`; the run token from `:token` (tests; ephemeral) or `:token_file` (64 lowercase hex, read once, never logged; anything else leaves no token); `peer_attest/2` (one attest per link; generation and adapter binding; constant-time MAC check; `peer.token_verified` journaled with the nonce and generation, never the MAC or token; every failure `peer.attest_failed` with its reason and the link closed, no fallback); `attest_telemetry/1` (section 26.1: schema, adapter identity against the link's hello, freshness; `operator.telemetry_attested` with the conclusion; cleared on link loss); `arm_effectful/1` (requires the effectful configuration, a token, a token-verified version-2 link, an open journal, an intact audit, nothing in flight, a fresh matching attestation, operator ownership evidence with its schema, freshness, `validation == "exactly_one_hitman"` and `connections == 1`, a TTL in 1,000..120,000 ms; journaled `authority.armed_effectful` with the evidence labelled operator-provided before arming); one-shot consumption journaled (`authority.effectful_consumed`) **before** `command.accepted`, with a journal failure refusing the command and leaving the arming consumed; expiry (`authority.effectful_expired`); revocation by disarm, link loss and audit degradation; the effectful issuance rules of the module doc (v1 never issuable; `:effectful` requires the configuration, version 2, `token_verified`, the entry advertised to this peer, an unexpired unconsumed arming for this link, the `mission_generation` precondition; `same_as_current` refused); inert arming unchanged and never implying effectful arming; effect classification from the read-back (`invocation` reported / not_called / not_reported; `effect` changed / unchanged / uncertain / none / unreported; `read_back` native_same_frame / none), `consequences: :unknown` always, `restored` for a reversal (native_same_frame / not_restored / unreported); `observe/4` (types `visual_confirmation`, `visual_no_change`, `later_frame_read_back` with an applied inspection compared on tuple, generation and frame, `engine_consistent` through the pure rule, `note`; bounded text; journaled first, attached only after the append succeeded; labelled testimony); the late-result refinement (`command.unknown_refined` for a non-application terminal with the exact command, link and adapter identity; `anomaly.conflicting_refinement` and `anomaly.duplicate_refinement`; `late_applied_claim` on a late `applied`; the status stays `unknown`); status gains `protocol_version`, `token_verified`, `effectful_armed`, an `effectful` block and `advertised`. |
| `Command.Journal` | `read/1`: parse every line, require the header first, one version, one `journal_id`, contiguous `seq`; a partial last line is `{:unreadable_line, n}`. |
| `Command.Reversal` (new) | `plan/3` (section 26.3): from the verified journal only — the four stage entries in order, exactly one terminal, no unknown or refinement, `applied`, both tuples observed, `effect changed` (uncertain only with a journaled consistent later-frame read-back; unchanged is nothing to reverse), the adapter identity from `peer.identified` of the command's link generation, the journal and audit not degraded, the in-memory record cross-checked when supplied; the plan's target is the reported previous tuple and its `expect_current` the reported current tuple, with `requires` and `consequences: :unknown`. |
| `Command.Correlation` (new) | `check/3`: the pure engine-consistent rule (adapter, event type, kind change, target id, contract session id, after the result within the window, above a sequence floor); verdict wording "consistent with the command; causality not established". |
| `Command` facade | `attest_telemetry/1`, `arm_effectful/1`, `set_outfit/2`, `plan_reversal/1`, `reverse/2` (fresh `confirmed_current` equal to the plan's `expect_current` and the live `expected_generation` equal to the plan's, then an ordinary issuance with `reversal_of`), `observe/4`; no browser path, no route. |
| Configuration | `:command` gains `effectful: false`, `token_file: nil`, `effectful_ttl_default_ms`, `effectful_ttl_max_ms`, `evidence_max_age_ms`; `runtime.exs` reads `GLACIER_RELAY_COMMAND_EFFECTFUL` and `GLACIER_RELAY_COMMAND_TOKEN_FILE`; nothing writes a token or a game file. |
| Fake peer | `test/support/fake_native.ex`: version-2 hello, `attest/4`, `handshake_v2/3`, field objects and a fake apply read-back; still never evidence of native execution. |
| Tests | `effectful_test.exs` (14), `reversal_test.exs` (4, pure over journal files written by the test), `correlation_test.exs` (3); `schema_test.exs` and `authority_test.exs` updated for the version field and the extended trust map; `boundary_test.exs` adds `Command.Reversal` and `Command.Correlation` to the modules the web and dashboard may never call. |

### 27.2 Protocol and trust model as implemented

Version 1 (the frozen C-1 native): hello → the unchanged welcome → inert commands; `token_verified` unreachable; an effectful entry never advertised or issuable (`:peer_protocol_version_1`). Version 2: hello → welcome with a fresh nonce → exactly one `attest`; verified → `token_verified` ("possession of the run token shown over this link; not process identity; not authenticated"); failed (wrong MAC, reused nonce, wrong generation, wrong identity, second attest, replay on a new link, attest on a version-1 link or before any hello, no token on BEAM) → `peer.attest_failed`, the link closed, no fallback; a reconnect is a new generation with a new nonce and chooses its version again; a line of the other version on a pinned link closes it. `authenticated` stays reserved and false everywhere. Effectful arming is distinct from inert arming, one-shot, bounded, journaled with the operator's corroboration and ownership evidence, consumed before acceptance, expired by its TTL, revoked by disarm, link loss or audit degradation, never persisted.

### 27.3 Compatibility policy

Explicit version-1 compatibility restricted to inert commands (section 26.2). No implicit fallback from version 2 to version 1 after a failed attestation: the failed link is closed; a version-1 reconnect is an explicitly inert-only link.

### 27.4 Status, effect and reversal semantics

Status ladder unchanged. An effectful record carries `effect` (invocation, effect, read_back, read_back_later, engine_consistent, operator), `consequences: :unknown`, `restored`, `reversal_of`, `operator_observations`, `refinement`, `late_applied_claim`; the terminal journal entry carries the same classification. Every value from a fake peer is fake-native evidence; `observed` is `:native` or `:none` and `independent_observation` stays `:not_available`; nothing peer-reported is promoted to observed game state. The reversal planner is pure over the journal file; `reverse/2` performs an ordinary issuance only with a fresh confirmation, the live generation and its own arming; nothing reverses automatically.

### 27.5 Offline gate (`c2a-offline\validate-c2a.sh`, `validate.log`)

- Compile (dev and test) with warnings as errors: ok. Format check on the 17 changed files: ok. The accepted M4 recording and the committed recordings and snapshots unchanged.
- Fresh-VM fake-peer transcript (`fresh-vm-c2a.exs`, `fresh-vm-c2a.txt`, `journal-fresh-vm.ndjson`): the command subtree alone with an ephemeral in-memory token; a version-1 peer (welcome keys exactly the C-1 five, inert-only, `arm_effectful` refused `:peer_protocol_version_1`); a version-2 peer attested (`token_verified`, the effectful entry advertised); `set_outfit` refused before arming; attestation, ownership evidence, arming; the same-kit refusal; the v2 command on the wire with the complete tuple and the precondition; the fake `applied` read-back classified `changed` / `native_same_frame`, consequences unknown; three operator observations (visual, later-frame consistent, engine-consistent); the reversal planned from the journal, refused without confirmation and without arming, then issued and reported `restored native_same_frame`; an unknown refined by a late `expired`; a 40-entry journal that does not contain the token.
- Five consecutive full Elixir runs: 504 tests, 0 failures on every run (seeds 806603, 926549, 951847, 618169, 35014; `mix5.txt`); the command directory alone 64 tests, 0 failures.
- Leftovers: no BEAM, ports 4747–4749 free; native tree `c1bfe0c5` with 0 modified files; the DLL hashes of record unchanged; no relay file under `mods/`; M0 26/26; no token file anywhere under the evidence tree.

### 27.6 Regression requirements (authorization section 11)

Warnings as errors (1), formatting (2), five runs (3), every M3, M4, M5-A, M5-B and C-1 test retained (4–5; the suite grew from 483 to 504 with 21 new tests and no deletion), headless supervision unchanged with the feature off (6; `headless_test.exs` unchanged and green), no Phoenix command route (7; `boundary_test.exs`), no observer→command and no command→observer-internal call (8–9; the compiled-import boundary test, extended with the two new modules), format-1 recordings unchanged (10), journal durability and degradation tests (11; `audit_hardening_test.exs` unchanged plus the two stub-writer tests of `effectful_test.exs`), every protocol v2 field and trust transition tested (12), no native change (13), no DLL (14), no HITMAN (15), no game configuration or real credential written (16; the only tokens are ephemeral test values inside the test VM and the fresh-VM transcript's in-memory random token).

### 27.7 Limitations

Fake peers only: nothing here shows that a real HITMAN process is authenticated or that an outfit command can execute safely. The native side has no version-2 handshake, no attest and no effectful entry (C-2B). The telemetry attestation and the ownership evidence are operator statements validated for shape, identity and freshness, not verified by the authority. The later-frame read-back is a comparison of two native read-backs. The engine-consistent observation is the operator's application of a pure rule to an envelope the authority never saw. The planner reads the live journal file while the journal writes; a partial last line fails closed and the operator retries. `authenticated` remains unreachable by design.

**Stop here. C-2A implemented and validated offline; C-2B, C-2C, C-1b and C-3 not started; no native change, no DLL, no game, no real token; M5 not complete.**

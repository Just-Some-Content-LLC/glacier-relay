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

# Hitmen — Runtime Probe: Observability, Debugger Workflow and First-Load Procedure

Date: 2026-10-06

**Status: first runtime load executed 2026-10-06 and passed (R1 to R4).** Results, findings and the predicted-versus-observed comparison are in `HITMEN_COMPILE_ARCHAEOLOGY.md`, experiment 4. The game directory was restored afterwards. **No further runtime experiment is authorized**; the next step is a decision made from that evidence.

The text below is the plan as written before the run and is kept unchanged as the record of what was approved. Where the run contradicted it, experiment 4 says so. In particular: `OnEngineInitialized` came after the first `OnLoadScene`, a mission restart did not call `LoadScene`, `m_PlayerData` is not a `TArray` on this build, the loading-stage offset is real, and no shutdown line is ever written because the game terminates its own process.

Artifact this document describes:

| Item | Value |
|---|---|
| Source | `Just-Some-Content-LLC/ZHMModSDK` `research/hitmen-revival` at `e748cdde` |
| Binary | `ZHMModSDK\_build\hitmen-x64-Debug\Mods\Hitmen\Hitmen.dll` (Debug, `/MTd`) |
| SHA-256 | `4a2176be9089889ab665ba1ec107a848c0b8a8c1f3d2a77dffb77af781d0a669` |
| Symbols | `Hitmen.pdb` beside the DLL; the DLL embeds that absolute path |
| Game | HITMAN WOA `3.280.0.0`, Steam, with the M0 SDK install (`M0_BASELINE.md`) |

What the DLL does and does not do is listed in `HITMEN_COMPILE_ARCHAEOLOGY.md` ("What the dormant build still does"). In short: two log-and-continue scene detours, one per-frame update that only reads, a null transport, no sync code.

## How this serves the roadmap

The roadmap is unchanged. Hitmen is enabling research for the existing M1 ("First semantic event": Glacier → native adapter → wire → BEAM), not a milestone of its own.

- The probe exercises the **Glacier-facing half** of that path on the current game: which hooks fire, when a scene and the local player become readable, and whether the reverse-engineered layouts still hold.
- The log lines below are deliberately shaped like candidate semantic events (scene load requested, scene state changed, local player resolved, position sample). After a successful first load, the scene-lifecycle observation is the natural candidate for M1's one versioned event.
- `IHitmenTransport` is where a future native-adapter → BEAM boundary would attach. It stays null in this phase. M1's exit criterion is not met by anything here.

## Durable log

### Why a separate log

`ZHMModLoader.log` loses everything after early startup (M0 finding F3), and SDK crash reporting does not work on this game build (M0 finding F2). The probe therefore keeps its own log, independent of the SDK logger and of the in-game UI.

### Location and properties

```
%LOCALAPPDATA%\GlacierRelay\Hitmen\hitmen-<YYYYMMDD-HHMMSS>-<pid>.log
```

- One file per game process, named from the process start time (UTC) and pid. Falls back to `%TEMP%` if `LOCALAPPDATA` is unset.
- **Outside the game directory.** The probe writes nothing under the game folder.
- Each line is one unbuffered `WriteFile` in append mode, so a line is with the OS as soon as the call returns and survives a crash of the game process. (It is not flushed to disk per line, so an OS crash or power loss can still lose the tail.)
- Each line also goes to `OutputDebugString`, prefixed `[Hitmen]`, for an attached debugger.
- The file is opened with full sharing, so it can be read while the game runs:

```powershell
Get-Content (Get-ChildItem "$env:LOCALAPPDATA\GlacierRelay\Hitmen\hitmen-*.log" | Sort-Object LastWriteTime | Select-Object -Last 1) -Wait
```

Line format (timestamps are UTC):

```
2026-10-06T19:54:31.112Z INFO  [tid 81048] <message>
```

### What is logged

| Area | Lines | What it establishes |
|---|---|---|
| Module load | `module attached: base …, pid …, path …, built …` | The DLL was mapped; where; which build |
| Module unload | `module detaching: FreeLibrary` / `module detaching: process is terminating` | Unload path taken |
| Plugin object | `plugin constructed: instance …, compiled against SDK 4.1.1 (ABI 1)`; `plugin destructor enter/exit` | The SDK instantiated / destroyed the plugin |
| Hook registration | `Init enter: registering detours on ClearScene hook … and LoadScene hook …`; `Init exit: …` | Detours were **registered** with the SDK |
| Initialization | `OnEngineInitialized enter`; `transport: NullHitmenTransport …`; `OnEngineInitialized exit: frame update registered …` | Engine-ready callback ran; null transport in use |
| Scene callbacks | `OnLoadScene enter: context …, scene '…', type '…', codename hint '…', start game …, N additional bricks`; `OnLoadScene brick: '…'`; `OnLoadScene exit: …`; `OnClearScene enter: … fully unload …, second Hitman was found …`; `OnClearScene exit: …` | The hooks are **live** and what the engine passed |
| Scene state | `scene state: loaded a -> b, loading stage x -> y (unverified offset), scene '…'` | Engine-side outcome of a load, polled each frame, logged on change |
| Local player | `local player not resolved in this scene yet: …` (once per scene); `local player resolved: ZHitman5 …, entity …, ZSpatialEntity …` | `SDK()->GetLocalPlayer()` works on this game build |
| Second Hitman | `loaded bricks: N, hitmen.brick loaded: false` | No second Hitman exists (expected) |
| Player registry | `registry: dump begin (local player resolved \| menu button) …` through `registry: dump end` | `ZPlayerRegistry` layout observations |
| Transform reads | `local transform read: position (x, y, z)` at resolution, then every 5 s | Read path works and tracks movement |
| Faults | `FAULT in <where>: exception 0x…, at … ('module' base …, offset …)[, reading/writing address …]. Not handled here; it continues to propagate.` | An exception left a probe path |
| Failures | `scene state unavailable: …`; `registry: Globals::PlayerRegistry is null …`; `registry: m_PlayerData size is implausible …` | A precondition did not hold |

Notes on interpretation:

- **"Registered" is not "installed".** `AddDetour` returns nothing and a mod cannot see whether the SDK found and patched the engine function. That is recorded only in `ZHMModLoader.log` during SDK startup (in M0: 79 of 80 hooks, `LoadScene` and `ClearScene` among the successes). The proof that a hook is live is the first `OnLoadScene enter` line.
- **"Exit" means the detour returned**, not that the engine function finished. A detour can only see the original's result by calling it and ending the chain for every other mod, which the probe does not do. The engine-side outcome shows up as `scene state` lines.
- **Two `module attached` lines per launch are expected.** The SDK loads every DLL in `Retail\mods` once to read its ABI version and frees it, then loads the enabled ones for real. Expected order: attached, detaching (FreeLibrary), attached, plugin constructed.
- **The fault filter does not keep the game alive.** It writes one line and returns `EXCEPTION_CONTINUE_SEARCH`. Verified outside the game: a null write and a C++ throw inside a guarded call were logged and then reached the outer handler; code after the faulting call did not run. There is no `catch (...)` and no handled SEH anywhere in Hitmen.
- **Shutdown may be only partly visible.** In M0 the SDK's own destructor evidently did not run at game exit. If the game ends with `TerminateProcess`, no destructor or detach line can be written. Which lines appear at exit is one of the things the first run will show.

### Player-registry dump

Runs once per scene when the local player first resolves, and on demand from the SDK menu button "Player registry" (the button also prints the log path to the in-game console). Read-only. It records:

1. `m_PlayerData` (the SDK's current reading of offset `0x390`): size, begin, end, allocation end.
2. For each entry, whether it lies inside the four inline `m_aPlayerData` slots and which one. This answers an open question (is the array a view over the inline slots?).
3. All four inline slots, with the same per-field list the 2023 code printed. The two string fields print `<n chars at ptr, not read>` instead of being dereferenced if their length is implausible.
4. What `SDK()->GetLocalPlayer()` returns, for comparison with the slots' `hitman entity` values.

## Debugger workflow (Visual Studio 2022)

Not yet exercised on this machine. Upstream's wiki warns that debugging "may have issues" on Visual Studio newer than `17.4.5`; this machine has `17.14`. Treat the steps as a plan and record deviations.

### Do not use upstream's F5 flow for this experiment

Upstream's `launch.vs.json` sample starts the game through the target `ZHMModSDK.dll (Install)`, and the `x64-Debug-Install` preset **builds everything and installs it into the game directory** on launch. That would replace the M0-verified SDK files and every mod in `Retail`. Also avoid opening the `ZHMModSDK` folder as a CMake project before the run: Visual Studio configures the default preset automatically, and a build in `_build\x64-Debug` would make the installed `ZHMModSDK.dll` stop matching its PDB.

### Attach (recommended for the first load)

1. Start Visual Studio with **Continue without code**.
2. Start the game through Steam as in M0. Wait for the main menu.
3. **Debug → Attach to Process…** (`Ctrl+Alt+P`). Set **Attach to: Native code** explicitly (not Automatic). Select `HITMAN3.exe`. Attach.
4. Open **Debug → Windows → Modules** and check `Hitmen.dll` (see "Expected module load").
5. Open **Debug → Windows → Exception Settings**, expand **Win32 Exceptions**, and make sure `0xc0000005 Access violation` is ticked so the debugger breaks when one is thrown.
6. Set the breakpoints below, then load a mission.

Attaching at the main menu means the debugger does not see DLL load, the constructor, `Init` or `OnEngineInitialized`. That is acceptable for the first run because the durable log covers exactly that window, and it avoids starting the game in an unusual way.

### Launch under the debugger (optional, covers startup)

Only if the startup window needs a debugger. Based on upstream's sample, which starts `Retail\HITMAN3.exe` directly with the Steam environment variables set and the game root as working directory. From a command prompt:

```
set SteamAppId=1659040
set SteamGameId=1659040
set SteamOverlayGameId=1659040
devenv /debugexe "C:\Program Files (x86)\Steam\steamapps\common\HITMAN 3\Retail\HITMAN3.exe"
```

In the temporary project Visual Studio creates, set **Working Directory** to `C:\Program Files (x86)\Steam\steamapps\common\HITMAN 3` before pressing F5 (the SDK writes `ZHMModLoader.log` to the working directory, and M0 ran with the game root). This builds and installs nothing. Whether the game tolerates being started this way on the current build is **untested**.

### Symbols

| Module | Loaded from | PDB | Notes |
|---|---|---|---|
| `Hitmen.dll` | `Retail\mods\` | `ZHMModSDK\_build\hitmen-x64-Debug\Mods\Hitmen\Hitmen.pdb` | Found automatically through the path embedded in the DLL, as long as the build tree is not rebuilt or moved after the copy. Source paths resolve to `ZHMModSDK\Mods\Hitmen\Src\`. |
| `ZHMModSDK.dll` | `Retail\` (M0 build) | `ZHMModSDK\_build\x64-Debug\ZHMModSDK\ZHMModSDK.pdb` | Present. Do not rebuild `_build\x64-Debug` before the run. |
| `HITMAN3.exe` | `Retail\` | None | Engine frames show as addresses only |

If the Modules window shows "Cannot find or open the PDB file" for `Hitmen.dll`, right-click → **Load Symbols** and point at the PDB above. If it reports a mismatch, the DLL in `Retail\mods` is not the build this document describes: stop and compare SHA-256.

### Expected module load

- `Hitmen.dll`, path `…\HITMAN 3\Retail\mods\Hitmen.dll`, symbols loaded, user code.
- If launched under the debugger, the Output window shows it load, unload, and load again (SDK discovery, then the real load). When attaching at the main menu only the final load is visible.
- No `ws2_32.dll` load is attributable to Hitmen: it does not import it. (Other components may load it; the Editor mod runs a WebSocket server.)

### Useful breakpoints

Add with **Debug → New Breakpoint → Function Breakpoint** (`Ctrl+K, B`). They bind by name when symbols load.

| Function | Why |
|---|---|
| `HitmenLog::LogFault` | **Most useful.** Hit only when an exception is passing through a probe path. The call stack and `p_Info` show the fault before anything unwinds. |
| `Hitmen::OnLoadScene_Internal` | Scene load requested. Inspect `p_SceneData` (`m_SceneResource`, `m_aAdditionalBrickResources`). |
| `Hitmen::OnClearScene_Internal` | Scene teardown, including mission restart. |
| `Hitmen::DumpPlayerRegistry` | Fires once per scene at local-player resolution. Step through to inspect `Globals::PlayerRegistry` live in the Watch window. |
| `NullHitmenTransport::StartServer`, `NullHitmenTransport::Connect` | Tripwires. Should never be hit unless someone uses the "Hitmen" menu. |
| `Hitmen::Hitmen`, `Hitmen::Init`, `Hitmen::OnEngineInitialized` | Only reachable when launched under the debugger |

Do not put a plain breakpoint in `Hitmen::OnFrameUpdate`, `ObserveSceneState` or `ObserveLocalPlayer`: they run every frame. Use a tracepoint or a condition (for example `!m_ObservedLocalPlayer` in `ObserveLocalPlayer`).

Watch expressions that are safe to evaluate while stopped (reads only): `Globals::PlayerRegistry->m_PlayerData`, `Globals::PlayerRegistry->m_aPlayerData[0]`, `*Globals::Hitman5Module->m_pEntitySceneContext`, `m_OurHitman`, `m_OtherHitman`. Do not edit values in the Watch window and do not use "Set Next Statement": both are mutations.

### Failures to watch for

| Symptom | Likely meaning | Where it shows |
|---|---|---|
| No log file at all | DLL never mapped: not in `Retail\mods`, or load failed | `ZHMModLoader.log`: "Failed to load mod. Error: …" or no "Found mod 'Hitmen'" |
| One `module attached` + `detaching`, nothing else | Discovered but not enabled, or marked incompatible (ABI version) | `ZHMModLoader.log`; `mods.ini` lacks `[hitmen]` |
| `plugin constructed` but never `OnEngineInitialized` | Engine-initialized callback did not reach the plugin | Hitmen log |
| No `OnLoadScene enter` when a mission loads | LoadScene hook not live on this game build | Hitmen log; `ZHMModLoader.log` hook lines |
| `scene state unavailable` | `Hitman5Module` / scene context / application engine global is null | Hitmen log (ERROR) |
| `local player not resolved` and never `resolved` inside a mission | `ZPlayerRegistry` layout or `GetLocalPlayer` drift | Hitmen log |
| `m_PlayerData` size 0 or implausible; entries "outside m_aPlayerData" | Registry layout differs from the SDK model (a finding, not necessarily a fault) | Hitmen log |
| Garbage or constant `position` | `ZSpatialEntity` layout drift | Hitmen log |
| `loading stage` never changes or shows wild values | The `0x178` offset is wrong (already marked unverified) | Hitmen log |
| `hitmen.brick loaded: true` | The SMF content mod is installed. **Abort**: a second Hitman may exist. | Hitmen log |
| `Networking is disabled; …` warning | Someone pressed "Start server" in the Hitmen menu. Harmless, but outside the script. | In-game console |
| `FAULT in …` | An exception left a probe path. The last lines before it show how far the probe got. | Hitmen log (ERROR), `HitmenLog::LogFault` breakpoint |
| Game closes with no `FAULT` line | Crash outside the guarded paths (legacy brick scan, another mod, the engine) | Debugger; dump |
| Crash or hang at exit | Destructor path (`UnregisterFrameUpdate`) or SDK teardown | Debugger; last log lines |

### Capturing a crash

SDK crash reporting is not functional on this game build (M0 F2), so capture is manual.

1. **With the debugger attached (preferred):** when Visual Studio breaks on the exception, do not continue. Use **Debug → Save Dump As…** and choose **Minidump with Heap**. Then copy the Call Stack and Modules windows (select all, copy) and save the Hitmen log.
2. **Without a debugger, process still present** (hung, or a crash dialog is on screen): Task Manager → Details → right-click `HITMAN3.exe` → **Create dump file**.
3. **Always:** the Hitmen log survives the crash. A `FAULT` line gives the exception code and the faulting address as module + offset, which can be resolved offline against `Hitmen.pdb`.

Optional and not set up: Windows Error Reporting `LocalDumps` for `HITMAN3.exe`, or Sysinternals ProcDump (`procdump -e -ma HITMAN3.exe`). Both are system-level changes or extra tools, ProcDump cannot be combined with an attached Visual Studio, and the engine installs its own unhandled-exception filter, so whether either would trigger is unknown.

Store dumps and logs outside the repository (they contain game memory). Record their hashes and location in the experiment notes.

## Proposed first-load procedure (NOT executed; requires explicit approval)

Intended shape, deliberately boring:

```
launch → DLL initializes → hooks register → mission loads → scene lifecycle observed
       → local player resolves → player registry dumped → local transform read
       → mission restart → clean exit
```

### Pre-flight (no game changes)

1. HITMAN is not running. Steam shows no pending game update (M0 recorded build `24833614`, version `3.280.0.0`); if the game has updated, stop and redo the M0 runtime check first.
2. `ZHMModSDK` is on `research/hitmen-revival` at `e748cdde`, working tree clean.
3. `Hitmen.dll` in the build tree has the SHA-256 above.
4. `Retail\ZHMModSDK.dll` and `Retail\dinput8.dll` still have their M0 hashes (`1358c4e7…`, `b4210964…`).
5. `Retail\mods\Hitmen.dll` does not exist. Confirm that no Simple Mod Framework deployment has been made since M0 (game content still vanilla), so that `hitmen.brick` cannot be loaded.
6. Save a listing of `Retail` and a copy of `Retail\mods.ini` outside the game directory.
7. Start the log tail command; start Visual Studio with "Continue without code".

### Install (the only game-directory changes)

1. Copy exactly one file: `ZHMModSDK\_build\hitmen-x64-Debug\Mods\Hitmen\Hitmen.dll` → `Retail\mods\Hitmen.dll`. Verify it is byte-identical.
2. Add an empty `[hitmen]` section to `Retail\mods.ini` so the SDK loads it at startup. (Alternative: enable it in the SDK's mod selector in game, which writes the same section. Startup loading is preferred because it exercises the intended sequence from the beginning.)

Do **not** run any CMake install target or `*-Install` preset, do **not** copy the PDB into the game directory, and do **not** deploy `Mods/Hitmen/Smf`.

Other mods: keep the M0 set (Editor, FreeCam, SkipIntro, NoPause) so that Hitmen is the only variable against a known-good run. Alternative, if a quieter process is preferred: enable only Hitmen and SkipIntro. This is a decision for the approver.

### Run

1. Launch through Steam. Reach the main menu.
2. Check the log: two `module attached` lines with a `detaching` between them, `plugin constructed`, `Init enter/exit`, `OnEngineInitialized enter/exit`, at least one `OnLoadScene enter` for the frontend scene, and `scene state` lines. Any `ERROR` line: stop.
3. Attach Visual Studio (native). Confirm `Hitmen.dll` symbols are loaded. Set the breakpoints, leaving `OnLoadScene_Internal` and `DumpPlayerRegistry` disabled unless stepping is wanted.
4. Load the same mission as M0 (Paris), same game mode as M0.
5. In the mission, check for: `OnLoadScene enter` with the Paris scene resource, `scene state: loaded false -> true`, `local player resolved`, `loaded bricks: N, hitmen.brick loaded: false`, a complete registry dump (`dump begin` … `dump end`), and a `local transform read`.
6. Walk for 20 to 30 seconds. Successive `local transform read` lines should change and look like plausible world coordinates.
7. Restart the mission from the pause menu. Expect `OnClearScene`, a new `OnLoadScene`, and the resolution, registry dump and transform read again.
8. Exit to the main menu, then quit the game normally. Note which shutdown lines appear.

During the run, do not: open the "Hitmen" menu window or press "Start server", start a second game instance, enter Ghost Mode or any online multiplayer mode, use other mods' features that move or spawn entities, or edit memory from the debugger.

### Abort immediately if

- any `FAULT` or other `ERROR` line appears, or the debugger breaks on an exception in `Hitmen.dll`;
- `hitmen.brick loaded: true`;
- the game hangs, or a load takes clearly longer than in M0;
- anything is written under the game directory other than the files M0 already identified (`mods.ini`, `ZHMModLoader.log`).

On abort: capture a dump if the process is still alive, quit the game, roll back, keep the logs.

### After the run

1. Collect the Hitmen log and `ZHMModLoader.log`. Compare a new `Retail` listing with the pre-flight one.
2. Roll back unless told otherwise: delete `Retail\mods\Hitmen.dll` and restore the saved `mods.ini`.
3. Write the results up as the next experiment in `HITMEN_COMPILE_ARCHAEOLOGY.md`, including the questions below.

### Questions the first run answers

| Question | Evidence |
|---|---|
| Does the SDK accept and load the revived DLL on `3.280.0.0`? | Module and plugin lines |
| Are the `LoadScene` / `ClearScene` hooks live, and when do they fire (boot, menu, mission, restart)? | Scene callback lines |
| Does `ClearScene` fire on mission restart, and with which `fully unload` value? | `OnClearScene enter` |
| Is `m_LoadingStage` at `0x178` real? | Whether `loading stage` steps through `0..8` in order |
| Does `SDK()->GetLocalPlayer()` resolve, and how long after the scene reports loaded? | Timestamps of `scene state` vs `local player resolved` |
| Is `m_PlayerData` a view over the inline slots? How many entries in single player? | Registry dump |
| Which slot is the local player, and do upstream's field annotations hold? | Registry dump |
| Do transform reads work and track movement? | `local transform read` lines |
| What does shutdown look like? | Final lines of the log |

## What has and has not been verified

Verified (offline):

- The DLL builds from a clean tree, twice, and passes the inertness gate (`HITMEN_COMPILE_ARCHAEOLOGY.md`).
- All of its `ZHMModSDK.dll` imports exist in the SDK build that M0 installed.
- The logger: file creation and naming, line format, append across a simulated unload/reload, and that the fault filter logs and does not handle. Tested in a standalone executable built from `HitmenLog.cpp`.

Not verified (needs the runtime load):

- Everything that touches the game: that the SDK loads the DLL, that the hooks fire, every engine layout read, the registry dump, transform reads, behavior at exit.
- The debugger workflow on Visual Studio `17.14` against this game build.

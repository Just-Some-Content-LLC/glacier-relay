# M0 — Development Baseline

Started: 2026-10-06

**M0 status: ✅ COMPLETE (2026-10-06).** Source, toolchain, build and runtime baselines established. See the summary at the end.

Objective: build and load the exact, unmodified ZHMModSDK baseline against the current Steam build of HITMAN World of Assassination, using the upstream-supported procedure. Any failure is recorded here before any intervention.

## Source Baseline

| Component | Version |
|---|---|
| ZHMModSDK | `5cc7f1b1` (`v4.1.1-8-g5cc7f1b1`) |
| vcpkg | `2273a28f` (`2026.07.29-196`) |
| mINI | `a5ebe269` (`0.9.17`) |
| IconFontCppHeaders | `8a381189` |

Fork status at baseline:

- `origin`: `Just-Some-Content-LLC/ZHMModSDK`
- `upstream`: `OrfeasZ/ZHMModSDK` (fetch only; push URL set to `DISABLED`)
- Ahead of upstream: `0`
- Behind upstream: `0`
- Working tree: clean

Git operations on both repositories are performed from WSL git only.

## Host Environment

| Component | Version |
|---|---|
| Windows | Windows 11 Home 23H2, build `22631.5909` (registry `ProductName` reports "Windows 10 Home"; known Windows 11 quirk) |
| Visual Studio | Visual Studio Community 2022 `17.14.37710.0` (was `17.14.37628.2` at survey; updated by the Installer when the game workload was added on 2026-10-06) |
| MSVC | `14.44.35207` (only toolset installed; default) |
| Windows SDK | `10.0.26100.0` |
| CMake | `3.31.6-msvc6` (bundled with VS; no standalone CMake on `PATH`) |
| Ninja | `1.12.1` (bundled with VS) |
| Rust | rustup `1.29.1` (via winget `Rustlang.Rustup`, 2026-10-06). Build toolchain: `nightly-x86_64-pc-windows-msvc`, rustc `1.101.0-nightly (ea137335b 2026-10-05)`, cargo `1.101.0-nightly (f3865b2a4 2026-09-29)`, LLVM `23.1.3`, with `rust-src`. Stable is also installed and is the rustup default; Corrosion selects `nightly` explicitly. |
| Git (Windows) | Not installed; WSL git is canonical |
| WSL | WSL `2.0.14.0`, kernel `5.15.133.1-1`, Ubuntu 20.04.6 LTS |

### Visual Studio components

| Component | Installed |
|---|---|
| Desktop development with C++ (`Workload.NativeDesktop`) | Yes |
| MSVC x64/x86 build tools (`VC.Tools.x86.x64`) | Yes |
| C++ CMake tools (`VC.CMake.Project`) | Yes |
| Game development with C++ (`Workload.NativeGame`) | Yes (added 2026-10-06; missing at initial survey) |

## HITMAN WOA

| Property | Value |
|---|---|
| Distribution | Steam |
| Steam app ID | `1659040` |
| Game version | `HITMAN3.exe` file/product version `3.280.0.0` |
| Steam build ID | `24833614` (matches `TargetBuildID`; no pending update) |
| Last updated | 2026-09-06 12:07:04 UTC (appmanifest `LastUpdated` `1788696424`) |
| Install path | `C:\Program Files (x86)\Steam\steamapps\common\HITMAN 3` |

Pre-existing mod state: no SDK files in `Retail` (no `dinput8.dll`, `mods.ini`, `mods/`). The game is vanilla.

Note: the game install path matches the path in upstream's `CMakeUserPresets.json-steam_sample` and `launch.vs.json-steam_sample` exactly.

## Upstream Build Procedure

Sources read at `5cc7f1b1`: `README.md`, `CMakePresets.json`, `CMakeUserPresets.json-steam_sample`, `launch.vs.json-steam_sample`, `.github/workflows/build.yml`, `ZHMModSDK/CMakeLists.txt`, and the upstream wiki pages "Building & debugging the SDK" and "Setting up Visual Studio for development" (read 2026-10-06).

Documented prerequisites (wiki): Visual Studio 2022 (any edition) with the C++ and game development workloads, and git. The wiki notes that debugging may have issues in VS versions newer than `17.4.5`.

Undocumented prerequisite found in source: **Rust nightly**. `ZHMModSDK/CMakeLists.txt` uses Corrosion with `Rust_TOOLCHAIN nightly` (unless `ZHM_RUST_NO_RUSTUP`) and `Rust_CARGO_TARGET x86_64-pc-windows-msvc` to build the `zhmmodsdk_rs` static library (`ZHMModSDK/Rust/Cargo.toml`, edition 2024). It also runs `cargo test --features c-headers` to generate C headers. CI installs `dtolnay/rust-toolchain@nightly` with the `rust-src` component for non-upstream repositories. The wiki does not mention Rust, so it is out of date for this commit.

Other build-time network dependencies: Corrosion is pulled with `FetchContent`; vcpkg ports are resolved from the pinned `External/vcpkg` submodule; Cargo fetches crates, including `quickentity-rs` pinned to git rev `fc6d5fdd`.

Supported procedure (from presets and CI):

```
# inside an x64 MSVC developer environment
cmake --preset x64-Debug .
cmake --build _build/x64-Debug
cmake --install _build/x64-Debug
```

- Generator: Ninja, `cl.exe`, vcpkg toolchain from `External/vcpkg`, overlay triplet `x64-windows-zhm`.
- `x64-Release` is `RelWithDebInfo` with the static `/MT` runtime; `x64-Debug` uses `/MTd`.
- The IDE flow (wiki) copies `CMakeUserPresets.json-steam_sample` to `CMakeUserPresets.json` and builds `x64-Debug-Install`. That build **installs directly into the game directory** through `GAME_INSTALL_PATH`.
- Both `CMakeUserPresets.json` and `.vs/launch.vs.json` are local files copied from upstream samples and are ignored by upstream `.gitignore`. They are not source modifications.
- Upstream `.gitignore` does **not** ignore the preset output directories `_build/` and `_install/`, so a build makes the working tree show untracked files. Handling: `/_build/` and `/_install/` were added to the local-only `.git/info/exclude` on 2026-10-06. Upstream `.gitignore` is unchanged.

## Baseline Build

**Status:** ✅ **PASSED** on attempt 3 (2026-10-06). Unmodified `5cc7f1b1` configures, builds and installs with the `x64-Debug` preset. Attempts 1 and 2 failed on undocumented or unmet environment prerequisites, not on source. No source changes were made.

Procedure: plain `x64-Debug` preset (installs to `ZHMModSDK/_install/x64-Debug`, **not** into the game directory), run from a Windows `cmd` environment initialised with `VsDevCmd.bat -arch=x64 -host_arch=x64`, with `%USERPROFILE%\.cargo\bin` prepended to `PATH`. No `CMakeUserPresets.json` was created for this step.

### Configure

#### Attempt 1: FAILED (2026-10-06 17:25:39Z to 17:38:36Z, about 13 min)

Command: `cmake --preset x64-Debug .`

Tools resolved inside the dev environment: `cl.exe` MSVC `14.44.35207` Hostx64/x64, VS-bundled `cmake` `3.31.6-msvc6` and `ninja`, `cargo`/`rustup` from `%USERPROFILE%\.cargo\bin`. The VS Developer Command Prompt reports itself as `v17.14.41`.

Progress before failure:

- vcpkg manifest dependencies built and installed successfully for triplet `x64-windows-zhm` (including `directx-dxc`, `abseil`, `zlib 1.3.2`, `simdjson`, `semver`, `sentry`, `imgui`, `imguizmo`, `imgui-node-editor`, `implot`, `directxtex`).
- Compiler checks passed; OpenMP 2.0 found.

Failure:

```
-- CPM: Adding package ZHMTools@4.0.0 (v4.0.0)
CMake Error at .../Modules/ExternalProject/shared_internal_commands.cmake:943 (message):
  error: could not find git for clone of zhmtools-populate
...
  _build/x64-Debug/cmake/CPM_0.42.0.cmake:1208 (FetchContent_MakeAvailable)
  _build/x64-Debug/cmake/CPM_0.42.0.cmake:989 (cpm_fetch_package)
  CMakeLists.txt:29 (CPMAddPackage)
-- Configuring incomplete, errors occurred!
```

Cause: top-level `CMakeLists.txt:29` runs `CPMAddPackage("gh:OrfeasZ/ZHMTools@4.0.0")` (CPM `0.42.0`), which clones via git at configure time. No Windows `git.exe` is on `PATH`: Git for Windows is not installed, and `VsDevCmd.bat` does not add VS's bundled git (`Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\Git\cmd\git.exe`, present) to `PATH`. The upstream wiki lists git as a prerequisite; WSL git cannot satisfy it for a Windows-hosted CMake.

Classification: missing **documented** environment prerequisite. Not a source or toolchain incompatibility. After the failure, the ZHMModSDK working tree and all submodules were verified clean.

Additional undocumented build-time dependency found: **ZHMTools `4.0.0`** (`OrfeasZ/ZHMTools`), fetched by CPM at configure time.

#### Attempt 2: configure PASSED (2026-10-06 17:48:04Z, about 23 s with cached vcpkg packages)

Environment change from attempt 1: VS-bundled git (`git version 2.55.0.windows.5`) prepended to `PATH` in the build script only. Git for Windows was not installed, and WSL git remains the only git used on the repositories.

CPM cloned ZHMTools `4.0.0` successfully, and configure completed.

### Build

#### Attempt 2: FAILED (2026-10-06 17:48:27Z to 17:49:38Z)

Command: `cmake --build _build/x64-Debug`

Failing target: `ZHMModSDK_RustHeaders` (custom target in `ZHMModSDK/CMakeLists.txt`), which runs:

```
cd /D ...\ZHMModSDK\ZHMModSDK\Rust && cargo test --features c-headers -- generate_headers
```

```
   Compiling auto_context v0.1.0 (https://github.com/atampy25/quickentity-rs.git?rev=fc6d5fdd...)
error[E0554]: `#![feature]` may not be used on the stable release channel
 --> ...\.cargo\git\checkouts\quickentity-rs-5b76768a4c4a8c70\fc6d5fd\auto_context\src\lib.rs:1:1
  |
1 | #![feature(proc_macro_quote)]
error: could not compile `auto_context` (lib) due to 1 previous error
ninja: build stopped: subcommand failed.
```

Cause: the Corrosion crate import selects `nightly` explicitly (`Rust_TOOLCHAIN nightly`), but the `ZHMModSDK_RustHeaders` custom command invokes bare `cargo`, which resolves rustup's **default** toolchain. On this host the default is `stable`, because the winget `Rustlang.Rustup` package installs stable as default. There is no `rust-toolchain(.toml)` file in `ZHMModSDK/Rust`. Transitive dependency `quickentity-rs/auto_context` (rev `fc6d5fdd`) requires nightly (`proc_macro_quote`).

Upstream CI does not hit this because `dtolnay/rust-toolchain@nightly` makes nightly the only, and therefore default, toolchain.

Classification: environment assumption. **Upstream implicitly requires nightly to be rustup's default toolchain, or at least the toolchain resolved in `ZHMModSDK/Rust`.** This is undocumented.

Resolution for attempt 3: a rustup **directory override** (`rustup override set nightly` for `C:\Users\steve\dev\glacier-relay\ZHMModSDK\ZHMModSDK\Rust`). It is stored in rustup's user settings, not in the repository, and also applies to builds started from the Visual Studio IDE. The global rustup default remains `stable`. Verified: `rustup show active-toolchain` in that directory reports `nightly-x86_64-pc-windows-msvc (directory override ...)`.

#### Attempt 3: PASSED (2026-10-06 17:55:17Z to 17:56:43Z, about 1.5 min incremental)

Environment change from attempt 2: the rustup directory override described above. Configure, build (`[124/125]` final ninja step, plus install) and install all succeeded.

Warnings: one, reported twice. Cargo future-incompatibility notice: `the following packages contain code that will be rejected by a future version of Rust: binrw v0.15.0`. This is non-fatal now, but because the build tracks floating `nightly`, it is a candidate for future breakage.

Note on timings: attempt 1's about 13 min was dominated by first-time vcpkg dependency builds, which are cached in `External/vcpkg/{buildtrees,packages}` (ignored by vcpkg's own `.gitignore`). A clean-machine build should expect roughly that cost or more.

Post-build verification: ZHMModSDK `HEAD` is still `5cc7f1b1`, the working tree is clean, and all three submodules are clean.

### Output

Install prefix: `ZHMModSDK\_install\x64-Debug` (not the game directory).

`bin/`: `dinput8.dll` (DirectInput proxy / loader), `ZHMModSDK.dll`, `ResourceLib_HM3.dll`, `crashpad_handler.exe`, `discord_game_sdk.dll`, with PDBs. Also `include/`, `lib/`, `licenses/`.

`bin/mods/` (21): AdvancedRating, Assets, Clumsy, DebugCheckKeyEntityEnabler, DebugMod, DiscordRichPresence, Editor, FreeCam, FreelancerSeeder, MaxPatchLevel, NoPause, Noclip, OnlineTools, Outfits, Player, QuickSave, Randomizer, SkipIntro, TitaniumBullets, WakingUpNpcs, World.

### Finding: Hitmen is not part of the upstream build

`Mods/Hitmen` is present in source, and the README lists it as a sample mod, but **it is not built**. In the top-level `CMakeLists.txt`:

- `#Hitmen` is commented out of the `MODS` list (line 56).
- `#CPMAddPackage("gh:ValveSoftware/GameNetworkingSockets@1.4.1")` is commented out (line 28), and `Mods/Hitmen/CMakeLists.txt` has `#GameNetworkingSockets::static` commented out of its link libraries.

Both were commented out in upstream commit `40d86dc7` (2024-12-22, "Update dependencies"). Since then, `Mods/Hitmen` has received only cross-cutting mechanical edits (latest: `e10ddf81`, 2026-08-12, "Prefix log messages with the mod name"; `6fdbdfa1`, 2026-08-12; `13ae7b83`, 2025-10-22, "Update ZScene.h, Hooks.h and rename variables in mods"). **None of these edits have been compiled by upstream's build since 2024-12-22.**

Implication for Hitmen research: at this baseline, Hitmen is not known to compile, its networking dependency is not wired in, and any engine-structure assumptions it makes were last build-validated against the game as of late 2024 at best. Re-enabling it is a deliberate deviation from upstream and belongs on a research branch, not in M0.

## Runtime Validation

**Status:** Not attempted.

**Status:** Installed 2026-10-06. Awaiting manual launch.

### Installation

Procedure: replicated upstream's developer install rule exactly (top-level `CMakeLists.txt:88-105`, the `GAME_INSTALL_PATH` block used by the `x64-Debug-Install` preset). That rule copies runtime binaries only, with no PDBs and no license files. Files were copied manually from `ZHMModSDK\_install\x64-Debug\bin` instead of running the install preset, so that every introduced path could be inventoried first. No `CMakeUserPresets.json` was created.

Pre-install inventory of `Retail`:

- 80 files. Listing saved locally as `retail-before.tsv`; not committed because it is game content.
- Checked case-insensitively: `dinput8.dll`, `ZHMModSDK.dll`, `ResourceLib_HM3.dll`, `crashpad_handler.exe`, `discord_game_sdk.dll`, `mods/`, `mods.ini`, `ZHMModLoader.log`. **All absent.** The same names were also absent from the game root.
- `%LOCALAPPDATA%\ZHMModSDK` (Sentry database path) is absent.
- **Nothing was overwritten, so no backups were needed.** HITMAN3.exe was not running during installation.

Post-install: 26 files introduced, 0 pre-existing files removed or changed (before/after listing diff). Each installed file was verified byte-identical (`cmp`) to its build output.

Introduced paths (all under `C:\Program Files (x86)\Steam\steamapps\common\HITMAN 3\Retail`), source `_install\x64-Debug\bin\<same path>`:

| Path | SHA-256 |
|---|---|
| `dinput8.dll` | `b42109641ba7234b3c627d54d4b927af3f059ce851bb5a3dc10160f4ca7f623b` |
| `ZHMModSDK.dll` | `1358c4e716cdf1e80e7b39800d1ade567721aded003301b3bff959aabfaa7cc5` |
| `ResourceLib_HM3.dll` | `81b65b26369ae5a00f1af15b5d8f2d53a69eeca845f1f999c33b917bdf95ba1c` |
| `crashpad_handler.exe` | `73819fa76999e0d0aec2e74df75eff2a928d9cfd5d91cb771545fbb7b901d5e5` |
| `discord_game_sdk.dll` | `527768710ddb0953fce5eb1700c2566b6451135d76f1d0610b63907cd5ba94c5` |
| `mods/AdvancedRating.dll` | `2e59136fa5cfee9a04f37f9bbc8eed2d7cfff0ecde56c47f6353982ad7f101b2` |
| `mods/Assets.dll` | `940f0b031dfbf2845974cd933c0fe5968a70837405e3799b017365d22dd01041` |
| `mods/Clumsy.dll` | `c9ce1fba943079e166c4baf6b98e20345e0ab519c588e6062278c69d582247ec` |
| `mods/DebugCheckKeyEntityEnabler.dll` | `dd93d2de6ed44a3cf86c33388d9aac029bf95c0d32f0f07e2671d1bb7d2350d9` |
| `mods/DebugMod.dll` | `d593ed8b22f27d2c8d5a236e7cfe560dbe92960cc4a5a0f5546b2100e7fabe34` |
| `mods/DiscordRichPresence.dll` | `d1fde0e9d4a00ee532af0654295b433ec84aebccbb75fe79100dfdc92c7566c6` |
| `mods/Editor.dll` | `ec5bf6bc447f10e2e709d9aaf60c3b3dd7f0e8a121ffa284697df92a9af4b33d` |
| `mods/FreeCam.dll` | `3b6b06b323884d340bed1de2f52e10bd1d5f24924430cd8e0db723a839ac3e8e` |
| `mods/FreelancerSeeder.dll` | `7af86af3855c37146704bc1b9299a50a68641c8bc84ce228ea0ca8cfd1d8f52b` |
| `mods/MaxPatchLevel.dll` | `3b880cf1fe6e017518b68fdffa68fb4283937c2048e749e37da5c5169da10bc1` |
| `mods/NoPause.dll` | `4a0293da5c5b55e7bf84393859075e2fb65b61e9a5a21a7e4f637081a49aca53` |
| `mods/Noclip.dll` | `083f08f7d4e069b7aae86584d0b497e34decda5001aa2d7a2cc40b56bf58b6c9` |
| `mods/OnlineTools.dll` | `4c9bcbd2713c96554899412fe04400e80cfe923673ba5a355f94f6d8010c5784` |
| `mods/Outfits.dll` | `1280259f3ed7ddf2a2a241d3c406b06994fb45a1dd1d632d082a53247baf7040` |
| `mods/Player.dll` | `5738491177c41a41a6c056cffdc6bf5d40165f28f99f1d67180b9c9c050fba61` |
| `mods/QuickSave.dll` | `af6fca1aefc8393bd1c0d10c599b36fde8d6bdb08e9064d9c0fa6ce284119473` |
| `mods/Randomizer.dll` | `80f8bf487ce161862020a4461449449fde9d0d4981c3b2e28d2fa3e27a6b01c3` |
| `mods/SkipIntro.dll` | `6b0ed45527ea33c2a1a462c1a03069a9ccff4d51084250d176e4a24ce4d1222c` |
| `mods/TitaniumBullets.dll` | `8ca1549a547ddfebef3e310e57396b3eff27a94a128213a6d90757ab8654f891` |
| `mods/WakingUpNpcs.dll` | `1fe69959f07a1d98f5d3591dab924f14e82a1e901b3a1f93671321d2ee96ee40` |
| `mods/World.dll` | `378397863b640dbe360c58c6d0fbceebb372250ef6f6e476e7480b69d4b4a634` |

Plus the new directory `Retail\mods\`.

Uninstall/rollback: delete the 26 files above, `Retail\mods\`, `Retail\mods.ini`, and the game-root `ZHMModLoader.log` (README "Uninstalling"). Steam "Verify integrity of game files" will not remove the extra files, but would restore any overwritten game files; none were overwritten.

### Run 1: procedure

- Launched manually through Steam by the operator (2026-10-06, about 18:30Z; the log was last written at 11:36 local, PDT).
- First-launch SDK dialogs: the mod selection dialog listed all 21 built mods. Selected: **Editor, FreeCam, SkipIntro, NoPause**. Mods excluded on purpose: OnlineTools (changes online endpoints), Clumsy and DiscordRichPresence (need extra setup), and the rest (not needed for the baseline).
- Crash-reporting consent: the operator **opted in** (`crash_reporting = true`). See the SetUnhandledExceptionFilter finding below: crash reporting is non-functional on this game build anyway. No `%LOCALAPPDATA%\ZHMModSDK` Sentry database directory was created during the run.
- The operator then loaded Paris, toggled FreeCam with `K`, and flew around the map. Afterwards the game was exited normally.

### Run 1: checklist

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | WOA launches normally | ✅ | Operator observation |
| 2 | ZHMModSDK initializes | ✅ | Log: hooks installed, `Engine was initialized.`, both renderers ready |
| 3 | SDK UI/menu opens | ✅ | Operator: `~` console and `F11` UI toggle both work; log: `[ImGuiRenderer] Renderer ready` |
| 4 | Built mods discovered / loaded | ✅ | Log: 21/21 `Found mod`; selected mods loaded per operator (FreeCam functional). Per-mod load lines were not captured; see the log-truncation finding |
| 5 | Normal mission can be entered | ✅ | Operator: Paris loaded |
| 6 | Stable for basic movement/gameplay | ✅ | Operator: no crashes, freezes or visible errors; FreeCam flight across Paris |
| 7 | SDK log errors / version / hook failures | ⚠️ Two non-blocking failures | See below |

### Run 1: log summary

Log file: `ZHMModLoader.log`, written to the **game root** (`...\HITMAN 3\ZHMModLoader.log`, the process working directory), **not** `Retail`. Size 24,576 bytes, 285 complete lines. A copy is preserved locally (`glacier-m0\run1\`); it is not committed.

| Stage | Result |
|---|---|
| Address resolution | **151 / 151** `Successfully located`: 80 functions and 71 globals. No pattern-scan failures. |
| Hook detours | **79 / 80** installed (`EOS_Platform_Create` failed; see below) |
| Mod discovery | **21 / 21**, from `...\HITMAN 3\retail\mods` |
| Code patches | Multi-instance patch applied (`Patching 84 bytes of code at 0x14003de1a`). **SetUnhandledExceptionFilter patch failed.** |
| Update check | `Mod SDK is up to date.` |
| Rendering | D3D12/DXGI hooks wrapped device, factories and swap chain; `[DirectXTKRenderer]` and `[ImGuiRenderer]` ready |
| Engine | `Engine was initialized.` |

### Run 1: findings

**F1. `EOS_Platform_Create` hook failed (expected on Steam, misleading message).**

```
Could not load requested module 'EOSSDK-Win64-Shipping.dll' for hook 'EOS_Platform_Create' (error: 126).
Could not find address for hook 'EOS_Platform_Create'. This probably means that the game was updated and the SDK requires changes.
```

The hook targets an export of the Epic Online Services SDK (`ZHMModSDK/Src/Hooks.cpp:357`). The Steam distribution ships **no** `EOSSDK*` file anywhere in the install tree (verified), so Win32 error 126 (module not found) is expected. Classification: platform-specific hook. On Steam this is benign, and the "game was updated" wording is misleading here.

**F2. SetUnhandledExceptionFilter patch failed (real pattern drift).**

```
Patching 84 bytes of code at 0x14003de1a with new code from 0x14e630.
Could not find pattern in call to PatchCode. Game might have been updated.
Could not patch SetUnhandledExceptionFilter. Crash reporting will not work.
```

`ZHMModSDK/Src/ModSDK.cpp:826-835` searches for byte pattern `FF 15 ?? ?? ?? ?? 48 8D 8D D0 01 00 00` (an indirect `call` followed by `lea rcx,[rbp+0x1D0]`) so it can NOP the engine's `SetUnhandledExceptionFilter` call. The patch was introduced upstream in `0c4ad008` (2025-10-01) and last touched in `3347409a` (2025-11-15). It does **not** match game `3.280.0.0` (updated 2026-09-06). Classification: **game-version drift** in a non-gameplay patch. Consequence: the engine's own exception filter stays in place, so Sentry crash capture will not work even with `crash_reporting = true`. This matters for research: **crashes during later experiments will not produce SDK crash reports**, so a debugger or a manual dump must be used instead.

This is the first concrete evidence of current-build drift against upstream `5cc7f1b1`.

**F3. File log is truncated: post-initialization events are lost.**

The log ends mid-line (`[D3D12Hook`) at exactly 24,576 bytes (6 × 4096), a buffer boundary. `ZHMModSDK/Src/Logging.cpp:94` creates a `basic_file_sink_mt` with no `flush_on` level or periodic flush. `FlushLoggers()` is called only from the `ModSDK` destructor, and only under `#if _DEBUG` (`ModSDK.cpp:171-173`). That destructor evidently did not run at game exit, so the tail of the buffer was lost. As a result, mod load/unload lines, scene loads (Paris) and anything logged during gameplay are **absent from the file**, although the operator saw the SDK and FreeCam working.

Classification: upstream logging behavior, not a game incompatibility. Implication for research: **`ZHMModLoader.log` is unreliable for anything after early initialization.** Later experiments need another capture path (for example the in-game SDK console, a debugger attached via `launch.vs.json`, or a deliberate flush policy on a research branch).

### Run 1: game-directory changes from running

Compared with the post-install listing, `Retail` gained only `mods.ini` (114 bytes). No other files under `Retail` were added, removed or changed. The game root gained `ZHMModLoader.log`.

`mods.ini` after run 1:

```ini
[sdk]
crash_reporting = true
shown_ui_toggle_warning = true

[editor]

[freecam]

[skipintro]

[nopause]
```

## Deviations from Upstream

Source: none. ZHMModSDK `5cc7f1b1` built unmodified.

Local environment and configuration (none in tracked files):

- `.git/info/exclude`: `/_build/`, `/_install/`.
- Build `PATH`: VS-bundled git prepended, and `%USERPROFILE%\.cargo\bin` prepended.
- rustup directory override: `ZHMModSDK\ZHMModSDK\Rust` uses `nightly`.
- `upstream` remote push URL set to `DISABLED`.

## Undocumented Prerequisites Discovered

Upstream wiki prerequisites are VS 2022 with the C++ and game workloads, plus git. The following are also required at `5cc7f1b1` but undocumented:

1. Rust **nightly** (`x86_64-pc-windows-msvc`), with `rust-src` per CI.
2. Nightly must be the toolchain that **bare `cargo`** resolves in `ZHMModSDK/Rust` (default toolchain or override), because the `ZHMModSDK_RustHeaders` step bypasses Corrosion's toolchain selection.
3. A **Windows** `git.exe` on the configure-time `PATH` (CPM fetch of ZHMTools). `VsDevCmd.bat` does not provide one, even though VS bundles git.
4. Network access at configure and build time: CPM/FetchContent (ZHMTools `4.0.0`, Corrosion), Cargo crates (including the `quickentity-rs` git dependency), and vcpkg sources.


## M0 Summary

```
SOURCE     ✓ exact upstream baseline (5cc7f1b1, fork delta 0, tree clean)
TOOLCHAIN  ✓ MSVC 14.44.35207   ✓ Windows SDK 10.0.26100.0   ✓ CMake 3.31.6
           ✓ vcpkg 2273a28f     ✓ Rust nightly 1.101.0 (2026-10-05)   ✓ ZHMTools 4.0.0
BUILD      ✓ configure   ✓ compile   ✓ install   (x64-Debug, unmodified)
RUNTIME    ✓ launch   ✓ SDK init   ✓ UI   ✓ 21/21 mods discovered   ✓ mission (Paris)
           ⚠ EOS hook absent on Steam (benign)
           ⚠ SetUnhandledExceptionFilter pattern drift → no crash reporting
           ⚠ file log loses post-init output
```

Facts established for later work:

1. Upstream-equivalent ZHMModSDK builds and runs on this machine against the current Steam WOA build.
2. All 151 address signatures and 79 of 80 hooks used by the SDK core resolve on game `3.280.0.0`. The core engine-facing surface is current.
3. Both build failures were environmental (undocumented prerequisites), not source incompatibilities.
4. **Hitmen is dormant**: it has been excluded from the build since `40d86dc7` (2024-12-22), and its compilability and runtime compatibility at this baseline are unknown. See `ZHM_HITMEN_ANALYSIS.md`.
5. Crash reporting does not work on this game build, and the file log is truncated, so later experiments need their own crash and log capture.

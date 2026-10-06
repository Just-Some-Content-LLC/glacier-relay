# M0 — Development Baseline

Started: 2026-10-06

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

Not yet attempted. The next step installs the built loader into the game's `Retail` directory, which is the first M0 action that modifies the game installation. Planned approach: install the built `bin/` contents (or use the `x64-Debug-Install` preset) and launch through Steam. To uninstall, delete `dinput8.dll` and the SDK files from `Retail`, as described in the upstream README.

### SDK loading

TBD

### Plugins

TBD

### Observations

TBD

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

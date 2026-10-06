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
| Visual Studio | Visual Studio Community 2022 `17.14.37628.2` |
| MSVC | `14.44.35207` (only toolset installed; default) |
| Windows SDK | `10.0.26100.0` |
| CMake | `3.31.6-msvc6` (bundled with VS; no standalone CMake on `PATH`) |
| Ninja | `1.12.1` (bundled with VS) |
| Rust | **Not installed** (no `rustup`/`cargo` on Windows) |
| Git (Windows) | Not installed; WSL git is canonical |
| WSL | WSL `2.0.14.0`, kernel `5.15.133.1-1`, Ubuntu 20.04.6 LTS |

### Visual Studio components

| Component | Installed |
|---|---|
| Desktop development with C++ (`Workload.NativeDesktop`) | Yes |
| MSVC x64/x86 build tools (`VC.Tools.x86.x64`) | Yes |
| C++ CMake tools (`VC.CMake.Project`) | Yes |
| Game development with C++ (`Workload.NativeGame`) | **No** |

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
- Upstream `.gitignore` does **not** ignore the preset output directories `_build/` and `_install/`, so a build makes the working tree show untracked files. Proposed handling: list them in the local-only `.git/info/exclude` instead of changing upstream `.gitignore`.

## Baseline Build

**Status:** Not attempted. Blocked on prerequisites: Rust nightly is not installed, and the VS "Game development with C++" workload is missing.

### Configure

TBD

### Build

TBD

### Output

TBD

## Runtime Validation

**Status:** Not attempted.

### SDK loading

TBD

### Plugins

TBD

### Observations

TBD

## Deviations from Upstream

None.

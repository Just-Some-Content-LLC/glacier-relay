# Hitmen Revival — Experiment 1: Compile Archaeology

Date: 2026-10-06

Question: **what happens when the current ZHMModSDK tries to compile the dormant Hitmen source?**

Scope: build wiring and compile characterization only. No Hitmen source, Glacier type, serialization or networking code was modified. No Hitmen DLL was produced, installed or loaded.

## Setup

| Item | Value |
|---|---|
| Baseline | ZHMModSDK `5cc7f1b1` (M0, see `M0_BASELINE.md`; glacier-relay tag `research/m0-baseline`) |
| Branch | `Just-Some-Content-LLC/ZHMModSDK` `research/hitmen-revival`, created from `5cc7f1b1` |
| Toolchain | Identical to M0 (MSVC `14.44.35207`, CMake `3.31.6-msvc6`, Rust nightly `1.101.0 (2026-10-05)`) |
| Build | Preset `x64-Debug`, but in a separate binary dir `_build/hitmen-x64-Debug`. Target `Hitmen` only, with `ninja -k 0` to collect every failure. **No install step.** The M0 build dir and installed game files were not touched. |

## Build wiring changes (separate from source compatibility)

These are the only changes on the branch. Both restore upstream's own historical state; neither adds anything new.

| Step | Commit | Change | Rationale |
|---|---|---|---|
| W1 | `e1e6c28f` | Uncomment `CPMAddPackage("gh:ValveSoftware/GameNetworkingSockets@1.4.1")`, `Hitmen` in `MODS`, and `GameNetworkingSockets::static` in `Mods/Hitmen/CMakeLists.txt` | Exact reversal of the three Hitmen-related lines disabled in upstream `40d86dc7` (2024-12-22) |
| W2 | `c33d207e` | Re-add `"openssl"` to `vcpkg.json` at its original position | Upstream dependency from `68c4c887` (2023-08-13) to `fc4f4555` (2026-06-02), so it was present when Hitmen was last built |

### W1 result: configure FAILED

```
CMake Error ... FindOpenSSL.cmake:691:
  Could NOT find OpenSSL ... (missing: OPENSSL_CRYPTO_LIBRARY OPENSSL_INCLUDE_DIR)
  _build/hitmen-x64-Debug/_deps/gamenetworkingsockets-src/CMakeLists.txt:106 (find_package)
```

GNS 1.4.1 defaults to `USE_CRYPTO=OpenSSL`. Upstream removed `openssl` from the manifest 18 months after disabling Hitmen, which silently broke GNS's configure. Not taken: GNS `USE_CRYPTO=BCrypt` (Windows-native, no OpenSSL). It is a viable alternative, but it is a GNS configuration upstream never used.

### W2 result: configure PASSED, build FAILED

GNS configured with `Crypto library for AES/SHA256: OpenSSL`. The ZHMModSDK core still builds (`ZHMModSDK.dll` linked). The build stopped with two independent groups of failures:

1. **GameNetworkingSockets 1.4.1 itself does not compile** (D1 below).
2. **`Hitmen.cpp` does not compile.** The real build aborts at a fatal missing include at `Hitmen.cpp:17` (D2 below), hiding most source errors.

The link phase was never reached, so link compatibility is unknown.

## Dependency and build-layout drift

### D1. GNS 1.4.1 vs protobuf 6.33.4 (dependency version drift)

4 errors in 3 GNS translation units (`csteamnetworkingsockets.cpp:653`, `steamnetworkingsockets_connections.cpp:1298`, `steamnetworkingsockets_udp.cpp:1482,1735`):

```
error C2039: 'c_str': is not a member of 'std::basic_string_view<char,...>'
```

All four come from the macro `SteamNetworkingIdentityToProtobuf` (`steamnetworkingsockets_internal.h:674`), which calls `msg.GetTypeName().c_str()` in an assertion message. Protobuf 6.x returns a string view from `GetTypeName()`, whereas GNS 1.4.1 (2022) was written against `std::string`. This is not a Hitmen problem. Resolving it needs a decision on the GNS/protobuf pairing (for example a newer GNS release, or not using GNS at all; see the architecture note at the end).

### D2. imgui backend include path (ZHM build-layout drift; fatal)

```
Hitmen.cpp(17): fatal error C1083: Cannot open include file: 'backends/imgui_impl_dx12.h'
```

Upstream `6a2ca3d1` (2025-10-13, "Update imgui integration, switch to vcpkg") moved imgui to vcpkg, which installs `imgui_impl_dx12.h` at the include root, not under `backends/`.

## Diagnostic probe: full Hitmen.cpp error catalogue

Because D2 is fatal, the real build reports only the first five Hitmen errors (up to line 17 of 615). To expose the rest **without modifying source or the build tree**, `Hitmen.cpp` was compiled once by hand:

- Used the exact `cl.exe` command line from `ninja -t commands` for `Hitmen.cpp.obj`.
- Added one extra `/I` pointing at a throwaway directory outside the repository, containing `backends/imgui_impl_dx12.h` with a single `#include <imgui_impl_dx12.h>`.
- Redirected `/Fo` and `/Fd` outside the build tree.

Result: **45 errors, 0 warnings, no fatal error**. MSVC's limit is 100 errors, so this is the complete front-end error set for `Hitmen.cpp` (given D2 shimmed). Only `Hitmen.cpp` is a translation unit. `BinaryStreamReader.h` and `BinaryStreamWriter.h` are header-only and were compiled through it.

### Root causes

The 45 errors reduce to **7 root causes**. Every error is assigned to exactly one.

| # | Root cause | Errors | Introduced upstream | Classification |
|---|---|---|---|---|
| H1 | `ZEntitySceneContext_LoadScene` hook changed from `void(ZEntitySceneContext*, ZSceneData&)` to `bool(ZEntitySceneContext*, SSceneInitParameters&)`. Hitmen still declares and defines the detour with `ZSceneData` (`Hitmen.h:43`, `Hitmen.cpp:66, 582`). | 13 | `13ae7b83` 2025-10-22 | ZHM API drift (Glacier scene-init type renamed; return type changed) |
| H2 | `Hooks::ZPlayerRegistry_GetLocalPlayer` no longer exists; it is commented out in `Hooks.h:177` (`Hitmen.cpp:67`). | 2 | `c3ca2d5b` 2024-12-13 ("Start updating sigs for 3.210.1.0"). The SDK replaced it with a re-implementation in `982f28ab` 2024-12-26. | **Game-version drift**, surfaced as ZHM API removal |
| H3 | `ZSpatialEntity::GetWorldMatrix` / `SetWorldMatrix` renamed to `GetObjectToWorldMatrix` / `SetObjectToWorldMatrixFromEditor` (`Hitmen.cpp:262, 317`). | 3 | `4b3394e6` 2026-01-27 | ZHM API rename. **Semantic question:** the setter is now named "FromEditor", so the replacement may not be behaviorally equivalent for runtime replication. |
| H4 | `ZActorManager` is an incomplete type: it is defined in `Glacier/ZActor.h`, which Hitmen does not include. `Globals.h` only forward-declares it (`Hitmen.cpp:276, 287, 341` and cascades). | 10 | Not dated. Probably a former transitive include that went away. | Header-include drift / latent dormant-code assumption |
| H5 | `TEntityRef<T>::m_ref` removed; it is now `m_entityRef` + `m_pInterfaceRef` (`Hitmen.cpp:385, 390, 513`). | 7 | `4b2c64b4` 2026-01-21 ("Refactor classes and structures in ZEntity.h and Reflection.h") | ZHM API refactor |
| H6 | `SBrickAllocationInfo::entityRef` / `runtimeResourceID` renamed to `m_EntityRef` / `m_RuntimeResourceID` (`Hitmen.cpp:394, 397, 404`). | 7 | `13ae7b83` 2025-10-22 | ZHM API rename (Glacier brick struct) |
| H7 | `ZPlayerRegistry::m_pLocalPlayer` removed. It was `SNetPlayerData* m_pLocalPlayer; // 0x390` with a `static_assert` (`Hitmen.cpp:509`). | 3 | `982f28ab` 2024-12-26 | **Glacier type/layout drift** |
| | **Total** | **45** | | |

The `fmt::v12::ptr` / `fstring` errors (C2672, C7595) at lines 509 and 513 are follow-on errors from H5 and H7, not formatting-library problems.

### By category

| Category | Root causes | Errors |
|---|---|---|
| Missing dependency / build wiring | OpenSSL (fixed by W2), D2 imgui include path | (configure), 1 fatal |
| Dependency version drift | D1 GNS 1.4.1 vs protobuf 6.33.4 | 4 (in GNS) |
| ZHM API drift (renames, signatures, removals) | H1, H3, H5, H6 | 30 |
| Game-version / Glacier type-layout drift | H2, H7 | 5 |
| Compiler / toolchain drift | none observed | 0 |
| Defects or assumptions in dormant implementation | H4 (relied on a transitive include) | 10 |

### What did *not* break

- **No errors in Hitmen's networking or serialization code.** Hitmen's use of the GNS API (`steam/steamnetworkingsockets.h`, `steamnetworkingtypes.h`) and `BinaryStreamReader` / `BinaryStreamWriter` compiled cleanly against GNS 1.4.1 headers under MSVC 14.44 and C++23.
- No errors from Hitmen's uses of `ZHitman5` (lines 22, 263, 319, 411, 413, 608), `ZPlayerRegistry::m_aPlayerData` (446), the character `InputProcessor` access (263, 321, 324), or `m_OtherHitman` (303–602), apart from the renamed members listed above (H3, H5, H6). These are the "archaeological artifacts" Glacier Relay most needs, and they still match the current SDK headers syntactically. **Whether their offsets and semantics still match game 3.280.0.0 is untested.**
- No compiler or standard-library drift. Every error traces to a dated upstream SDK change.

## Timeline reconstruction

| Date | Upstream commit | Event |
|---|---|---|
| 2023-04-09 | `773c7cc7` | Hitmen mod added |
| 2024-12-13 | `c3ca2d5b` | Signature update for game **3.210.1.0**: `ZPlayerRegistry_GetLocalPlayer` hook commented out |
| 2024-12-22 | `40d86dc7` | **Hitmen and GNS disabled** in the build ("Update dependencies") |
| 2024-12-26 | `982f28ab` | GetLocalPlayer re-implemented in the SDK; `ZPlayerRegistry::m_pLocalPlayer` (0x390) removed |
| 2025-10-13 | `6a2ca3d1` | imgui moved to vcpkg (`backends/` include path gone) |
| 2025-10-22 | `13ae7b83` | ZScene/Hooks update. Hitmen's `OnClearScene` parameter was renamed, but its stale `LoadScene` / `ZSceneData` and `SBrickAllocationInfo` usages were **not** updated |
| 2026-01-21 | `4b2c64b4` | `TEntityRef` refactor |
| 2026-01-27 | `4b3394e6` | `ZSpatialEntity` matrix accessor rename |
| 2026-06-02 | `fc4f4555` | `openssl` removed from `vcpkg.json` |

**Hypothesis (not proven):** Hitmen was disabled because game update 3.210.1.0 broke its `GetLocalPlayer` hook (H2). The hook was commented out 9 days before Hitmen was disabled. The commit message ("Update dependencies") does not say so.

`13ae7b83` is direct evidence of the "mechanical edits without compile validation" pattern: it edited Hitmen's `OnClearScene` parameter name while leaving the `LoadScene` declaration in the same header uncompilable.

## Side finding: multiplayer remnants documented in `ZPlayerRegistry`

The current SDK's `Glacier/ZPlayerRegistry.h` annotates player-data fields with multiplayer semantics:

```cpp
ZRakNetReplica* m_pRakNetReplica;   // 0x20 (-8)
uint32_t m_nFlags0x20;              // 0x28 (-8) 0000000B when in multiplayer, 0 otherwise
void* m_nFlags0x28;                 // 0x30 (-8) 0x55bd4b73 for player one, 0x55bd4b74 for player two (in mp)
bool m_bLocalPlayer;                // 0x38 (-8)
bool m_bConnectedToMultiplayer;     // 0x4A (-8) true for both players when in multiplayer, false in singleplayer
ZNetPlayer* m_pNetPlayer;           // 0x50 (-8)
```

Together with `External/RakNet` in the SDK tree, this is direct evidence for research question 3 (Glacier multiplayer / Ghost Mode remnants). The structure has been reverse-engineered and maintained upstream, independent of Hitmen.

## Conclusions

1. Hitmen's dormancy is **shallow at the API level**: 45 errors from 7 root causes, almost all renames or signature changes with clear current equivalents. The networking and serialization code compiles.
2. The **real risk is semantic, not syntactic.** H2 (GetLocalPlayer hook replaced by an SDK re-implementation), H3 (`SetObjectToWorldMatrixFromEditor`), H1 (a scene-load hook that now returns `bool` with a different parameter struct) and H7 (a removed `ZPlayerRegistry` field) all compile once renamed, but may not behave the way Hitmen's 2023 logic assumed. A green build would not show that Hitmen works.
3. **GNS 1.4.1 is the most expensive part to revive** (OpenSSL plus protobuf pairing), and it is the part Glacier Relay's architecture (ADR 0001 / 0002) intends to replace with a native-adapter-to-BEAM boundary anyway. This supports removing GNS from the revival path entirely, rather than repairing it.

## Proposed next steps (not taken)

- Decide the GNS question: repair D1 (newer GNS or a protobuf pin) or remove networking from the revival. Removing it is the recommended direction, per conclusion 3.
- Fix H1 to H7 on the branch as **separate, individually documented commits**, each mapped to its root-cause ID, so that compile fixes stay distinguishable from semantic decisions.
- Before any runtime load: establish research observability (live logging and a native debugger attached via `launch.vs.json`; see M0 findings F2 and F3).

## Artifacts

Not committed (local only, `%TEMP%\glacier-m0\hitmen\`): `w1.log`, `w2.log`, `probe/probe.log` (full 45-error output), `probe/run-probe.cmd`, `shim/`.

---

# Experiment 2: GNS removal and mechanical repairs

Date: 2026-10-06

Direction (agreed after experiment 1): do **not** repair GNS. Replace it with a transport seam, fix only the mechanical drift, and defer anything that changes meaning (H1, H2, H3, H7) for deliberate investigation. No runtime loading.

## Commits on `research/hitmen-revival`

Each commit is one root cause, so the history stays bisectable.

| Commit | ID | Change |
|---|---|---|
| `04329728` | S1 | Replace GNS with `IHitmenTransport` / `NullHitmenTransport` (`Mods/Hitmen/Src/HitmenTransport.h`). Reverts W1's GNS package/link and W2's `openssl`. Message encode/decode is unchanged. The historical contract is preserved in `HITMEN_GNS_CONTRACT.md`. |
| `c9da62fc` | D2 | `#include "backends/imgui_impl_dx12.h"` → `#include <imgui_impl_dx12.h>` (vcpkg layout). Hitmen never calls the DX12 backend; the include is kept so any transitive `imgui.h` dependency is preserved. |
| `09a45c72` | H4 | `#include "Glacier/ZActor.h"` |
| `6b6240ad` | H5 | `TEntityRef::m_ref` → `m_entityRef` (5 uses) |
| `6e1881d7` | H6 | `SBrickAllocationInfo::entityRef` / `runtimeResourceID` → `m_EntityRef` / `m_RuntimeResourceID` |
| `2effb125` | H9 | `ZEntityRef::m_pEntity` → `m_pObj` (new, see below) |

After S1, the build files differ from upstream `5cc7f1b1` **only** by `Hitmen` being re-enabled in `MODS`. There is no GNS and no OpenSSL; configure removed the `openssl` vcpkg package.

## Newly exposed root causes

Fixing the experiment-1 causes uncovered errors they had been hiding:

| # | Root cause | Errors | Hidden by | Introduced upstream | Classification |
|---|---|---|---|---|---|
| H8 | `ZActorManager::m_aActiveActors` no longer exists. Upstream **reinterpreted the layout**: `TEntityRef<ZActor> m_aActiveActors[1000]` at `0x1F68`, indexed by `Globals::NextActorId`, is now `TMaxArray<TEntityRef<ZActor>, 500> m_activatedActors` at `0x1F68`, beside the new `m_aActors[500]`, `m_enabledActors`, `m_aliveActors` and **`m_aliveHm5Characters`** lists (`Hitmen.cpp` `SendNpcPositions`, `OnNpcPositions`). | 10 | H4 (incomplete type) | `c2e1cc3d` 2025-12-08 | **Glacier type/layout drift, semantic.** The NPC path's cross-instance identity is "index into this array", so this is not a rename. **Deferred.** |
| H9 | `ZEntityRef::m_pEntity` renamed `m_pObj` (same `ZEntityType**`), passed to `GetSubEntity` in the `hitmen.brick` lookup | 1 | H6 | `4b2c64b4` 2026-01-21 (same refactor as H5) | ZHM API rename. **Fixed.** |

Root causes in total: 9 (H1 to H9).

## Build after the mechanical repairs

Real build (no probe or shim), target `Hitmen`, branch head `2effb125`: **31 errors, all in `Hitmen.cpp` / `Hitmen.h`, 0 warnings in Hitmen**.

| Root cause | Errors | Lines |
|---|---|---|
| H1 `LoadScene` / `ZSceneData` | 13 | `Hitmen.h:41`, `Hitmen.cpp:54, 441` |
| H2 `ZPlayerRegistry_GetLocalPlayer` hook | 2 | `55` |
| H3 `Get/SetWorldMatrix` | 3 | `129, 184` (the H3 uses at `159, 212` are still hidden behind H8) |
| H8 `ZActorManager` actor storage | 10 | `143–159, 208–212` |
| H7 `ZPlayerRegistry::m_pLocalPlayer` | 3 | `368` |
| **Total** | **31** | |

Verified: **no errors come from the transport seam or any mechanical repair.** GNS and OpenSSL are fully gone from configure and build.

## Observations for the deferred work

Reading the full source changes the risk assessment for two of the deferred causes:

- **H1 is low-risk in behavior.** Hitmen's `OnLoadScene` detour is a pass-through: its body is only commented-out scene-swap experiments, and it returns `Continue`. The decision is whether Hitmen needs a load-scene hook at all; the scene lifecycle check for the dormant revival may be better served by `OnClearScene` plus the existing `m_bSceneLoaded` poll.
- **H2 is low-risk in behavior.** The `GetLocalPlayer` detour is also a pass-through (call the original, return the result). **Hitmen already uses the SDK's replacement `SDK()->GetLocalPlayer()`** (`OnFrameUpdate`, `OnDrawMenu`). The hook registration looks vestigial.
- **H7** is confined to a single debug log line in the "Player registry" menu button. The rest of that button dumps `m_aPlayerData[0..3]` controller fields (RakNet replica, multiplayer flags, net player, player IDs), which **compile against the current SDK unchanged**. That button is the ready-made instrument for the H2/H7 "how does the game represent the local player now" investigation.
- **H3** and **H8** sit only on the networking send/receive paths: `SendInputsAndPosition` and `SendNpcPositions` (transform reads), and `OnInputsAndPosition` and `OnNpcPositions` (transform writes). In the current source **none of these paths can run**. The sends and `ProcessMessages` / `UpdateConnection` are only called from the commented-out block in `OnFrameUpdate`, and `NullHitmenTransport` never delivers a message.

So reaching a building dormant DLL depends mainly on decisions about what to *remove or disable* in the dormant configuration, rather than on recreating lost engine behavior.

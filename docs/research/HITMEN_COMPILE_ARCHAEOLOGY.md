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

---

# Experiment 3: deferred causes and the dormant build gate

Date: 2026-10-06

Direction: resolve H1, H2, H3, H7 and H8 by understanding what the 2023 code intended and what the current SDK provides, keeping only behavior whose meaning is understood. The goal is a Hitmen DLL that builds and is behaviorally inert, not restored multiplayer. **No Hitmen DLL was copied, installed or loaded. No game files were touched.**

## Commits on `research/hitmen-revival`

| Commit | ID | Change | Hitmen errors after |
|---|---|---|---|
| `de96af48` | H1 | Adapt the `OnLoadScene` detour to `bool (ZEntitySceneContext*, SSceneInitParameters&)` | 18 (by count; not rebuilt per commit) |
| `64b2c19f` | H2 | Remove the `GetLocalPlayer` detour | 16 |
| `5763007a` | H7 | Replace the `m_pLocalPlayer` debug line with the player data array's size and begin pointer | 13 |
| `de76e4bc` | H3 | Compile out `ProcessMessages`, `SendInputsAndPosition`, `OnInputsAndPosition` (`#if 0`) | 10 |
| `b8c66ead` | H8 | Compile out `SendNpcPositions`, `OnNpcPositions` (`#if 0`) | **0** |

The per-commit error counts are the experiment-2 counts minus each fixed cause; only `b8c66ead` and the final head were actually built. H3 was committed before H8 because `ProcessMessages` references `OnNpcPositions`: excluding the dispatcher first means no commit leaves a live reference to an excluded function.

## H1: scene lifecycle

**What the old hook did.** Nothing. Since `773c7cc7` (2023-04-09) the detour body has been commented-out scene-swap experiments (forcing a different `m_sceneName` and brick list) followed by `return HookResult<void>(HookAction::Continue())`. There is no code before or after a call to the original, and it never called the original itself.

**Current hook semantics.** `Hooks::ZEntitySceneContext_LoadScene` is `Hook<bool(ZEntitySceneContext*, SSceneInitParameters&)>`. The SDK runs each registered detour in order. A detour that returns `HookAction::Continue()` produces no return value; when every detour continues, the SDK calls the original and returns its result (`Hook.h`, `Hook<ReturnType(Args...)>::Call`). A detour that returns `HookAction::Return(value)` ends the chain: later detours and the original do not run.

**The `bool`.** Not documented upstream. `f0e85638` (2025-12-17, "Change ZEntitySceneContext::LoadScene return type from void to bool") changed the hook signature and every in-tree detour mechanically, with no explanation. No SDK or mod code reads the value, and every in-tree detour returns `Continue`. The vtable declaration in `ZScene.h` still says `virtual void LoadScene(...)`. Its meaning is **unknown**. Because Hitmen's detour continues, it never has to produce one.

**Does Hitmen need more than call-through?** No. Scene-transition reset logic lives in `OnClearScene` (clears `m_OtherHitman`, `m_FirstHitman`, `m_SceneLoaded`), and scene readiness is polled in `OnFrameUpdate`. Neither depends on the load hook.

**Adaptation.** Signature and `HookResult` type only. The commented-out experiments are left verbatim, old field names included.

**Correction to experiments 1 and 2.** They attributed all of H1 to `13ae7b83`. That commit renamed `ZSceneData` to `SSceneInitParameters` (same layout, fields renamed). The `void` → `bool` change is the separate, later `f0e85638`.

## H2 and H7: local player and the player registry

Researched together; the code changes are independent and committed separately.

**H2: the detour was removed, not reconstructed.**

- The hook object has not existed since `c3ca2d5b` (2024-12-13). The engine function is no longer located by the SDK at all.
- The detour body, unchanged since 2023, was `CallOriginal` then `Return(out)`: an identity pass-through that touched no Hitmen state.
- Hitmen's two local-player lookups were switched upstream to `SDK()->GetLocalPlayer()` (`17bdce46`, `982f28ab`). That function walks `ZPlayerRegistry::m_PlayerData` directly and does not go through a hook, so a detour could not observe or change it even if the hook were restored.
- `m_FirstHitman`, the only member plausibly related, is never assigned. The detour reads as scaffolding for redirecting which Hitman counts as local, never written.

There is no evidence that Hitmen depended on anything the detour did.

**H7: `m_pLocalPlayer` was one of three readings of the same 8 bytes.**

| Date | Commit | SDK model of `ZPlayerRegistry` at `0x390` |
|---|---|---|
| 2023-03-06 | `89d417b1` | `SNetPlayerData* m_pLocalPlayer` |
| 2024-12-26 | `982f28ab` | `SNetPlayerData* m_pPlayerData[2]`; `int64_t m_nLocalPlayerId` at `0x3A0` |
| 2025-09-26 | `a4a9f2a4` | `TArray<SNetPlayerData> m_PlayerData` |

A `TArray` is three pointers (begin, end, allocation end). So the 2023 "local player" pointer is the array's begin pointer, the 2024 "second player" pointer is its end pointer, and the 2024 "local player id" is its allocation-end pointer. No replacement was invented: the single debug line that used the field now prints `m_PlayerData`'s size and begin pointer, which is the same memory under the current reading.

**What the current `ZPlayerRegistry` exposes without mutation** (all by plain reads of `Globals::PlayerRegistry`):

- `m_aPlayerData[4]` at `0x50`: four inline `SNetPlayerData` slots (`0xD0` bytes each). Per slot: `m_nPlayerId`, and a `ZNetPlayerController` with `m_pRakNetReplica`, `m_bLocalPlayer`, `m_bConnectedToMultiplayer`, `m_pNetPlayer`, `m_SelectedCharacterId`, `m_OutfitId`, a session id string, `m_HitmanEntity`, and several unnamed flag words.
- `m_PlayerData` at `0x390`: the list of registered players. `ModSDK::GetLocalPlayer` returns the `m_HitmanEntity` of the first entry with no `m_pNetPlayer`, else the first entry. Upstream's own comment says this "probably won't work correctly in multiplayer".
- The inline slots end exactly where the array begins (`0x50 + 4 × 0xD0 = 0x390`). Whether `m_PlayerData` is a view over those slots or separate storage is **not known**; the registry dump now reports it.

The field annotations in `ZPlayerRegistry.h` (for example "0000000B when in multiplayer", "0x55bd4b73 for player one") are upstream's notes from an unknown game version. None are verified on `3.280.0.0`.

## H3: transform access

All four H3 sites were inside the 2023 sync functions, which were already unreachable. They were compiled out rather than renamed.

- **Reads** (`GetWorldMatrix` → `GetObjectToWorldMatrix`): the accessor returns the cached world matrix and first calls the engine's `ZSpatialEntity_UpdateCachedWorldMat` if the entity's dirty flag is set. It is the accessor every in-tree mod uses. The dormant build uses it for the local Hitman only (observability, below).
- **Writes** (`SetWorldMatrix` → `SetObjectToWorldMatrixFromEditor`): not substituted. New finding: in the SDK's vtable model the renamed setter occupies the **same slot** `SetWorldMatrix` had in 2023 (12th `ZSpatialEntity` virtual, immediately before `CalculateBounds`). `4b3394e6` briefly swapped the two declarations; `df472b3d` restored the order the same day. So the rename appears to correct the name of the function the 2023 code was already calling, rather than point at a different one. That does not settle whether an editor-path setter is appropriate for runtime replication (it may bypass or trigger physics, room and streaming updates differently from gameplay movement). The question stays open and transform writes stay out of the build.

## H8: NPC identity

Compiled out, not ported. The 2023 protocol used the index into `ZActorManager::m_aActiveActors` as the NPC's cross-machine identity. The current model shows that array was really a 500-entry dense list of activated actors (`m_activatedActors`) whose order is local to one process. Full findings, the identifiers the engine does offer, and requirements for a stable scheme are in `HITMEN_ENTITY_IDENTITY.md`.

## Dormant build gate

Clean configure and build of target `Hitmen` (build tree deleted first; preset `x64-Debug` in `_build/hitmen-x64-Debug`; no install step), run twice: at `b8c66ead` (after H8) and at the final head `e748cdde` (after the observability commits below).

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Clean configure and build | ✅ | Both runs exit 0; `Hitmen.dll` linked. No warnings from Hitmen sources. |
| 2 | GNS absent | ✅ | No `gamenetworkingsockets` in `CMakeCache.txt` or `build.ninja`; no `_deps` entry; the `CPMAddPackage` and link lines are still commented out |
| 3 | OpenSSL not reintroduced | ✅ | Not in `vcpkg.json`; no `openssl` under `vcpkg_installed`; no `openssl`/`libssl`/`libcrypto` in the cache or build file |
| 4 | `NullHitmenTransport` is the only transport | ✅ | `IHitmenTransport` has one implementation; the only construction site is `std::make_unique<NullHitmenTransport>()` |
| 5 | Hitmen cannot open a socket | ✅ | `Hitmen.dll` imports only `ZHMModSDK.dll`, `KERNEL32`, `USER32`, `SHELL32`, `IMM32`. No `ws2_32`, `mswsock`, `winhttp` or `wininet`, and no socket- or HTTP-named import. |
| 6 | No remote transform mutation path | ✅ | With `#if 0` regions and comments stripped, the Hitmen sources contain no `SetObjectToWorldMatrix*`, `SetWorldMatrix`, `SetProperty`, `memcpy`, `ReadBytes` or input-processor access. The object file has no `OnInputsAndPosition` or `ProcessMessages` symbol. |
| 7 | No NPC synchronization path | ✅ | Same scan: no `ActorManager`, `m_activatedActors`, `m_aActiveActors` or `NextActorId`. No `SendNpcPositions` / `OnNpcPositions` symbol. |
| 8 | Hitmen DLL builds | ✅ | `_build/hitmen-x64-Debug/Mods/Hitmen/Hitmen.dll` with `Hitmen.pdb` |

Scope notes for check 5: `SHELL32!ShellExecuteW` and the `IMM32` imports are attributed to the statically linked Dear ImGui (open-link and IME support), not to Hitmen code; this attribution was not confirmed symbol by symbol. The statement is about `Hitmen.dll` only. The SDK core and other mods (for example the Editor mod's WebSocket server) are upstream baseline behavior and outside this gate.

Binary compatibility with the installed baseline: every one of the 14 functions `Hitmen.dll` imports from `ZHMModSDK.dll` is exported by the M0 build of that DLL (`_install/x64-Debug/bin/ZHMModSDK.dll`, SHA-256 `1358c4e7…`, the file M0 installed). The branch changes nothing under `ZHMModSDK/`, so the SDK core the game already has is the one Hitmen was compiled against.

### What the dormant build still does

Stated plainly, so "inert" is not overread:

- Registers two detours (`OnClearScene`, `OnLoadScene`) that only log and continue.
- Registers a per-frame update with the engine's game loop manager and unregisters it in the destructor.
- Each frame, once a scene is loaded: reads scene state, calls `SDK()->GetLocalPlayer()`, queries the `ZSpatialEntity` interface, and iterates the loaded-brick list looking for `hitmen.brick` (the legacy second-Hitman discovery, which only goes further if that brick is present).
- Reads the local Hitman's world matrix (which can trigger the engine's lazy cache refresh), and reads `ZPlayerRegistry`.
- `ZGuid::ToString` in the registry dump allocates and frees a small `ZString` through the SDK.
- Draws two menu buttons. "Hitmen" opens a window whose "Start server" button reaches `NullHitmenTransport::StartServer`, which logs a warning and returns false.

It does not create a second Hitman (that is content in `hitmen.brick`, added to global data by the SMF content mod in `Mods/Hitmen/Smf`, which is **not** deployed), write any transform, property or input state, read or write any actor, or open any network connection.

## Observability commits

Added only after the gate passed. No behavior change; details and the proposed first-run procedure are in `HITMEN_RUNTIME_PROBE.md`.

| Commit | ID | Change |
|---|---|---|
| `ff19bd57` | O1 | Durable per-process log (`HitmenLog`), unbuffered, outside the game directory |
| `0838b04d` | O2 | Module attach/detach, constructor/destructor, detour registration, `OnEngineInitialized` |
| `874ad676` | O3 | `OnLoadScene` / `OnClearScene` enter and exit; observed scene-state changes |
| `723d673d` | O4 | Local-player resolution, `hitmen.brick` presence, local transform reads |
| `e01effd2` | O5 | Player-registry dump moved to the durable log; runs once per scene and from the menu |
| `e748cdde` | O6 | Log-only SEH filter around the probe paths (never handles the exception) |

Final head `e748cdde`: `Hitmen.dll` SHA-256 `4a2176be9089889ab665ba1ec107a848c0b8a8c1f3d2a77dffb77af781d0a669` (local build; not reproducible bit-for-bit, recorded to identify the artifact a later run uses).

## State at the hard stop

- Hitmen builds from a clean tree.
- Networking is inert (null transport, no socket imports, sync code compiled out).
- Mutation paths are compiled out.
- Durable logging exists and was exercised outside the game.
- The debugger workflow and first-run procedure are written (`HITMEN_RUNTIME_PROBE.md`).
- **Not done, by design:** nothing was copied into the game directory and the DLL has never been loaded by HITMAN. The first runtime load needs explicit approval.

## Artifacts (local only, not committed)

`%TEMP%\glacier-m0\hitmen\`: `build-hitmen-clean.cmd`, `build-hitmen-incr.cmd`, `clean1.log` (gate build at `b8c66ead`), `clean2.log` (gate build at `e748cdde`), `logtest\` (standalone logger test and its output log).

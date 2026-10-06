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

---

# Experiment 4: first controlled runtime load

Date: 2026-10-06 (20:13Z to 20:40Z)

Authorized explicitly for this run. Objective: determine whether the dormant probe coexists with the current game and SDK and can observe `module load → initialization → hooks → scene lifecycle → local player → registry → transform read → mission restart → shutdown`, with no mutation, networking, synchronization or spawning. Procedure: `HITMEN_RUNTIME_PROBE.md`. Nothing in Hitmen was changed during or after the run.

**Result: R1, R2, R3 and R4 all passed. 686 log lines, 0 `ERROR`, 0 `FAULT`, exit code 0. The game directory was restored to its pre-run state and verified.**

## Setup

| Item | Value |
|---|---|
| Game | `3.280.0.0`, Steam build `24833614` (unchanged since M0), launched through Steam by the operator |
| Probe | `Hitmen.dll` from `e748cdde`, SHA-256 `4a2176be…d0a669`, copied to `Retail\mods\` |
| Mods enabled | M0 set (Editor, FreeCam, SkipIntro, NoPause) plus Hitmen. Hitmen was the only variable. |
| Pre-flight | Game not running; all 26 M0 file hashes matched; `Retail` listing identical to M0's post-run listing; no Hitmen files anywhere under the game root; no file in `Runtime` newer than the game update (no SMF deployment) |
| Game-directory changes | Exactly two: `Retail\mods\Hitmen.dll` added; `[hitmen]` appended to `Retail\mods.ini` |
| Debugger | Visual Studio attached by the operator after R1; stayed attached through exit |
| Evidence (local only) | `%TEMP%\glacier-m0\hitmen\probe-run1\`: the durable log (SHA-256 `f2d14b5d…c99595`), the SDK log, `mods.ini` before/after, `Retail` listings and hashes |

## Observed lifecycle (UTC, complete for scene events)

Every line in the log carries the same thread id: mod loading, both detours and the frame update all ran on one thread.

| Time | Event |
|---|---|
| 20:21:19.381 | Module attached (discovery load) |
| 20:21:19.382 | Module detaching: FreeLibrary |
| 20:21:19.506 | Module attached (real load); plugin constructed |
| 20:21:19.509 | `Init`: detours registered |
| 20:21:28.821 | `OnLoadScene`: `Frontend/MainMenu.entity`, type empty, start game true |
| 20:21:29.269 | `OnEngineInitialized`: null transport, frame update registered |
| 20:21:29.275 | First frame: scene loaded true, stage 5; local player not resolved |
| 20:21:29.412 | Stage 6 |
| 20:21:29.535 | **Local player resolved in the main menu**; 5 bricks; registry dump 1; first transform read |
| 20:21:29.571 – .575 | Stages 7, 8 |
| *(12.8 minutes at the menu while the debugger was attached; a transform sample every 5 s)* | |
| 20:34:20.002 | Scene loaded true → false |
| 20:34:20.031 | Stage 0 |
| 20:34:20.071 | `OnClearScene`, flag **false** |
| 20:34:20.251 | Stage 2 |
| 20:34:20.293 | `OnLoadScene`: `Missions/Paris/_Scene_FashionShowHit_01.entity`, type `mission`, codename hint `Peacock`, 0 additional bricks |
| 20:34:26.647 – 34.386 | Stages 5, 6, 7 |
| 20:34:34.787 | Stage 8, scene loaded true, local player resolved **in the same frame**; 23 bricks; registry dump 2 |
| 20:34:34.796 onward | Transform reads while the operator walked |
| 20:36:41.114 | *(mission restart)* Scene loaded true → false |
| 20:36:41.123 | Stage 0 |
| 20:36:41.582 | `OnClearScene`, flag **true** |
| 20:36:46.811 – 52.116 | Stages 5, 6, 7. **No `OnLoadScene`.** |
| 20:36:52.473 | Stage 8, loaded true, local player resolved in the same frame; registry dump 3 |
| 20:39:03.489 | *(exit to menu)* Scene loaded true → false |
| 20:39:03.872 | `OnClearScene`, flag **false** (stage still 8) |
| 20:39:06.548 | Stage 2 |
| 20:39:06.591 | `OnLoadScene`: `Frontend/MainMenu.entity` |
| 20:39:06.764 – 07.337 | Stages 5, 6, 7 |
| 20:39:07.416 | Stage 8, loaded true; local player resolved 1 ms later; registry dump 4 |
| 20:39:32.441 | Last line (a transform read). Process gone by 20:39:43. Debugger: "exited with code 0 (0x0)". |

Totals: 2 module attaches, 1 detach (the discovery unload), 1 construction, 3 `OnLoadScene`, 3 `OnClearScene`, 4 resolutions, 4 registry dumps, 213 transform reads, 4 `WARN` (one per registry dump, below). No callback fired twice for one event.

## Stage results

| Stage | Result | Basis |
|---|---|---|
| R1 process and module initialization | ✅ | Load, construct, `Init`, `OnEngineInitialized` as designed; SDK log: "Mod hitmen successfully loaded"; stable at the menu for 12.8 minutes |
| R2 first mission load | ✅ | Clear/load pair, monotonic stages, same-frame resolution, complete dump, transform reads tracking movement |
| R3 mission restart | ✅ | One clear, coherent reload, state reacquired, dump sane, reads resumed, nothing duplicated |
| R4 shutdown | ✅ | Normal quit, exit code 0. No Hitmen shutdown line exists to observe (below). |

Before R2 the registry finding below was put to the operator as a possible abort ("obviously invalid player/registry pointers"); the decision was to proceed, because every pointer the probe used was valid and the anomaly is in the SDK's model.

## Findings

### F1. The SDK's `TArray` model of `ZPlayerRegistry` at `0x390` is wrong on this build

All four dumps show the same three words at `0x390`:

| Offset | Value | As `TArray` (current SDK) |
|---|---|---|
| `0x390` | `0x14313db10` = registry + `0x50` = `&m_aPlayerData[0]` | begin |
| `0x398` | `0x0` | end |
| `0x3A0` | `0x4000000000000101` | allocation end |

As a `TArray` this has a null end and a non-pointer allocation end, and `size()` evaluates to 88,686,269,559,082,738. The probe's plausibility check caught it, logged a `WARN`, and did not walk it.

The values fit the two older readings instead: a pointer to the local player's slot (2023, `m_pLocalPlayer`), or a two-entry pointer array whose second entry is null (2024, `m_pPlayerData[2]`), followed by a non-pointer word. **This reverses the direction of experiment 3's H7 note**, which treated the `TArray` as the current truth and the older fields as earlier guesses at it. On `3.280.0.0` the older readings describe the memory better. What `0x3A0` holds is unknown.

Consequence outside Hitmen: `ModSDK::GetLocalPlayer` loops `i < m_PlayerData.size()`. It returns correctly here only because entry 0 has no `m_pNetPlayer`, so the loop stops on its first iteration. With a net player in slot 0 it would walk far past the registry. This is upstream SDK code, present in the M0 baseline; it was not changed.

### F2. A mission restart does not go through `LoadScene`

Restart produced `OnClearScene` and then stages 5 → 8 with no `OnLoadScene`. Anything keyed only on the load hook misses restarts. The 2023 design (reset in `OnClearScene`, poll readiness per frame) is the one that works; the reliable "scene is playing" signal is the stage reaching 8 together with `m_bSceneLoaded`.

### F3. The `ClearScene` flag behaves like "for reload", not "fully unload"

`true` on restart in place; `false` when changing scenes (menu → Paris and Paris → menu). One sample of each, so this is a hypothesis, but it matches the parameter's 2023 name `forReload` (`3e2ee83c`) better than its current name `bFullyUnloadScene` (`13ae7b83`).

### F4. `m_LoadingStage` at `0x178` is real

It only ever took values in `0..8` and moved in enum order on all four loads. Observed sequences at frame granularity: scene change `8 → 0 → 2 → 5 → 6 → 7 → 8`; restart `8 → 0 → 5 → 6 → 7 → 8`; exit to menu `8 → 2 → 5 → 6 → 7 → 8`. Stages 1, 3 and 4 were never seen, which may only mean no frame update ran during them. The "unverified offset" label in the log text is now out of date.

### F5. A local player exists in the main menu

`SDK()->GetLocalPlayer()` resolved in `MainMenu.entity` (5 bricks), at a fixed position, and slot 0's `hitman entity` matched it. "Local player resolved" therefore does not mean "in a mission". The menu's Hitman had the same addresses before and after the Paris session.

### F6. Resolution timing

In Paris (both loads) and on return to the menu, the local player was available on the first frame the scene reported loaded. Only at boot did it lag (260 ms), and there the probe's first frame already saw `m_bSceneLoaded` true at stage 5, unlike every later load where it turned true only at stage 8. Hypothesis: at boot the flag was left set by the boot scene that SkipIntro replaces.

### F7. Player registry contents (single player)

- The registry is a fixed object (`0x14313dac0`, inside the executable's image range) for the whole session.
- Slot 0: player id 0, `is local player` true, no RakNet replica, no net player, `connected` false, character id all zeros. In a mission, `outfit id` is set (`874C4C48-0A8B-49E9-883E-49FC5F1FB051`) and the session id string is `<decimal>-<guid>`. `hitman entity` always equals the SDK's local player entity.
- Slots 1 to 3: player id -1, `flags 0xA0` = `FFFFFFFF`, no entity, empty strings. Their `is local player` byte is also **true**, so that annotation does not distinguish the local player.
- All slots: `flags 0x18` = `40000000`, `flags 0x40` = 5, `flags 0x44` = 1 (the last two match upstream's "always 5", "always 1").
- **Across restart:** 104 of 105 dump lines identical. Only slot 0's session id changed, so it identifies a mission attempt. The Hitman pointers were the same values before and after; whether it is the same object or a reused address is not known.
- **Back at the menu:** slot 0 kept the mission's outfit id and last session id; only the entity pointers reverted.

### F8. Transform reads

213 reads, no faults. In Paris the position moved 10 to 12 units per 5 s in x/y with z steady near -1.53 while the operator ran, and stayed constant while standing still. The first two samples after the restart equalled the first two of the first load exactly, so the mission start is deterministic. The vertical axis is z. Gaps longer than 5 s occur only across scene transitions, where the observer does not run.

### F9. Shutdown is not observable from inside the DLL

No `OnClearScene`, no destructor line and no `module detaching: process is terminating` line at quit; the last line is an ordinary transform read. `ExitProcess` would have delivered `DLL_PROCESS_DETACH`, so the game ends by terminating its own process without loader teardown, with exit code 0. This explains M0's F3 (the SDK destructor never runs). Any state a native adapter must hand off at exit has to be flushed continuously or on an earlier signal.

### F10. Nothing unexpected was written or opened

- `mods.ini` was not modified by the run. `Retail` gained and changed nothing beyond the two installed changes. The game root's `ZHMModLoader.log` was rewritten, as on every launch.
- `hitmen.brick` was never loaded (4 checks), so no second Hitman existed. `NullHitmenTransport` was never called (no "Networking is disabled" line).
- The SDK log again stopped at exactly 24,576 bytes, confirming M0's F3 on a second run.

## Predicted versus observed

| Prediction (experiment 3 / probe doc) | Observed |
|---|---|
| Two module attaches with an unload between | ✅ |
| Detours are pass-through; first `OnLoadScene` proves the hook is live | ✅ SDK log also shows both hooks installed |
| `OnEngineInitialized` precedes scene callbacks | ❌ The first `OnLoadScene` came 448 ms **before** it. The SDK treats the engine as initialized once a scene resource is set. |
| `m_PlayerData` is a `TArray`; open question whether it views the inline slots | ❌ Not a `TArray` on this build (F1) |
| Mission restart: `OnClearScene`, then a new `OnLoadScene` | ❌ No `OnLoadScene` (F2) |
| `m_LoadingStage` offset unverified | ✅ Holds (F4) |
| Local player resolves some time after the scene loads, in missions | Partly: same frame in missions; also resolves in the menu (F5, F6) |
| Shutdown lines may be missing | ✅ None appear (F9) |
| Upstream registry annotations may not hold | Mixed (F7) |

## Cleanup and restoration

Performed after the process exited and the logs were copied out.

- `Retail\mods\Hitmen.dll` deleted; `Retail\mods.ini` restored from the pre-flight backup.
- Verified: all 107 files under `Retail` match their pre-flight SHA-256 hashes; the listing is identical to pre-flight (and so to M0's post-run listing); `mods.ini` hash `b90b4c5e…` as before; no Hitmen file anywhere under the game root; nothing new in `Runtime`.
- One difference from the pre-run state, outside `Retail`: `ZHMModLoader.log` in the game root now holds this run's SDK log instead of M0's. It is rewritten on every launch; M0's copy is preserved in `glacier-m0\run1\`.
- The game has not been launched since, so "M0 behavior" is restored as a file state, not re-demonstrated by a run.

## Debugger notes

From the operator's Visual Studio Output window (supplied in full after the run) and their report that nothing broke.

- **Attach works on Visual Studio 17.14.** The debugger was attached at about 20:28:55Z (the first `[Hitmen]` line in the Output window is 20:28:56), 5.5 minutes before the Paris load, and stayed attached through the Paris load, the restart, the return to the menu and exit. Attaching did not disturb the game.
- **Symbols:** `Hitmen.dll` (from `Retail\mods\`) reported "Symbols loaded", as did `ZHMModSDK.dll`, `dinput8.dll`, `ResourceLib_HM3.dll` and the four M0 mods. Almost every other module reported "Symbol loading disabled by Include/Exclude setting", which is a Visual Studio symbol-filter setting on this machine, not a failure.
- **Debugger channel:** every durable-log line also appeared in the Output window with the `[Hitmen]` prefix, in step with the file.
- **No stops:** no breakpoint was hit and the Output window contains no "Exception thrown" line, so there was no first-chance exception anywhere in the process while attached. `HitmenLog::LogFault` and the two `NullHitmenTransport` tripwires were never reached.
- **Exit:** about 135 thread-exit lines with code 0, then `The program '[77076] HITMAN3.exe' has exited with code 0 (0x0).` No module unload lines precede it, consistent with F9.
- **As predicted, the discovery load and unload were not visible**, because the debugger was attached after startup. Only the durable log shows them.

Other things the Output window shows, none of them from Hitmen:

- **The engine announces scene transitions itself.** A line `HandleTransition: <scene resource>` appears about one second before each transition, including the mission restart (`HandleTransition: …/Paris/_Scene_FashionShowHit_01.entity` at about 20:36:40), which never reached `LoadScene`. The string does not occur in the SDK or any mod, so it comes from the game.
- **FreeCam** logs "Creating free camera." after every clear, restart included.
- **Network-related modules are loaded by the process** (`ws2_32`, `winhttp`, `mswsock`, `dnsapi`, `schannel`) and there are threads named `sentry-http`, `sentry-logs` and `sentry-metrics`. These belong to the game, Steam, the Editor mod's WebSocket server and the SDK's Sentry client (`crash_reporting = true` in `mods.ini`), all present in the M0 baseline. `Hitmen.dll` imports none of them and its transport was never called. The run therefore gives no evidence of network activity by Hitmen, but it cannot by itself prove a negative for the process as a whole.
- A Windows network-location component (`nlansp_c.dll`) logs "No such service is known" roughly once a minute. It predates the Paris load and continues unchanged; unrelated.

Not done in this run: launching under the debugger (only attach was used), stepping, and dump capture (nothing to capture).

## Hypotheses raised by the run

1. `0x390` in `ZPlayerRegistry` is a pointer to the local player's slot (or the first of two player pointers), not an array header. Testable by reading it in a state with two players, which is out of scope for now.
2. The `ClearScene` flag means "reloading the same scene" (F3). Testable with more transitions: restart from a save, changing missions without visiting the menu.
3. "Mission playing" is best defined as stage 8 with `m_bSceneLoaded`, plus scene type `mission` from the last `OnLoadScene`. That would be the first semantic event for M1, and it must survive restarts that never call `LoadScene`.
4. Slot 0's session id is a per-attempt identifier and could key a mission-attempt event.
5. Stages 1, 3 and 4 happen while no frame update runs. Testable only by observing from somewhere other than the frame update.
6. The game always exits by self-termination (F9). Testable by quitting from inside a mission and via Alt+F4.
7. Whatever emits the engine's `HandleTransition` debug line sees every transition, restarts included. If it can be located, it may be a better lifecycle signal than `LoadScene`. Untested; it would need a new hook, which is outside this probe.

None of these is acted on. No second Hitman, state mutation, transport or further runtime experiment follows from this document without a new decision.

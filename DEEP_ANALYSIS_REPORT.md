# Deep Dump Analysis: Logic-State Sources vs Render-State Sources

## Scope and evidence standard

Inputs: `C:\Users\ranki\Desktop\smoba_UNITYDUMP\dump.cs`, the 115 Assembly fragments, `script.json`, `UnityFramework`, and the current `Tweak.xm`/`ESP.mm`. No device execution or disassembly toolchain was available in this workspace, so method bodies and runtime lifetimes remain explicitly separated from dump-level facts.

## VERIFIED from dump and symbol metadata

### 1. Actor logic has registries above the renderer

`Scripts.GameCore.dll.cs:149295-149311` defines `ActorManager` with:

```text
actorList            0x08   DictionaryView
updatableActorList   0x10   DictionaryView
HeroActors           0x18   TinyValueList
OrganActors          0x20   TinyValueList
TowerActors          0x28   TinyValueList
SoldierActors        0x30   TinyValueList
DragonActors         0x38   TinyValueList
VehicleActors        0x40   TinyValueList
BuffMonsterActors    0x48   TinyValueList
CallMonsterActors    0x58   TinyValueList
CallActors           0x60   TinyValueList
cacheList            0x70   DictionaryView
```

The same class declares `GetActor(UInt32 actorID, Boolean bAlwaysFind)`, `GetActorProxy`, `DeactiveActor`, `DestroyActor`, `DestroyCacheActor`, `LateUpdate`, `Interpolation`, `UpdateLogic`, `RefreshAllActorPositionByMovementDataCache`, `OnActorEnterView`, `OnActorLeaveView`, and `DestroyActorAndCacheActor` (`:149324-149417`). This is direct evidence of a logical actor registry, an update registry, and a deactivated/cache lifecycle distinct from Unity renderer objects.

### 2. The position-bearing object is not only a Transform

`ActorLinker` (`Scripts.GameCore.dll.cs:148307-148380`) contains:

- `MoveControl` at `0x420`;
- `PositionRecords` at `0x478`;
- `ObjID` at `0x4AC`;
- `position` at `0x4C4`;
- `lastPositionXZChangedFrameNum` at `0x4E0`;
- `BornPos` at `0x4F8`;
- visibility/camera bytes `0x505..0x509` and `0x520..0x522`;
- renderer/mesh handles at `0x528`, `0x698`, and Transform at `0x708`.

The field ordering is strong evidence that `position`, movement state, and visibility state live in the logic object before the mesh/Transform portion. `myTransform` and `ActorMesh` should therefore be treated as presentation consumers, not authoritative coordinates.

### 3. Movement state has explicit interpolation fields and update methods

`MoveComponent` (`Scripts.GameCore.dll.cs:139690-139749`) declares `curPosition` `0x28`, `remotePosition` `0x34`, `moveForward` `0x40`, and `UpdateLogic`/`LateUpdate`, plus managed getters `get_CurPosition` RVA `0x2EBC9BC` and `get_RemotePosition` RVA `0x2EBC9A4`. This is the best candidate for a continuously updated logical position while the actor remains in the game-core update set.

### 4. Display data is a game-core movement feed

`DisplayInfoData` (`Scripts.Base.dll.cs:43694-43710`) has `actorID`, `forward`, `position`, `groundY`, `rotation`, and `parentObjID`. `SGW` declares:

```text
GetDisplayData()                         RVA 0x159EBF4
GetDisplayData_Count()                   RVA 0x159ED30
GetDisplayPredictData()                  RVA 0x159F4E4
GetDebugMovementData(actorID, callback)  RVA 0x159F8EC
```

`ActorManager.RefreshAllActorPositionByMovementDataCache(DisplayInfoData*, UInt32)` is RVA `0x2FA3C14` (`Scripts.GameCore.dll.cs:149381-149417`). `script.json` independently records the SGW addresses as decimal `22670324`, `22670640`, and `22673644`, and records `ActorManager.RefreshAllActorPositionByMovementDataCache` at decimal `49953812`. This strongly supports a logic-frame path:

```text
SGW/core movement buffer -> ActorManager refresh -> ActorLinker.position
```

It is decoupled from mesh visibility, but the dump does not prove how long the buffer is retained or whether it contains every off-view actor.

### 5. Predict data is a specialized, not universal, source

`DisplayInfoPredictData` (`Scripts.Base.dll.cs:43660-43686`) contains `actorID`, `shadowPosition`, `lerpDiff`, `lerpToLogic`, `useShadow`, and `predictState`. `BattlePredictSystem.RefreshDisplayPredictData` exists (`Scripts.GameCore.dll.cs:91338`). This is a prediction/shadow source for the prediction subsystem, not a general entity registry; use it only for the actor and mode for which prediction is active.

### 6. Evidence for culling affecting presentation state

`ActorLinker` has separate `_logicVisible`, `_meshVisible`, `_inCamera`, `_rendererInCamera`, `_positionInCamera`, `_checkPositionInCamera`, `_clipped`, `ActorMesh`, and `myTransform` fields. The dump also contains camera/FOW methods such as `NtfActorCheckIsRealInCamera`, `NtfActorInCamera`, `NtfActorPositionInCamera`, `SetActorVisibility`, `CheckVisibility`, and `OnActorVisibilityChange`. This supports the observed statement that camera/FOW/renderer state can change independently of logical coordinates.

## CANDIDATE stability ranking

| Source | Layer | Expected update | Off-view behavior | Version risk | Assessment |
|---|---|---:|---|---|---|
| `MoveControl.get_CurPosition` | game logic interpolation | per logic/update tick | valid while actor remains in `updatableActorList` | method RVA/signature | primary |
| `ActorLinker.position` / `Position` | game logic state | movement refresh tick | may freeze after deactivation | field layout | primary fallback |
| `actorList` / `GetActor(id, bAlwaysFind)` | logical registry | lifecycle driven | may return cached/deactivated handle | custom `DictionaryView` ABI | identity/lifecycle anchor |
| `cacheList` + `DestroyCacheActor` lifecycle | pooled logic objects | enter/leave/recover | retained only until cache destruction | custom container ABI | useful for short TTL |
| `SGW.GetDisplayData` + count | core movement buffer | likely logic-frame batch | likely bounded to current/last frame | native ABI and buffer lifetime | secondary, verify first |
| `SGW.GetDebugMovementData` | per-actor debug callback | on request/callback | unknown; may require eligible actor | delegate ABI | targeted diagnostic fallback |
| `PositionRecords` | actor history | only if populated by build | history may stop on deactivation | managed list ABI | diagnostic/history, not primary |
| `DisplayInfoPredictData` | prediction subsystem | prediction ticks | only predicted actor/mode | mode-dependent | specialized |
| `myTransform` / `ActorMesh` / bones | renderer/presentation | render/LOD ticks | can be unloaded/culled | Unity object lifetime | reject as authority |

The strongest implementation is therefore logic-first: `actorID` from `ActorLinker`/registry, coordinate from `CurPosition` then `ActorLinker.position`, and display data only as a timestamped, exact-ID-matched reconciliation source.

## Current plugin assessment

The current code already follows the correct broad direction in `Tweak.xm:1076-1147` and `:2637-2675`: it probes movement fields first and uses display data only when the live actor position fails. However:

- `readDisplayCache` (`Tweak.xm:1201-1259`) directly calls the RVA functions and assumes a native pointer, `0x34` stride, and `0x00/0x10` fields. The struct declaration supports those offsets after removing value-type metadata bias, but the native return ABI and buffer lifetime remain unverified.
- `ActorManager.actorList`, `updatableActorList`, and `cacheList` are not yet used as the identity/lifecycle anchor; the current typed category lists can lose an actor on leave-view.
- `g_actorPositionRefs50` retains raw object pointers for the refresh pass. It has no generation, object-sequence, or actor-ID reuse guard.
- `projectWorldPosition` caches a camera object globally (`Tweak.xm:1273-1305`), while the logical sample and projection are performed in the same pass. A camera replacement or transient projection failure removes a valid logical sample.
- `ESP.mm:150-176` requires begin/commit pairing to release `g_entLock`; an exception or future early return can strand the lock.

## Verifiable implementation design

### Acquisition

Run on the Unity/game-core thread or a known safe callback. Resolve the current `ActorManager` provider each scene/session, then enumerate `actorList` or call `GetActor(actorID, bAlwaysFind)` for IDs observed through category lists/events. For every candidate, validate class, nonzero `ObjID`, and an object-sequence/generation value before reading fields.

### Position source policy

```text
1. MoveControl.get_CurPosition       (fresh logic interpolation)
2. ActorLinker.Position / 0x4C4      (logic state)
3. exact actorID match in DisplayInfoData (newer core-frame sample)
4. get_RemotePosition                (prediction/remote fallback, flagged)
5. last valid sample within bounded TTL (stale flag only)
```

Do not use `myTransform`, mesh bones, `_inCamera`, or renderer bounds to decide whether the coordinate is valid. Those fields are validity indicators for presentation, not the position source.

### Reconciliation

Maintain `actorID -> {world, source, sampleFrame/time, objectGeneration, stale}`. A display sample replaces a live sample only when its actor ID matches and its frame/timestamp is newer. On `OnActorLeaveView`, retain the last logical sample with `stale=true`; on `DestroyActorAndCacheActor` or ID/generation mismatch, expire it immediately. This avoids both frozen coordinates being mistaken for fresh data and ID reuse contaminating another entity.

### Projection/publishing

Project the reconciled world sample separately from acquisition. Refresh camera identity and viewport each frame or when the camera instance/instance ID changes. Reject nonfinite values, `z <= 0`, and points outside the actual viewport. Publish a generation-stamped immutable snapshot; drawing should never hold the acquisition lock or depend on a mesh object.

### Runtime verification sequence

For one visible and one off-view `BuffMonster`, record once per second:

```text
actorID, object generation/sequence
actorList/updatableActorList/cacheList membership
MoveControl, CurPosition, RemotePosition
ActorLinker.position, PositionRecords count/latest
SGW display count, matching display record, frame/timestamp if available
logic/mesh/inCamera/positionInCamera flags
camera identity, projection result
```

Acceptance criteria:

- `CurPosition` or `ActorLinker.position` continues to advance while the actor is logically active, regardless of renderer flags.
- A leave-view event changes presentation flags or list membership without silently changing `actorID`.
- A matching display record is newer than the previous sample and reproduces the same world coordinate within interpolation tolerance.
- Cache eviction or ID reuse expires the old sample rather than drawing it under a new actor.
- Projection failure leaves the logical sample intact and only marks the screen result invalid.

## UNRESOLVED

- Whether this build's `actorList`/`cacheList` retain off-view actors for the full desired TTL.
- Native ABI and ownership/lifetime of the `SGW` display buffer.
- Whether `GetDebugMovementData` is synchronous and view-independent.
- Whether `PositionRecords` is populated for all actor types or only selected movement modes.
- Exact device viewport adaptation and whether `WorldToScreenPointEx` is required.
- A successful rebuild and device trace; `build.log` still reports missing Theos `clang`/`clang++`.

# Runtime Entity/ESP Analysis

## Scope

This report covers the read-only Unity IL2CPP dump at `C:\Users\ranki\Desktop\smoba_UNITYDUMP` and the plugin sources in `C:\Users\ranki\Documents\userovo1`. It does not claim a successful device run; the current build log shows the configured Theos clang toolchain is missing.

## VERIFIED

- The dump identifies Unity `2022.3.5f1_7bdd7b0a2998` and an IL2CPP build.
- `ActorManager` exposes typed actor accessors/counts. The confirmed category order used by the plugin is `Hero`, `Organ`, `BuffMonster`, `Dragon`, `Soldier`.
- `ActorLinker` has `MoveControl` at `0x420`, `ObjID` at `0x4AC`, `position` at `0x4C4`, visibility bytes around `0x505..0x508`, and camera-position flags at `0x520..0x521`.
- `MoveComponent` has `curPosition` at `0x28` and `remotePosition` at `0x34`; the dump declares `get_CurPosition` and `get_RemotePosition`.
- `CameraSystem` and Unity `Camera.WorldToScreenPoint(Vector3)` are present in the dump.
- The plugin already uses a producer snapshot (`Tweak.xm`) and a locked consumer copy (`ESP.mm`). The relevant bridge is `Tweak.xm:2044-2730` and `ESP.mm:150-176,300-316`.
- The plugin's display-cache parser is explicitly based on native RVAs `0x159EBF4` and `0x159ED30`, record stride `0x34`, `actorID` at `0x00`, and position at `0x10` (`Tweak.xm:1176-1259`). These offsets are source-derived, not runtime-verified in the current workspace.

## CANDIDATE

The most reliable logical chain is:

```text
BattleSysMgr provider -> ActorManager -> typed ActorLinker
                       -> MoveControl/CurrPosition or ActorLinker.position
                       -> actorID keyed position cache
                       -> camera projection -> render snapshot
```

Use `MoveControl.get_CurPosition` as the primary live source, `get_RemotePosition` only as a prediction/fallback source, `ActorLinker.position` as the object-local fallback, and the SGW display buffer only when its `actorID` matches exactly. The current implementation follows most of this ordering in `readActorPositionWithMovement` (`Tweak.xm:1076-1147`) and `probeActorSnapshot50` (`Tweak.xm:2637-2675`).

## Instability Findings

1. **View lifecycle eviction.** `ActorManager` has enter/leave-view and cache-destruction paths in the dump. A typed accessor can therefore stop returning an actor when it leaves the renderer view. The current 30 Hz refresh (`Tweak.xm:2899-2949`) only refreshes references still present in `g_actorPositionRefs50`; it cannot recover an evicted object.

2. **Cache ABI is unverified.** `readDisplayCache` calls `g_sgwGetDisplayDataNative()` and `g_sgwGetDisplayCountNative()` directly (`Tweak.xm:1201-1224`). The dump provides method signatures, but not native body/ABI evidence. A wrong return ABI or a managed-wrapper return would produce plausible-looking yet unrelated memory. Treat `valid > 0` as a parse result, not proof of a valid world-position source.

3. **Projection context is sticky.** `g_projectionCamera` and `g_worldToScreenMethod` are cached globally (`Tweak.xm:1273-1305`). They are reset only around actor snapshot probes. Camera replacement, scene transition, or method/class reload can leave a non-null but stale camera object.

4. **Snapshot commit is exception-sensitive.** `espBeginEntitySnapshot` locks `g_entLock` and `espCommitEntitySnapshot` unlocks it (`ESP.mm:150-176`). Any exception or early return between those calls leaves the lock held and freezes all future drawing. The current callers have several `continue` paths but no RAII/`@try`-backed unlock guard around the whole transaction.

5. **Screen validation is incomplete.** `espAppendEntitySnapshot` accepts any finite non-negative `sx/sy` (`ESP.mm:156-164`) and does not compare against the current viewport. The renderer then trusts the supplied point (`ESP.mm:313-316`). A valid depth with a point outside the active safe area can be drawn as a disappearing or clipped entity.

6. **Identity is not carried to the renderer.** `EEnt` contains position and class strings but no `actorID` or source generation. This prevents the render layer from rejecting duplicate category entries, stale entries, or a cache point belonging to a previous object after ID reuse.

7. **Sampling and drawing are coupled.** `probeActorSnapshot50` performs IL2CPP invocation, position selection, projection, and snapshot construction in one pass (`Tweak.xm:2592-2727`). A transient camera/projection failure drops the entity even when its last known world position is still valid.

8. **Build cannot verify the patch.** `build.log` reports missing `/home/codespace/theos/toolchain/linux/iphone/bin/clang` and `clang++`; no compiled dylib or device log is evidence in this workspace.

## Recommended Implementation

Use a three-stage, generation-based pipeline:

1. **Acquire on the Unity/main thread.** Enumerate typed ActorManager lists. For each object, read `actorID`, team/type, and position using managed getters where available. Store `{actorID, object pointer, source, world, sampleTime, sourceGeneration}`. Never retain a raw object pointer beyond the current acquisition pass without revalidating its class and `ObjID`.

2. **Reconcile by actorID.** Keep a bounded map of the last two valid samples per actor ID. A display-cache sample may replace the world point only when `actorID` matches and its timestamp is newer. On leave-view, retain the last point for a short TTL and mark it `stale`; do not immediately delete it or fabricate a new point. Reject ID reuse when the class/type or source generation changes.

3. **Project and publish atomically.** Refresh the camera identity and viewport every frame or when the camera instance changes. Project the reconciled world points, apply `0 < z`, finite checks, and viewport bounds, then publish an immutable snapshot by swapping two buffers. The draw path reads one buffer without holding a lock. Include `actorID`, `stale`, `source`, and `generation` in the render entry.

Minimum data contract:

```text
EntitySample {
  uint32 actorID;
  Vec3 world;
  Vec3 screen;
  uint64 generation;
  double sampleTime;
  Source source;       // CurPosition, RemotePosition, ActorField, DisplayCache
  bool positionValid;
  bool screenValid;
  bool stale;
}
```

For the current codebase, the smallest safe patch is: add `actorID/source/generation` to `EEnt`; replace the begin/append/commit lock protocol with a scoped snapshot object whose destructor/unwind unlocks; add a viewport-bound check in `espAppendEntitySnapshot`; invalidate `g_projectionCamera` when `get_instanceID`/viewport changes; and make the display cache opt-in until a runtime probe proves the native return ABI.

## Verification Matrix

Run one controlled sample while a `BuffMonster` is visible, then after it leaves view. Log, for the same `actorID`, `MoveControl`, `CurPosition`, `RemotePosition`, `ActorLinker.position`, display-cache hit, camera flags, camera pointer, viewport, and projection result at 1 Hz. A stable implementation must show:

- `actorID` remains unchanged while the object is tracked.
- `CurPosition` or `ActorLinker.position` changes during motion while visible.
- After leave-view, either a matching display-cache sample advances or the reconciler marks the last point stale; it must not silently reuse an unrelated ID.
- Camera replacement causes a new projection context.
- A failed projection does not erase the last valid world sample.

The next runtime test should therefore be diagnostic-only; it should not enable the display-cache fallback globally until the log proves the expected `stride=0x34`, matching IDs, monotonic sample behavior, and correct native pointer range.

## UNRESOLVED

- Runtime addresses and ABI of `SGW.GetDisplayData`/`GetDisplayData_Count`.
- Runtime layout of the custom list wrappers and whether they preserve off-camera actors.
- Whether `WorldToScreenPointEx` is required for the device's safe-area scaling.
- Whether `GetDebugMovementData(actorID, ref DisplayInfoData)` can provide a view-independent source.
- Device build and runtime logs after the missing Theos toolchain is restored.

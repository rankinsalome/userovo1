# runtime-40.log Analysis

Source: `C:\Users\ranki\Downloads\runtime-40.log`  
Range: 2026-10-09 21:41:14 to 21:45:05 UTC  
Size: 751,443 bytes, 1,560 lines.

## VERIFIED

### Runtime initialization

- IL2CPP API resolution succeeded: `runtime_invoke=1 object_unbox=1 object_get_class=1 field=1 staticGet=1`.
- 115 assemblies were loaded and the actor/player/linker/camera/battle classes resolved.
- Camera and camera Transform calls returned valid objects; initial Transform position was `(0,1,-10)`.
- Sampling started twice during scene/loading transitions and stopped on background entry. The final line is `runtime paused reason=did-enter-background`.

### Logical actor data becomes available after loading

The first sample has zero actors. Later samples progress through `hero=3 organ=6`, then `hero=10 organ=24`, and eventually `buffMonster=4`. Across the nonempty phase there are 49 category reports, 41 of which report `buffMonster=4`.

At the populated phase, `actorList` count varies with the live match (examples: 101, 117, 114, 118, 113), while category lists report 10 heroes, 24 organs, 4 buff monsters, and varying soldier counts.

### Best-performing coordinate source in this run

The focused probes for IDs `123`, `128`, `129`, and `130` each have 93 samples:

| ID | fieldLive | logicalLive | `vis=0/0/0/0` | screen result |
|---:|---:|---:|---:|---:|
| 123 | 93/93 | 93/93 | 79 | 87/93 |
| 128 | 93/93 | 93/93 | 86 | 87/93 |
| 129 | 93/93 | 93/93 | 87 | 57/93 |
| 130 | 93/93 | 93/93 | 87 | 93/93 |

Representative evidence:

```text
focused source idx=0 id=123 ... fieldRead=1 fieldLive=1 field=(-24.52,0.00,2.63) logicalRead=1 logicalLive=1 ... vis=0/0/0/0 ... selected=actor ... screen=1
focused source idx=1 id=128 ... fieldRead=1 fieldLive=1 field=(24.52,0.00,-2.63) logicalRead=1 logicalLive=1 ... vis=0/0/0/0 ... selected=actor ... screen=1
```

This directly verifies that `ActorLinker.position` and the managed logical-position path remain readable and moving while all sampled visibility flags are false. It supports the original culling hypothesis, but shows that the logic-layer coordinate survives longer than the render state.

### MoveComponent is absent in this build/run

Every focused sample reports `move=0x0`, `curRead=0`, and `remoteRead=0`. The player-captain probe also reports `withMove=0`. Therefore `MoveControl.get_CurPosition` is not the usable primary source for this runtime state.

### DisplayData is structurally readable and useful as corroboration

The log records `display cache native resolved ... stride=0x34 actor=0x00 position=0x10`. There are 25 display-cache samples; each has `valid == count`, with observed counts from 20 to 74. Exact-ID display hits occur for focused actor 123 in 14 samples, actor 128 in 7, actor 129 in 7, and actor 130 in 6.

This verifies a working parser for this run, but not that the buffer is the authoritative source for all off-view actors. The live ActorLinker field is usually selected even when a display hit exists.

### Refresh and rendering behavior

- Position refresh reaches approximately 26.6-27.9 Hz during stable periods.
- Refresh `valid` varies substantially because screen projection succeeds or fails; examples include `refs=54 valid=64`, `refs=69 valid=65`, and `refs=73 valid=89`.
- There are 48 focused samples with `screen=0`, while logical position probes remain valid. This is a projection/viewport/depth issue, not a coordinate-read failure.
- `actor snapshot50 drawn` varies from 15 to 71, with average about 45.95. This is consistent with screen filtering and category composition changes.

## CANDIDATE conclusions

1. **Primary source for this version:** `ActorLinker.position` / managed `Position` or logical-position accessor. It is valid at roughly 93/93 focused samples even under `vis=0/0/0/0`.
2. **Renderer-independent status:** `_logicVisible`, actor ID, camp/player linkage, category membership, and game-core actor counts are more stable than mesh/Transform/bone state. The logs show actor counts and logical positions updating while render flags are zero.
3. **DisplayData role:** use as an exact-ID corroboration/fallback with freshness checks. Its count/stride parser is working in this capture, but the log lacks a frame sequence or monotonic timestamp proving retention semantics.
4. **Current visible failure:** screen projection is the dominant loss point. Coordinates remain valid while `WorldToScreenPoint` returns invalid depth or points outside the active viewport.

## UNRESOLVED / defects exposed by the log

- `actorList` `DictionaryView` reports valid counts and resolver methods, but every probe has `iterated=0`. The current boxed-enumerator invocation ABI is wrong or the enumerator is a value type being invoked incorrectly. Do not use this probe as evidence that `actorList` is empty.
- `MoveControl` being null may be a proxy/wrapper shape, an actor-type property, or an initialization mode. The capture does not prove that all actor types lack movement components.
- `stale=0` is expected from the current implementation: no TTL reconciler is active yet. The log does not test post-eviction retention.
- Player captain resolution finds 10 players but only 4 captain handles; those 4 have valid ActorLinker fields and no MoveComponent. The remaining six player records must not be treated as missing actors without checking their handle representation.
- The initial refresh line reports `rate=0.2Hz` because it is the first sample window; later stable rates are near 27 Hz.

## Actionable interpretation

For this build, keep the acquisition order as:

```text
ActorLinker.Position / logical accessor
-> exact actorID DisplayData match
-> bounded last sample marked stale
```

Do not promote `MoveControl` until a runtime sample shows a nonzero pointer and valid getter results. Fix the projection path separately: log camera instance/viewport, distinguish `z<=0` from out-of-viewport coordinates, and preserve a valid world sample when projection fails. Replace the `DictionaryView` enumerator probe with a typed `GetActor(actorID, bAlwaysFind)`/category-to-ID cross-check before treating it as a complete registry.

## Unified validation pass

`Tweak.xm` now performs a bounded same-frame comparison for the first eight
valid actors. Each record emits one `unified actor=...` line containing the
ActorLinker source, `LuaCallCs_Battle.GetActorWorldPos`, and exact-ID
`DisplayInfoData` values, followed by `selected=...`. The overlay labels the
selected ActorManager source as `[A]` and the DisplayData fallback as `[D]`.

The same pass logs whether `SGW.GetActorLogicPos`,
`SGW.GetDebugMovementData`, and `SGW.GetDisplayPredictData` resolve in the
current image. Resolution is only an ABI prerequisite; a non-null MethodInfo
is not treated as proof that callback invocation is safe.

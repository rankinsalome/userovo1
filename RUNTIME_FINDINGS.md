# Runtime Findings

## Confirmed

- The tweak enters the target process and resolves the IL2CPP API through `dlsym`.
- The main-thread dispatch path is active.
- `Scripts.GameCore.dll`, `Scripts.Base.dll`, and `UnityEngine.CoreModule.dll` are discoverable.
- Confirmed metadata/classes include `ActorManager`, `GamePlayerCenter`, `IActorLinker`, `Camera`, `BattleSysMgr`, and `CBattleSystem`.
- Native minimap projection has returned finite coordinates in prior logs:
  `CBattleSystem -> TheMinimapSys -> GetPositionInScreen(Vector3, 0) -> CheckMiniMapScreenPosValid(Vector2)`.
- The reference source uses `SGW.GetActorLogicPos(actorID, delegate)` and then reads `Player.captainLogicPos` before minimap projection.
- `ActorLinker.position`/`Transform.position` can become a parked placeholder after a target leaves the render view; this is not proof that the logical actor position stopped changing.
- The existing full observer path is not a reliable minimal test: it traverses actor/player/display/movement/callback paths and has coincided with in-match crashes.
- Puerts metadata exists in the dump (`Puerts.JsEnv`, `Puerts.PuertsDLL`, `IByteCodeLoader`), but no safe initialized `JsEnv` instance address or verified native invocation ABI is established.

## Not proven

- Reusing an already initialized `JsEnv` from native code.
- A working PDCODE/`socialbroker_lua64.bytes` compiler.
- Continuous off-screen logic-position responses in the current native observer.

## Minimal test contract

The reduced build must do only:

1. Wait for `UnityFramework` and IL2CPP metadata.
2. Resolve `ActorManager.GetInstance`, `GetRawHostPlayerActorId`, and `GetHeroActorByIndex`.
3. Locate the host actor and read its `ActorLinker.position` field through the confirmed getter.
4. Resolve and call the native minimap projection chain.
5. Log one bounded result per second.

It must not create a UI, draw ESP, change Fog, call logic callbacks, enumerate all actors, or write game state.
#mao
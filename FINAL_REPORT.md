# ESP 当前版本报告

## 已确认

- `ActorManager` 的分类计数链路可工作；日志中可见 `Hero`、`Organ`、`BuffMonster` 等计数。
- `ActorLinker` 对象、类型名、Transform/位置和 Camera 投影链路已能产生有效屏幕坐标。
- 普通模式继续使用已验证的分类对象链路，不再依赖未验证的显示缓存布局。
- UI 已收敛为两个按钮：透视模式和调试模式。
- 删除了旧 UI 对 `g_output` 的引用，避免面板打开后向已移除控件写入造成崩溃。
- `GetOrganActors` 补充枚举已保留；`GetBuffMonster` 主分类链路已保留。

## 高概率

- 小野怪已经被 `GetBuffMonsterCount` / `GetBuffMonsterByIndex` 计数链路发现，但仍需新版日志确认返回对象和位置是否有效。
- 视野外冻结的直接原因是投影/绘制过滤，而不是当前日志中的逻辑坐标读取。
- `SGW.GetDisplayData()` 是可用的按 actorID 匹配辅助源，但需用时间戳和位置变化确认其保留语义。

## 当前代码策略

- `DisplayInfoData` 按 native `actorID=0x00`、`position=0x10`、stride `0x34` 解析。
- `SGW.GetDisplayData()` / `GetDisplayData_Count()` 使用 dump 中的静态 RVA `0x159EBF4` / `0x159ED30`。
- native 返回地址和每条记录都经过可读性、actorID、坐标有效性检查；失败时不覆盖对象原始位置。
- ActorManager 的采集顺序为 `Hero -> Organ -> BuffMonster -> Dragon -> Soldier`。
- 只有 `actorID` 精确匹配时，显示缓存坐标才会替代 `ActorLinker` 位置。
- 有限但屏幕外的投影保留到 overlay，由边缘钳制逻辑绘制。

## 未确认

- 当前环境尚未重新编译运行，因此不能声称目标设备已最终修复。
- 尚未在目标设备确认 `SGW.GetActorLogicPos(actorID)` 的回调 ABI；dump 已确认该入口及其 `ActorLogicTransInfo` 结构。
- 尚未确认所有对象都进入 SGW display cache；需通过 actorID、更新时间和位置变化验证。

## 下一次运行应只观察

1. `position refresh` 中 `live` 是否持续高于 `screen`，并且 `screen` 失败时对象仍有有限世界坐标。
2. `[EDGE]` 对象是否出现，且位置随镜头/对象移动变化。
3. `GetActorWorldPos`、`GetActorLogicPos`、`DisplayInfoData` 三者的 actorID 和时间序列是否一致。
4. 视野切换前后，actorID 是否保持、位置更新时间是否连续。

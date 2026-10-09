# ESP 当前版本报告
1
## 已确认

- `ActorManager` 的分类计数链路可工作；日志中可见 `Hero`、`Organ`、`BuffMonster` 等计数。
- `ActorLinker` 对象、类型名、Transform/位置和 Camera 投影链路已能产生有效屏幕坐标。
- 普通模式继续使用已验证的分类对象链路，不再依赖未验证的显示缓存布局。
- UI 已收敛为两个按钮：透视模式和调试模式。
- 删除了旧 UI 对 `g_output` 的引用，避免面板打开后向已移除控件写入造成崩溃。
- `GetOrganActors` 补充枚举已保留；`GetBuffMonster` 主分类链路已保留。

## 高概率

- 小野怪已经被 `GetBuffMonsterCount` / `GetBuffMonsterByIndex` 计数链路发现，但仍需新版日志确认返回对象和位置是否有效。
- 视野外冻结的直接原因是 `ActorLinker.position` 在失去视野后停止刷新；要消除冻结，需要一个持续更新的运行时位置缓存。
- `SGW.GetDisplayData()` 可能就是该缓存来源，但其 native pointer 返回 ABI 和数组 stride 仍需要运行时日志验证。

## 当前代码策略

- 已纠正 value type 偏移约定：`DisplayInfoData` 按 native `actorID=0x00`、`position=0x10`、stride `0x34` 解析；dump 中显示的 `0x08` 是值类型字段基址偏移。
- `SGW.GetDisplayData()` / `GetDisplayData_Count()` 改为调用 dump 中的静态 RVA `0x159EBF4` / `0x159ED30`；移除了会把 `runtime_invoke` 返回值误解为 native 数组指针的路径。
- native 返回地址和每条记录都经过可读性、actorID、坐标有效性检查；失败时不覆盖对象原始位置，避免错误坐标污染普通模式。
- ActorManager 的采集顺序调整为 `Hero -> Organ -> BuffMonster -> Dragon -> Soldier`，普通模式的 50 个显示槽优先保留小野怪和 Boss。
- 调试模式先刷新全部已缓存 ActorLinker，再追加没有对应 ActorLinker 的 display-cache 记录，不再用 4~8 条 display-cache 记录替换完整实体列表。
- 只有 `actorID` 精确匹配时，显示缓存坐标才会替代 `ActorLinker` 位置。

## 未确认

- 当前环境尚未重新编译运行，因此不能声称小野怪已经最终修复。
- 尚未在目标设备确认修正后的 `DisplayInfoData` native 偏移与当前二进制完全一致；这一步必须通过新日志中的 `stride=0x34`、合理 ActorID 和匹配数量完成验证。
- 尚未确认所有小野怪都进入 SGW display cache；若 `BuffMonster` 仍只有分类对象而没有对应 actorID，需要继续沿 `GetDebugMovementData(actorID, callback)` 做按对象补充。

## 下一次运行应只观察

1. `display cache native resolved ... stride=0x34 actor=0x00 position=0x10` 是否出现。
2. `display cache sample count=... valid=...` 的 `valid` 是否大于 0。
3. `actor source=BuffMonster objects=... positionOK=... screenOK=...` 是否达到 `4/4/4`。
4. `actor snapshot50 composition` 是否出现 `BuffMonster[...]`。
5. 实体离开视野后，匹配 actorID 的 display-cache 坐标是否继续变化。


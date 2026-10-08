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
- 视野外冻结的直接原因是 `ActorLinker.position` 在失去视野后停止刷新；要消除冻结，需要一个持续更新的运行时位置缓存。
- `SGW.GetDisplayData()` 可能就是该缓存来源，但其 native pointer 返回 ABI 和数组 stride 仍需要运行时日志验证。

## 当前代码策略

- 显示缓存字段只按 dump 已确认的 `actorID=0x08`、`position=0x18` 解析，stride 仅保留对齐候选 `0x40/0x48/0x3C`。
- 候选布局评分不足时拒绝缓存，不覆盖对象原始位置，避免错误坐标污染普通模式。
- 只有 `actorID` 精确匹配时，显示缓存坐标才会替代 `ActorLinker` 位置。
- 调试模式可继续绘制已成功解析的缓存记录，用于确认小野怪和视野外对象是否存在于缓存。

## 未确认

- 当前环境尚未重新编译运行，因此不能声称小野怪已经最终修复。
- 尚未确认 `SGW.GetDisplayData()` 的 `runtime_invoke` 返回值是否是可直接解包的 native pointer。
- 尚未确认显示缓存 native stride；不得据此推导新的地址或 Offset。

## 下一次运行应只观察

1. `display cache layout=...` 是否出现，及其 `valid` 是否大于 0。
2. `actor supplemental itemType source=...` 是否出现 `BuffMonster` 对象。
3. `actor snapshot50 composition` 是否出现 `BuffMonster[...]`。
4. 实体离开视野后，`display cache sample` 中对应 actorID 的位置是否继续变化。


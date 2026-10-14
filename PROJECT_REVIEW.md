# 项目问题审查

审查对象：`C:\Users\ranki\Documents\userovo1`，HEAD `1d09963`，审查日期 2026-10-12。

## 结论

目前最大的工程问题是“实际构建目标、运行测试契约、综合实验代码”三者不一致。仓库默认 Theos 构建仅编译 `Tweak_minimal.mm`，而 `Tweak.xm`/`ESP.mm` 的复杂路径没有进入该产物；同时最小探针实际只执行三次，且启用不安全的固定偏移裸读。已有运行记录又明确指出 callback ABI 尚未设备验证、综合观察路径曾与局内崩溃同时出现。因此当前不能把仓库状态描述为一个已验证可运行的完整 tweak。

审查期间未修改项目源文件，也未在设备上运行代码。

## 高优先级

### 1. 构建目标与正在验证的源码不一致

`Makefile:8` 的 `gamehack_FILES` 只有 `Tweak_minimal.mm`。因此正常 `make package` 不会编译 `Tweak.xm` 或链接 `ESP.mm`；它们中的 callback、overlay 与 observer-only 分支不是该包的实现。反过来，`build.log` 显示此前一次构建正在预处理/编译 `Tweak.xm`，与当前 Makefile 不一致，说明日志来自另一份配置或较早构建状态，不能作为当前 Makefile 的成功/失败结论。

### 2. 最小探针不满足文档所写的持续观测契约

`RUNTIME_FINDINGS.md:25-31` 要求“每秒一个有界结果”。但 `Tweak_minimal.mm:203-214` 只安排立即、+1 秒、+2 秒三次调用；此后停止。发生较晚的 IL2CPP/战斗初始化时，探针可能在有效状态出现前结束。

此外，`Tweak_minimal.mm:141-149` 在第一次解析后无条件设置 `methodsResolved = YES`，即使类或方法仍为空。后续调用即使 image 已可用，也不会重试类/方法解析，可能永久停留在失败状态。

### 3. 最小探针的固定偏移读取没有地址保护

`Tweak_minimal.mm:114-117` 通过 `memcpy(object + offset)` 读取对象字段，没有地址映射检查、对象大小检查或异常边界；调用点在 `:164` 与 `:169` 直接使用固定偏移 `0x4AC` 和 `0x4C4`。若对象布局与目标版本不符或候选对象已失效，这条路径可能崩溃或产生伪数据。对比之下，`Tweak.xm:1233-1239` 使用 `vm_read_overwrite` 检查读取结果，但当前 Makefile 并未构建那套读取实现。

### 4. callback 桥接仍是未验证实验，却在综合采样路径中开启

当前源码 `Tweak.xm:1674` 将 `g_logicCallbackLiveEnabled` 设为 `YES`，且 `appendActorPositionSnapshot` 在 `:3037-3043` 对英雄调用 callback 路径。虽然 `g_logicCallbackDiagnosticOnly` 在 `:1675` 为 `YES`，使响应不会被用作最终位置，但 callback 请求仍会发出，见 `:1991-2004`。这与 `RUNTIME_FINDINGS.md:14-18` 所述“未建立安全初始化 JsEnv/已验证调用 ABI”和 `:31` 所述最小契约“不得调用 logic callbacks”矛盾。

源码 `:1668-1670` 还保留“设备侧证明前禁用实验桥接”的注释，和当前 YES 状态互相冲突。`verification/VERIFICATION.txt` 也明确记载没有设备验证或 Theos 编译。这里首先是配置/证据一致性问题；实际 ABI 是否错误尚未被本轮验证。

## 中优先级

### 5. 综合路径的 30 Hz 工作全部排入主线程

`Tweak.xm:4037` 把位置刷新间隔设为 `1/30` 秒；`scheduleNextEntityPositionRefresh` 在 `:4085-4091` 将刷新 dispatch 到 main queue。一次刷新会进入 `refreshActorSnapshotPositions`（`:3128-3163`），读取 display cache、遍历 actor refs、执行 IL2CPP 调用及投影。若单次成本超过约 33 ms，会与 Unity/UI 主线程争用。文档已记录完整 observer 曾与局内崩溃同时出现，但因果关系尚无证据，不能把它定性为已证实崩溃原因。

### 6. “observer-only”并不等价于整个二进制无写入/无 UI

`Tweak.xm:111` 将 `kRuntimeObserverOnly` 固定为 YES，构造入口因此跳过 `showHUD`（`:4352-4358`）；但 HUD 的 Fog 按钮在 `:552-568` 会执行 fog 修改测试，`ESP.mm:265-275` 的 `installMapHack` 会写入静态字段，`Tweak.xm:145-152` 也有可改写对象字段的可见性 hook。当前搜索没有发现 `installMapHack()` 的调用点，因此不应声称它在本构建中已可达；但若以后把 observer flag 改为 NO 或重新接通 HUD/ESP，这些旧功能会进入行为面。模式标记目前只是调用路径上的开关，不是对整个目标文件的写入/副作用隔离证明。

### 7. 固定 RVA/对象偏移对目标版本敏感

综合实现使用固定 `DATA_SLOT_STATICFIELDS`、字段偏移（例如 `0x4AC`、`0x460`）和多个硬编码布局偏移。`Tweak.xm:342-350` 对静态字段地址做了部分范围检查，但这不能证明 RVA 与结构布局匹配当前游戏构建。`ESP.mm:257-263` 的同名 `getStaticFields` 检查更少。目标版本更新后，错误布局可能造成读取失真或越界写；目前没有版本指纹/偏移校验将这些常量与特定二进制绑定。

### 8. 日志上限的轮转判断允许超限

`Tweak.xm:41-46` 只有当写入前现有文件已经大于 8 MiB 才轮转，因此文件可在一次追加后超过上限；两个日志目标都采用该逻辑。`runtimeLog` 与 `runtimeLogOnce` 的全局状态没有锁（`:72-95`），如果未来有多个线程同时写，文件大小检查、轮转与追加不是原子操作。当前调度大部分在主线程，故并发风险取决于其他调用线程，未确认实际触发。

## 构建与交付

- `.github/workflows/build.yml` 在 macOS runner 克隆 Theos 并安装 `ldid`，但未显式安装/校验 iOS SDK 或选定 SDK 版本；Makefile 使用 `iphone:clang:latest:14.0`。CI 是否可构建需要由 workflow 实跑确认，本轮没有执行 CI。
- 当前 Windows 主机未检测到 `make`、`clang`、`xcrun`；已有 `build.log` 的 Linux Theos clang 路径不存在。故本轮不能确认任一源码目标可编译。
- `gamehack.plist` 过滤 bundle `com.tencent.smoba`；`Makefile` 的 `INSTALL_TARGET_PROCESSES=smoba` 使用进程名。它们需要与设备实际 bundle/process 名及 rootless/bootstrap 安装目标分别核对，当前文件本身没有给出这些核验结果。
- 包元信息/界面文案与 observer-only 最小探针的行为可能不匹配；应在交付前统一功能描述、构建目标和实际启用功能。

## 建议的验证顺序

1. 选定唯一目标：最小探针或综合观察器，并让 Makefile、CI、文档与产物源码保持一致。
2. 对 minimal probe 去除未经校验的裸固定偏移访问；用已确认的字段 getter/运行时元数据，并在对象、字段与读取长度验证失败时停止。
3. 解析失败时保持可重试；持续探测应由明确的生命周期/停止条件驱动，并满足每秒一次的文档契约。
4. 在 callback ABI 经设备验证前，将 callback 调用从常规 observer 刷新中断开；把“请求被发出”与“结果用于位置”作为两项独立指标记录。
5. 对综合路径先降低采样成本/频率并测量每次刷新耗时，避免未量化的 30 Hz 主线程工作。
6. 在匹配的 macOS/Theos/iOS SDK 环境执行干净构建；随后在可控测试目标执行 smoke test，记录 bundle/process、解析结果、异常计数、主线程耗时和日志体积。

## 证据与限制

本报告依据 `Makefile`、`.github/workflows/build.yml`、`Tweak_minimal.mm`、`Tweak.xm`、`ESP.mm`、`RUNTIME_FINDINGS.md`、`build.log` 和 `verification/VERIFICATION.txt` 静态核对。结论区分了源码可直接确认的问题与待设备/CI验证的风险；未把文档中引用的行为当作本轮指令执行。

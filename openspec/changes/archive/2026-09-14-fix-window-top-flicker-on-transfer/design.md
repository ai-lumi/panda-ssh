# Design: fix-window-top-flicker-on-transfer

## Context

现状观察链（macOS 主窗口）：

- `PandaSSHApp` 以 `@StateObject` 持有全局 `TransferStore`（`PandaSSHApp.swift:9`），App body 订阅其变更；
- `WorkspaceView.swift:9` 与 `SidebarView.swift:58` 以 `@EnvironmentObject` 订阅同一实例；
- `TransferStore.optimalPollingInterval()` 在有活动任务时返回 0.2s，`tick()` 每拍重算 `liveSpeed`/`totalSpeed`/`estimatedTimeRemaining` 并写入 `@Published tasks`（`TransferStore.swift:566,704-719,939-968`）；
- `HostListView` 在 `WorkspaceView` 根部 background 挂 `MainWindowChrome`（NSViewRepresentable），其 `updateNSView` 每次更新都 async 调 `configure(window)` 重设 `titleVisibility`/`titlebarAppearsTransparent`/`styleMask`/`toolbar`/红绿灯按钮状态（`MainWindowChrome.swift:151-153,190-214`）；
- `MacosWorkspaceChromeMetrics` 的两个 `@Published` 属性在 `update(window:)`/`updateSidebarWidth(_:)` 中被无条件赋值，`@Published` 不做相等性去重，形成「发布 → 重渲染 → updateNSView → configure → 再赋值发布」自激环（`MainWindowChrome.swift:114-136`）；
- `MacosUnifiedSplitHost.Controller.apply` 每次更新都无条件 `splitView.setPosition`（`MainWindowChrome.swift:102-109`）。

上传期间三者叠加：5Hz 失效流点燃整树重渲染，每拍都触发 AppKit 窗口属性重写与分栏强制布局，顶部视觉上闪烁。无任务时轮询停止，但自激环仍以低频空转。

约束：

- 双端共享源码，SwiftUI 订阅关系无法用 XCTest 直接断言（依赖渲染管线私有行为）；项目要求 TDD 与全中文注释。
- 实测约束：`@EnvironmentObject`/`@Environment` 在 View `init()` 中不可访问（环境值在 body 评估前未传播到 self），而 `SftpTabView.session` 是 `@StateObject`，init 时必须把 transfers 传给 `SftpSessionStore(host:transfers:)`（`SftpTabView.swift:15,48-53`）——因此 `SftpTabView` 不能自读环境值，只能由父视图读取后以 init 参数传入。
- `SftpSessionStore` 经 Combine 订阅 `transfers.$tasks`（`observeCompletedTransfers()`，传输完成后 debounced 刷新文件列表），不依赖 `SftpTabView.body` 重评估，注入方式变化不影响该链路；其 init 签名被 `FilePaneNavigatorTests` 直接构造，不改。
- 独立传输窗口（`Window(TransferWindow.title, ...)`）是另一个 Window scene，不共享主窗口环境；App 层以 `let` 常量持有 transfers 后，该窗口直接参数引用。

## Goals / Non-Goals

**Goals:**

- 进行中任务的 5Hz 状态发布只引起传输相关视图重渲染（传输页/任务行/侧栏角标）；
- 消灭 chrome 度量自激环与无条件窗口属性重写，静止窗口不再产生自发性渲染；
- 传输页进度条平滑度、SFTP 完成自动刷新、独立传输窗口行为完全不变；
- 每个修复点独立可回退。

**Non-Goals:**

- 不改 `TransferStore` 轮询频率/发布节流（用户可感知的进度刷新节奏保持现状）；
- 不移除 `configure` 尾部的 async 重复块（既有 AppKit 时序 workaround，去重后其 `metrics.update` 已无环）；
- 不为 SwiftUI 订阅拓扑写渲染级单测（以编译期类型约束 + 既有套件回归 + 手动验证代替）。

## Decisions

### 决策 1：`TransferStore` 注入改为「非订阅 EnvironmentKey」

**选择**：自定义 `EnvironmentKey`（`\.transferStore`，值为 `TransferStore` 引用）替代 `.environmentObject(transfers)`；App 侧持有方式从 `@StateObject` 改为 init 中创建的 `let` 常量。

**理由**：`@StateObject`/`@EnvironmentObject` 都会建立订阅关系，是 5Hz 失效的两个入口；EnvironmentKey 存纯引用、不订阅，恰好表达「需要拿到实例但不关心其变更」的语义。App init 只执行一次，`let` 持有的生命周期语义与 `@StateObject` 等价（与 App 同生命周期）。

**备选**：
- 保留 `@StateObject` 但把 `WindowGroup` 内容抽出为不观察 store 的子视图——治标，依赖层级重构且未来任何人再在 App body 读一次 store 就复发；
- `TransferStore` 拆分为「任务列表 ObservableObject」+「派生速度 ObservableObject」两层——架构改动大，且速度字段与任务同生命周期，拆分后仍需同步机制，超出本次修复必要范围。
- 「`TransferPageView` 改 `@EnvironmentObject` 自取 + 新增路由视图吸收 5Hz 重评估」（替代提案 `fix-workspace-chrome-flicker-on-transfer` 的路线，已废弃并入本提案）——`TransferPageView` 改 env 后，独立传输窗口是另一 Window scene、环境不共享，必须补注入且漏注入为运行时 crash；该路线还保留 App `@StateObject` 与 Sidebar 两个 5Hz 入口、未触及 metrics 自激环，覆盖不足。本提案吸收其实测约束（init 内环境值不可访问）与手动验证清单。

**消费方式**：需要实时刷新的叶子视图（`TransferPageView`/传输行）继续以 `@ObservedObject var store: TransferStore` 参数接收（现状不变，本来就是正确姿势）；仅取引用的中间视图（`WorkspaceView`）改读 `@Environment(\.transferStore)`，读取后仍以 init 参数向下传给 `SftpTabView`——环境值在 View `init()` 内不可访问，`SftpTabView` 的 `@StateObject session` 初始化链必须依赖参数注入（见 Context 约束）。`SftpSessionStore` 经构造注入不受影响。

### 决策 2：侧栏传输角标隔离为小子视图

**选择**：`SidebarView` 移除 `@EnvironmentObject transfers`；310 行的 `badgeCount: transfers.activeCount` 改由一个只读 `@Environment(\.transferStore)` + `@ObservedObject`（或直接接收 activeCount 的小视图）的私有小组件渲染。

**理由**：角标是侧栏树中唯一消费传输状态的点，隔离后 5Hz 失效被压缩到该小组件（每次重算的 body 只有数字/红点）；侧栏树（分组、主机列表、搜索）不再重渲染。小组件读环境值取得引用再用 `@ObservedObject` 包装，保证只订阅自己。

**备选**：让 `AppModel` 聚合 `activeCount`——引入跨对象状态同步，两处事实源，得不偿失。

### 决策 3：chrome 度量赋值前相等性去重

**选择**：`update(window:)` 与 `updateSidebarWidth(_:)` 中 `guard 新值 != 当前值`，值不变不赋值。

**理由**：`@Published` 的 `willSet` 不做相等性检查是 Combine 的既定行为，去重是消灭自激环的最小改动；同时是可 TDD 的纯逻辑（对 `objectWillChange` 发布次数计数断言）。双端影响：该类为 `#if os(macOS)` 专属，iPadOS 不涉及。

**备选**：把度量改为非 `@Published` 存储 + 显式变更回调——改动面更大且失去 SwiftUI 声明式绑定，无额外收益。

### 决策 4：分栏 `setPosition` 幂等化（低优先级，可选）

**选择**：`Controller` 记录上次应用的侧栏宽度，`abs(新值 - 旧值) > 0.5` 才调用 `setPosition`。

**理由**：决策 1-3 落地后该路径只在合法失效时执行，此项是防御性加固，防止未来其他高频源再次点燃。阈值 0.5pt 与 `UnifiedWorkspaceTabStrip.scroll` 的位移守卫一致。

**备选**：不加——可接受，但用户拖动侧栏时每拍重设同值仍可能引起 NSSplitView 微抖，加上无风险。

### 决策 5：修复不涉及 spec 既有需求的 MODIFIED

两个 delta 均为 ADDED 需求：`transfers` 的「传输轮询按需启动」既有需求与本次修复方向一致（实现回归 spec），无需修改；`workspace` 既有需求均不涉及 chrome 配置的幂等性。

## 修复点总表

| 文件 | 问题 | 改法 | 改后影响 |
|---|---|---|---|
| `PandaSSHApp.swift` | `@StateObject transfers` 使 App body 订阅 5Hz 发布，整个窗口树随任务进度重渲染 | init 中改为普通 `let` 常量，经 `\.transferStore` 环境值注入（不触发 App body 失效） | 上传期间 App 层不再重算；任务生命周期语义不变 |
| `WorkspaceView.swift` | `@EnvironmentObject transfers` 导致顶部 chrome、分栏宿主随 5Hz 整体重算 | 改为 `@Environment(\.transferStore)` 读取纯引用（不订阅），仅在向传输页/SFTP 标签页传参处使用 | 顶部闪烁主源消失；终端/SFTP/空态视图上传期间静默 |
| `SidebarView.swift` | 整视图为传输入口角标一处观察整个 TransferStore，侧栏树 5Hz 重渲染 | 观察下沉到只渲染角标的小子视图（`@ObservedObject`） | 角标仍随任务起止实时变化，侧栏其余部分不再重绘 |
| `MainWindowChrome.swift`（MacosWorkspaceChromeMetrics） | `update(window:)`/`updateSidebarWidth` 对 `@Published` 无条件赋值，形成「发布→重渲染→再发布」自激环，常驻空转渲染 | 赋值前做相等性比较，值不变不发布 | 无任务空转时主线程持续空转渲染消失；上传时叠加风暴的一个源被消灭 |
| `MainWindowChrome.swift`（MacosUnifiedSplitHost.apply，可选） | 每次 SwiftUI 更新无条件 `splitView.setPosition`，强制 NSSplitView 反复布局 | 记录上次应用宽度，差异超 0.5pt 才设置 | 分栏不再每次失效都触发布局；防御性加固 |

## Risks / Trade-offs

- [某些视图隐式依赖 5Hz 全树重渲染来刷新非传输内容] → 全量 grep 已确认订阅 `TransferStore` 的视图仅 3 处（App/WorkspaceView/SidebarView）+ 传输面板叶子；既有 Swift 测试套件与手动验证清单兜底。
- [Preview 漏注入新 EnvironmentKey，传输页显示为空] → 属编译期/肉眼可见的失败模式；tasks 中明确逐个更新约 7 处 Preview 注入点。
- [badge 隔离后角标更新滞后] → 小子视图仍 `@ObservedObject` 订阅同一实例，`activeCount` 变化即时生效，无滞后。
- [metrics 去重掩盖真实几何变化] → 去重仅比较浮点相等；真实变化（窗口 resize、全屏）必然产生不同值，正常发布。
- [SwiftUI 渲染拓扑无自动化测试] → 编译期类型约束（移除 `@EnvironmentObject` 后无法误用）+ 回归测试 + Time Profiler/手动验证（200ms 周期调用消失、空闲 CPU 下降）。
- [`SftpTabView` 误改为自读环境值导致 init 阶段 crash] → 设计上保持其 init 参数签名不变，由 `WorkspaceView` 读取环境值后传参；`ViewCoverageTests` 中 `SftpTabView(tab:host:transfers:)` 既有构造用例兜底。

## Migration Plan

实施顺序（每步独立提交、可单独回退）：

1. metrics 相等性去重（含新增 XCTest，先红后绿）→ 验证空闲空转渲染消失；
2. `TransferStore` 环境值注入改造（App/WorkspaceView/SidebarView + Preview 注入点）→ 验证上传期间顶部无闪烁；
3. 分栏 `setPosition` 幂等化（可选，含阈值判定纯函数测试）。

回滚：任一步出问题，revert 对应提交即可，步骤间无数据迁移、无持久化格式变更。

## Open Questions

（无）

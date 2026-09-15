# Proposal: fix-window-top-flicker-on-transfer

## Why

有传输任务运行期间，macOS 主窗口顶部（页签栏/标题栏区域）持续闪烁，且无任务空转时主线程存在持续的无效渲染。根因是 `TransferStore` 以 5Hz 高频发布 `@Published tasks`（速度/剩余时间每拍都变），被 `PandaSSHApp`（`@StateObject`）、`WorkspaceView` 与 `SidebarView`（`@EnvironmentObject`）整树订阅，导致整个主窗口以 5Hz 重渲染；叠加 `MacosWorkspaceChromeMetrics` 对 `@Published` 属性无条件赋值形成的「发布 → 重渲染 → 再发布」自激环，`MainWindowChrome` 在每次 SwiftUI 更新时都反复重设窗口标题栏属性与红绿灯按钮状态，视觉上表现为顶部闪烁。

## What Changes

- `PandaSSHApp` 中 `TransferStore` 由 `@StateObject` 改为 init 中创建的普通常量，经自定义 `EnvironmentKey`（`\.transferStore`，存引用不订阅）注入，App body 不再订阅传输状态。
- `WorkspaceView` 移除 `@EnvironmentObject transfers` 整视图观察，改为从环境值读取纯引用，仅在向下传参（传输页、SFTP 标签页）处使用。
- `SidebarView` 移除整视图观察，传输角标（badgeCount）隔离到只渲染角标的小子视图中观察。
- `MacosWorkspaceChromeMetrics.update(window:)` 与 `updateSidebarWidth(_:)` 赋值前做相等性去重，值不变不发布，消灭自激渲染环。
- `MacosUnifiedSplitHost.apply` 记录上次应用的侧栏宽度，差异超过阈值（0.5pt）才调用 `splitView.setPosition`，实现幂等（防御性加固，低优先级）。

视图与 store 的传参签名保持不变：`SftpTabView` 的 `@StateObject session` 初始化链依赖 init 参数注入 transfers（环境值在 View `init()` 内不可访问，实测会 crash），由 `WorkspaceView` 读取环境值后向下传参；`SftpSessionStore` 经 Combine 订阅 `transfers.$tasks` 的文件列表刷新链路不受影响。

不修改任何业务逻辑（传输调度、FFI 轮询、速度计算）与用户可见功能行为；仅修正 SwiftUI 观察关系与 AppKit 窗口属性写入的条件。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `transfers`: 新增需求「传输进度更新的渲染范围」——进行中任务的进度刷新 SHALL 仅重渲染传输相关视图（传输页面/任务行、侧栏传输角标），MUST NOT 触发主窗口 chrome、侧栏主机树、终端/SFTP 标签页等无关视图的重渲染或视觉闪烁。现有「传输轮询按需启动」需求不受影响。
- `workspace`: 新增需求「主窗口 chrome 配置幂等」——窗口 chrome 属性（标题栏样式、红绿灯按钮、分栏位置）SHALL 仅在其有效输入变化时重新配置；几何度量值未变化时 MUST NOT 重新发布变更通知。

## Impact

- **代码**：`apple/PandaSSH/PandaSSHApp.swift`、`apple/PandaSSH/Workspace/WorkspaceView.swift`、`apple/PandaSSH/SidebarView.swift`、`apple/PandaSSH/MainWindowChrome.swift`；新增 `EnvironmentKey` 定义（并入 `TransferStore.swift`）；约 7 处 Preview 注入点同步更新；`SftpTabView`/`TransferPageView`/`SftpSessionStore` 签名与生命周期不变。
- **测试**：新增 `MacosWorkspaceChromeMetricsTests`（相等性去重的正常/意外输入/边界三类场景）；既有 Swift 测试套件全量回归——`ViewCoverageTests`/`AppModelSelectionTests`/`FilePaneNavigatorTests` 因视图签名不变无需调整。
- **依赖/API**：无新增第三方依赖；无 FFI 变更；`TransferStore` 对外接口不变（`TransferPageView`/`SftpTabView` 仍以参数取得同一实例）。
- **macOS**：消除上传期间顶部闪烁、无任务空转时的持续主线程渲染；红绿灯、全屏、分栏拖动行为不变。
- **iPadOS**：`SidebarView` badge 隔离改动双端共享（iPadOS 侧栏同样受益于传输角标精确刷新），顶部页签栏（`UnifiedWorkspaceTabStrip`，位于导航栏 principal 位置）也不再被 5Hz tick 触发重评估；`MacosWorkspaceChromeMetrics`/`MacosUnifiedSplitHost` 为 `#if os(macOS)` 专属，iPadOS 不受影响。

## Non-goals

- 不修改 `TransferStore` 的轮询频率与发布节流（传输页进度条平滑度保持现状，且 spec 已允许任务列表变化即更新）。
- 不修改 `MainWindowChrome.configure` 尾部的 async 重复块（疑似针对 AppKit 时序问题的既有 workaround，去重后其第二次 `metrics.update` 已不再产生环；贸然移除有回归风险）。
- 不改动 `UnifiedWorkspaceTabStrip` 的 preference/scrollTo 反馈环（已有 0.5pt 位移守卫，观察链修复后不再被 5Hz 触发）。
- 不涉及 Rust 侧（panda-core/panda-ffi）任何改动。
- 不为 SwiftUI 订阅关系建立自动化单测（依赖 SwiftUI 私有渲染管线，靠编译期类型约束与手动验证兜底）。

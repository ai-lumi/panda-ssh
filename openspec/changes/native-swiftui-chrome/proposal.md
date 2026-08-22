## Why

当前 macOS 主窗口采用 `NSTitlebarAccessoryViewController` 将自定义工具栏挂载到标题栏，实现侧栏按钮与页签栏的顶部对齐。该方案引入 AppKit 依赖，增加复杂度，且与纯 SwiftUI 的声明式理念不符。为了降低维护成本、避免 KVO/通知导致的崩溃风险，并统一 macOS 与 iPadOS 的 UI 架构，需要将主窗口框架改为原生 SwiftUI 布局，完全移除 titlebar accessory 方案。

## What Changes

- **移除** `MainWindowChrome.swift` 与 `WorkspaceToolbar.swift`，废弃 `NSTitlebarAccessoryViewController` 挂载方案。
- **重构** `SidebarView`（macOS）：在侧边栏顶部（红绿灯避让区）添加工具栏，放置「添加主机」「新建分组」按钮。
- **重构** `WorkspaceView`（macOS）：在内容区顶部内嵌自定义页签栏，页签栏最左侧放置「隐藏/显示侧边栏」按钮；页签栏与侧边栏顶部工具栏在同一水平线，视觉对齐。
- **保留并复用** 现有的 `WorkspaceTabBar`、`WorkspaceTabButton`、`FlowLayout`、`WorkspaceToolbarViewModel` 等组件，将其从 titlebar accessory 上下文迁移到普通 SwiftUI 视图上下文。
- **保持** iPadOS 布局不变：继续使用 `NavigationSplitView` + 底部页签栏（iOS body），不受本次变更影响。
- **保持** 设置页面中的「标签页溢出模式」设置及预览不变。

## Non-goals

- 不改变页签栏的溢出行为（滚动/扩展）逻辑，仅调整布局载体。
- 不改变 iPadOS 的任何 UI 结构。
- 不新增或修改 Rust 核心/FFI 行为。
- 不改变设置页面中溢出模式预览的实现。

## Capabilities

### New Capabilities

（无新增能力，本次为 UI 架构重构）

### Modified Capabilities

- `workspace`：主窗口工具栏精简（已完成）的基础上，进一步将工具栏从 titlebar accessory 下沉为 SwiftUI 原生视图；页签栏的显隐、位置、对齐方式由 accessory 驱动改为 `NavigationSplitView` detail 区内部驱动。该变更不改变页签栏的功能性需求（打开/关闭/切换/溢出模式/右键菜单/二次确认等），仅改变实现布局。

## Impact

- **Swift 源码**：`apple/PandaSSH/MainWindowChrome.swift`（删除）、`apple/PandaSSH/Workspace/WorkspaceToolbar.swift`（删除）、`apple/PandaSSH/HostListView.swift`（移除 `.background(MainWindowChrome(...))`）、`apple/PandaSSH/SidebarView.swift`（macOS 顶部加工具栏）、`apple/PandaSSH/Workspace/WorkspaceView.swift`（macOS body 内嵌 tabBar）。
- **Xcode 工程**：`apple/project.yml` 中移除已删除文件的引用（如仍保留）。
- **测试**：`WorkspaceToolbarViewModel` 的逻辑不变，现有 Swift 测试继续有效；需补充布局变更后的 UI 行为验证（如侧栏隐藏时页签栏左侧避让）。
- **双端影响**：仅 macOS；iPadOS 无影响。

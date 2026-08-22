## Context

当前 macOS 主窗口通过 `MainWindowChrome`（`NSViewRepresentable`）在窗口挂载后异步配置 `NSTitlebarAccessoryViewController`，将 `WorkspaceToolbar` 作为 titlebar accessory 插入。该方案存在以下问题：

1. **AppKit 耦合**：`MainWindowChrome` 与 `WorkspaceToolbar` 依赖 `NSWindow`、`NSTitlebarAccessoryViewController`、`NSHostingView` 等 AppKit API，与 SwiftUI 声明式架构割裂。
2. **生命周期脆弱**：旧方案曾使用 `WindowAccessor`（KVO 监听 `window` 属性）导致崩溃；当前方案改为 `viewDidMoveToWindow` + `DispatchQueue.main.async` 仍属异步补丁。
3. **布局复杂**：`WorkspaceToolbar` 需通过 `SidebarWidthPreferenceKey` 读取侧栏实际宽度，动态计算左侧占位区宽度，逻辑分散在 `SidebarView`、`AppModel`、`WorkspaceToolbar` 三地。
4. **与 iPadOS 不统一**：iPadOS 的页签栏直接内嵌在 `WorkspaceView` 中，macOS 却走 accessory 路径，两端维护成本翻倍。

`PandaSSHApp` 已设置 `.windowStyle(.hiddenTitleBar)`，窗口标题栏文字已隐藏；`MainWindowChrome` 额外设置了 `.fullSizeContentView`，使内容区延伸至窗口顶部。保留 `.hiddenTitleBar` 并移除 accessory 后，SwiftUI 视图天然占据窗口顶部，页签栏可直接在 `NavigationSplitView` 的 detail 区顶部渲染。

## Goals / Non-Goals

**Goals:**
- 完全移除 `MainWindowChrome.swift` 与 `WorkspaceToolbar.swift`，消除 AppKit titlebar accessory 依赖。
- macOS 主窗口顶部框架（侧栏工具栏 + 内容区页签栏）全部由 SwiftUI 原生视图实现。
- 页签栏与侧栏顶部工具栏视觉对齐（同一水平线）。
- 复用现有 `WorkspaceTabBar`、`WorkspaceTabButton`、`FlowLayout`、`WorkspaceToolbarViewModel`，最小化新代码。
- iPadOS 布局零改动。

**Non-Goals:**
- 不改变页签栏的功能逻辑（溢出模式、滚动、扩展、右键菜单、关闭确认等）。
- 不修改设置页面的溢出模式预览。
- 不调整 iPadOS 的 `NavigationSplitView` 或页签栏位置。
- 不引入新的外部依赖。

## Decisions

### 1. 保留 `.windowStyle(.hiddenTitleBar)`，移除 `.fullSizeContentView` 与 accessory

- **Rationale**：`.hiddenTitleBar` 已足够隐藏标题栏文字；内容区在 SwiftUI 中通过正常布局即可延伸到顶部。`fullSizeContentView` 是 `MainWindowChrome` 为了 accessory 能覆盖全宽而加的，移除后 SwiftUI 自动处理 safe area。
- **Alternative**：改为 `.windowStyle(.plain)` 并手动处理顶部 padding，会重新引入标题栏文字，与「标题栏不出现 App 名称」的历史需求冲突。

### 2. `SidebarView` 顶部添加 macOS 专属工具栏

- **Rationale**：侧栏顶部需要放置「添加主机」「新建分组」按钮。在 `SidebarView` 的 `VStack` 最上方插入一个 `HStack`（条件编译 `#if os(macOS)`），高度约 38pt，与红绿灯区域视觉对齐。
- **Alternative**：在 `HostListView` 层用 `ZStack` 叠加一个顶部工具栏跨_sidebar + detail_全宽，但会打破 `NavigationSplitView` 的拖动分割线语义，且与 iPadOS 结构差异更大。

### 3. `WorkspaceView` macOS body 内嵌 `tabBar`

- **Rationale**：macOS 之前走 accessory 所以 `macOSBody` 里没有 `tabBar`；现在改为和 iPadOS 一样在 `WorkspaceView` 内部放置 `tabBar`。`macOSBody` 的 `NavigationSplitView` detail 区用 `VStack(spacing: 0) { tabBar; Divider(); content }`。
- **Alternative**：继续使用 accessory 但简化 accessory 内容，放弃——用户明确要求不用 accessory。

### 4. 红绿灯避让：侧栏隐藏时页签栏左侧留空

- **Rationale**：当侧栏隐藏（`columnVisibility == .detailOnly`）时，`NavigationSplitView` 的 detail 区占据全宽，页签栏最左侧的「显示侧栏」按钮若直接贴边会与红绿灯重叠。在 `tabBar` 最左侧的 `sidebarToggleButton` 前加一个条件性的 `Color.clear` 占位，宽度约 78pt（红绿灯标准宽度），仅在侧栏隐藏时生效。
- **Alternative**：在 `WindowGroup` 层面设置 `.toolbar { ... }` 用 SwiftUI 原生工具栏，但 `.hiddenTitleBar` 下原生 toolbar 行为不稳定，且难以精确对齐红绿灯。

### 5. `WorkspaceTabBar` 直接嵌入，不复用 `WorkspaceToolbar`

- **Rationale**：`WorkspaceTabBar` 已经封装了滚动/扩展模式、`WorkspaceTabButton` 渲染、`WorkspaceToolbarViewModel` 滚动计算。移除 `WorkspaceToolbar` 后，将 `WorkspaceTabBar` 直接放进 `WorkspaceView.tabBar` 的 `ScrollView`/`HStack` 中即可。
- **注意**：`WorkspaceTabBar` 目前被 `#if os(macOS)` 包裹，且内部包含 `sidebarToggleButton` 的左右滚动按钮逻辑。需要把 `sidebarToggleButton` 从 `WorkspaceTabBar` 中提取到 `WorkspaceView.tabBar` 中，因为 `sidebarToggleButton` 不属于页签栏本身，而是内容区框架的一部分。

### 6. 删除文件清单

- `apple/PandaSSH/MainWindowChrome.swift`（完整删除）
- `apple/PandaSSH/Workspace/WorkspaceToolbar.swift`（完整删除）
- `apple/PandaSSH/HostListView.swift` 中移除 `.background(MainWindowChrome(toolbar: WorkspaceToolbar()))`

## Risks / Trade-offs

- **[Risk] 红绿灯避让区宽度在不同 macOS 版本/主题下不一致** → **Mitigation**：使用系统标准安全区域或固定 78pt（当前 `WorkspaceToolbar` 已用此值且运行稳定）。若未来 Apple 改变红绿灯布局，可改为读取 `NSWindow` 的 `trafficLightButtons` 框架，但这会重新引入 AppKit 依赖；当前先保持固定值。
- **[Risk] `NavigationSplitView` 在 hiddenTitleBar 下顶部 safe area 行为变化** → **Mitigation**：在 macOS 14+ 上实测验证；若 SwiftUI 自动为 sidebar 顶部增加安全区域 padding，则 `SidebarView` 的工具栏 HStack 不需要额外 top padding；若未自动增加，则手动加 `.padding(.top, 12)` 避让。开发时通过 Preview 快速验证。
- **[Risk] 页签栏从 accessory 下沉到 detail 区后，窗口拖拽区域减少** → **Mitigation**：在 `SidebarView` 顶部工具栏的空白区域以及页签栏的空白区域均保留窗口拖拽能力。`WindowDragView` 可从 `WorkspaceToolbar` 迁移到 `SidebarView` 的顶部工具栏中（放在按钮后面的 `ZStack` 层），或直接在顶部工具栏的 `HStack` 中使用 `.allowsHitTesting(false)` 的 spacer 作为拖拽区。macOS 下任何 `NSView` 的透明区域默认可拖拽窗口，SwiftUI 中透明 `Color.clear` 在 `hiddenTitleBar` 模式下通常也能拖拽。

## Migration Plan

1. 在 feature 分支中删除 `MainWindowChrome.swift`、`WorkspaceToolbar.swift`。
2. 修改 `HostListView.swift` 移除 `.background(MainWindowChrome(...))`。
3. 修改 `SidebarView.swift` 添加 macOS 顶部工具栏。
4. 修改 `WorkspaceView.swift` macOS body 内嵌 `tabBar`，提取 `sidebarToggleButton` 到 `tabBar` 中。
5. 更新 `apple/project.yml` 移除已删除文件的引用（如果存在）。
6. 运行 macOS build 验证布局；运行 Swift 测试确保 `WorkspaceToolbarViewModel` 逻辑不受影响。
7. 合并到主分支。

Rollback：若发现严重布局问题，直接 revert 本次 commit，`MainWindowChrome` 与 `WorkspaceToolbar` 即恢复。

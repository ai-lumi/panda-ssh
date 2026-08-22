## Context

当前 macOS 主窗口实现来自 `macos-workspace-layout-refactor`：使用 `NavigationSplitView` + 全宽 `WorkspaceToolbar` 覆盖层模拟标题栏工具带。为了实现「工具带与红绿灯同一水平线」，代码把 `NavigationSplitView` 整体向下偏移 38pt，再把 `WorkspaceToolbar` 以 ZStack 覆盖层置顶。副作用是左侧边栏顶部出现 38pt 空白/圆角，未能真正延伸至窗口顶部；同时工具带左侧使用固定的 78pt 红绿灯避让区，未随侧栏显隐切换。

## Goals / Non-Goals

**Goals:**
- 左侧边栏延伸至窗口最顶部，顶部放置「添加主机」「添加分组」按钮。
- 工具带（侧栏切换 + 页签区）随侧栏宽度自适应，侧栏可见时从侧栏右边缘开始，侧栏隐藏时从红绿灯避让区之后开始。
- 侧栏可见时，红绿灯区域仍可拖拽窗口；侧栏隐藏时，内容区工具带保留可拖拽区域。
- 保持 iPadOS 布局不变。

**Non-Goals:**
- 不引入 AppKit titlebar accessory 或自定义 NSToolbar。
- 不修改页签按钮视觉样式、溢出模式、设置持久化逻辑。
- 不改动 Rust/FFI 层。

## Decisions

1. **移除 `NavigationSplitView` 的 38pt 偏移并延伸到顶部**
   - 让 `NavigationSplitView` 占据完整窗口高度；`SidebarView` 通过 `.ignoresSafeArea(.container, edges: .top)` 延伸到窗口最顶部，并通过 `.padding(.top, 38)` 让实际内容从自定义工具带下方开始。
   - 理由：侧栏因此真正顶到窗口上边缘；内容区也符合 spec 中「内容区延伸到窗口顶部」的要求。
   - 替代方案：把工具带移到 detail 列内部；已排除，因为 `NavigationSplitView` detail 列可能受系统分栏动画/安全区影响，覆盖层方案更稳定。

2. **工具带覆盖层统一承载顶部按钮**
   - `WorkspaceToolbar` 左侧区域宽度等于侧栏宽度（可见时）或红绿灯宽度（隐藏时），内部放置 78pt 红绿灯避让/拖拽区，其后紧跟「添加主机」「添加分组」按钮；右侧区域放置侧栏切换按钮与页签区。
   - 侧栏可见时，工具带背景与页签从侧栏右边缘开始；侧栏隐藏时，左侧仅保留 78pt 拖拽区，工具带从拖拽区之后开始。
   - 理由：把顶部所有控件放在同一层级，避免 `NavigationSplitView` sidebar 默认内边距导致按钮被居中或下移；同时保证工具带随侧栏宽度自动调整。

3. **侧栏内部不再放置顶部工具栏**
   - `SidebarView` 移除 macOS 顶部 `sidebarToolbar`，顶部直接显示搜索框；macOS 下 `treeView` 使用 `.listStyle(.plain)` 以避免 List 默认顶部内边距造成的额外空白。
   - 理由：顶部按钮已上移至 `WorkspaceToolbar`，侧栏内容需要紧贴工具带下方；`.listStyle(.plain)` 消除了 `.sidebar` 默认的标题栏内边距。

4. **继续使用 `SidebarWidthPreferenceKey` 上报侧栏宽度**
   - `WorkspaceToolbar` 仍通过 preference key 读取 `sidebarWidth`，用于动态调整左侧区域宽度。
   - 理由：现有机制工作良好，只需调整布局计算。

## Risks / Trade-offs

- **[Risk]** 侧栏动画期间工具带左侧区域可能与侧栏内容短暂错位。
  - **Mitigation**：对 `sidebarWidth` 变化使用与 `NavigationSplitView` 一致的动画时长（0.2s），减少视觉跳跃。

- **[Risk]** `WindowDragView` 在工具带左侧可能与「添加主机」按钮点击区域相邻，用户可能误触。
  - **Mitigation**：拖拽视图宽度严格限定为 78pt（红绿灯标准宽度），按钮从 78pt 之后开始，并保持 8pt 间距。

- **[Risk]** 移除 38pt 偏移并把按钮放到 `WorkspaceToolbar` 后，侧栏隐藏时「添加主机」「添加分组」入口不可见。
  - **Mitigation**：这两个按钮属于侧栏功能，侧栏隐藏时用户可通过侧栏切换按钮重新显示侧栏后再使用；符合侧栏显隐语义。

- **[Risk]** `SidebarView` 使用 `.listStyle(.plain)` 后，选中态/背景可能与 `.sidebar` 视觉不一致。
  - **Mitigation**：`NavigationSplitView` 的 sidebar 列仍会提供默认 sidebar 背景；`.plain` 的默认选中高亮与目标图一致，后续如需微调可再恢复样式。

## Migration Plan

1. 修改 `WorkspaceView.swift`：给 `SidebarView` 添加 `.ignoresSafeArea(.container, edges: .top)` 与 `.padding(.top, 38)`，让侧栏顶到窗口顶部且内容从工具带下方开始。
2. 修改 `WorkspaceToolbar.swift`：左侧区域与侧栏同宽，内部放置 78pt 红绿灯避让/拖拽区与「添加主机」「添加分组」按钮；右侧区域保留侧栏切换与页签。
3. 修改 `SidebarView.swift`：移除 macOS 顶部 `sidebarToolbar`；macOS 下 `treeView` 改为 `.listStyle(.plain)` 以消除默认顶部内边距；提取 `SidebarSheetKind` 供 `WorkspaceToolbar` 共享。
4. 更新/新增 XCTest 用例，验证侧栏显隐状态与工具带偏移。
5. 运行 `cargo test`（无 Rust 改动，作为回归）、`xcodegen`、`xcodebuild` macOS/iOS 双端构建与测试。

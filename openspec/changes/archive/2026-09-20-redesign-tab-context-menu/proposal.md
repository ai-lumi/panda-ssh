## Why

当前页签栏右键菜单在 `ui-workspace-optimization` 提案中以 SwiftUI `.contextMenu` 实现，视觉为纯文本列表——无图标、无快捷键提示、无分隔线分组。在后续 `refactor-macos-titlebar-tab-strip` 重构中，该 `.contextMenu` 未被迁移到新的 `UnifiedWorkspaceTabStrip`，导致功能完全丢失。

需要同时解决两个问题：
1. **功能恢复**：页签右键菜单（重连、关闭其他、关闭全部）必须回归。
2. **UI 重构**：参考 macOS 原生应用（Safari、Xcode、Finder）的标签页右键菜单样式，使用 NSMenu 直接构建，支持 SF Symbol 图标、键盘快捷键提示、分隔线分组。

## What Changes

- 新增 `TabContextMenuBuilder`：纯值逻辑，根据标签类型（terminal/sftp）和连接状态生成菜单条目与分组结构。
- macOS 端：在 `UnifiedWorkspaceTabStrip` 的每个标签按钮上叠加透明 AppKit 桥接视图，捕获 `rightMouseDown` 后构建并弹出 `NSMenu`。复用项目已有的 NSMenu 模式（与 `PandaTerminalView` 一致）。
- iPadOS 端：保留 SwiftUI `.contextMenu`（系统自动映射长按手势），菜单条目与 macOS 端一致。
- 菜单条目：「重连」（仅终端标签）、「关闭标签页」、「关闭其他标签页」、「关闭全部标签页」，以分隔线分为两组。
- 所有条目携带 SF Symbol 图标与键盘快捷键。

## Non-goals

- 不改变 `WorkspaceStore` 已有的 `closeOthers`/`closeAll`/`reconnectTerminal` 业务逻辑。
- 不改变终端内容区右键菜单（`PandaTerminalView` / `TerminalContextMenuBuilder`）。
- 不改变侧栏、SFTP 文件行的右键菜单。
- 不新增 FFI 或 Rust 侧变更。

## Capabilities

### New Capabilities

（无新增 capability，修改已有 workspace capability 的 UI 实现。）

### Modified Capabilities

- `workspace`：标签页右键上下文菜单的 macOS 端实现从 SwiftUI `.contextMenu` 改为 NSMenu 直接构建，新增图标、快捷键、分隔线分组；iPadOS 端保持 `.contextMenu` 但条目集对齐。

## Impact

- 影响 `UnifiedWorkspaceTabStrip.swift`（新增右键捕获与 NSMenu 弹出路径）。
- 新增 `TabContextMenuBuilder.swift`（纯值菜单构建逻辑，可单测）。
- 不影响 Rust、FFI、SSH/SFTP 会话生命周期。
- iPadOS 端仅条目集对齐，仍用 `.contextMenu`，无 AppKit 依赖。

## Why

当前 macOS 页签栏位于 detail 内容区，滚轮速度问题暴露出其滚动、视口和窗口 chrome 的职责分散；它也无法像 Chromium 一样进入标题栏。此前把完整页签栏作为系统工具栏 principal item 已被证明会与系统溢出布局竞争，因而需要一个不依附于普通 toolbar item 的独立标题栏容器方案。

## What Changes

- 新增 macOS 专用的标题栏页签栏容器：由 AppKit 管理其在窗口标题栏中的几何、窗口控件避让与事件宿主，由独立页签栏 UI 组件管理页签 viewport、溢出、滚动与活动页签显露。
- 将新的 macOS 标题栏页签栏设计为可独立测试、可独立装配的组件；它不得成为系统工具栏的 principal item。
- 保留现有 `WorkspaceTabBar`、`HorizontalWheelScrollView` 及 detail 内容区装配路径，不在本变更中删除或改名；新增明确的运行时选择路径，用于回退与视觉/交互对照。
- 新容器采用 Chromium 风格的输入策略：传统鼠标采用离散页签步距，精确滚动设备保持连续滚动；滚动、按钮、选中页签显露与窗口尺寸变化共享同一 viewport 状态。
- 保留系统工具栏，以维持 macOS 26 的侧栏标题栏融合与系统侧栏恢复入口；iPadOS 继续使用现有内容区页签栏。

## Non-goals

- 不删除现有内容区页签栏，不在本变更内完成旧实现的迁移或清理。
- 不改变 Rust 核心、FFI、SSH/SFTP 会话生命周期、页签数据模型或 iPadOS 页签栏行为。
- 不将新页签栏注册为普通 `NSToolbarItem` 或 principal toolbar item，也不以重建整个窗口为代价替换系统侧栏。

## Capabilities

### New Capabilities

- `macos-titlebar-tab-strip`: macOS 标题栏中的独立页签容器、viewport、输入策略、回退选择及窗口 chrome 协作规则。

### Modified Capabilities

- `workspace`: 修改 macOS 页签栏的默认装配位置，并保留可选择的旧内容区路径；iPadOS 要求保持不变。

## Impact

- 影响 macOS 的 `MainWindowChrome`、`WorkspaceView`、页签栏装配及 macOS XCTest；将新增 AppKit 宿主与独立页签栏组件，而不直接移除现有组件。
- 影响 `openspec/specs/workspace` 的主窗口工具栏与页签栏位置要求，并新增 macOS 标题栏页签栏能力规格。
- 不新增 Rust、FFI 或第三方依赖；iPadOS 不改变布局、交互或构建目标。

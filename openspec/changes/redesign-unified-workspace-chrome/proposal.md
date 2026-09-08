## Why

当前 macOS 页签栏受系统 toolbar 与内容区分层约束，难以同时获得稳定的独立滚动、优雅标题栏整合和最大工作空间。此前仅重构标题栏页签的方案不能可靠提供 detail 专属的原生 titlebar 区域，且会扩大 macOS/iPadOS 的实现分叉。

## What Changes

- 建立统一工作区 chrome：顶行同时承载侧栏操作区和独立页签栏，内容区只承载终端、SFTP 或空态，从而减少垂直 chrome 占用。
- macOS 使用透明原生标题栏与 full-size 内容承载自绘统一 chrome，保留红绿灯、窗口缩放、全屏和空白拖拽区，但不依赖普通系统 toolbar item 承载页签栏。
- 新增跨平台共享的页签 viewport、滚动输入和页签栏 UI；鼠标离散步进、触控板连续滚动、活动页签显露等规则由同一代码实现。
- 以共享 `WorkspaceShell` 表达顶部 chrome、侧栏和 detail；`#if os()` 仅允许出现在窗口安全区、拖拽、原生窗口控件与系统导航等平台适配边界。
- 保留现有内容区页签栏及其装配路径，作为新 shell 的对照与可回退实现，不在本变更删除旧代码。

## Non-goals

- 不改动 Rust、FFI、SSH/SFTP 连接或页签数据/会话生命周期。
- 不在本变更移除旧页签栏，也不为 macOS/iPadOS复制业务规则。
- 不复刻 Chromium 的私有窗口框架或牺牲原生 macOS 窗口控制行为。

## Capabilities

### New Capabilities

- `unified-workspace-chrome`: 跨 macOS/iPadOS 的统一工作区 chrome、共享页签容器与平台适配边界。

### Modified Capabilities

- `workspace`: 修改 macOS 工作区的窗口 chrome、页签栏位置与侧栏布局，同时保持 iPadOS 的功能和会话行为一致。

## Impact

- 影响 `WorkspaceView`、`MainWindowChrome`、侧栏装配、页签栏组件、macOS/iPadOS XCTest 和 workspace 规格。
- 现有 `refactor-macos-titlebar-tab-strip` 提案不再是实施依据；其内容只保留作问题与回退路径的参考。

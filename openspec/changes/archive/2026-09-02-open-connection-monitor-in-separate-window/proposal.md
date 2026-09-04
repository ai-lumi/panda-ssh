## Why

macOS 侧栏的“连接监控”当前直接切换 `sidebarPage`，会用监控页面覆盖主窗口工作区；这与现有“日志”入口的独立窗口交互不一致，也会打断用户正在查看的终端或 SFTP 上下文。

## What Changes

- macOS 注册独立的“连接监控”窗口，并让侧栏入口优先激活已有窗口，否则创建窗口。
- macOS 点击连接监控入口时不修改主窗口的侧栏页面、主机选择、标签页选择或工作区呈现状态。
- iPadOS 继续在主工作区内展示共享的连接监控页面，保持现有单窗口导航行为。
- 保持连接快照刷新、流量统计和手动健康检查行为不变。

## Non-goals

- 不修改 Rust 遥测、FFI 契约、Socket/SSH 状态模型或健康检查语义。
- 不为 iPadOS 引入多窗口会话管理。
- 不改变日志窗口的现有实现。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `workspace`：明确 macOS 连接监控入口使用独立窗口且不覆盖主工作区；iPadOS 保持工作区内页面。

## Impact

- SwiftUI Scene 注册：`PandaSSHApp.swift`。
- 侧栏入口与窗口激活：`SidebarView.swift`。
- 平台呈现策略及导航测试：`AppModelSelectionTests.swift`。
- `ConnectionMonitorView`、Rust core、FFI 和持久化格式均保持兼容。

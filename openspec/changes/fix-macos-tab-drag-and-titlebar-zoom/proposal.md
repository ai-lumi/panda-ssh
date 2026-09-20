## Why

macOS 自绘顶部 chrome 曾让窗口拖动视图覆盖页签命中区，导致 AppKit 窗口拖动与 SwiftUI 页签拖放竞争；即使当前代码已局部收窄该区域，也没有端到端验证来防止回归。自绘标题栏也没有保留系统标题栏的双击缩放行为。此外，分组内排序和取消拖放的状态更新与渲染数据源不一致，未达到既有页签分组与拖拽规格。

## What Changes

- 明确并验证 macOS 顶部 chrome 的互斥命中区：窗口拖动只在显式空白区生效，页签及其控件始终优先接收拖放和点击。
- 为 macOS 自绘标题栏空白区补回双击缩放/还原窗口行为；页签、关闭按钮和侧栏操作不触发窗口缩放。
- 修正页签拖放状态：分组内重排更新组内顺序，未分组重排更新未分组顺序；取消或失败的拖放恢复开始前顺序并清除拖拽反馈。
- 新增可重复的 macOS 事件验收与 XCTest 覆盖，替代仅断言 `mouseDownCanMoveWindow` 属性的测试。

## Non-goals

- 不改变 Rust 工作区、FFI 契约、SSH/SFTP 会话或页签持久化语义。
- 不新增跨窗口拖放、跨分组移动规则或 iPadOS 窗口缩放行为。
- 不改变 macOS 红绿灯、全屏、侧栏或页签视觉设计。

## Capabilities

### New Capabilities

- `tab-drag-reliability`: 定义跨平台页签拖放的提交、取消及分组内排序一致性。

### Modified Capabilities

- `unified-workspace-chrome`: 规定 macOS 自绘顶部 chrome 的窗口拖动命中边界及空白区双击缩放行为。

## Impact

- **Swift/macOS**：`MainWindowChrome`、`UnifiedWorkspaceChrome` 与 `UnifiedWorkspaceTabStrip` 的 AppKit/SwiftUI 事件桥接和拖放生命周期；`WorkspaceStore` 的排序状态更新。
- **测试**：新增纯值排序事务测试、AppKit 命中/双击桥接测试，以及受控的 macOS 手工验收；不访问真实主机或凭据。
- **平台**：macOS 增加自绘标题栏空白区双击缩放；iPadOS 继续复用排序/取消语义，但不引入窗口 chrome 分支。

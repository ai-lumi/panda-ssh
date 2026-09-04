## Why

连接监控页面每秒无条件发布整份快照，即使遥测未变化也触发 SwiftUI 布局计算；内容变化时还可能因动态卡片高度让正在浏览的页面跳动。监控应只在真实数据改变时更新，并保持连接卡片的视觉身份与布局稳定。

## What Changes

- 连接监控快照的自动刷新仅在可见遥测字段实际变化时发布到 SwiftUI。
- 刷新时按稳定连接 ID 合并记录，保留未变化卡片的视图身份；不再以整表替换作为常规更新机制。
- 为动态指标采用固定宽度与稳定布局，避免数值或状态变化导致卡片在横向与纵向布局之间切换。
- 保持后台快照读取、手动刷新和用户触发健康检查；不新增自动网络探测、重连或凭据访问。

## Non-goals

- 不将 Rust 遥测改造成跨 FFI 的推送事件流。
- 不改变连接健康检查的触发时机或语义。
- 不改变 macOS 与 iPadOS 的连接监控信息、隐私边界或业务规则。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `connection-monitoring`: 自动刷新仅在连接监控数据实质变化时更新页面，且更新不得造成既有连接卡片的非必要布局跳动。

## Impact

- 修改 `apple/PandaSSH/Workspace/ConnectionMonitorView.swift` 中的 Store 合并策略与卡片布局。
- 修改 `apple/PandaSSHTests/ConnectionMonitorStoreTests.swift`，先覆盖无变化刷新不发布、增量更新与布局策略。
- macOS 与 iPadOS 使用同一 SwiftUI Store 和视图，因此两端同步受益；不影响 Rust/FFI 公开接口或新增依赖。

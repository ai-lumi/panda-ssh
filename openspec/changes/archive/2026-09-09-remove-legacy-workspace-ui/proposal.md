## Why

用户于 2026-09-09 确认重构 UI 验收通过，并明确批准清理旧版及完成任务。原统一 chrome 提案要求后续单独评审删除旧路径，本提案记录此次批准范围。

## What Changes

- 删除 macOS/iPadOS 旧内容区页签栏、装配回退开关及专用辅助类型。
- 移除仅作用于旧栏的溢出模式设置；历史 UserDefaults 保留但不再读取或写入。
- 保留统一栏、会话与关闭确认，清理仅验证已退役路径的测试，保留新路径及会话回归。

## Capabilities

### Modified Capabilities
- `workspace`: 仅使用验收通过的统一页签栏。
- `unified-workspace-chrome`: 结束双路径迁移。
- `macos-workspace-toolbar`: 同步统一顶行及退役扩展显示行为。
- `settings-tab-bar`: 退役旧版溢出模式配置。

## Impact

Swift UI 装配、旧页签专用组件及测试、OpenSpec；Rust/FFI 与会话生命周期不变。

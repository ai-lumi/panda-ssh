## Why

审计发现若干 Swift 声明仅被单元测试调用，或仅作为已由新入口替代的兼容层存在。它们会让生产 target 携带测试专用 API，并使实际调用路径难以辨识。

## What Changes

- 移除没有生产调用点的测试专用实现或过时兼容入口，并同步移除只验证这些入口的测试。
- 对仍有价值的事件行为测试，改用测试 target 内的事件构造，而不在生产类型暴露测试钩子。
- 保持批量下载、文件删除、终端重连、页签排序和代码片段的现行用户行为与 FFI 契约。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

无；现有 `sftp-batch-transfer`、`workspace`、`tab-drag-sort`、`snippets` 等规格能力保持不变。

## Impact

- Swift：清理本地化辅助、测试 fake、过时工作区/SFTP/传输入口与生产测试钩子。
- XCTest：删除只验证被移除入口的测试，或将事件构造收回测试 target。
- macOS 与 iPadOS：共享业务行为、UI 和平台服务不变。
- 不修改 Rust core、FFI 导出、持久化格式或依赖。

## Non-goals

- 不移除当前规格要求的批量下载、SFTP 删除、终端重连、页签排序或代码片段能力。
- 不修复或绕过 SwiftTerm 构建插件授权；该问题作为独立验收前置条件处理。

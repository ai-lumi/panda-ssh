## Why

静态引用审计发现一组生产与测试均不可达的实现，以及未被调用的 FFI 适配层。保留它们会扩大维护面，并掩盖真实调用链。

## What Changes

- 删除已验证没有生产或测试引用的 Swift 辅助类型、私有函数和过时桥接封装。
- 删除未被调用的 Rust 日志快捷方法。
- 不删除仅由测试引用、但可能表示尚未接入界面的产品能力。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

无；这是不改变外部行为、数据格式或用户可见能力的内部清理。

## Impact

- Swift：清理 `PandaCoreBridge`、SFTP 会话、终端视图、本地文件选择器和工作区存储中的不可达代码。
- Rust：清理 `panda-core` 未使用的日志快捷方法。
- macOS 与 iPadOS：不改变 UI、平台服务、SSH/SFTP 或持久化行为。
- 不增加依赖，不改变 FFI 导出契约。

## Non-goals

- 不删除当前仅被单元测试引用的批量下载、右键删除、连接状态或页签排序能力。
- 不借此变更补接 UI，或调整现有规格化行为。

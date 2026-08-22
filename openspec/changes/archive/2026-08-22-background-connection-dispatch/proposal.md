## Why

SSH/SFTP 连接建立（`shellOpen`、`sftpHomeDir`）及传输预检（扫描、冲突检测、删除）是同步 FFI 调用（Rust 侧 `block_on`），当前直接跑在 `@MainActor` 的主线程上：连不上时 UI 完全冻结秒级；同时打开多个标签时连接只能串行排队（主线程被占用，后续连接无法开始），网速慢时体验极差。FFI 同步契约（`ffi-bridge` spec）保持不变，修复点在 Swift 侧调度。

## What Changes

- **新增统一的非主线程调度入口**：为阻塞型 FFI 调用提供后台执行设施（如 `Task.detached` / 非隔离 async 包装），保证主线程不被网络往返占住。
- **连接建立异步化**：
  - `TerminalSessionStore.connect` 中 `PandaShellConnection`（`shellOpen` 全握手 + PTY）改为在后台线程创建，完成后回主线程更新状态。
  - `SftpSessionStore.connect` 中 `resolveSftpHomeDir`（SSH 握手 + SFTP 会话 + home 解析）改为后台执行。
- **传输预检/管理异步化**：`scanLocalBatch` / `scanRemoteBatch`（目录扫描）、`sftpCheckUploadConflict` / `sftpCheckDownloadConflict`（覆盖预检）、`sftpRemoveFile` / `sftpRemoveDir`（删除）等网络往返型 FFI 调用移出主线程。
- **多连接并行**：利用全局 tokio 多线程 runtime 的并发 `block_on`，多个标签的连接在后台并行握手，不再互相排队。
- **行为保持**：FFI 层全部函数保持同步导出（spec 不变）；Swift 侧结果回传仍走 MainActor，UI 状态机（connecting → shell/failed）与现有协议不变。

## Capabilities

### New Capabilities

（无新增能力）

### Modified Capabilities

- `ffi-bridge`: 新增需求——阻塞型导出调用（连接、SFTP 网络操作）SHALL 由 Swift 侧在非主线程调度执行，MUST NOT 阻塞主线程；连接建立 SHALL 支持并发并行。

## Impact

- **Swift**：`apple/PandaSSH/Workspace/TerminalSessionStore.swift`、`SftpSessionStore.swift`、`ShellConnection.swift`，新增后台调度设施（可放 `PandaCoreBridge.swift` 或独立文件）。
- **Rust**：无改动（FFI 契约、导出签名、业务逻辑均不变）。
- **测试**：Swift 侧新增调度行为测试（断言阻塞型调用不占用主线程、连接可并行/顺序保持）；既有 FFI 测试与 `cargo test` 不受影响。
- **双端影响**：macOS 与 iPadOS 共享同一 SwiftUI 源码，调度改动同时生效于两端；连接并行后两个标签的连接动画与失败提示语义不变。

## Non-goals

- 不把 FFI 导出改为异步接口（`ffi-bridge` spec 的同步契约保持）。
- 不为每次键盘/读循环调用做后台化（`shellRead`/`shellWrite`/`shellResize`/轮询已是毫秒级或已后台）。
- 不调整 Rust 连接池并发语义（连接池按主机复用，天然并行）。
- 不引入额外依赖。
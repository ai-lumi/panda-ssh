## Why

用户批量上传目录时报错 `is a directory(os error 21)`，因为单文件上传路径把目录当作文件处理。另外用户观察到传输任务并未按预期的 3 任务并发、其余排队执行，且添加任务时体感较慢。

## What Changes

- Rust `run_transfer_task` 先获取信号量许可证，再切换为 `Running` 状态；等待期间保持 `Queued`，让 UI 正确显示排队中。
- Swift `SftpSessionStore.uploadSelected` 在真实连接模式下，若选中的是本地目录，则枚举该目录下的直接文件，每个文件作为一个独立上传任务加入队列。
- 演示/测试模式保持目录 placeholder 单任务行为，避免破坏现有测试。

## Non-Goals

- 不实现远程目录下载拆分。
- 不实现子目录递归上传（当前只处理选中目录的直接文件）。
- 不实现断点续传。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ffi-bridge`: 单文件传输任务排队状态语义修正。
- `transfers`: 本地目录上传拆分为多文件任务；并发排队状态正确显示。

## Impact

- 上传目录不再报错，而是为每个文件创建任务。
- 超出并发上限的任务正确显示「排队中」。
- macOS / iPadOS 双端共享 Swift 源码同时生效。

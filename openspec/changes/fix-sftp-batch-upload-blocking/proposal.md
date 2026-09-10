## Why

SFTP 目录上传在慢网速下导致 UI 阻塞、停止响应。根因是当前 UI 的目录上传走「逐文件建连」路径（`enqueueGroup`），每个文件独立新建 SSH 连接，慢网速下建连耗时长，信号量限流 3 并发导致界面卡顿。批量传输路径（`start_batch_upload`）已实现但未接入 UI。同时，Rust FFI 层的 `block_on` 调用占住 tokio worker 线程、冲突回调的 `recv_timeout` 同步阻塞，进一步加剧了线程饥饿。

## What Changes

- **UI 目录上传路由切换**：`SftpSessionStore.upload(localPaths:)` 检测到目录时，调用已有的 `addBatchUpload()` 走批量传输路径（单 SSH 连接复用），而非逐文件 `enqueueGroup()`。
- **修正 `transfers` spec 中过时的「本地目录上传拆分」规则**：该规则要求目录上传拆分为逐文件独立任务，与 `sftp-batch-transfer` 和 `sftp-transfer` 中已有的批量传输规则矛盾。需更新为目录上传走批量传输路径。
- **FFI 扫描阶段消除 `block_on`**：`scan_local_batch` 与 `scan_remote_batch` 中的 `runtime().block_on(...)` 改为 `runtime().spawn()` + oneshot channel，避免占住 tokio worker 线程。
- **冲突回调改为异步等待**：批量传输冲突回调中 `std::sync::mpsc::Receiver::recv_timeout` 改为 `tokio::sync::oneshot` + `tokio::time::timeout`，避免阻塞 worker 线程。

## Non-goals

- 不改变单文件上传/下载的行为路径（仍走逐文件独立连接）。
- 不改变批量传输的并发模型（每个批量任务独占一个 SSH 连接，任务间不共享 Socket）。
- 不引入连接池或连接复用给单文件传输。
- 不改变传输任务的暂停/继续/取消/重试语义。

## Capabilities

### New Capabilities

（无新增能力）

### Modified Capabilities

- `transfers`：更新「本地目录上传拆分」规则，目录上传 SHALL 通过批量传输接口处理，不再拆分为逐文件独立任务。
- `sftp-batch-transfer`：补充 FFI 层异步非阻塞约束——批量传输的扫描与冲突回调 MUST NOT 阻塞 tokio worker 线程。

## Impact

- **Swift 侧**：`SftpSessionStore.upload(localPaths:)` 路由逻辑修改；`TransferStore` 中 `addBatchUpload()` 已被调用。macOS 与 iPadOS 双端共享此逻辑，行为一致。
- **Rust FFI 侧**：`batch_transfer.rs` 中 `scan_local_batch`/`scan_remote_batch` 签名或实现变更；冲突回调 channel 类型变更。
- **API 变更**：`scan_local_batch`/`scan_remote_batch` 的 FFI 导出可能从同步阻塞改为异步 spawn，返回方式变化（需确认 uniffi 兼容性）。
- **测试**：需更新 `SftpSessionStore` 相关测试以验证目录上传走批量路径；需更新 Rust 侧批量传输测试以覆盖异步扫描与冲突回调。

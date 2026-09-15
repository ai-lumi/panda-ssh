## Context

当前 UI 目录上传走 `enqueueGroup()` 路径，逐文件调用 `start_transfer()` FFI，每个文件独立新建 SSH 连接。批量传输路径（`start_batch_upload` / `addBatchUpload`）已在 Rust FFI 和 Swift `TransferStore` 中实现，但未被 UI 调用。同时 FFI 层的 `block_on` 和 `recv_timeout` 同步阻塞 tokio worker 线程，在慢网速下加剧线程饥饿。

关键代码路径：
- Swift 入口：`SftpSessionStore.upload(localPaths:)` → `enqueueGroup()`
- Rust 逐文件路径：`start_transfer()` → `run_upload()` → 每次 `connect_shared`
- Rust 批量路径：`start_batch_upload()` → `run_batch_transfer_task()` → 单连接复用
- 阻塞点：`batch_transfer.rs` 中 `scan_local_batch`/`scan_remote_batch` 的 `block_on`；冲突回调的 `recv_timeout`

## Goals / Non-Goals

**Goals:**

- 目录上传走批量传输路径，单 SSH 连接复用，消除逐文件建连开销
- FFI 层扫描与冲突回调不阻塞 tokio worker 线程
- 慢网速下 UI 保持响应，进度可持续更新

**Non-Goals:**

- 不改变单文件上传/下载的连接模型
- 不引入连接池或跨任务连接复用
- 不改变批量传输的并发语义（每任务独占连接）
- 不改变暂停/继续/取消/重试的行为规则

## Decisions

### 决策 1：UI 目录上传路由切换到批量路径

**选择**：`SftpSessionStore.upload(localPaths:)` 检测到目录时调用 `addBatchUpload()` 走 `start_batch_upload` FFI。

**理由**：批量路径已实现且经过测试（`batch_transfer.rs` + `batch.rs`），单连接复用消除了 N 次 SSH 建连开销。`addBatchUpload()` 在 `TransferStore` 中已存在，只需 UI 层路由切换。

**替代方案**：为 `enqueueGroup()` 路径添加连接池——复杂度高，且批量路径已满足需求。

### 决策 2：扫描阶段 `block_on` 改为 `spawn` + oneshot

**选择**：`scan_local_batch` 和 `scan_remote_batch` 的 FFI 导出改为 `runtime().spawn()` 提交异步任务，通过 `tokio::sync::oneshot` channel 将结果返回给调用方。调用方在 `Task.detached` 线程上 `await` oneshot receiver。

**理由**：`block_on` 会占住调用线程对应的 tokio worker slot，在并发扫描+传输场景下导致 worker 饥饿。`spawn` + oneshot 释放 worker 线程，保持异步调度。

**替代方案**：增大 tokio runtime worker 线程数——治标不治本，且增加资源消耗。

**uniffi 兼容性**：需确认 `scan_local_batch`/`scan_remote_batch` 的 FFI 签名是否需要变更。如果 uniffi 不支持 async 导出，则保持同步 FFI 签名，内部改为 `spawn` + 在调用线程上 `block_on(oneshot_rx)`——此时 `block_on` 仅等待 oneshot 结果，不执行实际 I/O，worker 线程不被长时间占住。

### 决策 3：冲突回调 `recv_timeout` 改为异步等待

**选择**：将 `std::sync::mpsc::Receiver::recv_timeout(Duration::from_secs(300))` 替换为 `tokio::sync::oneshot::Receiver` + `tokio::time::timeout(Duration::from_secs(300), rx)`。

**理由**：`recv_timeout` 是同步阻塞原语，在 async task 中调用会阻塞整个 tokio worker 线程长达 300 秒。`tokio::time::timeout` 是异步的，等待期间释放 worker 线程。

**替代方案**：使用 `tokio::sync::mpsc` + `tokio::time::timeout`——但 oneshot 语义更匹配（单次响应）。

## Risks / Trade-offs

- **[风险] uniffi async 导出限制** → 若 uniffi 不支持 async 函数导出，则保持同步 FFI 签名，内部用 `spawn` + `block_on(oneshot_rx)` 最小化阻塞时间。需先验证 uniffi 版本支持情况。
- **[风险] 批量路径的冲突 UI 集成** → 批量传输的冲突回调需要 Swift UI 层正确处理。当前 `TransferStore` 中批量冲突的处理逻辑需确认是否与逐文件冲突的 UI 一致。→ 实现时先确认现有冲突回调链路，确保 UI 可复用。
- **[权衡] 批量任务单连接 vs 多连接并发** → 单连接复用减少建连开销，但单个批量任务内文件只能串行传输。对于大量小文件场景这是可接受的（建连开销 >> 传输时间）。→ 未来可考虑批量任务内多 SFTP channel 并发，但不在本次变更范围。

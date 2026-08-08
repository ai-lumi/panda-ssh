## Context

现有 `SftpClient::upload`/`download`（`crates/panda-core/src/sftp.rs`）一次性读写整个文件，FFI 的 `sftp_upload`/`sftp_download` 用 `block_on` 同步等待，UI 无进度、无取消。传输需要：分块读写（便于进度与取消）、任务注册表（跨多次调用存活）、同步查询接口（符合「FFI 全部同步导出」约定）。

## Goals / Non-Goals

**Goals:**

- 任务化：每次上传/下载创建一个任务，可查询状态与进度。
- 进度精确：按已传输字节 / 总字节计算百分比。
- 可取消：传输中与排队中均可取消。
- 并发受限：固定并发数，其余排队。
- 保持 FFI 同步导出约定，不引入跨 FFI 回调。

**Non-Goals:**

- 限速、断点续传、文件校验。
- 目录递归批量传输（本次仅单文件/多文件选择）。
- 任务列表跨 App 重启持久化。
- 传输完成后自动重试（仅手动重试）。

## Decisions

### 分块传输与进度回传

`SftpClient` 增加分块读写路径：按固定缓冲（如 256 KiB）循环读取本地文件 / 远端句柄，每完成一块累加字节并更新进度；每次写块后检查取消标志。公开返回 `TransferHandle`（内含已传输字节、总字节、状态），或通过回调在 FFI 层更新任务记录。

### FFI 任务注册表：任务 id + 同步查询

在 panda-ffi 内维护全局任务注册表（`OnceLock<Mutex<HashMap<Uuid, TransferTask>>>`）：

- `start_transfer(kind, host_id, local, remote, password, passphrase) -> task_id`：`spawn` 到全局 runtime 执行，立即返回任务 id。
- `transfer_status(task_id) -> TransferStatusRecord`：同步读取当前状态与进度。
- `transfer_list() -> [TransferStatusRecord]`：全部任务概览。
- `transfer_cancel(task_id)`：置取消标志（排队中直接转 cancelled）。
- `transfer_retry(task_id)`：失败任务按原参数重建任务。

Swift 侧用 `Task`/定时器轮询 `transfer_list` 刷新任务面板。取消标志由 core 的分块循环在块间检查，保证及时退出并断开会话。

### 并发与队列

全局 runtime 内用 `Semaphore`（`tokio::sync::Semaphore`，许可数=并发上限，初始值如 3）限制同时执行的传输，超出任务等待许可即「排队」。

### UI

任务面板展示：方向图标、文件名/远程路径、总大小、进度条、已完成百分比/字节、状态徽标、取消/重试按钮。任务按创建时间排序。

## Risks / Trade-offs

- [轮询刷新存在秒级延迟] → 可接受；进度更新以 100–200ms 间隔轮询，满足视觉反馈。
- [分块循环需频繁检查取消标志，增加每块开销] → 每块一次 `try_acquire`/标志检查成本可忽略。
- [任务注册表在 panda-ffi 进程内，App 重启即丢失] → 已列入 Non-Goal，本次聚焦单会话内体验。

## Migration Plan

无数据迁移。既有 `sftp_upload`/`sftp_download` 保留（兼容旧调用方），新增任务化接口为增量。

## Open Questions

- 任务面板入口：作为 SFTP 标签页内的独立面板，还是全局抽屉？先实现 SFTP 标签页内面板，双端一致，后续按反馈调整。

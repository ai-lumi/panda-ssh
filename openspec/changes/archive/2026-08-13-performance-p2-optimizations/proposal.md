# P2 性能优化合集

## Why

代码审查中识别的 P2 级性能与内存优化项：避免内存泄漏、减少布局开销、消除不必要的字符串分配。

## What Changes

### P2-10: Swift 侧字典无限增长清理
- `TransferStore.clearFinished()` 中清理 `speedCalculators`、`lastSeenStatuses`、`pausedTaskIDs`，仅保留仍在 FFI 任务列表中的条目
- `SftpSessionStore` 的 `refreshedTaskIDs` 在监听 `transfers.$tasks` 时，与当前任务列表取交集，避免完成事件 ID 无限累积

### P2-11: 框选 GeometryReader 只在拖拽态启用
- `SftpTabView.fileList` 中每行的 `GeometryReader` 收集器改为 `@ViewBuilder` 条件视图 `rowFrameCollector`
- 仅在 `localDragRect != nil || remoteDragRect != nil` 时启用 `GeometryReader`，非拖拽态使用 `Color.clear`，显著降低大目录下的布局 pass 数量

### P2-12: fingerprint_sha256 预分配 String
- `hostkey.rs` 中指纹十六进制拼接由 `format!("{b:02x}")` + `Vec<String>` + `join(":")` 改为预分配 `String::with_capacity(95)`，逐字节 `write!` 写入，消除 32 次中间 String 分配

### P2-13: write_atomic 增加异步版本
- `config.rs` 中 `write_atomic` 保持同步版本（调用方均为同步 Store API）
- 新增 `write_atomic_async`，内部使用 `tokio::task::spawn_blocking`，为后续异步 I/O 场景预留接口

## Skip P2-8 / P2-9

- **P2-8 (Mutex → RwLock)**: 当前 FFI 全局锁（`TRANSFER_TASKS`、`STORES` 等）持有时间均为微秒级（HashMap 查找/插入），且并发度极低（传输由 Semaphore 限制为 3，进度查询由 Swift 侧限制为 ≤5Hz）。改为 tokio::sync::RwLock 需要把所有同步 FFI 函数入口改为 `block_on` 包裹，复杂度与收益不匹配，暂不实施。
- **P2-9 (tokio::select! 包裹 I/O)**: russh-sftp 内部使用同步 I/O 流，`tokio::select!` 无法直接包裹其阻塞读写；当前每 8KB chunk 检查一次 `cancel` AtomicBool，在 1Gbps 下约每 64μs 检查一次，取消响应足够及时。如需更细粒度取消，需等 russh-sftp 暴露取消友好的 async API。

## Impact

- `apple/PandaSSH/Workspace/TransferStore.swift`
- `apple/PandaSSH/Workspace/SftpSessionStore.swift`
- `apple/PandaSSH/Workspace/SftpTabView.swift`
- `crates/panda-core/src/hostkey.rs`
- `crates/panda-core/src/config.rs`

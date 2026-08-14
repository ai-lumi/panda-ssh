# Transfer Polling Optimization Design

## Context

`TransferStore.tick()` 每 100ms 调用一次 `FFITransferSource.listTransfers()`，后者通过 FFI 调用 Rust `transfer_list()`。Rust 侧锁全局 `Mutex`、克隆每个任务的 `host_id`、`local_path`、`remote_path`（这些字段在传输过程中从不变化），然后序列化为 `TransferStatusRecord` 数组。Swift 侧收到后做全量 `!=` 比较决定是否更新 UI。

## Goals / Non-Goals

**Goals：**
- 减少 90% 以上的无效轮询数据克隆与比较
- 无活跃传输时 Timer 自动停止，节省 CPU/电量
- 保持 Swift 侧 `TransferTask` 模型与 UI 不变

**Non-Goals：**
- 不实现 Rust→Swift 的主动回调/推送（保持当前轮询架构）
- 不改变传输并发数、重试策略等传输行为

## Decisions

### 决策 1：用单调版本号 + `transfer_poll()` 实现增量更新

**理由：** 比“脏标记位图”更简单可靠；每个任务独立版本号避免全局锁竞争；`transfer_poll()` 接口语义清晰（"给我上次查询之后的变化"）。

### 决策 2：自适应频率分三档：200ms / 1s / 停止

**理由：** 传输活跃时 5Hz 足够流畅；终态任务仅需偶尔刷新以便用户看到完成；无任务时彻底停止避免空转。

### 决策 3：首次仍用 `transfer_list()` 全量，后续全部增量

**理由：** 保证 Swift 初始状态完整；后续只传变化，大幅减少 FFI 往返数据量。

## Risks / Trade-offs

- **[Risk] `transfer_poll` 返回的任务 Swift 侧可能尚未缓存（竞态窗口）**
  → 缓解：若收到未知任务 ID，自动回退到 `transfer_list()` 全量同步一次
- **[Risk] 版本号溢出（u64）**
  → 缓解：u64 每秒递增 1 次可用 5.8 亿年，实际不可能溢出

# Design: 传输失败重试复用原任务

## 状态重置策略

`TransferTask` 是 `Arc<...>` 共享对象，重试时直接修改其内部状态：

| 字段 | 重置前值 | 重置后值 |
|------|---------|---------|
| status | Failed / Cancelled | Queued |
| transferred | 任意 | 0 |
| error | Some(...) | None |
| cancel | true/false | false |

方向、路径、大小、主机、密码/口令等传输参数保持不变。

## 并发安全

- 状态检查与重置在持有 `Mutex` 的短暂临界区内完成。
- 仅当原状态为 `Failed` 或 `Cancelled` 时才允许重试，其他状态返回 `PandaError::Core`。
- 重置后调用 `runtime().spawn(async move { run_transfer_task(task, cfg).await; })`，沿用现有信号量排队逻辑。

## Swift 侧配合

`TransferStore.retry(id:)` 与 `retryGroup(groupID:)` 在调用 `source.retryTransfer` 后，从 `speedCalculators` 中移除对应 id 的条目，使速度计算从 0 开始。

## OpenSpec 变更

`transfers/spec.md` 的「失败重试」需求从"重新创建"改为"复用原任务 id 重新执行"。

# Design: 传输任务暂停与继续

## 状态机

新增 `Paused` 状态：

```
Queued --start--> Running --complete--> Completed
  |                 |
  | pause           | pause
  v                 v
Paused             Paused
  |                 |
  | resume          | resume
  v                 v
Queued            Running
```

- 从 `Queued` 暂停：状态直接变为 `Paused`，任务不会尝试获取信号量。
- 从 `Running` 暂停：当前缓冲块完成后进入 `Paused`，任务仍持有信号量许可证。
- 继续：状态回到 `Queued`（若尚未获取信号量）或 `Running`（若已获取）。
- 取消：任何状态下均可取消；取消优先级高于暂停。

## Rust 层暂停机制

### `panda-core/src/sftp.rs`

新增内部辅助函数 `wait_if_paused`：

```rust
async fn wait_if_paused(
    cancel: Option<&Arc<AtomicBool>>,
    pause: Option<&Arc<AtomicBool>>,
    resume: Option<&Arc<Notify>>,
) -> Result<()> {
    loop {
        if cancel.as_ref().map(|c| c.load(Ordering::Relaxed)).unwrap_or(false) {
            return Err(Error::Cancelled);
        }
        if !pause.as_ref().map(|p| p.load(Ordering::Relaxed)).unwrap_or(false) {
            return Ok(());
        }
        if let Some(notify) = resume {
            notify.notified().await;
        } else {
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
}
```

`upload_with_cancel` 与 `download_with_cancel` 保留原签名，内部委托给新的 `upload_with_pause` / `download_with_pause`，传入 `None, None`。

新函数在每次循环顶部调用 `wait_if_paused`，实现非忙等暂停。

### `panda-ffi/src/lib.rs`

`TransferTask` 新增字段：

- `paused: Arc<AtomicBool>`
- `resume_notify: Arc<Notify>`

新增导出函数：

- `transfer_pause(task_id) -> Result<(), PandaError>`
  - 查找任务。
  - 若状态已是终态，返回错误。
  - 设置 `paused = true`。
  - 若状态为 `Queued` 或 `Running`，改为 `Paused`。
- `transfer_resume(task_id) -> Result<(), PandaError>`
  - 查找任务。
  - 设置 `paused = false`。
  - 调用 `resume_notify.notify_waiters()`。
  - 若状态为 `Paused`，改为 `Queued`（由工作线程在获取信号量后/循环中再转为 `Running`）。

`run_transfer_task` 修改：

1. 在获取信号量前循环等待暂停解除。
2. 获取信号量后、进入 `Running` 前再次检查暂停。
3. 在 `run_upload`/`run_download` 的读写循环中通过 `pause`/`resume_notify` 阻塞。

`transfer_retry` 重置时同时设置 `paused = false`。

## Swift 层

- `TransferStatus` 增加 `paused` case。
- `TransferSource` 协议增加 `pauseTransfer(id:) -> Bool`、`resumeTransfer(id:) -> Bool`。
- `PandaCoreBackend` 调用 `transferPause` / `transferResume`。
- `MockBackend` 支持模拟暂停/继续。
- `TransferStore` 增加 `pause(id:)`、`resume(id:)`，并清除/恢复速度计算器。
- `TransferPanelView` 在任务行右侧根据状态显示暂停/继续按钮：
  - `running` → 显示暂停按钮
  - `paused` → 显示继续按钮
  - `queued` 且支持暂停 → 可显示暂停按钮（可后续迭代）

## 并发槽位

暂停的任务继续占用许可证，以保留"这个槽位就是我暂停前的传输"的语义。排队任务暂停时不占用许可证，恢复后按顺序重新参与竞争。

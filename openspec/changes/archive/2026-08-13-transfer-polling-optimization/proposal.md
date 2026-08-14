# Transfer Polling Optimization

## Why

当前 Swift 侧以固定 10Hz（100ms）轮询 Rust 传输状态，每次全量克隆所有任务的 `String` 字段并做 O(n) 数组比较。这造成双端 CPU 空转、Mutex 持续争用、电池损耗（尤其 iPadOS）。通过增量轮询 + 自适应频率，可将轮询开销降低一个数量级。

## What Changes

- Rust `TransferTask` 增加单调递增版本号，任何状态/进度/错误变更时自动递增
- 新增 FFI `transfer_poll(since_version: u64)`：仅返回版本号大于 `since_version` 的变更任务（增量更新）
- Swift `TransferStore` 改造：首次全量 `transfer_list()`，后续增量 `transfer_poll()`；无变更时自动降频
- 自适应轮询频率：存在 Running/Queued 任务时 5Hz（200ms），仅存在终态任务时 1Hz（1s），无任务时彻底停止 Timer
- 保持所有现有 FFI 函数与 Swift API 不变

## Capabilities

无 spec 级行为变更；纯实现优化，skip_specs。

## Impact

- `crates/panda-ffi/src/lib.rs`：版本号字段 + `transfer_poll` FFI
- `apple/PandaSSH/Workspace/TransferStore.swift`：轮询策略改造
- 对 macOS/iPadOS 双端影响一致

## Non-goals

- 不做 Rust→Swift 的主动推送（回调/通知），保持轮询模型简单
- 不改变传输任务的生命周期或状态机

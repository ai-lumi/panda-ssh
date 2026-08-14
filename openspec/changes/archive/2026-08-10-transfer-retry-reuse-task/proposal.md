# Proposal: 传输失败重试复用原任务

## Problem

当前 `transfer_retry` 在 Rust 侧会调用 `start_transfer` 创建一条**新任务**，返回新 `task_id`。这导致：

- 重试后任务列表出现两条记录（一条失败、一条新排队），视觉上像"重复任务"。
- 如果任务已传输一半后失败，新任务会从 0 开始，用户无法看到"续传"状态，也不便于继续等待同一个任务。
- Swift 侧 `TransferStore.retry(id:)` 以原 id 为入口，但 FFI 返回新 id，语义不一致。

## Goal

失败重试应当在**保留原任务 id** 的前提下重置状态并重新调度，不产生新任务条目。

## Scope

- Rust `panda-ffi`：`transfer_retry` 改为重置现有任务状态（Queued / transferred=0 / error=None / cancel=false）并重新 `spawn`。
- Swift `TransferStore`：重试时清除对应 id 的速度计算器缓存，避免旧速度数据误导。
- OpenSpec `transfers/spec.md`：明确重试应复用原任务 id。
- 测试：补充 Rust FFI 测试（验证复用 id、非终态任务拒绝重试），更新 Swift 测试断言。

## Non-Goals

- 不实现断点续传（从已传输字节处继续），仅保证重试不产生新任务。
- 不改变批量任务（batch）行为；目录任务组中的单文件任务各自复用自己的 id。

## Success Criteria

1. `cargo test` 全绿。
2. Swift `PandaSSH-macOS` 测试全绿。
3. 重试失败后同一任务 id 的状态从 `failed` 变为 `queued` 再变为 `running`/`completed`。

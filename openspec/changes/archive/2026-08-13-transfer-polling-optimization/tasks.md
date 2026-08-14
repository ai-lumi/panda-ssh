# Tasks

## 1. Rust 侧版本号与增量查询

### 1.1 测试
- [x] 1.1.1 状态变更时版本号递增
- [x] 1.1.2 `transfer_poll` 返回增量任务
- [x] 1.1.3 `transfer_poll` 无变更时返回空
- [x] 1.1.4 全量 `transfer_list` 仍正常工作

### 1.2 实现
- [x] 1.2.1 `TransferTask` 增加 `version: Arc<AtomicU64>`
- [x] 1.2.2 状态/进度/错误变更时自动递增版本号
- [x] 1.2.3 新增 `transfer_poll(since_version: u64) -> Vec<TransferStatusRecord>`
- [x] 1.2.4 `transfer_list` 也返回当前全局最新版本号（或 Swift 侧自行取最大值）
- [x] 1.2.5 跑 `cargo test` 全绿

## 2. Swift 侧轮询策略改造

### 2.1 测试（可测逻辑）
- [x] 2.1.1 首次调用走全量 `listTransfers`
- [x] 2.1.2 后续调用走 `transferPoll`
- [x] 2.1.3 无变更时降低频率
- [x] 2.1.4 收到未知任务时回退全量

### 2.2 实现
- [x] 2.2.1 `FFITransferSource` 新增 `pollTransfers(since: UInt64) -> [TransferRecord]`
- [x] 2.2.2 `TransferStore` 维护 `lastPollVersion: UInt64`
- [x] 2.2.3 `tick()` 改为：首次/回退时全量，正常时增量
- [x] 2.2.4 `startPollingIfNeeded` 根据任务状态选择频率（200ms / 1s / 停止）
- [x] 2.2.5 跑 Swift 编译通过

## 3. 端到端验证

- [x] 3.1 `cargo test` 全绿
- [x] 3.2 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`
- [x] 3.3 `build-rust.sh` → `xcodebuild` 通过

## 4. 归档

- [x] 4.1 `openspec archive transfer-polling-optimization`

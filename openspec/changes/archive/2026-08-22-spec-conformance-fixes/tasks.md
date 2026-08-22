## 1. Rust：批量传输冲突确认（red-green）

- [x] 1.1 先写失败测试：`panda-ffi/tests/` 新增批量传输冲突测试（fake server 场景：目标已存在 → 任务进入 `WaitingForConflict` 且携带完整冲突元数据；`batch_transfer_resolve_conflict(true)` 后覆盖完成；`false` 后跳过并计入 skipped）
- [x] 1.2 先写失败测试：取消等待确认中的批量任务 → 状态最终为 `Cancelled`，无悬空等待
- [x] 1.3 实现：`BatchTransferStatusEnum` 新增 `WaitingForConflict` 变体，`BatchTransferStatusRecord` 新增 `pending_conflict: Option<BatchConflictRecord>`（含 source/destination/size/mtime 全量字段）
- [x] 1.4 实现：`run_batch_transfer_task` 的冲突回调改为向任务状态写入 `pending_conflict` 并 `await` 决策通道（tokio `oneshot`）；新增 `batch_transfer_resolve_conflict(task_id, overwrite)` 回传决策；`batch_transfer_cancel` 唤醒等待者
- [x] 1.5 回归：`cargo test` 全绿；批量任务无冲突时行为与变更前一致（直接传输）

## 2. Swift：批量冲突确认 UI

- [x] 2.1 先写失败测试：`TransferStore` 批量记录映射 `WaitingForConflict` → 呈现等待确认语义（UI 状态不新增枚举，映射为 `.queued` 展示等待徽标）
- [x] 2.2 实现：`SftpSessionStore` 轮询批量任务 `pending_conflict`，命中时弹出 `OverwriteConfirmationSheet`（复用单文件确认弹窗），决策回传 `batch_transfer_resolve_conflict`
- [x] 2.3 实现：`TransferStore`/`TransferRecord` 映射新状态与冲突字段；批量行在等待确认时展示「等待确认」提示而非失败
- [x] 2.4 Swift 测试：批量冲突覆盖/跳过两条路径 + 取消等待中任务，全部通过

## 3. macOS 主窗口隐藏 `>>` 按钮

- [x] 3.1 先写失败测试（如可测）：`WorkspaceView` 工具栏不含 `sidebarToggle` 项
- [x] 3.2 实现：macOS 分支 `.toolbar(removing: .sidebarToggle)` 移除自动注入按钮

## 4. 日志模块名规范化

- [x] 4.1 先写失败测试：`Logger` 默认模块名不再产生 `App`（白名单断言）
- [x] 4.2 实现：`Logger.log` 默认模块名改为 `Config`；全仓搜索 `Logger.shared.*` 调用点，逐一确认模块名 ∈ {SSH, SFTP, Transfer, HostKey, Config, FFI}，不规范调用点修正

## 5. 收尾

- [x] 5.1 `cargo test` + `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 通过
- [x] 5.2 `build-rust.sh` → `xcodegen` → macOS/iOS 双端 `xcodebuild` 通过
- [x] 5.3 变更归档：spec 无 delta（skip_specs），执行 archive 流程

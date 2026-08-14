# Tasks: 传输任务暂停与继续

- [x] 更新 OpenSpec `transfers/spec.md` 新增暂停/继续需求。
- [x] `panda-core`：`SftpClient` 增加 `upload_with_pause` / `download_with_pause`，原 `*_with_cancel` 保持兼容。
- [x] `panda-ffi`：`TransferStatusEnum` 增加 `Paused`，`TransferTask` 增加 `paused`/`resume_notify`。
- [x] `panda-ffi`：新增 `transfer_pause`、`transfer_resume` 导出函数。
- [x] `panda-ffi`：`run_transfer_task` 在获取信号量前后与循环内检查暂停。
- [x] `panda-ffi`：`transfer_retry` 重置时清除 `paused`。
- [x] Rust 测试：`panda-core` 暂停/继续上传下载；`panda-ffi` 暂停/继续任务。
- [x] Swift `TransferStatus` 增加 `paused`；`TransferSource` 增加 `pauseTransfer`/`resumeTransfer`。
- [x] Swift `TransferStore` 增加 `pause(id:)` / `resume(id:)` 并处理速度计算器。
- [x] Swift `TransferPanelView` 显示暂停/继续按钮。
- [x] Swift 测试：暂停/继续状态转换与排队任务不占用槽位。
- [x] 运行 `cargo test` 与 `xcodebuild` 测试全绿。
- [x] 归档 OpenSpec change 并合并 spec delta。

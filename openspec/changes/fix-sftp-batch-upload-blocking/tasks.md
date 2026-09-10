## 1. FFI 扫描阶段异步化

- [x] 1.1 编写测试：验证 `scan_local_batch` 在扫描期间不阻塞 tokio worker 线程（并发 spawn 其他异步任务可正常执行）
- [x] 1.2 编写测试：验证 `scan_remote_batch` 在扫描期间不阻塞 tokio worker 线程
- [x] 1.3 实现：将 `scan_local_batch` 中的 `runtime().block_on(scan_local_sources(...))` 改为 `runtime().spawn()` + oneshot channel，确认 uniffi 兼容性后决定 FFI 签名是否变更
- [x] 1.4 实现：将 `scan_remote_batch` 中的 `runtime().block_on(...)` 改为 `runtime().spawn()` + oneshot channel
- [x] 1.5 验证：`cargo test` 全绿，扫描相关测试覆盖正常流程（含子目录递归）、意外操作（无效路径）、边界条件（空目录）

## 2. 冲突回调异步化

- [x] 2.1 编写测试：验证批量传输冲突回调等待期间不阻塞 tokio worker 线程
- [x] 2.2 编写测试：验证冲突回调超时后任务正确失败（覆盖 300 秒超时场景，测试中用短超时替代）
- [x] 2.3 实现：将 `run_batch_transfer_task` 中冲突回调的 `std::sync::mpsc::Receiver::recv_timeout` 替换为 `tokio::sync::oneshot` + `tokio::time::timeout`
- [x] 2.4 验证：`cargo test` 全绿，冲突回调测试覆盖正常流程（用户选择覆盖/跳过）、意外操作（超时）、边界条件（即时响应）

## 3. UI 目录上传路由切换

- [x] 3.1 编写测试：验证 `SftpSessionStore.upload(localPaths:)` 检测到目录时调用 `addBatchUpload()` 而非 `enqueueGroup()`
- [x] 3.2 编写测试：验证多选非目录文件时仍走 `enqueueGroup()` 逐文件路径
- [x] 3.3 实现：修改 `SftpSessionStore.upload(localPaths:)` 路由逻辑——包含目录时调用 `TransferStore.addBatchUpload()`，仅非目录文件时保持 `enqueueGroup()`
- [x] 3.4 验证：Swift 测试全绿，覆盖正常流程（单目录上传）、意外操作（混合选中目录与文件）、边界条件（空目录）

## 4. 集成验证与覆盖率

- [x] 4.1 运行 `cargo test` 确认 Rust 侧全绿
- [x] 4.2 运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 确认覆盖率门禁通过
- [x] 4.3 运行 Swift 侧相关 target 测试确认全绿
- [x] 4.4 手动验证：macOS 端目录上传走批量路径，慢网速模拟下 UI 保持响应
- [x] 4.5 手动验证：iPadOS 端行为与 macOS 一致（共享 Swift 源码，逻辑相同）

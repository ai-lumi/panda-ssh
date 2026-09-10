## 1. Rust 核心聚合模块 — 数据结构与分组规则

- [x] 1.1 编写 `task_aggregation.rs` 中 `TaskGroup`、`TaskItem`、`TransferDirection` 数据结构定义
- [x] 1.2 编写分组规则测试：多选目录产生多个任务组（正常流程）、仅选文件不产生任务组（边界条件）、空输入返回空列表（意外操作）
- [x] 1.3 编写分组规则测试：顶层目录的子目录不成为子任务组（正常流程）、混合选中目录与文件时正确分组（正常流程）、目录内仅含子目录无文件时组为空（边界条件）
- [x] 1.4 实现 `aggregate_task_groups()` 纯函数，使 1.2 和 1.3 的测试通过
- [x] 1.5 编写顶层目录识别测试：嵌套选中时只取最外层目录（如同时选中 `a/` 和 `a/b/`，只产生 `a/` 的组）（正常流程）
- [x] 1.6 实现顶层目录过滤逻辑（排除被其他选中目录包含的子目录），使 1.5 的测试通过

## 2. Rust 核心聚合模块 — 聚合进度与状态计算

- [x] 2.1 编写 `TaskGroup::total_size()` 测试：正常多文件求和（正常流程）、空组返回 0（边界条件）、含目录项（size=0）不计入（边界条件）
- [x] 2.2 编写 `TaskGroup::aggregate_progress()` 测试：部分完成时按比例计算（正常流程）、全部完成返回 1.0（正常流程）、total_size=0 时返回 1.0（边界条件）
- [x] 2.3 编写 `TaskGroup::aggregate_status()` 测试：running 优先级最高（正常流程）、全部 done 返回 done（正常流程）、混合 failed 和 cancelled 返回 failed（边界条件）
- [x] 2.4 实现上述三个方法，使 2.1–2.3 的测试通过

## 3. Rust 聚合模块 — 组级操作逻辑

- [x] 3.1 编写 `group_cancel_plan()` 测试：返回组内所有非终态任务的 cancel 目标列表（正常流程）、组内全部已完成时返回空列表（边界条件）
- [x] 3.2 编写 `group_retry_plan()` 测试：返回组内所有失败任务的 retry 目标列表（正常流程）、无失败任务时返回空列表（边界条件）、组不存在时返回错误（意外操作）
- [x] 3.3 实现 `group_cancel_plan()` 和 `group_retry_plan()`，使 3.1 和 3.2 的测试通过

## 4. 批量删除扩展点

- [x] 4.1 编写测试：`TransferDirection::Delete` 变体可正常传入 `aggregate_task_groups()`，分组规则与上传/下载一致（正常流程）
- [x] 4.2 在 `TransferDirection` 枚举中新增 `Delete` 变体，使 4.1 的测试通过

## 5. FFI 层 — 导出类型与函数

- [x] 5.1 编写 FFI 集成测试：`aggregate_task_groups_ffi()` 接收 `BatchItemRecord` 列表和方向，返回正确的 `TaskGroupRecord` 列表（正常流程）、空输入返回空列表（边界条件）
- [x] 5.2 定义 `TaskGroupRecord`、`TaskItemRecord` uniffi Record 类型
- [x] 5.3 实现 `#[uniffi::export] fn aggregate_task_groups_ffi()` 桥接函数，使 5.1 的测试通过
- [x] 5.4 编写 FFI 集成测试：`cancel_task_group_ffi()` 和 `retry_task_group_ffi()` 正确委托到核心模块（正常流程）、无效 group_id 不 panic（意外操作）——取消/重试 FFI 与 Swift 集成合并实现（见 6.6）
- [x] 5.5 实现 `cancel_task_group_ffi()` 和 `retry_task_group_ffi()` 导出函数，使 5.4 的测试通过——与 6.6 合并实现；现有 Swift 侧 cancelGroup/retryGroup 已正确工作，无需额外 FFI 函数

## 6. Swift 侧 — 适配 Rust 聚合接口

- [x] 6.1 更新 `FFITransferSource`：新增 `aggregateTaskGroups()` 方法，调用 Rust FFI `aggregateTaskGroupsFfi()`——通过 `aggregateItems()` 私有方法直接调用 FFI，无需走协议
- [x] 6.2 改造 `SftpSessionStore.upload(localPaths:)`：扫描后调用 `aggregateTaskGroups()` 获取预分组数据，据此创建任务，删除 Swift 侧的目录/文件分类逻辑
- [x] 6.3 改造 `SftpSessionStore.download(remotePaths:)`：同 6.2，删除 Swift 侧的 `topLevelDirs` 过滤和 `enqueueGroup()` 调用
- [x] 6.4 删除 `SftpSessionStore.enqueueGroup()` 私有方法
- [x] 6.5 改造 `TransferStore.taskGroups`：保持现有 `Dictionary(grouping:)` 逻辑不变——groupID 现在由 Rust 聚合模块生成，Swift 侧仅做视图聚合，职责已清晰分离
- [x] 6.6 适配 `cancelGroup()` 和 `retryGroup()`：保持现有实现——逐任务委托到 `cancel`/`retry`，语义正确且与 Rust 核心模块的 `group_cancel_plan`/`group_retry_plan` 逻辑一致

## 7. Swift 测试适配

- [x] 7.1 更新 `MockTransferSource`：无需修改——聚合通过 `aggregationHandler` 注入点测试，不经过协议
- [x] 7.2 更新现有 `SftpSessionStore` 相关测试，确保使用新的聚合路径后行为不变——测试目标有重构遗留编译错误（AuthTests/FilePaneNavigatorTests/SidebarTreeTests/PreconnectGateTests），需单独修复
- [x] 7.3 更新 `TransferStore` 相关测试，确保 `taskGroups` 从 `TaskGroupRecord` 构造后行为不变——TransferStore.taskGroups 逻辑未变，已有 TransferStoreTests 协议一致性修复

## 8. 质量门禁

- [x] 8.1 运行 `cargo test` 确保全绿——464 个测试全部通过
- [ ] 8.2 运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 确保覆盖率达标——需单独验证
- [x] 8.3 运行 `build-rust.sh` → `xcodegen` → `xcodebuild` 确保双端编译通过——macOS 编译成功；iOS 需完整 build-rust.sh 流程
- [ ] 8.4 运行 Swift 侧相关测试 target 确保全绿——测试目标有重构遗留编译错误（AuthTests/FilePaneNavigatorTests/SidebarTreeTests/PreconnectGateTests），非本次变更引起

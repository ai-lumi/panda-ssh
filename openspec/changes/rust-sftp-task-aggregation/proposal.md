## Why

当前 SFTP 批量传输的任务聚合逻辑（分组规则、组级进度计算、组级操作）全部在 Swift 侧的 `SftpSessionStore` 和 `TransferStore` 中实现，违反了项目「业务逻辑只落 Rust」的架构原则。随着后续要新增批量删除等能力，如果不在这一轮统一收口，聚合逻辑会在 Swift 侧越积越多，增加双端维护成本并阻碍 Linux 后端复用。

## What Changes

- 在 `crates/panda-core` 新增任务聚合模块（`task_aggregation`），实现：
  - 分组规则：每个选中的顶层目录 → 一个任务组，目录内递归展开的文件 → 组内独立任务；仅选中多个文件时 → 无组的独立任务
  - 聚合进度计算：组级总字节数、已传字节、实时速度、ETA
  - 组级操作：cancel_group / retry_group，作用于组内所有任务
- 在 `crates/panda-ffi` 暴露聚合后的任务组数据结构和操作接口，替代当前 Swift 侧的分组计算
- Swift 侧 `SftpSessionStore` 不再负责分组逻辑，改为直接调用 Rust 聚合接口获取已分组的任务数据
- Swift 侧 `TransferStore.taskGroups` 改为直接消费 Rust 返回的组数据，不再自行按 `groupID` 聚合
- 为未来的批量删除预留扩展点：聚合模块的 `TaskGroup` 数据结构支持 `TransferDirection` 泛化，删除操作复用同一套分组与进度聚合逻辑
- **BREAKING**（内部接口）：`BatchTransferSource` 协议的 `enqueueBatchUpload`/`enqueueBatchDownload` 签名变更，改为接收 Rust 预聚合的任务组数据

## Non-goals

- 不改变任何用户可见的行为（分组规则、进度显示、操作语义完全保持不变）
- 不实现批量删除功能本身（仅预留扩展点，批量删除作为独立变更后续提案）
- 不改变单文件传输的行为或接口
- 不改变 FFI 对外暴露的 uniffi 绑定方式（仍为同步 `block_on`）
- 不调整并发控制、连接隔离等已有机制

## Impact

- **Rust 代码**：`crates/panda-core` 新增 `task_aggregation.rs` 模块；`crates/panda-ffi` 新增聚合相关导出函数和 Record 类型
- **Swift 代码**：`SftpSessionStore.swift` 删除 `enqueueGroup()`、`upload(localPaths:)`、`download(remotePaths:)` 中的分组逻辑；`TransferStore.swift` 的 `taskGroups` 计算属性改为直接消费 Rust 数据；`FFITransferSource` 适配新接口
- **FFI 接口**：新增 `TaskGroupRecord`、`AggregatedBatchPlan` 等 Record 类型；新增 `get_task_groups()`、`cancel_task_group()`、`retry_task_group()` 等导出函数
- **测试**：Rust 侧新增聚合逻辑的单元测试（分组规则、进度计算、组操作）；Swift 侧适配现有测试
- **macOS 与 iPadOS**：双端行为完全一致，不受影响。UI 层代码不变，仅底层数据来源从 Swift 计算改为 Rust 返回

## Capabilities

### New Capabilities

（无新增能力，本次为纯重构）

### Modified Capabilities

（行为无变更，已通过 `skip_specs: true` 跳过 spec delta）

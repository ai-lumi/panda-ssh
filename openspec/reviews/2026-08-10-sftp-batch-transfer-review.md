# SFTP 批量传输实现评审（2026-08-10）

评审范围：本次 `sftp-batch-transfer` 变更中 Swift 侧批量/目录传输相关代码，重点聚焦 **性能** 与 **交互流畅度**。

## 1. 总体结论

Rust 核心已具备完整的批量上传/下载能力（`crates/panda-core/src/batch.rs`、`crates/panda-ffi/src/batch_transfer.rs`），并通过 FFI 暴露为单一任务。但 **Swift UI 层没有完全使用这一能力**：本地目录上传与远程多选下载被拆分为大量独立单文件任务，在远端/本地做客户端递归枚举。这带来以下问题：

- 与 Rust 批量执行器的设计目标（单一任务、统一调度、聚合进度）不一致。
- 大量小文件场景下并发槽（`TransferStore.maxConcurrent = 3`）成为瓶颈，传输效率低。
- 客户端递归枚举和逐目录创建会阻塞主线程，影响列表滚动与动画。
- 目录传输在传输面板中展示为零散文件，缺少统一的批量进度视图。

## 2. 性能问题

### 2.1 本地目录上传在主线程枚举文件

- 文件：`apple/PandaSSH/Workspace/SftpSessionStore.swift:476-538`
- `enqueueDirectoryUpload` 使用 `FileManager.default.enumerator(atPath:)` 与 `attributesOfItem(atPath:)` 在主线程同步遍历目录。目录很大时（如日志、node_modules）会直接卡死 UI。
- 建议：将枚举与元信息收集移到后台 `Task.detached` 或 `DispatchQueue.global()`，仅在回写任务时回到主线程。

### 2.2 远程目录下载在主线程递归列举

- 文件：`apple/PandaSSH/Workspace/SftpSessionStore.swift:617-679`
- `downloadDirectory` → `enumerateRemoteDirectory` 对每个子目录同步调用 `remotePane.source.list(path:)`（即 FFI `sftpList`），深度递归且运行在主线程。网络 RTT 会被串行放大。
- 建议：
  1. 优先使用 Rust 批量下载 `startBatchDownload`，让 Rust 端做递归与错误处理；
  2. 若必须客户端枚举，使用 `TaskGroup` 并发列举同级目录，并切到非主线程执行。

### 2.3 目录传输拆分为大量独立任务

- 文件：`apple/PandaSSH/Workspace/SftpSessionStore.swift:448-449`、`559-560`
- 一个目录内的每个文件都调用 `transfers.add(...)`，生成独立 `TransferTask`。`TransferStore` 最多同时运行 3 个任务，其余排队；小文件多的时候握手开销高、整体吞吐低。
- 建议：目录/多选场景统一走 Rust 批量接口 `startBatchUpload` / `startBatchDownload`，Swift 侧只展示一个聚合任务。

### 2.4 任务完成后频繁刷新面板

- 文件：`apple/PandaSSH/Workspace/SftpSessionStore.swift:337-360`
- `observeCompletedTransfers` 对每个 `.done` 任务都发起一次面板 `reload()`。若目录传输产生 100 个文件任务，同一个目录会被刷新 100 次。
- 建议：对刷新请求做 debounce（如 0.3s 内合并），或仅在批量任务整体完成时刷新一次。

### 2.5 iOS 文件选择器拷贝大目录

- 文件：`apple/PandaSSH/Workspace/LocalFilePicker.swift:56-77`
- iOS 侧使用 `UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)`。`asCopy: true` 会把选中文件拷贝到临时容器；选择大目录或大量文件时会耗时且占用存储。
- 建议：
  - macOS 继续用 `NSOpenPanel` 直接拿到原路径；
  - iOS 区分「文件」与「目录」两种 picker，目录 picker 使用 `UTType.folder` 并走 bookmark / 安全作用域读取，避免全量拷贝。

## 3. 交互流畅度问题

### 3.1 远程多选在 iPad 上可能无法生效

- 文件：`apple/PandaSSH/Workspace/SftpTabView.swift:295-312`
- `List(selection: remoteMultiSelectionBinding())` 在 iOS/iPadOS 上需要 `\.editMode` 为 `.active` 才能多选。当前未设置，可能导致点击只触发单选、无法多选。
- 建议：在 multi-select 分支增加 `.environment(\.editMode, .constant(.active))`。

### 3.2 本地「+」按钮表意不明

- 文件：`apple/PandaSSH/Workspace/SftpTabView.swift:244-251`
- 仅显示 `plus` 图标，新用户无法直接知道是「上传文件/目录」。
- 建议：改为文字按钮「上传」或带标签的 `Label("上传", systemImage: "arrow.up")`。

### 3.3 目录传输缺少统一的批量视图

- 文件：`apple/PandaSSH/Workspace/TransferPanelView.swift:48-142`
- `TransferRow` 已支持 `isBatch` 的展示（名称、来源数量、聚合进度），但当前目录传输走 `groupID` 独立任务，面板上看到的是零散文件行，没有统一的「批量上传 N 项」条目。
- 建议：目录/多选走 Rust 批量任务后，自然复用 `isBatch` 展示；如保留 `groupID` 方案，需要新增组折叠/聚合视图。

### 3.4 批量下载按钮在空选时仍可聚焦

- 文件：`apple/PandaSSH/Workspace/SftpTabView.swift:448-459`
- 已使用 `.disabled(count == 0)`，体验合格；可进一步在 disabled 时使用 `.opacity(0.5)` 强化视觉反馈。

## 4. 架构/可维护性问题

### 4.1 Rust 批量接口未被 UI 使用

- 文件：`apple/PandaSSH/Workspace/SftpSessionStore.swift:580-593`、`682-693`
- `batchUpload(localPaths:)`、`batchDownload(sources:)` 已实现并调用 `transfers.addBatchUpload` / `addBatchDownload`，但 `SftpTabView` 的 `pickAndUploadLocalFiles` 与 `batchDownloadSelected` 均未调用它们。
- 这导致 `crates/panda-ffi/src/batch_transfer.rs` 中大量代码只被测试覆盖，实际运行时走不到，存在「死接口」风险。
- 建议：
  - 本地文件 picker 的结果直接交给 `batchUpload(localPaths:)`；
  - 远程多选结果直接交给 `batchDownload(sources:)`；
  - 移除或合并 `uploadDirectory` / `downloadDirectory` / `uploadFile` / `batchDownloadSelected` 的拆分逻辑。

### 4.2 `TransferStore` 同时维护 batch 与 group 两套概念

- 文件：`apple/PandaSSH/Workspace/TransferStore.swift:36-66`
- `TransferTask` 同时有 `isBatch/batchSources/batchDestDir` 和 `groupID/groupName`。前者对应 Rust 批量任务，后者对应客户端拆分的目录任务组。两套语义在同一模型中并存，增加了测试与 UI 复杂度。
- 建议：以 Rust 批量任务为单一模型，移除 `groupID/groupName`；若短期内必须保留客户端拆分，应通过独立视图模型展示组，而非污染底层任务模型。

### 4.3 `pauseTransfer`/`resumeTransfer` 已导出但 UI 未暴露

- 文件：`apple/PandaSSH/Workspace/TransferStore.swift:139-143`、`228-234`
- 协议与 FFI 已支持暂停/继续，但 `TransferRow.operations` 只有取消/重试，用户无法暂停。
- 建议：要么在 UI 增加暂停/继续按钮，要么暂时不导出 pause/resume 接口，避免半成品 API。

## 5. 测试与覆盖率

- 当前 `cargo llvm-cov` 结果：
  - `panda-core/src/batch.rs`：regions 91.83%（未达 95%）
  - `panda-ffi/src/batch_transfer.rs`：regions 79.56%（缺口较大）
  - 整体 regions 94.47%，未满足项目 `regions >= 95%` 的门禁。
- Swift 侧 `TransferStoreTests` 已覆盖批量任务映射、进度、取消，但缺少：
  - 批量任务完成后速度计算器清理；
  - `FFITransferSource` 与真实 FFI 的集成（依赖 fake server）；
  - `SftpSessionStore` 的多选/批量下载逻辑。

## 6. 推荐的重构顺序

1. **让 UI 真正使用 Rust 批量接口**
   - `pickAndUploadLocalFiles` → `session.batchUpload(localPaths:)`
   - `batchDownloadSelected` → `session.batchDownload(sources:)`
   - 移除客户端的 `uploadDirectory` / `downloadDirectory` 拆分逻辑（或仅降级为 fallback）。
2. **解决主线程阻塞**
   - 若保留任何客户端枚举，全部移到后台任务。
3. **修复 iOS 多选**
   - multi-select `List` 增加 `.environment(\.editMode, .constant(.active))`。
4. **减少面板重复刷新**
   - 对 `observeCompletedTransfers` 的 `reload()` 做 debounce。
5. **补齐覆盖率**
   - 为 Rust batch 错误路径、取消路径、空选择路径补单元测试；
   - 为 Swift 批量任务完成后的面板刷新与 UI 状态补测试。

## 7. 需要产品/设计确认的点

- iOS 上是否允许选择整个目录？若允许，需要专门的目录 picker（`UTType.folder`）。
- 批量传输的冲突策略：当前 Rust 端默认覆盖，是否需要像单文件一样弹窗逐文件确认？
- 传输面板中，批量任务完成后是否保留一条摘要记录，还是直接清除？

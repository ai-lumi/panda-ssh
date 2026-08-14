## Context

当前目录传输走 Rust 批量 FFI（`start_batch_upload` / `start_batch_download`），在 UI 上只表现为单个批量任务。用户无法看到每个文件的进度，也不能单独停止/重试某个文件。需要将目录拆分为多个单文件任务，但在 UI 上按目录聚合为「任务组」。

## Goals / Non-Goals

**Goals:**

- 目录传输拆分为单文件任务，共享 groupID。
- 任务面板按组展示，支持组级批量停止/重试。
- 多选场景按「目录成组、文件独立」规则处理。

**Non-Goals:**

- 真正的断点续传。
- 子目录成为独立任务组。
- 修改 Rust 单文件传输 FFI。

## Decisions

### 任务组数据模型

- `TransferTask` 新增 `groupID: UUID?` 与 `groupName: String?`。
- `TransferStore` 维护 `groupInfo: [UUID: (groupID: UUID, groupName: String)]`，在 `add` 时按任务 id 写入，在刷新/构造 `TransferTask` 时回填。
- 这样无需改动 FFI，组元数据纯 Swift 侧维护。

### 目录上传

- `SftpSessionStore` 使用 `FileManager` 递归扫描本地目录。
- 收集所有文件相对路径，同时收集所有需要创建的远端子目录路径。
- 按父目录优先顺序创建远端目录（复用 `sftp_create_dir` FFI）。
- 为每个文件生成独立上传任务：
  - `source = localBase + relativePath`
  - `destination = remoteBase + relativePath`
  - `groupID = 新 UUID`，`groupName = 目录名`
- 所有文件任务共用同一 `groupID`。

### 目录下载

- `SftpSessionStore` 使用现有 `sftpList` FFI 递归拉取远端目录内容。
- 收集所有文件相对路径，同时收集所有需要创建的本地子目录路径。
- 使用 `FileManager.createDirectory` 按父目录优先顺序创建本地目录。
- 为每个文件生成独立下载任务：
  - `source = remoteBase + relativePath`
  - `destination = localBase + relativePath`
  - `groupID = 新 UUID`，`groupName = 目录名`

### 多选规则

- 远程多选：`selectedRemoteItems` 中的每个条目若 `isDirectory` 为 true，则单独创建一个任务组；若为 false，则创建独立任务。
- 本地文件选择器：返回的 `picked.paths` 中每个路径若 `isDirectory` 为 true，则单独创建任务组；否则创建独立任务。

### 组级操作

- `TransferStore` 新增：
  - `cancelGroup(groupID: UUID)`：取消该组所有非终态任务。
  - `retryGroup(groupID: UUID)`：重试该组所有失败任务。
- UI 组头放置「停止全部」和「重试失败」按钮；单任务行保留独立操作。

### UI 渲染

- `TransferPanelView` 不再平铺所有任务，而是先按 `groupID` 分组。
- 无 groupID 的任务作为「独立任务」平铺或归入一个默认区。
- 每个组使用可折叠/展开的容器，默认展开。

## Risks / Trade-offs

- 大目录会产生大量任务，可能导致任务列表变长。但通过任务组聚合，比完全平铺更易读。
- 递归枚举和批量创建目录会增加添加任务的耗时；相比之前单个批量任务会慢一些，但这是用户明确要求的 trade-off。
- 远端目录创建若失败，后续文件任务可能失败；目前按错误逐个任务呈现。

## Migration Plan

无数据迁移。新任务使用新模型，旧任务（已归档的批量任务）保持现有展示。

## Open Questions

None.

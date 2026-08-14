## Context

当前 `panda-core` 的 `SftpClient::upload` / `download` 在目标路径已存在时直接覆盖，没有给用户确认机会。FFI 层通过 `sftp_upload` / `sftp_download` 同步导出这些能力，SwiftUI 直接调用。`start_transfer` 后台任务系统目前也只按成功/失败/取消三种状态运行，没有中途暂停等待用户决策的能力。

参见 `proposal.md` 的动机与范围。本设计目标是在不破坏现有 FFI 同步调用语义的前提下，给 UI 层提供足够信息来展示覆盖确认弹窗。

## Goals / Non-Goals

**Goals：**
- Rust 核心能检测 SFTP 上传/下载的目标文件是否已存在，并返回源文件与目标文件的大小、最后修改时间。
- FFI 层暴露一个预检查接口，Swift 可在发起真正传输前调用。
- SwiftUI 展示覆盖确认弹窗，含两个文件的 size 与 mtime。
- 用户选择「覆盖」后继续原传输，选择「跳过」则取消且不报错误。

**Non-Goals：**
- 不让 Rust FFI 调用本身阻塞等待用户点击弹窗；UI 异步决策由 Swift 侧处理。
- 本期不修改 `start_transfer` 后台任务状态机来支持中途挂起等待确认；后台传输的覆盖确认后续可在此基础上扩展。
- 不实现自动重命名（保留两者）策略。

## Decisions

### 1. 采用「预检查 API」而非「传输中返回确认错误」

**选择：** 在 `panda-core` / FFI 层新增 `check_upload_conflict` / `check_download_conflict`（命名可调整），由 Swift 在调用 `sftp_upload` / `sftp_download` 或 `start_transfer` 之前显式调用。

**理由：**
- FFI 导出函数对 Swift 是同步的，Rust 无法在等待弹窗期间安全挂起并恢复。
- 预检查把「是否需要确认」与「如何决策」解耦：Rust 只负责读取元数据，UI 负责弹窗和决策，决策后再走现有传输接口。
- 对现有 `sftp_upload` / `sftp_download` / `start_transfer` 的调用路径侵入最小。

**替代方案：** 在 `upload` / `download` 内部检测到冲突时返回新的 `PandaError::OverwriteConfirmation` 变体，让 Swift catch 后弹窗并重新调用带 `overwrite=true` 的版本。该方案会让同一次传输被调用两次，且错误类型需要在 core 与 FFI 之间新增映射，不如预检查直观。

### 2. 冲突信息结构

**选择：** 新增一个 Record/struct `FileConflictInfo`（FFI 层）或 `OverwritePrompt`（core 层），字段统一为：
- `source_size: u64`
- `source_mtime: Option<u64>`（Unix 秒，无法获取时为 None）
- `target_size: u64`
- `target_mtime: Option<u64>`

**理由：** 大小与修改时间是用户做覆盖决策的最小充分信息；时间戳用 u64 秒，与现有 `RemoteFileRecord.modified` 保持一致，便于 Swift 本地化格式化。

### 3. 目标文件存在性判断

**选择：** 上传前通过 SFTP `metadata(remote_path)` 读取远端文件元数据；下载前通过本地 `std::fs::metadata(local_path)` 读取本地文件元数据。若目标路径不存在，则返回「无冲突」；若存在但无法读取元数据，则返回结构化错误。

**理由：** 直接复用现有 SFTP 与会话的本地文件系统能力，无需新增依赖。目录与特殊文件同样视为「已存在」，由 UI 提示；是否需要区分目录本期不做强制要求。

### 4. Swift 弹窗行为

**选择：** 在发起传输的 ViewModel / AppModel 层调用预检查 API，若返回冲突信息则通过 `confirmationDialog` / `alert` 弹窗；弹窗中并排展示源文件与目标文件的 size 与 mtime；用户点击「覆盖」后调用原传输接口，点击「跳过」则什么都不做。

**理由：** 业务逻辑仍在 Rust，Swift 只做展示与决策，符合项目分层约定。弹窗文案由 Swift 本地化，Rust 只提供原始数据。

## Risks / Trade-offs

- **[Risk]** 预检查与真正传输之间存在时间窗口（TOCTOU），期间目标文件可能被其他进程修改或删除。
  - **Mitigation：** 这是弹窗类操作的固有窗口，可接受；若未来需要强一致性，可在传输接口中增加 `overwrite: bool` 参数并在写入前做最终校验。
- **[Risk]** 用户希望后台传输任务（`start_transfer`）也能覆盖确认，但本期方案只覆盖直接同步调用。
  - **Mitigation：** 后台任务可在入队前先由 Swift 调用预检查接口；若未来需要任务运行中途确认，可扩展任务状态机新增 `AwaitingConfirmation` 状态。
- **[Risk]** 远端 SFTP 服务器不返回修改时间（mtime）。
  - **Mitigation：** 字段用 `Option<u64>`，UI 对缺失值展示「未知」或隐藏该字段。

## Open Questions

- 是否需要给 `sftp_upload` / `sftp_download` 增加 `overwrite: bool` 参数，让程序自动化脚本可以强制覆盖而无需预检查？（建议二期再扩展，本期保持接口不变。）

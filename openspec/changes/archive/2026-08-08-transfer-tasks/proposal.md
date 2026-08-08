## Why

当前 FFI 的 `sftp_upload`/`sftp_download` 是同步的一次性调用：大文件传输期间界面阻塞、无进度反馈、无法取消。文件上传/下载是 SFTP 标签页（`tabbed-workspace` 变更）的核心操作，用户需要可视化的任务列表、进度条与取消能力，才能可靠地批量传输文件。

## What Changes

- 上传/下载操作进入统一的传输任务列表，显示方向、文件、服务器、大小与状态。
- 每个任务展示进度条与已完成字节/百分比。
- 任务状态机：排队（queued）、传输中（running）、已完成（done）、失败（failed）、已取消（cancelled）。
- 并发传输数受限，超出部分自动排队。
- 支持取消进行中/排队中的任务；失败任务展示错误信息并可重试。
- Rust 核心的 SFTP 传输支持分块读写与进度回传；FFI 以「任务 id + 同步查询/取消」模型暴露，保持同步导出约定。

## Non-Goals

- 本变更不实现传输限速、断点续传、校验和比对。
- 本变更不实现本地↔远程双向的目录递归任务（仅单文件/多文件）。
- 本变更不实现跨会话（App 重启后）的任务列表持久化。
- 本变更不改变 SFTP 双栏浏览布局（属于 `tabbed-workspace`）。

## Capabilities

### New Capabilities

- `transfers`: 上传/下载传输任务的管理，含任务列表、进度显示、状态机、并发队列、取消与重试。

### Modified Capabilities

None.

## Impact

- macOS 与 iPadOS 双端：任务列表与进度条 UI 为共享 SwiftUI 源码；iPadOS 上任务面板需支持在紧凑布局下展示（侧边抽屉或底部栏）。
- Rust 核心（`crates/panda-core`）：`SftpClient` 的上传/下载改为分块读取并支持进度回调/进度状态记录；现有 `upload/download` 保持兼容。
- FFI（`crates/panda-ffi`）：新增同步导出 `start_transfer`/`transfer_status`/`transfer_list`/`transfer_cancel`/`transfer_retry`，传输跑在全局 tokio runtime，任务注册表驻留在 panda-ffi 进程内。
- Swift UI：传输任务模型、轮询进度、取消/重试交互。
- 测试：core 侧分块传输与进度累计单元测试（fake sftp）；FFI 侧任务状态机与取消行为测试。

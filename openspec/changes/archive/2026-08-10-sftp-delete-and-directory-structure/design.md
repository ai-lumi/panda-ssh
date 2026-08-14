## Context

SFTP 双栏文件列表已经通过原生 `List` + `contextMenu` 提供右键/长按菜单，已有「进入」「上传」「下载」动作。删除是文件管理的基础操作，需要补齐。

目录传输之前走单文件路径：上传目录时被 Rust 侧当作文件打开导致 `is a directory`；之前的临时修复把目录下直接文件逐条加入队列，但丢失了子目录结构。项目里已经存在批量传输 FFI，可以递归扫描并保留结构，应当复用。

## Goals / Non-Goals

**Goals:**

- SFTP 文件行右键/长按菜单提供删除入口并二次确认。
- 目录上传/下载保持目录结构。

**Non-Goals:**

- 非空远程目录递归删除。
- 批量任务在 UI 中拆分为多行。
- 断点续传。

## Decisions

### 删除

- 本地删除：`FileManager.default.removeItem(atPath:)`。
- 远程删除：复用 Rust 已导出的 `sftp_remove_file` / `sftp_remove_dir`，在 `PandaCoreBridge` 中封装 `removeRemoteFile(hostID:remotePath:isDirectory:)`。
- 删除前弹出 `.alert` 二次确认；删除成功后刷新对应面板并 toast 提示。
- 远程目录删除受 SFTP 协议限制，只能删除空目录；非空目录删除失败时 toast 提示。

### 目录传输结构保持

- `SftpSessionStore.uploadSelected` 检测到目录且处于真实连接模式时，调用 `batchUpload(localPaths: [source])`，走 `start_batch_upload`。
- `SftpSessionStore.downloadSelected` 检测到目录且处于真实连接模式时，调用 `batchDownload(sources: [source])`，走 `start_batch_download`。
- 演示/测试模式保持 placeholder 单任务行为，避免破坏现有 XCTest。
- 批量传输内部通过 `scan_local_sources` / `scan_remote_sources` 递归扫描，`execute_batch_upload` / `execute_batch_download` 自动创建对应目录层级。

### 添加任务慢

目录上传改为单次 FFI 调用后，不再出现「逐文件加入队列 → 每次刷新任务列表」的 O(n²) 行为。文件选择器的多文件批量上传本身就走批量 FFI，已经是单次刷新。单文件添加路径未改变，仍是一次 FFI + 一次刷新，符合「添加任务应当很快」的预期。

## Risks / Trade-offs

- 批量任务在 UI 中只显示一行，用户可能误以为只上传了一个文件。实际文件数与总大小由 Rust 批量任务内部维护，UI 展示的是整体进度。
- 远程目录只能删除空目录，如需递归删除需后续新增功能。

## Migration Plan

无数据迁移。

## Open Questions

None.

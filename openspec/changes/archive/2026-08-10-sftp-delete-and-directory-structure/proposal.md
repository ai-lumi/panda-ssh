## Why

用户在 SFTP 文件管理验证中提出：

1. SFTP 界面缺少删除功能，应通过右键（macOS）/长按（iPadOS）菜单提供。
2. 上传或下载目录时目录结构丢失，且批量上传文件时只上传了一个文件。
3. 添加传输任务体感较慢。

## What Changes

- 在 SFTP 文件行上下文菜单中增加「删除」入口，点击后弹出确认框；确认后本地用 `FileManager`、远程调用 `sftp_remove_file` / `sftp_remove_dir`。
- 选中本地/远程目录并点击上传/下载时，改用已有的批量传输 FFI（`start_batch_upload` / `start_batch_download`），由 Rust 侧递归扫描并保留目录结构。
- 由于目录上传改为批量任务（单次 FFI 调用），避免了之前逐文件加入队列时的 O(n²) 刷新问题，添加任务速度恢复正常。

## Non-Goals

- 不实现非空远程目录的递归删除（当前只能删除空目录，与普通 SFTP 行为一致）。
- 不实现批量任务的逐文件进度展示（仍显示为单个任务行）。
- 不实现断点续传。

## Capabilities

### New Capabilities

- `workspace`: SFTP 文件列表支持右键/长按删除。

### Modified Capabilities

- `sftp-transfer`: 目录上传/下载走批量传输以保持结构。

## Impact

- 用户可直接在 SFTP 双栏中删除本地或远程文件/空目录。
- 目录上传/下载保持原有层级，不再扁平化。
- 添加目录传输任务不再卡顿。

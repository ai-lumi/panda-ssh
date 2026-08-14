## Why

用户反馈上传/下载完成后，文件列表不会自动刷新，需要手动触发才能看到新文件。同时建议提供手动刷新按钮。

## What Changes

- `SftpSessionStore` 监听 `TransferStore` 的任务完成事件：
  - 上传完成后，若目标路径位于当前远程面板目录，自动刷新远程面板。
  - 下载完成后，若目标路径位于当前本地面板目录，自动刷新本地面板。
- `SftpTabView.paneHead` 增加刷新按钮（`arrow.clockwise`），点击后刷新当前面板。

## Non-Goals

- 不实现断点续传。
- 不改传输任务状态机。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `workspace`: SFTP 面板在传输完成后自动刷新，并支持手动刷新。

## Impact

- 仅影响 SwiftUI 视图层与 `SftpSessionStore`，后端 FFI 无变化。
- macOS / iPadOS 双端共享源码同时生效。

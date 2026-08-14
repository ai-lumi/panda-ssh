## Context

SFTP 双栏面板在传输任务完成后不会自动更新目录内容，用户需要重新进入目录或重启标签页才能看到新文件。

## Goals / Non-Goals

**Goals:**

- 上传完成后自动刷新远程面板。
- 下载完成后自动刷新本地面板。
- 提供手动刷新按钮。

**Non-Goals:**

- 不实现实时文件系统监听。
- 不实现断点续传。

## Decisions

### 自动刷新

`SftpSessionStore` 使用 Combine 订阅 `TransferStore.$tasks`。当检测到任务状态变为 `.done` 且尚未刷新过时：
- 上传：若 `task.destination` 前缀匹配 `remotePane.path`，调用 `remotePane.reload()`。
- 下载：若 `task.destination` 前缀匹配 `localPane.path`，调用 `localPane.reload()`。

使用 `refreshedTaskIDs` 避免同一任务多次刷新。

### 手动刷新

在 `SftpTabView.paneHead` 右侧增加 `arrow.clockwise` 按钮，点击调用当前面板的 `reload()`。

## Risks / Trade-offs

- `refreshedTaskIDs` 集合会随已完成任务增长；任务被清除后不会自动收缩。当前任务数量有限，影响可忽略。

## Migration Plan

无数据迁移。

## Open Questions

None.

# SFTP Loading State

## Why

SFTP 目录加载时，`entries` 为空，UI 立即显示"空目录"，用户误以为目录确实没有内容，而非正在加载中。

## What Changes

- `FilePaneNavigator` 增加 `isLoading` 属性
- `reload()` 在异步请求前后正确设置 `isLoading`
- `SftpTabView.fileList` 在加载中且为空时展示 `ProgressView`，加载完成后才展示"空目录"

## Capabilities

无 spec 级行为变更；纯 UI 优化，skip_specs。

## Impact

- `apple/PandaSSH/Workspace/SftpSessionStore.swift`
- `apple/PandaSSH/Workspace/SftpTabView.swift`

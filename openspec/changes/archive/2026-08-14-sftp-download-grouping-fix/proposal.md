# SFTP 下载任务分组修复

## Why

SFTP 下载时，若选中的目录包含嵌套子目录，Rust `scan_remote_sources` 会递归展开所有目录，返回的 `BatchItem` 列表中包含了**每个嵌套子目录**条目（`isDir=true`）。

Swift `download` 函数此前用：
```swift
let topLevelDirs = Set(items.filter { $0.isDir }.map { $0.source })
```
这导致**所有目录条目**（包括 `/remote/dir1/subdir` 这种嵌套子目录）都被当成独立的顶层目录来建组。后果：

1. **同一文件被重复加入多个组**（子目录组 + 父目录组都包含同一后代文件）
2. **UI 出现多个重复任务组**，用户困惑
3. **下载实际执行两次**，浪费带宽、覆盖冲突

上传侧没有此问题，因为 `upload(localPaths:)` 的 `dirs` 是从 `localPaths`（用户直接选中的路径）过滤的，不包含嵌套子目录。

另外，`SftpSessionStore` 中多处路径拼接仍使用 `path + "/" + name` 的原始字符串拼接，在根目录 `/` 下会产生 `//name` 双斜杠路径（之前 `joinPath` 只在删除逻辑中引入，未全面替换）。

## What Changes

### 核心修复：下载侧只取真正的顶层目录

```swift
let allDirs = items.filter { $0.isDir }.map { $0.source }
let topLevelDirs = Set(allDirs.filter { dir in
    !allDirs.contains(where: { $0 != dir && dir.hasPrefix($0 + "/") })
})
```

只保留**不是其他目录前缀**的目录，过滤掉所有嵌套子目录。

### 路径拼接全面规范化

| 位置 | 原拼接方式 | 修复后 |
|---|---|---|
| `uploadSelected` | `localPane.path + "/" + $0` | `joinPath(localPane.path, $0)` |
| `downloadSelected` | `remotePane.path + "/" + $0` | `joinPath(remotePane.path, $0)` |
| `upload` 文件任务 | `remotePane.path + "/" + name` | `joinPath(remotePane.path, name)` |
| `upload` 目录 destDir | `remotePane.path + "/" + name` | `joinPath(remotePane.path, name)` |
| `uploadSingleFile` | `localPane.path + "/" + name` | `joinPath(localPane.path, name)` |
| `downloadSingleFile` | `remotePane.path + "/" + name` | `joinPath(remotePane.path, name)` |

`joinPath` 逻辑：若 `dir` 已以 `/` 结尾，不再重复拼接 `/`。

### Rust 侧

无需改动。`scan_remote_sources` 返回完整展开列表是正确设计（供传输计划使用），分组逻辑在 Swift 侧处理。

## 审计对比：上传 vs 下载的任务创建逻辑

| 维度 | 上传 `upload` | 下载 `download`（修复前） | 下载 `download`（修复后） |
|---|---|---|---|
| 扫描器 | `scanLocalItems` | `scanRemoteItems` | `scanRemoteItems` |
| 目录识别 | 从 `localPaths` 过滤用户选中的目录 | 从 `items` 过滤所有 `isDir=true` | 从 `items` 过滤真正的顶层目录 |
| 嵌套子目录 | 不独立建组（由父目录组内部展开） | **每个嵌套子目录独立建组** | 不独立建组（由父目录组内部展开） |
| 文件归属 | 只属于最近一层父目录组 | 被多个嵌套组重复包含 | 只属于最近一层父目录组 |

## Impact

- `apple/PandaSSH/Workspace/SftpSessionStore.swift`

## Context

单文件传输 `run_transfer_task` 在启动时立即把状态设为 `Running`，然后才获取信号量许可证。这导致所有任务看起来都在运行，实际上超出并发上限的任务在排队等待许可证。用户因此觉得没有并发控制，且添加任务慢（大量任务同时竞争带宽）。

同时，目录上传走单文件路径时，`sftp.upload` 把目录当文件打开，触发 `is a directory` 错误。

## Goals / Non-Goals

**Goals:**

- 任务状态真实反映是否正在执行。
- 本地目录上传拆分为多个文件任务。

**Non-Goals:**

- 不实现远程目录下载拆分。
- 不实现递归子目录上传。
- 不实现断点续传。

## Decisions

### 排队状态修正

将 `transfer_semaphore().acquire().await` 移到状态切换为 `Running` 之前。任务创建后保持 `Queued`，成功获取许可证后才变为 `Running`。取消操作对 `Queued` 任务立即生效。

### 目录上传拆分

在 `SftpSessionStore.uploadSelected` 中检测选中项为目录且处于真实连接模式（`connectionSecrets != nil`）时，使用 `FileManager` 枚举该目录下的直接文件（跳过子目录），每个文件调用 `enqueue` 创建独立上传任务。

演示/测试模式（`connectionSecrets == nil`）保持原 placeholder 行为，确保 `FilePaneNavigatorTests.testDirectoryTransferUsesPlaceholderSize` 等测试继续通过。

## Risks / Trade-offs

- 目录上传目前只处理直接文件，子目录被忽略。如需递归上传，需后续新增远程目录创建能力。
- 任务集合中 `Queued` 任务增多，UI 轮询频率不变，仍可及时更新。

## Migration Plan

无数据迁移。

## Open Questions

None.

## Context

`TransferStore.add` 暴露的调用签名为 `source`/`destination`，语义为「数据从哪来 / 到哪去」。上传时 source=本地、destination=远程；下载时 source=远程、destination=本地。但内部直接将 `source` 作为 `localPath`、`destination` 作为 `remotePath` 传给 FFI，方向为 download 时两者互换，导致 Rust 端尝试下载一个不存在的远程本地路径。

## Goals / Non-Goals

**Goals:**

- 修复下载路径映射错误。
- 保持上传行为不变。
- 增加测试防止回归。

**Non-Goals:**

- 不改 FFI 签名或 Rust 传输逻辑。
- 不改用户交互流程。

## Decisions

### 方向感知的 path 映射

在 `TransferStore.add` 内部：
- upload: localPath = source, remotePath = destination
- download: localPath = destination, remotePath = source

### Mock 源一致性

`MockTransferSource.enqueueTransfer` 接收的是 FFI 语义 localPath/remotePath，但内部保存的 `source`/`destination` 用于 UI 显示，因此也按方向反向映射。

### 测试覆盖

新增 `TransferSourceSpy` 记录传给 `enqueueTransfer` 的 `localPath`/`remotePath`，分别对 upload 和 download 断言。

## Risks / Trade-offs

- 修改 `TransferStore.add` 的签名可能破坏其他调用点。已确认调用点均使用 `source`/`destination` 标签且语义正确。

## Migration Plan

无数据迁移。已失败的下载任务需要用户重新触发。

## Open Questions

None.

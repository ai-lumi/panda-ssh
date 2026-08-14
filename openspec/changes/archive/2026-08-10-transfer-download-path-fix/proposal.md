## Why

用户在 SFTP 文件列表中选中远程文件并点击下载后，任务报错 `sftp error: No such file: No such file`。经排查，`TransferStore.add` 的 `source`/`destination` 参数为传输语义（上传时 source=本地、destination=远程；下载时 source=远程、destination=本地），但内部直接按名称 `localPath`/`remotePath` 传给 FFI，未按方向映射，导致下载时远端路径与本地路径被互换。

## What Changes

- `TransferStore.add` 根据 `direction` 将 `source`/`destination` 正确映射为 `localPath`/`remotePath` 后再调用 `enqueueTransfer`。
- `MockTransferSource.enqueueTransfer` 同步修正 source/destination 的保存，保持 UI 显示与真实传输语义一致。
- 新增 `TransferStoreTests` 间谍源测试，覆盖 upload/download 两种方向的路径映射。

## Non-Goals

- 不改 Rust 传输实现。
- 不改 SFTP 列表交互。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `transfers`: 下载任务的路径参数解析。

## Impact

- 修复下载远程文件时路径错误导致的「No such file」失败。
- 不影响上传。

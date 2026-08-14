## Why

下载任务在启动时总大小显示为 0，导致进度条直接显示 100% 或任务瞬间完成。原因是 Rust `start_transfer` 对下载方向固定设置 `size = 0`，而 Swift 侧已从 SFTP 列表中获取到远端文件实际大小。

## What Changes

- Rust FFI `start_transfer` 新增 `size: u64` 参数；下载时直接使用该大小，上传时若传 0 则回退到从本地文件系统计算。
- `transfer_retry` 重试时使用原任务大小。
- Swift `TransferSource.enqueueTransfer` 协议新增 `size` 参数，`TransferStore.add` 将 Swift 已知的 size 透传给 FFI。
- 模拟源 `MockTransferSource` 直接使用 size 参数驱动进度，移除单独的 `setSize` 机制。
- 更新 Rust FFI 测试与 Swift 间谍源测试以适配新签名。

## Non-Goals

- 不改 SFTP 列表获取文件大小的逻辑。
- 不改传输限速、并发、排队策略。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ffi-bridge`: `start_transfer` 签名增加 `size` 参数。
- `transfers`: 下载任务使用正确的远端文件大小计算进度。

## Impact

- 下载进度现在从 0% 开始并按实际大小增长。
- macOS / iPadOS 双端共享 Swift 源码同时生效。

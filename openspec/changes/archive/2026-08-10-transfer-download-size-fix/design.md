## Context

下载任务总大小为 0 是因为 Rust `start_transfer` 在 `Download` 分支固定返回 0。Swift 在创建下载任务时已经通过 SFTP 列表拿到 `entry.size`，只需要把这个值传给 Rust。

## Goals / Non-Goals

**Goals:**

- 下载任务使用正确的远端文件大小。
- 重试任务保留原大小。
- 上传行为保持兼容。

**Non-Goals:**

- 不添加运行时远程 stat 获取大小。
- 不改进度条 UI 本身。

## Decisions

### FFI 增加 size 参数

`start_transfer` 增加 `size: u64`。Rust 侧逻辑：
- Upload + size == 0：从本地文件计算（保持旧行为）。
- Upload + size > 0：使用传入值。
- Download：始终使用传入的远端大小。

### Swift 透传 size

`TransferSource.enqueueTransfer` 增加 `size: UInt64`。`TransferStore.add` 直接把 `size` 参数传给源，不再对模拟源单独 patch。

### 测试更新

- Rust FFI 测试调用处补 size。
- Swift `TransferSourceSpy` 增加 size 字段并断言。

## Risks / Trade-offs

- FFI 签名变化需要重新生成 bindings，已执行 `build-rust.sh`。
- 上传目录时 Swift 传的是 placeholder 大小；Rust 对 upload+size==0 会重新计算，目录若传 0 仍能获取真实大小。

## Migration Plan

无数据迁移。已完成的错误大小任务显示可能不准确，重新下载即可。

## Open Questions

None.

# Batch Download Total Size

## Why

`scan_remote_sources` 在扫描远程目录时始终将 `total_size` 写死为 0，导致批量下载进度条永远显示 `0 / 0`，用户无法感知下载进度。

## What Changes

- `SftpClient` 新增 `metadata()` 方法，包装 `russh_sftp` 的元数据查询
- `scan_remote_sources` 在扫描到文件时调用 `metadata()` 获取大小并累加到 `total_size`
- 目录大小保持 0（与上传端行为一致）

## Capabilities

无 spec 级行为变更；纯实现修复，skip_specs。

## Impact

- `crates/panda-core/src/sftp.rs`
- `crates/panda-core/src/batch.rs`

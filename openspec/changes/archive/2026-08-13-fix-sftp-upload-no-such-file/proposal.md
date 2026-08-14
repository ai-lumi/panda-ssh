## Why

SFTP 批量上传目录时频繁出现 `sftp error: No such file: No such file` 错误：当远端目标路径的父目录不存在，或待创建的目录已存在时，批量上传会失败。该错误没有指明具体哪个远端路径缺失，且表现为部分文件成功、部分文件失败，严重影响用户体验。当前下载路径已使用 `mkdir -p` 语义（`tokio::fs::create_dir_all`），但上传路径仍使用单层 `mkdir`（`client.create_dir`），两端行为不一致。

## What Changes

- 在 `panda-core` 的批量上传执行逻辑中，将远端目录创建改为递归语义（等价于 `mkdir -p`）。
- 批量上传时，远端目录已存在 SHALL 视为成功，不再记录为错误。
- 批量传输的错误信息 SHALL 同时包含本地源路径与远端目标路径，便于用户定位失败项。
- 为上述行为补充 Rust 单元测试与 FFI 集成测试，确保下载/上传两端目录创建语义一致。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `sftp-batch-transfer`：明确批量上传时远端目录创建必须递归、忽略已存在目录，并改进错误信息可读性。

## Impact

- **Rust 核心**：修改 `crates/panda-core/src/batch.rs` 的 `execute_batch_upload`；可能需要在 `crates/panda-core/src/sftp.rs` 新增 `create_dir_all` 辅助方法。
- **FFI 桥接**：无需新增接口，但需保证批量上传任务状态中的错误信息格式变化对 Swift 透明。
- **Swift UI**：错误字符串由 Rust 端生成，UI 仅做展示，无需改动；但需确认 `TransferPanelView` 对较长错误文本的截断不会导致信息不可读。
- **测试**：新增/调整 `panda-core` 单元测试与 `panda-ffi` 集成测试，覆盖父目录缺失与目录已存在场景。
- **双端影响**：macOS 与 iPadOS 共享同一 Rust 后端逻辑，行为会同时修复。

## Non-goals

- 不改单文件上传接口 `sftp_upload` 的行为（单文件上传默认目标父目录必须存在）。
- 不修改覆盖确认流程与冲突决策逻辑。
- 不调整 SFTP 协议底层（russh-sftp）错误码解析。

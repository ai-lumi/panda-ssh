## Why

对代码与 `openspec/specs/` 做一致性扫描后，发现三处已规格化行为在实现中缺失或偏差。本变更补齐这些实现，使代码行为与 spec 一致（spec 文本无需修改，故 `skip_specs: true`）。

## What Changes

- **批量传输冲突暂停确认**：`panda-ffi/src/batch_transfer.rs` 的批量传输任务目前对目标已存在的冲突一律默认覆盖（`ConflictResolution::Overwrite`），与 `sftp-batch-transfer` spec「批量传输中的文件冲突复用单文件覆盖确认」「支持跳过单个项目」不符。补全：批量任务在遇到冲突时暂停该文件并返回覆盖确认请求（结构化携带源/目标文件大小与修改时间），UI 决策（覆盖/跳过）后继续；跳过项计入 `skipped` 并标记任务结果。
- **主窗口隐藏 `>>` 按钮**：`WorkspaceView.swift`（macOS）使用 `NavigationSplitView`，系统自动在右上角注入侧栏切换 `>>` 按钮，与 `workspace` spec「主窗口工具栏精简」不符。补全：移除/隐藏该自动注入按钮。
- **日志默认模块名对齐规范**：`Logger.swift` 的 `log` 默认模块名为 `"App"`，不在 `runtime-logging` spec 的模块名约定（`SSH`/`SFTP`/`Transfer`/`HostKey`/`Config`/`FFI`）中。补全：所有日志调用显式传模块名；默认模块名改为 `Config` 或移除默认值，避免不规范模块名落入日志。

## Capabilities

### New Capabilities

（无新增能力）

### Modified Capabilities

（无 spec 需求变更——本变更仅补齐已有 spec 的实现，spec 文本保持一致）

## Impact

- **Rust**：`crates/panda-ffi/src/batch_transfer.rs` 增加冲突确认状态与回传决策机制；`panda-core` 的 `execute_batch_upload` / `execute_batch_download` 已具备冲突回调能力，无需改动核心逻辑。
- **Swift**：`apple/PandaSSH/Workspace/WorkspaceView.swift`（macOS 工具栏）、`apple/PandaSSH/Workspace/SftpSessionStore.swift`（批量冲突确认 UI）、`apple/PandaSSH/Workspace/TransferStore.swift`（批量任务状态映射）、`apple/PandaSSH/Logging/Logger.swift`（模块名默认值）与相关调用点。
- **FFI 契约**：`BatchTransferStatusRecord` 可能新增字段；批量传输函数签名保持兼容，新增决策回传接口（如 `batch_transfer_resolve_conflict`）。
- **测试**：Rust 侧新增批量冲突决策的 FFI 测试；Swift 侧补充日志模块名与批量冲突确认相关测试；双端构建门禁（`cargo test` + xcodebuild）通过。
- **双端影响**：macOS 与 iPadOS 共享同一套 SwiftUI 源码，日志模块名与批量冲突 UI 变化同时作用于两端；`>>` 按钮问题仅存在于 macOS 的 `NavigationSplitView`。

## Non-goals

- 不修改 `sftp-batch-transfer`、`workspace`、`runtime-logging` 的 spec 文本（本变更只对齐实现）。
- 不为单文件传输（已具备 `sftp_check_*_conflict` + 覆盖确认弹窗）做行为调整。
- 不引入批量传输「保留两者」等新冲突决策。
- 不调整日志轮转、缓冲区容量等已符合 spec 的行为。

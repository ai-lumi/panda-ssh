## Why

当前 SFTP 双栏面板中，用户无法选中目录项发起传输，也无法同时选中多个文件或目录进行批量上传/下载。这限制了批量传输能力的易用性：用户必须逐个点击文件，且目录只能先进入再单独处理内部文件。为了让批量传输真正高效，需要允许在本地和远程文件栏中直接多选文件与目录，并统一通过批量接口发起传输。

## What Changes

- 本地文件栏（`SftpTabView` 本地侧）支持同时选择多个文件和目录项；点击上传时，每个选中的顶层目录生成一个任务组，组内每个文件为独立任务；仅选中多个文件时不生成任务组。
- 远程文件栏（`SftpTabView` 远程侧）的多选模式扩展为允许选中目录项；选中多个远程文件/目录后，目录生成任务组、文件生成独立任务。
- 单选文件时的原有行为保持不变：仍走单文件传输并触发覆盖确认。
- 单选目录时生成一个任务组，组内每个文件为独立任务。
- 任务组支持整体停止、继续、重试；组内每个文件任务支持单独控制。
- 调整 `FilePaneNavigator` / `SftpSessionStore` 的选中模型，使其支持多选文件与目录，并区分「进入目录」与「选中目录」两种操作。

## Capabilities

### New Capabilities

（无新增能力）

### Modified Capabilities

- `sftp-batch-transfer`：扩展批量传输触发条件，明确本地/远程面板均支持同时选择多个文件与目录作为批量传输源。

## Non-goals

- 不改变批量传输的 Rust 核心执行逻辑（扫描、递归、冲突处理、进度聚合）。
- 不引入跨栏拖拽或剪贴板复制粘贴等新的交互模式。
- 不修改现有单文件传输的覆盖确认流程。

## Impact

- **SwiftUI（macOS / iPadOS）**：`SftpTabView`、`FilePaneNavigator`、`SftpSessionStore`、`TransferPanelView` 的选中与传输挂载逻辑需要调整。
- **测试**：Swift 侧单元测试需补充多选文件/目录的传输挂载用例；Rust 核心逻辑无需改动，保持现有批量接口测试即可。
- **平台适配**：macOS 与 iPadOS 共享同一套 `SftpTabView` 与 `FilePaneNavigator`，行为一致；仅文件选择器（`NSOpenPanel` / `UIDocumentPicker`）的平台差异保持现状。

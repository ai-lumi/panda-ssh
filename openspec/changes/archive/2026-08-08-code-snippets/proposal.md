## Why

运维与开发人员经常在终端中重复输入常用命令/脚本（部署、排查、批量操作）。代码片段功能允许用户保存并复用这些命令。按用户要求，本能力为**低优先级**，本变更仅固化为规格与设计（proposal/design/tasks/spec），**不进入本轮实现排期**，实现任务标记为「预留待启动」，避免阻塞其它能力开发。

## What Changes

- 支持以 Markdown 文件形式管理代码片段（标题、说明、代码块、标签）。
- 允许用户选择代码片段存储目录。
- 提供片段的新建、编辑、删除、查看与复制。
- 片段以独立 `.md` 文件落盘，格式规范可读、便于手工编辑与版本管理。

## Non-Goals

- 本变更不进入当前实现阶段，仅预留规格与设计。
- 本变更不实现片段云端同步、共享市场、模板变量替换。
- 本变更不实现片段在终端标签页中的「一键执行」（后续可基于 `tabbed-workspace` 的 shell 通道扩展）。
- 本变更不实现按语言的智能语法补全。

## Capabilities

### New Capabilities

- `snippets`: 代码片段的 Markdown 化管理，含存储路径选择、片段 CRUD 与 Markdown 格式。

### Modified Capabilities

None.

## Impact

- macOS 与 iPadOS 双端：片段列表与编辑 UI 为共享 SwiftUI 源码；存储目录选择在 macOS 用 `NSOpenPanel`、iPadOS 用 `UIDocumentPicker`（安全作用域，需要时拷贝入容器）。
- Rust 核心（`crates/panda-core`）：新增 `SnippetStore`（目录扫描、`*.md` 解析/写入），纯文件操作、平台无关。
- FFI（`crates/panda-ffi`）：新增同步导出 `init_snippets(dir)`/`list_snippets`/`save_snippet`/`delete_snippet`。
- 测试：core 侧 Markdown 解析/写入 round-trip、非法文件容错单元测试；FFI 侧 store 未初始化等报错路径。
- 实现优先级：低。tasks.md 中全部标记为「预留」，待用户确认启动。

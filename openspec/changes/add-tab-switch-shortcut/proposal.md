## Why

当前 Panda SSH 工作区支持多页签（SSH 终端、SFTP 窗口等），但用户只能通过点击页签标题来切换。当页签数量较多时，频繁点击效率低下。提供键盘快捷键切换页签可以显著提升多任务操作效率，这是终端类应用的常见交互模式。

## What Changes

- 新增键盘快捷键支持：当焦点在 SSH 终端或 SFTP 窗口时，按 `Ctrl+Tab` 从左往右依次切换页签，按 `Ctrl+Shift+Tab` 从右往左依次切换页签。
- 页签切换为循环模式：到达最后一个页签后继续按 `Ctrl+Tab` 会回到第一个页签，反之亦然。
- 快捷键仅在页签内容区域（SSH 终端、SFTP 窗口）获得焦点时生效，不影响其他 UI 区域的默认行为。

## Non-goals

- 不实现自定义快捷键绑定（用户无法修改此快捷键）。
- 不实现页签拖拽重排序功能。
- 不实现页签预览或快速跳转面板。

## Capabilities

### New Capabilities

（无新增能力）

### Modified Capabilities

- `workspace`: 新增页签键盘快捷键切换的行为规范，定义快捷键触发条件、切换方向和循环逻辑。

## Impact

- **SwiftUI 视图层**：需要在 `WorkspaceView` 或页签内容视图中添加键盘事件监听（`.onKeyPress` 或 `.keyboardShortcut`）。
- **macOS 与 iPadOS 双端影响**：
  - macOS：`Ctrl+Tab` 和 `Ctrl+Shift+Tab` 是标准的页签切换快捷键，符合用户预期。
  - iPadOS：外接键盘同样支持此快捷键组合，行为一致。
- **无 Rust 核心变更**：此功能纯属 UI 交互层，不涉及 `panda-core` 或 FFI 层。
- **无 API 或依赖变更**：仅使用 SwiftUI 原生键盘事件处理能力。

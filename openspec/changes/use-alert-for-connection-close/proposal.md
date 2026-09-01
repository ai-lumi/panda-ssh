## Why

已连接终端的关闭确认目前在 macOS 和 iPadOS 上使用确认菜单，视觉与「确认会导致会话断开」这一明确的破坏性操作不匹配。应改用两端均为系统原生警告框的呈现方式，使风险、后果与取消路径更清晰。

## What Changes

- macOS 与 iPadOS 对关闭已连接终端的单项确认统一使用 SwiftUI 系统 `.alert`。
- 批量关闭包含已连接终端时，也使用 `.alert`，并显示受影响会话数量。
- 确认操作文案改为「关闭并断开」，取消操作保持为系统取消角色；关闭、断开与取消的既有状态语义不变。

## Non-goals

- 不改变终端、SFTP 或连接池的生命周期规则。
- 不改变未连接、连接中或失败终端标签的直接关闭行为。
- 不新增自定义弹窗、平台专有业务逻辑、FFI 或第三方依赖。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `workspace`: 修改已连接 SSH 终端标签关闭确认在 macOS 与 iPadOS 上的原生呈现与操作文案。

## Impact

- 修改 `apple/PandaSSH/Workspace/WorkspaceView.swift` 中单项与批量关闭确认的 SwiftUI 修饰符。
- 修改 `openspec/specs/workspace/spec.md` 对原生确认控件的要求。
- UI 呈现本身无可隔离的业务逻辑；沿用 `WorkspaceStoreTests` 对确认、取消和连接释放状态机的覆盖，并以双端系统构建与手动交互核验呈现类型。

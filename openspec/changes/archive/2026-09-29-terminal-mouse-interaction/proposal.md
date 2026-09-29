## Why

当前 SSH 终端视图（基于 SwiftTerm `TerminalView`）只支持基础的左键文本选择与系统级 Edit 菜单快捷键，缺失两类 Linux/XShell 用户高度依赖的交互：

1. **中键粘贴选中文本**：Linux 终端约定「鼠标选中即写入 PRIMARY selection，中键点击即粘贴 PRIMARY」，当前实现下选中文本后无法用中键快速回写到远端 shell，必须走 Cmd+C / Cmd+V 两步。
2. **终端内容区右键上下文菜单**：SwiftTerm 的 `MacTerminalView` 未重写 `rightMouseDown`，默认右键无任何自定义菜单，用户在终端内无法通过右键完成复制 / 粘贴 / 全选 / 清屏 / 重连等高频操作，与 XShell 等主流 SSH 客户端的肌肉记忆不兼容。

补齐这两类交互能显著降低从 Linux/XShell 迁移用户的操作摩擦，让终端标签页达到「开箱即用、原生手感」。

## What Changes

- 新增**中键粘贴（PRIMARY selection 语义）**：在终端视图选中文本并松开鼠标后，系统内部维护一份「终端 PRIMARY selection」缓冲（不污染系统剪贴板）；用户中键点击终端任意位置时，把该缓冲内容作为输入字节流写入当前 SSH shell 通道。
  - macOS 端通过子类化 `TerminalView` 重写 `otherMouseDown(with:)` 实现。
  - iPadOS 端 SHALL NOT 启用此能力。**限制根因**：SwiftTerm iOS 端用 `UIPointerInteraction`（仅位置 / 修饰键，无按键区分）+ `pressesBegan`（只处理 `UIKey` 键盘按键）处理鼠标，[iOSTerminalView.swift:696-710](file:///Users/luowenqiang/files/my-codes/panda-ssh/apple/DerivedData/SourcePackages/checkouts/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift#L696-L710) 把触摸 tap hard-code 为左键。**外接鼠标（蓝牙/USB）和 Universal Control 把 Mac 鼠标移到 iPad 时的中键事件不会被 SwiftTerm iOS 路径捕获**，因此即使外接鼠标也无法触发中键粘贴。该限制保留为已知边界（符合 `#if os()` 允许清单；未来 SwiftTerm 升级或自研补丁后再解锁）。
- 新增**终端内容区右键上下文菜单（XShell 风格）**：右键点击终端内容区弹出原生菜单，包含以下条目（按可用性动态启用 / 禁用）：
  - 复制（无选中时禁用）
  - 粘贴（系统剪贴板无文本或会话非 shell 阶段时禁用）
  - 粘贴并回车（同上）
  - 全选
  - 清屏（保留滚动历史，发送 `clear` 命令或等价控制序列）
  - 重置终端（清空滚动缓冲，发送 RIS 转义序列）
  - 复制并粘贴（一次完成「复制当前选中 + 粘贴到光标」）
  - 重连（调用 `WorkspaceStore` 的终端重连流程，会话非已连接态时禁用）
  - 关闭标签页（带已连接态二次确认，复用既有 `WorkspaceStore.close(tabID:)` 门控）
  - 复制链接地址（仅当右键位置命中 OSC 8 / URL 时显示）
  - 打开链接（同上，调用 `requestOpenLink`）
  - macOS 端通过子类化 `TerminalView` 重写 `rightMouseDown(with:)` 构建 `NSMenu`。
  - iPadOS 端通过长按手势（触摸用户）**和**外接鼠标右键（`UIPointerInteraction` 配合 `UIEditMenuInteraction`，iPadOS 13.4+ 鼠标右键自动转 contextual menu）触发 `UIEditMenuInteraction`。菜单项与 macOS 保持一致（条目内文案一致，平台特定实现属允许差异）。
- 新增**选中文本联动**（仅 macOS，作为中键粘贴的前置）：`mouseUp` 后若存在非空选中文本，自动写入「终端 PRIMARY selection」内部缓冲，不写入 `NSPasteboard.general`，避免与 Cmd+C 复制语义冲突。iPadOS 端不维护此缓冲（中键能力不启用）。
- **BREAKING**：无（所有新增交互为可选叠加层，既有快捷键、左键选择、Cmd+C/Cmd+V 路径行为不变）。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `workspace`：在既有「SSH 终端标签页关闭二次确认」「标签页右键上下文菜单」之外，新增终端**内容区**鼠标交互（中键粘贴、右键上下文菜单、选中即缓存 PRIMARY），并约束 macOS 与 iPadOS 两端的能力差异边界。

## Impact

- **Swift 视图层**：
  - `apple/PandaSSH/Workspace/TerminalTabView.swift`：新增 `TerminalView` 子类（macOS / iOS 分别实现），替换现有裸 `TerminalView` 实例化；`TerminalCoordinator` 新增 PRIMARY selection 缓冲与右键菜单回调接口。
  - 新增 `TerminalContextMenu.swift`（macOS `NSMenu` 构建 + iOS `UIEditMenuInteraction` 配置共享），统一菜单条目定义，避免业务逻辑分支。
  - `WorkspaceStore`：暴露 `reconnect(terminalTabID:)` 与既有 `close(tabID:)` 给终端右键菜单调用（仅 UI 转发，不新增业务逻辑）。
- **FFI / Rust 核心**：无改动。中键粘贴与右键菜单的「写入终端」最终都走既有 `TerminalViewDelegate.send` → `ShellConnection.write` → FFI `shell_write` → `ShellSession::write`，无新增导出函数，无业务逻辑变更，符合分层边界。
- **依赖**：无新增三方依赖；仅复用 SwiftTerm 已暴露的 `paste(_:)/copy(_:)/selectAll(_:)`、`selection.getSelectedText()`、`insertText(_:replacementRange:isPaste:)` 与 `clearTerminal`/`softReset` 等公共 API。
- **测试**：
  - Rust 侧无新增可测逻辑，`cargo test` 维持全绿。
  - Swift 侧新增 `TerminalContextMenuTests`（XCTest）：覆盖菜单条目按会话阶段 / 选中态 / 链接命中状态的启用禁用规则（正常流程、意外输入、边界条件）。
  - macOS 端 `TerminalView` 子类的 `rightMouseDown` / `otherMouseDown` 行为通过 `XCTest` 验证（用 in-process `TerminalView` 实例 + mock `TerminalCoordinator`，不依赖真实 SSH）。
- **双端影响**：
  - macOS：完整启用中键粘贴、右键菜单、选中即缓存 PRIMARY。
  - iPadOS：右键菜单对**触摸长按**和**外接鼠标右键**（蓝牙/USB 鼠标 + Universal Control 转入 Mac 鼠标）都触发；中键粘贴与「选中即缓存 PRIMARY」SHALL NOT 启用（**限制根因**：SwiftTerm iOS 不区分鼠标按键，外接鼠标的中键事件无法被 SwiftTerm iOS 路径捕获，详见 What Changes）。所有差异通过 `#if os()` 收敛在视图层，不进入业务逻辑。
- **Non-goals**：
  - 不改造 SwiftTerm 的 `allowMouseReporting` / 鼠标模式协议（远端应用鼠标事件转发）行为；本提案只覆盖本地 UI 交互层。
  - 不引入系统级全局热键或跨应用 PRIMARY selection（X11 PRIMARY 与系统剪贴板的桥接不在范围内）。
  - 不改动标签页右键菜单（已在 `ui-workspace-optimization` 规范化）。
  - 不实现自定义按键绑定 / 用户可配置菜单项（后续提案另行处理）。
  - 不在 iPadOS 上自研补丁让 SwiftTerm iOS 识别鼠标中键（保留为已知边界，未来 SwiftTerm 升级或独立提案处理）。

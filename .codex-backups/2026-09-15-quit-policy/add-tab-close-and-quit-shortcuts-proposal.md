## Why

当前 App 缺少 CMD+W（关闭当前页签）和 CMD+Q（退出应用）的键盘快捷键处理。macOS 用户习惯使用这两个快捷键进行页签关闭和应用退出；缺少支持导致用户必须使用鼠标/触控板操作，体验不完整。同时，CMD+Q 误触会导致所有 SSH 会话断开，需要类似 Chrome 的「两次按下才退出」保护机制，防止意外丢失工作状态。

## What Changes

- 新增 CMD+W 键盘快捷键：当焦点在页签区域时关闭当前活动页签（遵循既有关闭流程，包括已连接终端的二次确认）；当焦点不在页签区域（如侧栏、主机详情、SFTP 文件列表等）时，不做任何响应。
- 新增 CMD+Q 键盘快捷键：在窗口任意位置按下时，不立即退出，而是显示一个短暂的「再按一次退出」提示（类似 Chrome 行为）；在提示可见期间再次按下 CMD+Q 才真正退出应用；提示超时后自动消失，需重新按两次才能退出。
- 两项快捷键仅适用于 macOS 端；iPadOS 端无物理键盘 CMD+W/CMD+Q 语义（iPad 外接键盘的 CMD+W 由系统处理为关闭当前视图，CMD+Q 不触发退出），不在本次变更范围内。

## Non-goals

- 不实现 CMD+Shift+W（关闭全部页签）等其他页签快捷键。
- 不改变现有页签关闭按钮、右键菜单的关闭行为。
- 不实现「退出前逐个确认每个活跃会话」的弹窗——CMD+Q 的保护机制仅为「两次按下」，不额外弹窗。
- 不处理 iPadOS 外接键盘的 CMD+W/CMD+Q 行为。

## Capabilities

### New Capabilities

- `keyboard-shortcuts`: 覆盖 CMD+W（焦点感知的页签关闭）和 CMD+Q（两次按下退出保护）的键盘快捷键行为规格。

### Modified Capabilities

（无现有 spec 需要修改——workspace spec 已定义页签关闭流程，本次仅新增快捷键触发入口，不改变关闭语义本身。）

## Impact

- **Swift 侧 View 层**：需在 macOS 主窗口 View 上注册 `.onKeyPress` 或 `.keyboardShortcut` 处理 CMD+W 和 CMD+Q。CMD+W 需判断当前焦点是否在页签区域；CMD+Q 需维护一个带超时的「待退出」状态。
- **不影响 Rust 核心**：快捷键处理完全在 SwiftUI 层完成，不涉及 FFI 或 panda-core 变更。
- **不影响现有页签关闭逻辑**：CMD+W 复用既有的页签关闭入口（包括已连接终端的二次确认流程），仅新增触发方式。
- **测试**：需在 macOS 端 XCTest 或手动验证中覆盖焦点在/不在页签区域时 CMD+W 的行为，以及 CMD+Q 的两次按下与超时重置。

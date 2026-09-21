## Why

SSH 终端视图可能在 shell 连接建立前完成初次布局并产生真实行列数；现有实现仅在该时刻尝试上报，因连接尚不存在而丢失请求。随后不缩放窗口时远端 PTY 会保留默认 80×24，导致 `vi`、`top` 等全屏程序初始尺寸错误。

## What Changes

- 让终端协调器在新的 shell 连接挂载时立即同步已知的最新终端行列数。
- 连接挂载前尚未建立连接的尺寸变化仍只保留最新值；连接挂载时取消过期的去抖任务，避免对新连接重复发送旧的延迟请求。
- 保持既有「首次尺寸立即上报、后续连续变化约 150ms 去抖」的窗口调整契约。

## Non-goals

- 不改变 PTY 初始默认尺寸、SSH/FFI 接口或远端 shell 行为。
- 不增加重连、轮询或额外网络请求；仅在已建立 shell 通道上补发一次必要的 `window-change`。
- 不改变 macOS 与 iPadOS 的终端布局或键盘焦点行为。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `shell-terminal`: 补充连接在初次终端布局之后建立时的尺寸同步要求。

## Impact

- macOS 与 iPadOS 共用的 `TerminalCoordinator` 将在新 `ShellConnection` 可用时发送缓存的行列数；两端获得相同的初始 PTY 尺寸协商行为。
- 影响 `apple/PandaSSH/Workspace/TerminalTabView.swift` 及其 XCTest；不涉及 Rust 核心、FFI、依赖或配置数据。

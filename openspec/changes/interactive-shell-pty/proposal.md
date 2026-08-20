## Why

当前 SSH 终端实现缺少 PTY 分配、窗口大小调整和终端模式配置，导致远程 shell 运行在「哑终端」模式：无 ANSI 转义码处理、无行编辑、无作业控制，vim/top/htop 等交互式程序完全无法使用。补齐 PTY 终端对接是让终端真正可用的关键一步。

## What Changes

- Rust 核心 `ShellSession::open()` 在 `request_shell` 之前先调用 `channel.request_pty()`，分配伪终端并配置终端模式（ECHO、ICANON、ISIG 等）与 `TERM=xterm-256color` 环境变量
- Rust 核心 `ShellSession` 新增 `resize()` 方法，调用 `channel.window_change()` 将客户端窗口尺寸变化传递到服务端
- FFI 层新增 `shell_resize(handle, cols, rows)` 导出函数
- Swift `ShellConnection` 协议扩展 `resize(cols:rows:)` 方法，`PandaShellConnection` 实现桥接 FFI
- Swift `TerminalCoordinator.sizeChanged` 从空桩改为调用 `connection.resize()`
- OpenSpec 更新 `ssh-connection` 规格，移除「本期不做交互式 shell」排除条款

## Capabilities

### New Capabilities

- `shell-terminal`: SSH 交互式终端的 PTY 分配、终端模式配置、TERM 环境变量设置、窗口大小调整与数据流对接

### Modified Capabilities

- `ssh-connection`: 新增交互式 shell 会话需求，移除「终端对接属于后续变更」的排除条款

## Impact

- `crates/panda-core/src/ssh.rs` — `ShellSession::open()` 增加 PTY 分配与终端模式，新增 `resize()` 方法
- `crates/panda-ffi/src/lib.rs` — 新增 `shell_resize` FFI 导出
- `apple/PandaSSH/Workspace/ShellConnection.swift` — 协议扩展 `resize` 方法
- `apple/PandaSSH/Workspace/TerminalTabView.swift` — `TerminalCoordinator.sizeChanged` 实现窗口调整转发
- `openspec/specs/ssh-connection/spec.md` — 新增 shell 会话需求
- `openspec/specs/shell-terminal/spec.md` — 新建终端规格
- 影响 macOS 与 iPadOS 双端（共享源码），终端功能在双端均可用

## Non-goals

- 本期不实现信号转发（Ctrl-C 等仍通过数据流传递，PTY 分配后服务端可正确处理）
- 本期不实现 X11 转发、agent 转发等扩展通道
- 本期不改变 `shell_open` 的 FFI 签名（终端类型与初始尺寸由 Rust 侧使用合理默认值，后续可按需暴露给 Swift）

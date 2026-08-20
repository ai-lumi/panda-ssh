## 1. PTY 分配与终端模式（Rust 核心）

- [ ] 1.1 测试：`ShellSession::open()` 在 `request_shell` 之前调用 `request_pty`（正常流程：成功分配 PTY、设置 TERM、请求 shell）
- [ ] 1.2 测试：`request_pty` 失败时返回明确错误，不继续请求 shell（意外操作：服务端拒绝 PTY）
- [ ] 1.3 测试：`set_env("TERM", "xterm-256color")` 失败不阻断 shell 打开（意外操作：服务端不支持 set-env）
- [ ] 1.4 测试：终端模式数组包含 ECHO/ICANON/ISIG/ICTRNL（边界条件：模式配置完整性）
- [ ] 1.5 实现：修改 `ShellSession::open()`，在 `request_shell` 前依次调用 `request_pty` 和 `set_env`
- [ ] 1.6 实现：定义标准终端模式常量数组 `STANDARD_TERMINAL_MODES`

## 2. 窗口调整（Rust 核心 + FFI）

- [ ] 2.1 测试：`ShellSession::resize()` 调用 `channel.window_change()` 并传递正确的 cols/rows（正常流程）
- [ ] 2.2 测试：`resize()` 在 shell 关闭后返回 `ShellSessionClosed` 错误（意外操作）
- [ ] 2.3 测试：`shell_resize` FFI 导出对未知句柄返回 `UnknownShellHandle`（边界条件）
- [ ] 2.4 实现：`ShellSession` 新增 `resize(cols, rows)` 方法
- [ ] 2.5 实现：`panda-ffi` 新增 `shell_resize(handle, cols, rows)` 导出函数

## 3. Swift 终端桥接

- [ ] 3.1 测试：`ShellConnection` 协议扩展 `resize(cols:rows:)` 方法声明
- [ ] 3.2 测试：`PandaShellConnection.resize()` 桥接 FFI 调用
- [ ] 3.3 测试：`TerminalCoordinator.sizeChanged` 触发 `connection.resize()`
- [ ] 3.4 实现：`ShellConnection` 协议新增 `resize(cols:rows:) throws`
- [ ] 3.5 实现：`PandaShellConnection` 实现 `resize` 调用 `shellResize(handle:cols:rows:)`
- [ ] 3.6 实现：`TerminalCoordinator.sizeChanged` 从空桩改为调用 `connection?.resize(cols:rows:)`
- [ ] 3.7 实现：`MockShellConnection` 实现 `resize` 空操作（用于 Preview/测试）

## 4. 规格更新与验证

- [ ] 4.1 测试：`cargo test` 全绿（覆盖正常/意外/边界三类场景）
- [ ] 4.2 测试：`cargo llvm-cov --fail-under-lines 95 --fail-under-regions 95` 通过
- [ ] 4.3 测试：macOS/iOS 双端 `xcodebuild test` 全绿
- [ ] 4.4 实现：更新 `openspec/specs/ssh-connection/spec.md`，移除排除条款，新增 shell 会话需求
- [ ] 4.5 实现：创建 `openspec/specs/shell-terminal/spec.md` 主规格
- [ ] 4.6 验证：`openspec validate interactive-shell-pty --strict` 通过

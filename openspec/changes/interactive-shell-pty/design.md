## Context

当前 `ShellSession::open()` 通过 `channel.request_shell(true)` 直接请求远程 shell，跳过了 PTY 分配。russh 0.62 的 `Channel` 提供了完整的 PTY API：`request_pty(want_reply, term, col_width, row_height, pix_width, pix_height, terminal_modes)`。Swift 端 `TerminalCoordinator.sizeChanged` 是空桩，russh 的 `window_change` 方法从未被调用。OpenSpec `ssh-connection/spec.md` 明确排除了交互式 shell。

## Goals / Non-Goals

**Goals:**
- 在 `ShellSession::open()` 中正确分配 PTY，使远程 shell 具备完整终端语义
- 设置 `TERM=xterm-256color` 环境变量
- 配置标准终端模式（ECHO、ICANON、ISIG、ICTRNL）
- 实现窗口动态调整：Swift 尺寸变化 → Rust `window_change` → 服务端
- 通过现有 FFI → Swift 桥接层保持双端一致

**Non-Goals:**
- 不实现信号转发（SIGINT/SIGTSTP 等仍通过数据流传递，PTY 分配后服务端可正确解析 Ctrl-C 字节）
- 不实现 X11/agent 转发
- 不改变 `shell_open` 的 FFI 签名（终端类型和初始尺寸使用合理默认值）
- 不实现 shell 会话退出码/退出信号追踪（shell 进程通常持续到用户关闭）

## Decisions

### 决策 1：PTY 分配在 `request_shell` 之前执行

**选择**：`ShellSession::open()` 调用顺序改为：`channel.request_pty()` → `channel.set_env("TERM", ...)` → `channel.request_shell()`

**备选方案**：先 `request_shell` 再 `request_pty` — 被否决，因为 SSH 协议要求 PTY 请求必须在 shell 请求之前，否则服务端可能拒绝或产生竞态。

**备选方案**：仅设置 `TERM` 环境变量而不分配 PTY — 被否决，无 PTY 时服务端不会分配终端设备，readline 等功能完全不工作。

### 决策 2：终端模式使用标准组合

**选择**：ECHO（回显开启）+ ICANON（规范行输入模式）+ ISIG（信号处理开启）+ ICTRNL（Ctrl-C 产生 SIGINT）

**备选方案**：使用空终端模式数组（`&[]`）— 被否决，无模式时服务端可能使用非标准默认值。

### 决策 3：窗口调整通过 `ShellSession::resize()` 同步调用

**选择**：新增 `ShellSession::resize(cols, rows)` 方法，内部调用 `channel.window_change()`。通过 FFI `shell_resize` 导出为同步调用（`block_on`），Swift 端 `PandaShellConnection.resize()` 调用 FFI，`TerminalCoordinator.sizeChanged` 触发。

**备选方案**：窗口调整通过后台 reader 任务转发 — 被否决，增加不必要的复杂度；窗口调整是低频操作，同步调用开销可忽略。

### 决策 4：初始终端尺寸硬编码为 80×24

**选择**：在 `shell_open` 内部使用默认 80 列 × 24 行。后续可通过新增 FFI 参数或新接口暴露自定义初始尺寸。

**备选方案**：`shell_open` 增加初始尺寸参数 — 被否决，增加 FFI 复杂度且大多数场景使用默认值。

## Risks / Trade-offs

- **[服务端不支持 PTY]** → 如果服务端不支持 PTY 分配，`request_pty` 返回错误。此时 shell 会话打开失败，用户看到错误提示。可接受，因为无 PTY 的终端体验极差，宁可失败也不降级为哑终端。
- **[set_env 失败]** → 如果服务端不支持 `set-env`，`set_env` 返回错误。我们选择不阻断 shell 打开（`let _ = channel.set_env(...)`），仅记录日志。某些老旧 OpenSSH 版本不支持 set-env，但仍可正常工作。
- **[窗口调整延迟]** → Swift 侧 `sizeChanged` 由 SwiftTerm 实时触发，经 FFI 同步调用到 Rust，延迟极低。可接受。
- **[终端模式兼容性]** → 不同服务端对终端模式的支持程度不同。使用最通用的 ECHO/ICANON/ISIG 组合可在绝大多数 Linux/macOS 服务器上正常工作。

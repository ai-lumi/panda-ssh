## Purpose

基于 PTY 的 SSH 交互式终端：在 SSH 会话上分配伪终端、配置终端模式、设置 TERM 环境变量、支持窗口大小调整，使远程 shell 具备完整的终端语义（ANSI 转义码、行编辑、作业控制）。

## ADDED Requirements

### Requirement: PTY 分配

系统 SHALL 在打开交互式 shell 会话时，先向服务端请求伪终端（PTY）分配，再请求远程 shell。PTY 请求 MUST 携带终端类型（`TERM=XTERM-256COLOR`）、初始窗口尺寸（默认 80×24 列行）和标准终端模式配置。

标准终端模式 MUST 包含：ECHO（回显开启）、ICANON（规范模式）、ISIG（信号处理开启）、ICTRNL（Ctrl-C 生成 SIGINT）。

#### Scenario: 成功分配 PTY 并打开 shell

- **WHEN** 客户端在已认证的 SSH 会话上请求交互式终端
- **THEN** 服务端分配 PTY 并启动 shell 进程，客户端收到 PTY 分配成功确认，shell 通道就绪

#### Scenario: 服务端拒绝 PTY 分配

- **WHEN** 服务端不支持或拒绝 PTY 分配
- **THEN** 返回明确的错误，SHALL NOT 继续请求 shell

#### Scenario: 使用默认终端尺寸

- **WHEN** 客户端未指定初始窗口尺寸
- **THEN** 使用 80 列 × 24 行作为默认值

### Requirement: TERM 环境变量

系统 SHALL 在请求 shell 之前，通过 SSH `set-env` 请求将 `TERM` 环境变量设为 `xterm-256color`。远程 shell MUST 能识别此环境变量以启用正确的终端模拟。

#### Scenario: TERM 变量设置成功

- **WHEN** 客户端打开交互式 shell 会话
- **THEN** `TERM=xterm-256color` 环境变量被发送到服务端

#### Scenario: 服务端不支持 set-env

- **WHEN** 服务端不支持 `set-env` 请求
- **THEN** 终端会话仍可建立，SHALL NOT 因为 set-env 失败而阻断 shell 打开

### Requirement: 终端窗口调整

系统 SHALL 支持在终端会话存活期间动态调整窗口尺寸。客户端窗口尺寸变化时 MUST 向服务端发送 `window-change` 请求，携带新的列数和行数。

#### Scenario: 客户端调整窗口尺寸

- **WHEN** 用户拖拽调整终端窗口大小（例如从 80×24 变为 120×40）
- **THEN** 服务端终端收到新的尺寸参数，应用程序（如 vim、top）正确适配

#### Scenario: 窗口尺寸变化频繁

- **WHEN** 用户快速拖拽调整窗口，短时间内产生多次尺寸变化事件
- **THEN** 最新尺寸 MUST 最终被服务端正确接收，SHALL NOT 丢失最后一次调整

### Requirement: 终端数据流

系统 SHALL 支持 PTY shell 的双向数据流。客户端写入的输入字节 MUST 通过 SSH 通道发送到服务端 PTY；服务端 PTY 输出 MUST 被客户端读取并缓存，供上层终端视图消费。

#### Scenario: 用户输入被正确转发

- **WHEN** 用户在终端中输入字符
- **THEN** 输入字节通过 SSH 通道发送到服务端 PTY

#### Scenario: 服务端输出被正确读取

- **WHEN** 服务端 shell 产生输出（包含 ANSI 转义码）
- **THEN** 输出字节被客户端读取并传递给终端视图渲染

#### Scenario: 空读取不阻塞

- **WHEN** 当前没有服务端输出
- **THEN** 读取操作立即返回空数据，SHALL NOT 阻塞调用线程

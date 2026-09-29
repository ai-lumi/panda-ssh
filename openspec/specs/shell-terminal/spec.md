# shell-terminal Specification

## Purpose

基于 PTY 的 SSH 交互式终端：在 SSH 会话上分配伪终端、配置终端模式、设置 TERM 环境变量、支持窗口大小调整，使远程 shell 具备完整的终端语义（ANSI 转义码、行编辑、作业控制）。
## Requirements
### Requirement: PTY 分配

系统 SHALL 在打开交互式 shell 会话时，先向服务端请求伪终端（PTY）分配，再请求远程 shell。PTY 请求 MUST 携带终端类型（`TERM=xterm-256color`）、初始窗口尺寸（默认 80×24 列行）和标准终端模式配置。

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

若终端视图在 shell 连接建立前已获得有效行列数，系统 MUST 保留最新尺寸，并在该 shell 连接可用时立即向服务端发送一次 `window-change`。此同步 MUST 使用最新的已知尺寸，且不得依赖用户再次缩放窗口。

尺寸上报采用去抖策略：会话建立后的首次尺寸 MUST 立即上报；此后的连续尺寸变化（如侧栏显隐动画、窗口拖拽产生的逐帧回调）SHALL 做约 150ms 去抖，仅在尺寸稳定后上报最终值，MUST NOT 逐帧发送——逐帧 `window-change` 会让远端 shell 遭遇 SIGWINCH 风暴，其重绘序列与本地 reflow 交错时会把光标推到屏幕中部（终端上方出现大片空白）。连接可用前遗留的去抖任务 MUST NOT 在连接同步后重复发送过期尺寸。

本地终端视图的行列适配（SwiftTerm resize/reflow）SHALL 保持实时，不受上报去抖影响。

#### Scenario: 客户端调整窗口尺寸

- **WHEN** 用户拖拽调整终端窗口大小（例如从 80×24 变为 120×40）
- **THEN** 服务端终端收到新的尺寸参数，应用程序（如 vim、top）正确适配

#### Scenario: 窗口尺寸变化频繁

- **WHEN** 用户快速拖拽调整窗口，短时间内产生多次尺寸变化事件
- **THEN** 最新尺寸 MUST 最终被服务端正确接收，SHALL NOT 丢失最后一次调整
- **AND** 连续变化期间 SHALL 去抖上报，不逐帧发送 `window-change`

#### Scenario: 初次布局早于 shell 连接

- **GIVEN** 终端视图已完成有效行列数的初次布局，但 shell 连接尚未建立
- **WHEN** shell 连接随后可用，且用户没有缩放窗口
- **THEN** 服务端终端立即收到该最新行列数的一次 `window-change`，全屏程序以正确初始尺寸启动

### Requirement: 终端数据流

系统 SHALL 支持 PTY shell 的双向数据流。客户端写入的输入字节 MUST 通过 SSH 通道发送到服务端 PTY；服务端 PTY 输出 MUST 被客户端读取并缓存，供上层终端视图消费。终端缓冲区大小 MUST 在终端初始化时从用户配置读取并应用；若用户未配置或配置无效，则使用默认值 10000 行。

#### Scenario: 用户输入被正确转发

- **WHEN** 用户在终端中输入字符
- **THEN** 输入字节通过 SSH 通道发送到服务端 PTY

#### Scenario: 服务端输出被正确读取

- **WHEN** 服务端 shell 产生输出（包含 ANSI 转义码）
- **THEN** 输出字节被客户端读取并传递给终端视图渲染

#### Scenario: 空读取不阻塞

- **WHEN** 当前没有服务端输出
- **THEN** 读取操作立即返回空数据，SHALL NOT 阻塞调用线程

#### Scenario: 终端使用配置的缓冲区大小初始化

- **GIVEN** 用户在设置中将缓冲区行数设为 25000
- **WHEN** 打开新的终端标签页
- **THEN** 该终端的回滚缓冲区上限为 25000 行

#### Scenario: 无效配置回退默认值

- **GIVEN** UserDefaults 中存储了非法值或无配置
- **WHEN** 打开新的终端标签页
- **THEN** 该终端使用默认值 10000 行回滚缓冲区

### Requirement: 终端连接隔离

每个终端标签 SHALL 独占一条 SSH Transport 和一个 shell Channel。远端 shell 正常结束、本地关闭或连接失败时，系统 SHALL 只终止该标签拥有的 Transport，并向该标签报告可区分的最终状态。

#### Scenario: 远端 exit 正常结束

- **GIVEN** 同一主机有两个可交互终端标签
- **WHEN** 用户在其中一个终端输入 `exit` 且远端 shell 正常结束
- **THEN** 该标签显示已关闭并释放自己的 Socket，另一个标签继续可交互

#### Scenario: Socket 异常关闭

- **WHEN** 某终端的 Socket 发生 EOF、读写错误或 keepalive 连续失败
- **THEN** 该终端立即显示不可交互和失败摘要，并提供重试操作

### Requirement: 终端单飞重试

终端标签的重试流程 SHALL 保证同一标签同一重试代次最多存在一个在途建连请求。重复的 UI 生命周期触发或回调 MUST NOT 为同一代次再次打开 Transport。

#### Scenario: 点击一次重试

- **GIVEN** 终端已进入关闭或失败状态
- **WHEN** 用户点击一次重试且视图同时因状态变化重新执行生命周期任务
- **THEN** 仅一个建连请求生效并生成一个新 Socket

### Requirement: 终端键盘焦点

系统 SHALL 在新 SSH 终端视图完成挂载后，以及用户切换到已打开的 SSH 终端标签页后，将键盘焦点置于该活动终端，使用户可直接输入。为保持 SSH shell 存活而留在视图树中的非活动终端 MUST NOT 请求或抢占键盘焦点。

#### Scenario: 打开新终端

- **WHEN** 用户打开一个 SSH 终端且连接进入 shell 状态
- **THEN** 新终端视图成为键盘输入目标，无需用户额外点击

#### Scenario: 切回已打开终端

- **GIVEN** 两个已打开的 SSH 终端标签页均保留在视图树中
- **WHEN** 用户切换到其中一个终端标签页
- **THEN** 被切换到的终端成为键盘输入目标
- **AND** 隐藏终端不得抢占该焦点

### Requirement: 重连后 PTY 恢复

自动重连成功建立新 shell Channel 后，系统 SHALL 恢复重连前的 PTY 窗口尺寸（列数和行数）。恢复 SHALL 在新 shell 建立后立即发送 `window-change` 请求。

#### Scenario: 重连后恢复窗口尺寸

- **GIVEN** 终端标签窗口尺寸为 120×40，连接失效后自动重连
- **WHEN** 重连成功并建立新 shell
- **THEN** 系统立即发送 `window-change` 请求，将远端 PTY 设为 120×40


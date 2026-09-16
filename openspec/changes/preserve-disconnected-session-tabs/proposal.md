# 保留断开会话的标签页上下文

## Why

已建立的 SSH 或 SFTP 会话断开时，当前工作区会用包含「重试」与「关闭标签」的错误页替换原内容。SSH 错误页既丢失可见的终端上下文，也仅显示泛化摘要；SFTP 错误页会丢失目录浏览上下文。这使用户无法判断断开前发生了什么，必须依赖另行打开日志窗口排查。

公开产品的交互提供了可复核的方向：MobaXterm 会把已断开的终端标签以红色显示，并可在会话结束后提示重连；Termius 的自动重连也复用原终端标签并保留此前终端进度。两者均把「会话已结束」作为原工作上下文中的状态，而不是切换至独立错误页面。

## What Changes

- SSH 已进入 shell 后发生正常或异常结束时，保留终端画布与已缓存滚动历史；输入立即失效，并在终端末尾追加安全、结构化的结束原因和手动重新连接入口。标签状态图标显示红色。
- SFTP 已进入可浏览状态后发生会话级断开时，保留当前本地/远程目录快照、路径和选中状态；不以错误页替换浏览器，标签状态图标显示红色。远程操作须明确告知会话已断开并提供手动重新连接入口。
- 初次建连失败继续使用现有错误页；本地显式关闭标签继续移除标签，均不适用本提案的保留规则。
- 复用 `fix-ssh-session-failure-diagnostics` 的安全结构化终态模型。所谓“原始原因”只表示保留可安全呈现的类别、阶段、退出码/信号类别或系统错误码；不得将任意远端文本、终端输出、命令、凭据或 panic 载荷直接回显。
- 单个 SFTP 文件操作的权限、路径、冲突等业务错误不得误判为会话断开；只有已确认本标签 SFTP 会话或其底层 SSH Transport 不可再用时才标红。

## Non-goals

- 不实现自动重连、重放命令/传输或恢复远端 shell 状态。
- 不改变连接所有权、标签关闭、后台传输、主机密钥或凭据语义。
- 不承诺诊断能够提供任意远端程序的自由文本原因；安全边界优先于完整原始载荷。
- 不在本提案阶段修改代码、合并主规格或执行真实服务器操作。

## Capabilities

### New Capabilities

无；扩展现有工作区、终端内容页和终端会话能力。

### Modified Capabilities

- `workspace`：区分初次建连失败与已建立会话的后续断开，定义标签红色失败状态及 SFTP 快照保留语义。
- `ssh-content-page`：已连接后断开时继续使用终端画布，而非居中错误页。
- `shell-terminal`：将安全终态原因追加到保留的终端上下文，且保持输入不可用与手动重连。

## Impact

- SwiftUI：`TerminalTabView`、`TerminalSessionStore`、`SftpTabView`、`SftpSessionStore` 和工作区标签状态映射需要调整；不得在 Swift 重复诊断分类业务逻辑。
- Rust / FFI：优先复用既有结构化 shell 终态；若 SFTP 无法区分会话级失效与单次业务错误，才以最小 FFI 契约补足该区分，保持同步导出及既有全局 Tokio runtime。
- 测试：先写 Swift XCTest / Rust fake 的失败用例，覆盖正常、意外与边界场景；既有 `fix-ssh-session-failure-diagnostics` 未完成时，本提案依赖其安全原因模型而不复制其错误分类。

## References

- MobaXterm release notes: terminal disconnection tracking marks inactive disconnected terminal-tab titles red; session settings include an end-of-session reconnection message. <https://mobaxterm.mobatek.net/download-home-edition.html>
- MobaXterm documentation: “Display reconnection message at session end”. <https://mobaxterm.mobatek.net/documentation.html>
- Termius: auto-reconnect keeps prior progress in the same terminal tab. <https://termius.com/blog/stay-connected-with-auto-reconnect>

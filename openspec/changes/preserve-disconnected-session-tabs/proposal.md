## Why

SSH 已建立后断开时，工作区会以错误页替换终端视图，导致用户无法查看断开前的 shell 输出与滚动上下文。SSH 建连提示也另建内容页，令同一页签在生命周期中反复替换画布。SFTP 已建立后断开同样不应丢弃已有目录浏览上下文。

## What Changes

- SSH 页签在凭据与主机密钥门控通过后 SHALL 持续使用同一个终端画布；连接中、已连接、正常结束及异常断开均以该画布中的本地状态提示呈现，不再以独立状态页替换终端。
- SSH 已建立后的正常结束或异常断开 SHALL 保留已接收的终端输出与滚动上下文，立即禁用输入与其它写入型终端操作，并追加安全的终态提示。
- SFTP 已建立后的会话级断开 SHALL 保留本地/远程目录快照、路径和选中状态；依赖远程会话的操作不可用。
- SSH 与 SFTP 的重新连接 SHALL 仅由现有页签操作触发；终端画布、SFTP 内容区、初次连接失败页和断连提示均 MUST NOT 提供重复的重新连接按钮。
- 初次连接失败仍可显示可区分的失败摘要，但重连入口同样收敛到页签操作。

## Non-goals

- 不实现自动重连、命令重放、传输重放或远端 shell 状态恢复。
- 不改变连接所有权、标签关闭、后台传输、主机密钥或凭据语义。
- 不显示任意远端自由文本、终端输出、命令、凭据或 panic 载荷作为诊断原因。
- 本提案不实施代码、不合并主规格，也不执行真实服务器操作。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `workspace`：定义已建立会话断开后的页签状态、内容保留与页签唯一重连入口。
- `ssh-content-page`：SSH 连接中与已建立后终态均复用持续存在的终端画布。
- `shell-terminal`：终态后的输出保留、输入禁用、安全提示及页签重连语义。

## Impact

- SwiftUI：`TerminalTabView`、`TerminalSessionStore`、`SftpTabView`、`SftpSessionStore`、页签操作和状态映射需要调整，macOS 与 iPadOS 共享同一业务行为。
- Rust / FFI：优先复用既有结构化 shell 终态；仅在 SFTP 无法可靠区分会话级失效时以最小 FFI 契约补足区分，保持同步导出及既有全局 Tokio runtime。
- 测试：先写 Swift XCTest / Rust fake 的失败用例，覆盖正常、意外与边界场景；不得在 Swift 通过错误字符串猜测断开原因。

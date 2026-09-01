## Why

交互式 SSH 终端执行 `exit` 后，远端 shell 已关闭，但客户端把“无可读输出”误认为连接仍存活，导致页签栏和侧栏持续显示已连接。该状态还会阻止最后一个会话正确释放连接池中的 SSH Socket。

## What Changes

- 区分 SSH shell 的暂时无输出与远端已关闭，并在读完关闭前最后一批输出后报告终止。
- 终端标签收到远端关闭后释放 shell 句柄，并将页签状态更新为断开。
- 当该主机没有其他连接中或已连接的标签页、且没有活跃传输任务时，移除连接池中的主机连接，使最后一个 SSH Socket 随引用释放而关闭。
- 在 macOS 与 iPadOS 的共享终端实现中统一呈现断开状态。

## Non-goals

- 不改变用户主动关闭标签页、重连、SFTP 传输或主机密钥校验的既有语义。
- 不增加后台心跳或对未连接主机的网络探测。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `workspace`: 终端远端 shell 正常退出时，标签状态与主机连接释放规则。

## Impact

- `panda-core` shell 会话终止状态及其测试。
- `panda-ffi` 的 shell 读取错误传播及集成测试。
- Swift `ShellConnection`、终端会话状态机、工作区连接协调与 XCTest。

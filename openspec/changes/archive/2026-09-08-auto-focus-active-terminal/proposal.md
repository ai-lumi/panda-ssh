## Why

打开新的 SSH 终端或切回已打开终端后，终端内容区未成为第一响应者；用户还需额外点击后才能输入。这破坏交互式 shell 的连续工作流。

## What Changes

- 活动终端视图在首次挂载及从非活动状态切换为活动状态时请求键盘焦点。
- 隐藏的常驻终端视图不得请求或抢占焦点。
- macOS 与 iPadOS 分别使用各自原生第一响应者机制，不改变 SSH 会话、连接池或输入数据流。

## Non-goals

- 不改变终端连接、认证、主机密钥或后台终端保活语义。
- 不为非终端标签页设置焦点。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `shell-terminal`: 补充活动终端的键盘焦点要求。

## Impact

- `apple/PandaSSH/Workspace/TerminalTabView.swift`：将活动状态传给平台终端包装器并请求第一响应者。
- `apple/PandaSSH/Workspace/WorkspaceView.swift`：向常驻终端容器传递可见/活动状态。
- 新增 XCTest 覆盖焦点请求判定。

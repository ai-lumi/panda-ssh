## Why

当前工作区只渲染活动页签，并以页签 ID 强制重建视图；终端页签切出时会关闭其 shell。用户切回已打开的终端时因此重新初始化 SSH，违背连接池“切换 tab 后连接保持”的既有契约。

## What Changes

- 保留已打开终端页签的会话视图与 SSH shell，非活动页签只隐藏而不销毁。
- 终端页签仅在用户关闭页签或应用退出时释放 shell；切换页签不得触发连接关闭或重新初始化。
- 为 macOS 与 iPadOS 的工作区切换行为增加回归测试，覆盖正常切换、反复切换和关闭页签。
- 页签状态点 SHALL 反映其自身会话的连接中、已连接或失败状态；侧栏主机状态点 SHALL
  仅反映该主机当前已打开会话的可达性，不再将主机密钥记录状态显示为连接状态。

## Non-goals

- 不改变 Rust 连接池、认证、主机密钥验证或 SFTP 连接生命周期。
- 不改变标签页关闭时断开最后一个同主机连接的行为。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `connection-pool`: 明确 UI 工作区不得因活动页签切换而销毁已打开终端的 shell 会话。

## Impact

- 影响 `apple/PandaSSH/Workspace/WorkspaceView.swift` 与终端页签的 SwiftUI 生命周期管理。
- 增加 `apple/PandaSSHTests` 中的会话保持回归测试。
- 不新增 API 或依赖；macOS 与 iPadOS 使用同一套工作区生命周期规则。

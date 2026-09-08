## Why

终端连接中、已连接和失败态目前分别由临时 SwiftUI 片段呈现，缺少稳定的内容区几何契约；窗口缩放或侧栏显隐时容易把状态放到错误的位置或形成第二条 chrome。

## What Changes

- 建立 SSH 内容页的共享呈现策略，明确连接中、可交互、失败/断开和凭据/主机密钥门控的内容区层级。
- 连接中与失败态使用终端内容画布的中心状态面板；已连接态由终端画布独占可用空间。
- 将窗口缩放、侧栏显隐视为同一内容容器的尺寸变化，禁止重建终端会话或把状态迁移到顶部/底部。

## Non-goals

- 不改变 SSH 认证、重试、会话所有权、凭据或主机密钥校验规则。
- 不改变标题栏页签栏或 iPadOS 的系统导航入口。

## Capabilities

### New Capabilities

- `ssh-content-page`: SSH 终端标签的跨阶段内容呈现、尺寸适配与会话连续性。

### Modified Capabilities

- `workspace`: 终端标签的连接中与失败内容呈现从临时状态行改为稳定内容页。

## Impact

影响 `TerminalTabView`、终端 SwiftUI/AppKit 包装层、工作区尺寸装配和 macOS/iPadOS XCTest；不影响 Rust、FFI 或保存的数据。

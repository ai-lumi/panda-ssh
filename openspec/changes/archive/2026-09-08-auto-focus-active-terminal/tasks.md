## 1. 测试（Red）

- [x] 1.1 新增 `TerminalFocusRequestPolicyTests`，覆盖活动终端请求焦点、隐藏终端不请求焦点。

## 2. 实现（Green）

- [x] 2.1 实现纯值焦点请求策略。
- [x] 2.2 将终端活动状态从 `WorkspaceView` 传至平台终端包装器；在 macOS/iPadOS 请求第一响应者，隐藏页签不请求。

## 3. 验证

- [x] 3.1 运行新增 XCTest 与相关工作区回归测试。
- [x] 3.2 运行 OpenSpec 严格校验。

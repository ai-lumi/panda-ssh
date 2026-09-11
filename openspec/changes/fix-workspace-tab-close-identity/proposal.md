## Why

工作区重构后，Swift UUID 大写字符串与 Rust 保存的小写页签 ID 不匹配，状态上报、查询、选择与关闭均可能失效。关闭路径先释放本地会话，因而出现 SSH 断开、页签保留且没有确认框的界面。

## What Changes

- 在 Swift 工作区边界统一页签 ID 表示，恢复状态和页签操作。
- 明确请求关闭与执行关闭的分工，保证确认前保留会话，执行后同步移除页签。
- 使用真实工作区 FFI 补充正常、失败及边界回归测试；将现有测试适配到当前连接状态接口。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

无。恢复 `workspace` 中多标签页工作区、连接失败提示及 SSH 终端标签页关闭二次确认的既有要求；`skip_specs: true`，不创建规格增量。

## Impact

影响 macOS 与 iPadOS 共用的 `WorkspaceStore` 和相关 XCTest。保留 Rust/FFI 签名、页签 UI、主机级连接隔离及后台传输生命周期。

## Non-goals

不调整 UI 样式、SSH 协议、存储、认证或 Rust 工作区架构；不修改已有的其他未提交改动，不连接真实服务器。

## Why

首次连接未知服务器时，底层正确返回了 `UnknownHostKey`，但终端标签有时将其显示为通用连接失败页。用户无法核对并确认服务器指纹，且容易误判为密码错误。

## What Changes

- 确保未知主机密钥的探测在认证前完成，并将其稳定地转换为首次信任（TOFU）确认对话框。
- 防止 `UnknownHostKey` 进入终端或 SFTP 的通用连接失败页。
- 覆盖首次连接、探测异常和已确认主机的连接门控测试。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `host-keys`: 明确未知主机密钥不得作为通用连接失败展示，必须进入用户确认流程。

## Impact

- macOS 与 iPadOS 共用的 SwiftUI 连接门控和终端/SFTP 标签页。
- 不修改 Rust 主机密钥校验、FFI 契约或凭据存储；不自动信任任何服务器。

## Non-goals

- 不改变已记录密钥不匹配时的阻断行为。
- 不将密码、私钥口令或主机密钥材料写入新的位置。
- 不改变网络超时和认证失败的错误分类。

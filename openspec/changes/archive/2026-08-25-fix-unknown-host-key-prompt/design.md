## Context

见 proposal.md。当前门控先依据本地 known_hosts 状态决定是否以 Reject 策略探测服务端密钥；只有探测结果转换为待确认状态时，连接才可取得凭据并开始 shell 或 SFTP 会话。实际会话入口仍须将意外到达的 `UnknownHostKey` 视为可恢复的安全门控状态，避免显示原始 FFI 错误。

## Goals / Non-Goals

**Goals:**

- 在 macOS 与 iPadOS 共享的终端和 SFTP 入口中可靠进入 TOFU 确认流程。
- 在认证前完成首次主机密钥确认，不削弱 Reject 默认策略。
- 以 XCTest 覆盖正常、错误与边界路径。

**Non-Goals:**

- 不修改 Rust SSH/FFI 接口、known_hosts 格式或认证方式。
- 不对已记录密钥变更提供自动替换或绕过。

## Decisions

- 复用既有 `PreconnectGate` 和 `AppModel` 的同主机确认串行化；它已持有呈现密钥并能在信任后继续凭据流程。这样不会新增第二套信任状态或导致两端行为分叉。
- 对会话建立阶段意外返回的 `UnknownHostKey`，将其重新送入门控而非 `ConnectionFailure.other`。这是防御性回退，处理 known_hosts 状态与实际握手之间的竞态，以及前置探测未能完成的路径。
- 测试以可注入的连接/探测结果驱动；不访问真实服务器或凭据。

替代方案是将 `UnknownHostKey` 原样保留在失败页并提示用户重试；它无法让用户安全确认本次呈现的密钥，违反既有主机密钥规格，故不采用。

## Risks / Trade-offs

- [前置探测被网络错误中断] → 后续握手的 UnknownHostKey 仍会回到 TOFU 门控；其他网络错误继续显示真实错误。
- [重复弹窗] → 沿用 `AppModel` 现有的按主机确认队列，确认结果统一广播。

## Migration Plan

无需数据迁移。升级后未知主机首次连接会显示指纹确认；用户取消不会写入 known_hosts。若需回滚，恢复现有 SwiftUI 文件即可，已有 known_hosts 记录保持不变。

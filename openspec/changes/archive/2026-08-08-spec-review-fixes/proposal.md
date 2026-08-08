# 提案：spec-review-fixes

## Why

2026-08-04 三方 specs 评审（见 `openspec/reviews/2026-08-04-spec-review.md`）发现 6 个阻断项与若干重要项，涉及安全正确性（钥匙串访问组、known_hosts 多 keytype 误判、TOFU 信息不足）、跨 spec 断链（SFTP 管理功能与进度未过 FFI、config-sync 未接线）、错误语义丢失（FFI flat error）。这些必须在联调前修复。

## What Changes

- **B1 钥匙串访问组**：`KeychainHelper` 去掉显式 `kSecAttrAccessGroup`（单 App 无需访问组共享，iCloud 漫游走 synchronizable），entitlements 移除 `keychain-access-groups`；保存主机时钥匙串写入失败 MUST 报错并阻止保存。
- **B2 known_hosts 多 keytype**：按 `(host, keytype)` 存取，消除一机多密钥误判 Mismatch；新增 `remove(host, port)` 支持密钥删除/更新；known_hosts 写入改为原子写。
- **B3 TOFU 信息补全**：`UnknownHostKey` 错误携带服务端呈现的密钥与指纹；FFI 以结构化错误暴露 host-key 问题，为 server-management 的确认 UI 铺路；`AcceptAndStore` 保持骨架期默认但在 spec 标注发布门禁。
- **B4 SFTP 管理导出**：FFI 补 `sftp_remove_file` / `sftp_remove_dir` / `sftp_create_dir`。
- **B5 config-sync 接线**：保存/删除主机后自动 push hosts.toml；App 启动时 pull 应用远端配置并 startObserving 监听变更（last-write-wins，冲突合并仍属后续 config-sync 变更）。
- **B6 结构化错误**：`PandaError` 增加可编程区分的类别（AuthFailed / Timeout / HostKeyMismatch{stored,presented} / UnknownHostKey{host,fingerprint} / NotInitialized / UnknownHost / MissingPassword / Core）。
- **I5 凭据级联清理**：删除主机时删除关联钥匙串条目。
- **I6 exec 超时**：命令执行增加默认 60 秒超时，超时返回 `Timeout`。
- **I8 测试基架**：基于 russh server API 的进程内 fake SSH/SFTP 服务器集成测试，覆盖连接、认证失败、exec、sftp 基本操作。

## Non-Goals

- 不实现 TOFU 确认交互 UI（属 `server-management` 变更，本变更只补数据通路）。
- 不实现传输进度跨 FFI（属 `transfer-tasks` 变更）。
- 不实现连接池 / 会话复用（属 `tabbed-workspace` 变更）。
- 不处理 iCloud 冲突合并策略（属 `config-sync` 变更的 last-write-wins 设计）。

## Capabilities

### Modified Capabilities

- `host-config`：补空文件行为 Scenario、删除主机的凭据级联要求、可判定措辞。
- `host-key-verification`：多 keytype 存取、密钥删除、原子写、TOFU 发布门禁。
- `ssh-connection`：exec 超时。
- `ffi-bridge`：SFTP 管理导出、结构化错误。
- `config-sync`：访问组修正、同步接线行为、消除 Purpose/Requirement 矛盾。

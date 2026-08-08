## Why

多服务器管理（增删改查）与主机指纹记录是 SSH 客户端的基础能力。核心库（`panda-core`）与 FFI 已具备主机 CRUD 与 known_hosts 读写，但缺少完整的主机管理界面、指纹展示，以及「首次连接需确认指纹」的安全确认流程——当前 FFI 对未知主机密钥是静默 TOFU 自动接受，存在中间人攻击风险，必须改为用户确认后接受。

## What Changes

- 完整的主机管理 UI：创建、编辑、删除、查看服务器（地址、端口、用户名、认证、备注、分组）。
- 主机数据持久化于 TOML 配置（原子写），重启与跨设备同步保持一致。
- 记录并展示每台服务器的已知主机密钥指纹（known_hosts）。
- 首次连接未知主机：展示指纹供用户确认，确认后接受并存储；拒绝则放弃连接。
- 主机密钥与已记录不一致时阻断连接并告警。
- FFI 暴露指纹状态查询与显式接受接口，替代当前 `AcceptAndStore` 的静默行为。

## Non-Goals

- 本变更不实现分组功能（属于 `server-groups` 变更）。
- 本变更不实现密码/密钥的保存与选择（属于 `authentication` 变更）。
- 本变更不实现 known_hosts 的手动编辑/导入导出。
- 本变更不实现基于指纹的其它验证方式（如 DNS 指纹、证书）。

## Capabilities

### New Capabilities

- `hosts`: 多服务器主机的管理（创建/编辑/删除/查看/持久化）。
- `host-keys`: 服务器主机密钥指纹的记录、展示、首次连接确认与变更检测。

### Modified Capabilities

- `host-key-verification`：连接期策略从「FFI 硬编码 `AcceptAndStore` 静默接受」改为「Reject 探测 + UI 确认后存储呈现密钥」，移除开发期过渡的发布门禁注记。
- `ffi-bridge`：连接入口（`test_connection`/`sftp_*`）新增 `trust_on_first_use` 参数；新增 `host_key_status`/`accept_unknown_host_key` 导出。

## Dependencies

- 前置：`server-groups`（主机表单的「所属分组」字段依赖其 `list_groups` 与 groups.toml）。
- 被依赖：`tabbed-workspace` 的 `shell_open` 签名与指纹确认串行化遵循本变更定义的约定；`transfer-tasks` 的 `start_transfer` 同样需带 `trust_on_first_use`。

## Impact

- macOS 与 iPadOS 双端：主机管理表单与指纹确认对话框为共享 SwiftUI 源码；iPadOS 上需要适配表单弹出方式（sheet/分栏）。
- Rust 核心（`crates/panda-core`）：`UnknownHostKeyPolicy::Reject` 已存在但需扩展——新增可查询指纹状态与显式接受存储的接口；主机 CRUD 复用现有 `TomlConfigStore`。
- FFI（`crates/panda-ffi`）：`test_connection` 等连接入口的未知主机策略从硬编码 `AcceptAndStore` 改为由 Swift 侧传入（`trust_on_first_use: bool` 或先查询指纹再确认）；新增 `host_key_status(host)`/`accept_unknown_host_key(host)` 导出。此改动必须同步更新 AGENTS.md 中关于当前 host key 行为的描述。
- 测试：core 侧指纹状态查询、接受/拒绝策略的单元测试；Swift 侧确认对话框状态测试。

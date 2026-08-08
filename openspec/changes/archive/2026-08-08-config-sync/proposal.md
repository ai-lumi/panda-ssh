## Why

README 将「macOS ⇄ iPadOS 通过 iCloud 共享配置与凭据」列为双端核心能力：用户在一端维护的主机列表、分组等配置应自动出现在另一端。现有 `ConfigSync.swift` 只是 push/pull 骨架（无变更通知应用、无冲突处理、仅覆盖 hosts 配置），且此前 7 个变更提案均未覆盖此能力——这是规格遗漏，本变更补齐。

## What Changes

- 主机、分组等配置文件通过 iCloud Key-Value Storage 在 macOS 与 iPadOS 间同步。
- 本地配置继续落盘于 App Group 容器（`init_store` 注入路径），iCloud KV 作为跨设备同步载体，离线时本地可用。
- 远端变更到达时自动应用并更新本地文件；本地保存后主动推送。
- 多端并发修改采用可预期的冲突策略（最后写入生效）。
- 密码、私钥口令等密钥材料 MUST NOT 经 KV 同步（只走 iCloud 同步钥匙串，见 `authentication` 变更）。
- 同步能力需开发者账号签名与 iCloud 容器权限（README 路线图已注明）。

## Non-Goals

- 本变更不实现细粒度同步（文件级整体快照即可）。
- 本变更不实现同步冲突 UI 与手动合并（采用 last-write-wins）。
- 本变更不改变钥匙串同步机制（iCloud 同步钥匙串已由 `authentication` 覆盖）。
- 本变更不实现 Linux/Windows 的配置同步。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `config-sync`：从 hosts.toml 骨架同步升级为 hosts + groups 版本化快照同步；冲突策略细化为按 `updatedAt` 时间戳的 last-write-wins（替代原「以 iCloud 为准覆盖本地」的表述）；明确同步边界：密钥材料、私钥路径（`key_path`）、known_hosts 信任记录均不进 KV。

## Dependencies

- 前置：`server-groups`（快照含 groups.toml）、`authentication`（`*_ref` 引用语义稳定）。
- 边界约定：私钥路径按设备独立（不同步、不被远端覆盖）；known_hosts 不同步，各端独立 TOFU——两项均已写入 spec delta。

## Impact

- macOS 与 iPadOS 双端：`ConfigSync` 从骨架升级为完整同步服务；两端行为一致，需要验证 iCloud 账号登录、KV 限制（单 key 1MB、总量 1MB 提示）下的可靠性。
- Rust 核心（`crates/panda-core`）：不改动；同步载体在 Swift 侧（KV 存整份 hosts/groups 快照，落盘仍由 `init_store` 管理的 TOML）。
- Swift UI：配置变更点接入同步（保存主机/分组后推送；收到远端变更后刷新并落盘）。
- 测试：Swift 侧同步逻辑用内存 fake（KV 抽象协议）测试 push/pull/冲突/通知；真实 iCloud 联调需开发者账号。

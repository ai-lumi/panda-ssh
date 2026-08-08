## Context

`apple/PandaSSH/Sync/ConfigSync.swift` 目前只有：`push(data)` 写入 `NSUbiquitousKeyValueStore`、`pull()` 读回、`startObserving(onChange:)` 监听 `didChangeExternallyNotification` 并回调。缺失：远端变更后把数据落盘到本地配置、本地保存后主动推送、冲突策略、多配置（hosts + groups）覆盖。README 声明本地文件落在 App Group 容器，路径由 App 注入 Rust 核心（`init_store`）。

## Goals / Non-Goals

**Goals:**

- 主机、分组等配置在双端自动同步，一端修改另一端自动更新。
- 本地落盘 + iCloud KV 快照双层：离线可用、联网收敛。
- 密钥材料不进 KV。
- 冲突可预期（last-write-wins）。

**Non-Goals:**

- 细粒度增量同步（KV 整体快照）。
- 冲突解决 UI / 手动合并。
- 超出 KV 限制的大配置（提示即可）。
- Linux/Windows 同步。

## Decisions

### 同步单位：配置快照

将需要同步的配置（hosts.toml 内容、groups.toml 内容，后续片段列表如需同步再扩展）序列化为一枚 KV 值（如 key `panda-ssh.config.v1`，值为版本化 JSON：`{version, updatedAt, hosts, groups}`）。`updatedAt` 为写入时间戳，用于冲突判定。单 key 数据量受 KV 限制（单 key 1MB），配置为文本 TOML/JSON，规模可控。

### 变更流向

- **本地写入**：保存主机/分组成功落盘后，Swift 组装快照 `push` 到 KV。
- **远端到达**：`didChangeExternallyNotification` 回调 → 比对快照 `updatedAt`（last-write-wins）→ 若远端更新则把 hosts/groups 落盘（经 FFI 复用原子写与校验）并刷新 UI。**应用远端变更期间置抑制标志，本次落盘不再触发 push，防止「远端到达 → 落盘 → 保存钩子 → push」回环**。
- **启动时**：`startObserving` 时 `synchronize()` 拉取一次最新快照，再按上述规则应用。

### 冲突策略

以 `updatedAt` 时间戳为判定：后写入者生效（last-write-wins）。相等时间戳时以本地方案为准。不做合并 UI（Non-Goal）。

### 密钥材料排除

同步快照只含主机配置与分组；`AuthMethod` 中的 `password_ref`/`passphrase_ref` 仅为钥匙串引用标识，可随配置同步，但密钥材料本身只存在于钥匙串，KV 中 MUST NOT 出现明文密码/口令（与安全红线一致）。

### 同步边界：私钥路径与 known_hosts 不进 KV

- **私钥路径按设备独立**：`key_path` 是本机文件系统路径，私钥文件不漫游。应用远端快照时保留本机 `key_path`，不被远端值覆盖；本机未设置私钥而主机为密钥认证时，连接报错并引导用户选择本机私钥。
- **known_hosts 不同步**：主机密钥信任记录不纳入快照，每台设备独立执行 TOFU 确认。信任域限定在本机，避免 iCloud 账户被攻破时信任记录被批量污染。

### 测试隔离

将 KV 抽象为 `KVStore` 协议（`set/get/data/synchronize`），生产用 `NSUbiquitousKeyValueStore` 适配，测试注入内存 fake，模拟两端设备互推与冲突时间戳。

## Risks / Trade-offs

- [KV 有总量与单 key 限制] → 快照为文本且整体 <1MB；超限时记录并提示，不崩溃。
- [iCloud 未登录 / KV 不可用时同步静默失败] → 本地功能不受影响，仅在必要时提示。
- [last-write-wins 会覆盖远端较新修改] → 接受为显式取舍，冲突 UI 留待后续。

## Migration Plan

无数据迁移；`ConfigSync` 从骨架扩展，key 从旧的 `panda-ssh.hosts.toml` 迁移到版本化 `panda-ssh.config.v1`（启动时检测旧 key 并存则迁移）。

## Open Questions

- 片段列表（`code-snippets`）是否纳入同一同步快照？当前 Non-Goal，待片段功能实现后再评估。

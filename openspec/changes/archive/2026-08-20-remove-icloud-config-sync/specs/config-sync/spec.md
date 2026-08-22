# Spec Delta: config-sync

## Purpose

本地配置文件持久化：主机配置与分组以 TOML 文件落盘，macOS 在 `~/.panda-ssh/`，iPadOS 在 App Group 容器。跨设备同步能力本期移除，作为后续版本预留。

## Removed Requirements

### Requirement: 配置同步行为

~~系统 SHALL 基于 `NSUbiquitousKeyValueStore` 同步配置快照：hosts.toml 与 groups.toml 序列化为一枚版本化 KV 值（含 `version` 与 `updatedAt` 写入时间戳）。保存或删除主机、调整分组后 MUST 自动 push 最新快照；App 启动时 MUST pull 远端快照并在本地为空或远端 `updatedAt` 更新时应用；`startObserving` 监听远端变更，收到后 MUST 落盘并刷新主机列表。冲突策略为 last-write-wins：以 `updatedAt` 时间戳判定，后写入者生效；时间戳相等时以本地为准。应用远端变更的落盘 MUST 抑制由此触发的本地 push，防止同步回环。KV store 实现 SHALL 可注入以便测试。~~

**Reason:** 当前使用个人开发者账号无法为 iOS 构建生成包含 iCloud KV + App Groups 的 provisioning profile。为让本地开发构建可运行，暂时移除 iCloud 配置同步，待加入 Apple Developer Program 后再恢复。

**Migration:** 下一版本将重新引入跨设备同步，届时会提供从本地 TOML 到同步载体的迁移逻辑。

### Requirement: 离线可用

~~配置 SHALL 始终落盘于 App Group 容器（本地文件），iCloud KV 仅作为同步载体；iCloud 不可用时本地功能 MUST 保持可用。~~

**Reason:** 同步载体已移除，本地落盘成为唯一持久化方式。

**Migration:** 无需迁移；本地文件继续作为配置来源。

### Requirement: 密钥材料不同步

~~密码、私钥口令等密钥材料 MUST NOT 通过 KV 同步；同步内容仅允许配置与钥匙串引用标识，明文密钥 MUST NOT 出现。~~

**Reason:** KV 同步已移除，密钥材料本来就不经 KV 同步；该约束由 `auth` 规格的「密钥材料保护」继续覆盖。

**Migration:** 无。

### Requirement: 私钥路径按设备独立

~~`AuthMethod::PublicKey.key_path` 指向本机文件系统路径，私钥文件不随同步漫游；应用远端快照时 MUST NOT 用它端写入的 `key_path` 覆盖本机值，各端独立设置。~~

**Reason:** 远端快照已不存在。

**Migration:** 无。

### Requirement: 主机密钥信任不同步

~~known_hosts 的主机密钥信任记录 MUST NOT 纳入同步；每台设备 SHALL 独立执行首次连接指纹确认（TOFU）。~~

**Reason:** 同步范围已不存在；known_hosts 继续作为本地文件由各端独立维护。

**Migration:** 无。

## Modified Requirements

### Requirement: 凭据漫游

系统 SHALL 将密码与私钥口令存入系统钥匙串。配置文件 SHALL 只存引用 key。单 App 场景 SHALL NOT 设置显式 `kSecAttrAccessGroup`。钥匙串写入失败 MUST 以错误呈现给用户并阻止保存，SHALL NOT 静默丢失凭据。删除主机时 MUST 级联删除其关联的钥匙串条目（密码与口令引用）。

**变更说明：** 原规格要求 `kSecAttrSynchronizable = true` 以支持 iCloud Keychain 漫游；本期仍保留 `synchronizable` 属性，但不以「跨设备漫游」作为强制要求描述，避免与个人账号构建冲突。钥匙串是否漫游由用户 iCloud 设置决定，App 侧保持原属性不变。

#### Scenario: 新增主机保存密码

- **WHEN** 用户在编辑表单中填写密码并保存
- **THEN** 密码进入系统钥匙串，hosts.toml 中仅出现引用 key

#### Scenario: 钥匙串写入失败

- **WHEN** 保存时钥匙串写入失败
- **THEN** 用户看到错误提示，主机配置不被保存

#### Scenario: 删除主机清理凭据

- **WHEN** 用户删除一台主机
- **THEN** 其 `host.<id>.password` / `host.<id>.passphrase` 钥匙串条目被一并删除

### Requirement: 本地存储位置

两平台的本地配置文件 MUST 落在各自平台的本地配置目录下：macOS 为 `~/.panda-ssh/`，iPadOS 为 App Group 容器 `group.com.pandassh.shared` 下（不可用时回退 Documents），路径由 App 注入 Rust 核心。

**变更说明：** 移除「跨设备同步」相关描述，仅保留本地落盘路径要求。

#### Scenario: macOS 本地落盘

- **WHEN** 用户在 macOS 保存主机
- **THEN** 配置文件写入 `~/.panda-ssh/hosts.toml` 与 `groups.toml`

#### Scenario: iPadOS 本地落盘

- **WHEN** 用户在 iPadOS 保存主机
- **THEN** 配置文件写入 App Group 容器内的 `hosts.toml` 与 `groups.toml`

#### Scenario: 容器不可用回退

- **WHEN** App Group 容器路径不可得（如未配置签名的开发构建）
- **THEN** 使用 Documents 目录，功能不受影响

## Added Requirements

### Requirement: 跨设备同步预留

系统 SHALL 保留未来恢复跨设备配置同步的扩展点：本地配置文件格式保持稳定，钥匙串引用 key 命名不变，不得在代码中引入与 iCloud KV 冲突的替代同步机制。

#### Scenario: 未来启用 iCloud 同步

- **WHEN** 后续版本重新引入 iCloud KV 同步
- **THEN** 现有本地配置文件可直接作为同步基准，无需迁移格式

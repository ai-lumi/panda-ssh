# config-sync Specification

## Purpose

本地配置文件持久化：主机配置与分组以 TOML 文件落盘，macOS 在 `~/.panda-ssh/`，iPadOS 在 App Group 容器。跨设备同步能力本期移除，作为后续版本预留。

## Requirements

### Requirement: 凭据存储

密码与私钥口令 MUST 存入系统钥匙串，配置文件 SHALL 只存引用 key。单 App 场景 SHALL NOT 设置显式 `kSecAttrAccessGroup`（避免 Team ID 前缀耦合）。钥匙串写入失败 MUST 以错误呈现给用户并阻止保存，SHALL NOT 静默丢失凭据。删除主机时 MUST 级联删除其关联的钥匙串条目（密码与口令引用）。

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

两平台的本地配置文件 MUST 落在以下路径：macOS 为 `~/.panda-ssh/`，iPadOS 为 App Group 容器 `group.com.pandassh.shared`（不可用时回退 Documents），路径由 App 注入 Rust 核心。

**变更说明：** 移除「跨设备同步」相关描述，仅保留本地落盘路径要求。

#### Scenario: 容器不可用回退

- **WHEN** App Group 容器路径不可得（如未配置签名的开发构建）
- **THEN** 使用 Documents 目录，功能不受影响

### Requirement: 配置变更即时生效

保存或删除主机、调整分组后，本地文件 MUST 立即更新，且主机列表 MUST 即时刷新。本地文件为唯一持久化来源，不存在异步同步回环问题。

#### Scenario: 保存主机后列表刷新

- **WHEN** 用户保存或删除一台主机
- **THEN** 本地文件立即更新，主机列表同步刷新

### Requirement: 跨设备同步预留

系统 SHALL 保留未来恢复跨设备配置同步的扩展点：本地配置文件格式保持稳定，钥匙串引用 key 命名不变，不得在代码中引入与 iCloud KV 冲突的替代同步机制。在 iCloud 同步不可用期间，用户 SHALL 可通过导出/导入功能手动迁移配置。

#### Scenario: 未来启用 iCloud 同步

- **WHEN** 后续版本重新引入 iCloud KV 同步
- **THEN** 现有本地配置文件可直接作为同步基准，无需迁移格式

#### Scenario: 无 iCloud 时通过导出导入迁移

- **GIVEN** 用户有两台设备均未启用 iCloud 同步
- **WHEN** 用户在设备 A 导出配置，在设备 B 导入
- **THEN** 设备 B 获得与设备 A 一致的主机列表、分组与代码片段

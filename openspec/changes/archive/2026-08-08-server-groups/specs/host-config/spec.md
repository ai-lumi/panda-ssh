# host-config Spec Delta

## MODIFIED Requirements

### Requirement: 主机配置数据模型

系统 SHALL 以 `HostConfig` 表示一台主机：`id`（UUID 字符串）、`name`、`host`、`port`（缺省 22）、`username`、`auth`、`notes`（可选）、`group_id`（可选，所属分组 id，缺省/缺失为根级）。`auth` MUST 为 `Password { password_ref }` 或 `PublicKey { key_path, passphrase_ref }` 之一，`*_ref` 字段 MUST 只保存钥匙串引用，SHALL NOT 保存明文密码或口令。旧版配置文件缺少 `group_id` 字段时 MUST 按根级（`None`）处理，无需迁移。

#### Scenario: 密码认证配置序列化

- **WHEN** 一个使用密码认证的 `HostConfig` 被序列化为 TOML 再反序列化
- **THEN** 结果与原始值相等，且 TOML 文本中不出现 `password` 字段、仅出现 `password_ref`

#### Scenario: 密钥认证配置序列化

- **WHEN** 一个使用密钥认证（含私钥路径与可选口令引用）的 `HostConfig` 被序列化为 TOML 再反序列化
- **THEN** 结果与原始值相等

#### Scenario: 端口缺省值

- **WHEN** TOML 中的主机条目缺少 `port` 字段
- **THEN** 反序列化结果 `port` 为 22

#### Scenario: 分组归属缺省值

- **WHEN** 旧版 TOML 中的主机条目缺少 `group_id` 字段
- **THEN** 反序列化结果 `group_id` 为 `None`（根级）

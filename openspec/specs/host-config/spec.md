# host-config Specification

## Purpose

主机配置的建模与持久化：主机列表以 TOML 文件存储，密钥材料（密码、私钥口令）只存配置目录内的专用凭据文件，配置文件仅存引用 key。macOS 与 iPadOS 共用同一份布局，存储路径由宿主 App 注入（macOS 为 `~/.panda-ssh/`，iPadOS 为 App Group 容器）。
## Requirements
### Requirement: 主机配置数据模型

系统 SHALL 以 `HostConfig` 表示一台主机：`id`（UUID 字符串）、`name`、`host`、`port`（缺省 22）、`username`、`auth`、`notes`（可选）、`group_id`（可选，所属分组 id，缺省/缺失为根级）。`auth` MUST 为 `Password { password_ref }` 或 `PublicKey { key_path, passphrase_ref }` 之一，`*_ref` 字段 MUST 只保存本地凭据引用，SHALL NOT 保存明文密码或口令。旧版配置文件缺少 `group_id` 字段时 MUST 按根级（`None`）处理，无需迁移。

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

### Requirement: 配置存储

系统 SHALL 提供 `ConfigStore` 抽象（list / get / upsert / delete），并给出基于单个 TOML 文件的默认实现 `TomlConfigStore`。写入 MUST 原子完成（临时文件 + rename），存储路径 MUST 由调用方注入，实现 SHALL NOT 硬编码任何路径。同 id upsert MUST 为替换语义。配置文件损坏时读取 MUST 返回错误而非静默丢弃或 panic。

#### Scenario: 首次启动空配置

- **WHEN** 配置文件尚不存在时执行 list
- **THEN** 返回空列表而非错误

#### Scenario: upsert 后持久化

- **WHEN** 对 `TomlConfigStore` 执行 upsert 后用同一路径重新打开
- **THEN** 新实例 list 结果包含该主机

#### Scenario: 同 id 替换

- **WHEN** 以相同 id upsert 两个不同配置
- **THEN** list 中该 id 仅出现一次且为后写入的配置

#### Scenario: delete 后持久化

- **WHEN** 删除某主机并用同一路径重新打开
- **THEN** 新实例 list 结果不包含该主机

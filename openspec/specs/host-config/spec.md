# host-config Specification

## Purpose

主机配置的建模与持久化：主机列表以 TOML 文件存储，密钥材料（密码、私钥口令）只存配置目录内的专用凭据文件，配置文件仅存引用 key。macOS 与 iPadOS 共用同一份布局，存储路径由宿主 App 注入（macOS 为 `~/.panda-ssh/`，iPadOS 为 App Group 容器）。
## Requirements
### Requirement: 主机配置数据模型

系统 SHALL 以 `HostConfig` 表示一台主机：`id`（UUID 字符串）、`name`、`host`、`port`（缺省 22）、`username`、`auth`、`notes`（可选）、`group_id`（可选，所属分组 id，缺省/缺失为根级）、`proxy_jump`（可选，跳板机引用，指向另一台 `HostConfig` 的 id；缺省/缺失为 `None` 即直连）。`auth` MUST 为 `Password { password_ref }` 或 `PublicKey { key_path, passphrase_ref }` 之一，`*_ref` 字段 MUST 只保存本地凭据引用，SHALL NOT 保存明文密码或口令。旧版配置文件缺少 `group_id` 字段时 MUST 按根级（`None`）处理，无需迁移。`proxy_jump` MUST 参与序列化和反序列化，TOML 中 MUST 以跳板机的 id 字符串表示。

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

#### Scenario: 含跳板机引用的配置序列化

- **WHEN** 一个 `proxy_jump` 指向有效 id 的 `HostConfig` 被序列化为 TOML 再反序列化
- **THEN** 结果与原始值相等，且 TOML 文本中 `proxy_jump` 字段为跳板机的 id 字符串

#### Scenario: 缺少 proxy_jump 字段的旧配置

- **WHEN** TOML 中的主机条目缺少 `proxy_jump` 字段
- **THEN** 反序列化结果 `proxy_jump` 为 `None`（直连）

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

### Requirement: 跳板链校验

系统 SHALL 在 HostConfig upsert 和配置加载时校验 `proxy_jump` 引用的合法性。校验 MUST 覆盖以下约束：

1. **悬空引用**：`proxy_jump` 引用的 id MUST 存在于同一配置存储；不存在时 MUST 返回 `DanglingProxyJumpRef` 错误。
2. **自引用**：`proxy_jump` MUST NOT 指向自身 id；违反时 MUST 返回 `SelfReferencingProxyJump` 错误。
3. **环检测**：沿 `proxy_jump` 递归遍历 MUST NOT 出现环；违反时 MUST 返回 `CyclicProxyJump` 错误，并携带环路径。
4. **最大链深**：跳板链深度 MUST NOT 超过 `MAX_PROXY_CHAIN_DEPTH`（8）；违反时 MUST 返回 `ProxyJumpChainTooDeep` 错误。

校验 SHALL 在 upsert 时先于持久化执行，MUST NOT 允许非法配置写入文件。

#### Scenario: 合法单跳引用

- **WHEN** 主机 A 的 `proxy_jump` 指向已存在的主机 B，且 B 无 `proxy_jump`
- **THEN** upsert 成功，校验通过

#### Scenario: 合法多级跳板引用

- **WHEN** A → B → C（C 无 `proxy_jump`），链深为 3
- **THEN** upsert 成功，校验通过

#### Scenario: 自引用拒绝

- **WHEN** 主机 A 的 `proxy_jump` 指向 A 自身的 id
- **THEN** upsert 被拒绝，返回 `SelfReferencingProxyJump` 错误

#### Scenario: 环引用拒绝

- **WHEN** A → B → C → A 形成环
- **THEN** upsert 被拒绝，返回 `CyclicProxyJump` 错误

#### Scenario: 超深链拒绝

- **WHEN** 跳板链深度为 9（超过上限 8）
- **THEN** upsert 被拒绝，返回 `ProxyJumpChainTooDeep` 错误

#### Scenario: 悬空引用拒绝

- **WHEN** `proxy_jump` 引用的 id 在配置存储中不存在
- **THEN** upsert 被拒绝，返回 `DanglingProxyJumpRef` 错误

#### Scenario: 边界——链深恰好等于上限

- **WHEN** 跳板链深度恰好为 8
- **THEN** upsert 成功，校验通过

### Requirement: 跳板机删除约束

系统 SHALL 在删除 `HostConfig` 时检查该 id 是否被其他主机的 `proxy_jump` 引用。被引用时 MUST 拒绝删除并返回 `ProxyJumpInUse` 错误，错误信息 MUST 包含引用方的 id 和 name 列表。此约束 MUST 在 `ConfigStore::delete` 层统一实施，覆盖所有调用入口（UI、导入、MCP）。

#### Scenario: 删除被引用的跳板机

- **WHEN** 主机 B 被主机 A 的 `proxy_jump` 引用，尝试删除 B
- **THEN** 删除被拒绝，返回 `ProxyJumpInUse` 错误，包含 A 的 id 和 name

#### Scenario: 删除未被引用的主机

- **WHEN** 主机 B 未被任何主机的 `proxy_jump` 引用
- **THEN** 删除正常成功

#### Scenario: 引用方已删除后可删除被引用方

- **WHEN** A 曾引用 B，A 已被删除后再删除 B
- **THEN** 删除正常成功


# ffi-bridge Specification

## Purpose

通过 uniffi 把 panda-core 暴露给 SwiftUI（macOS / iPadOS）。FFI 层只做翻译与生命周期管理，不含业务逻辑。
## Requirements
### Requirement: 导出接口

FFI 层 SHALL 导出：`init_store(config_dir)`、`list_hosts`、`save_host`、`delete_host`、`list_groups`、`save_group`、`delete_group`、`move_group`、`test_connection`、`sftp_list`、`sftp_upload`、`sftp_download`、`sftp_remove_file`、`sftp_remove_dir`、`sftp_create_dir`、`host_key_status(host, port)`、`accept_unknown_host_key(host, port, key)`。连接入口（`test_connection`、`sftp_*`）MUST 接受 `trust_on_first_use: bool` 参数：`false` 时对未知主机密钥使用 `Reject` 策略，`true` 时使用 `AcceptAndStore`。类型以 FFI 友好的 Record/Enum 暴露（`HostConfigRecord`、`AuthMethodEnum`、`RemoteFileRecord`、`GroupRecord`），错误以结构化 `PandaError` 暴露（见「错误分类」）。`save_host` / `save_group` 传入空 id 时 MUST 生成新 UUID。`HostConfigRecord` MUST 携带 `group_id: Option<String>` 表示主机归属分组（`None` 为根级）。`delete_group` MUST 级联清空被删分组（含子分组）下所有主机的 `group_id`，并一并删除子分组；`move_group` MUST 拒绝会造成环的移动（移入自身或后代分组）。

#### Scenario: Swift 绑定可生成

- **WHEN** 运行 `apple/Scripts/build-rust.sh`（手动/CI 验证步骤）
- **THEN** 生成 Swift 绑定源码与 xcframework（macOS / iOS / iOS 模拟器，arm64-only）

#### Scenario: 远程文件管理可达 UI

- **WHEN** Swift 侧调用 `sftp_remove_file` / `sftp_remove_dir` / `sftp_create_dir`
- **THEN** 对应 core 的 SFTP 管理能力被执行

#### Scenario: 分组管理可达 UI

- **WHEN** Swift 侧调用 `list_groups` / `save_group` / `delete_group` / `move_group`
- **THEN** 对应 core 的分组管理与删除级联清理被执行

#### Scenario: 未知主机密钥决策权在 UI

- **WHEN** Swift 以 `trust_on_first_use=false` 连接未知主机
- **THEN** 返回 `UnknownHostKey` 错误（携带呈现密钥与指纹），known_hosts 不被写入

#### Scenario: 指纹状态可查询

- **WHEN** Swift 调用 `host_key_status(host, port)`
- **THEN** 返回该主机的三态状态（Unknown / Match / Mismatch），供 UI 决定直接连接、弹确认框或阻断告警

### Requirement: 同步调用语义

所有导出函数对调用方 MUST 表现为同步调用；内部异步逻辑 SHALL 在懒初始化的全局 tokio runtime 上执行。

#### Scenario: 从任意线程调用

- **WHEN** Swift 侧从非 tokio 线程调用导出函数
- **THEN** 正常返回结果或错误，不发生 block_on 嵌套 panic

### Requirement: 凭据边界

FFI 层 SHALL NOT 访问系统钥匙串；密码与私钥口令 MUST 由 Swift 侧从钥匙串取出后作为参数传入。骨架阶段每次 SSH/SFTP 调用新建连接，SHALL NOT 做连接池。

#### Scenario: 缺密码时报错

- **WHEN** 对密码认证的主机调用 `test_connection` 但未传 password
- **THEN** 返回 `MissingPassword` 错误

### Requirement: 初始化

`init_store` 首次调用生效、后续调用为 no-op；未初始化时调用其他接口 MUST 返回 `NotInitialized`。

#### Scenario: 未初始化调用

- **WHEN** 未调用 `init_store` 直接调用 `list_hosts`
- **THEN** 返回 `NotInitialized` 错误

### Requirement: 错误分类

FFI 错误 MUST 保留可编程区分的类别：`AuthFailed`、`Timeout`、`HostKeyMismatch { stored, presented }`、`UnknownHostKey { host, fingerprint }`、`NotInitialized`、`UnknownHost`、`MissingPassword`、`Core(String)`（兜底）。SHALL NOT 把可区分的 core 错误一律压平为字符串。

#### Scenario: 认证失败可区分

- **WHEN** 密码错误导致连接失败
- **THEN** Swift 侧收到 `AuthFailed`，可与超时、网络错误区分处理

#### Scenario: 主机密钥问题携带指纹

- **WHEN** 发生 Mismatch 或 Reject 策略下的 Unknown
- **THEN** 错误以结构化字段携带相关指纹，UI 可直接展示


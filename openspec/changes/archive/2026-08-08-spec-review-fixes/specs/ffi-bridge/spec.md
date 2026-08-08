# ffi-bridge Spec Delta

## MODIFIED Requirements

### Requirement: 导出接口

FFI 层 SHALL 导出：`init_store(config_dir)`、`list_hosts`、`save_host`、`delete_host`、`test_connection`、`sftp_list`、`sftp_upload`、`sftp_download`、`sftp_remove_file`、`sftp_remove_dir`、`sftp_create_dir`。类型以 FFI 友好的 Record/Enum 暴露（`HostConfigRecord`、`AuthMethodEnum`、`RemoteFileRecord`），错误以结构化 `PandaError` 暴露（见「错误分类」）。`save_host` 传入空 id 时 MUST 生成新 UUID。

#### Scenario: Swift 绑定可生成

- **WHEN** 运行 `apple/Scripts/build-rust.sh`（手动/CI 验证步骤）
- **THEN** 生成 Swift 绑定源码与 xcframework（macOS / iOS / iOS 模拟器，arm64-only）

#### Scenario: 远程文件管理可达 UI

- **WHEN** Swift 侧调用 `sftp_remove_file` / `sftp_remove_dir` / `sftp_create_dir`
- **THEN** 对应 core 的 SFTP 管理能力被执行

## ADDED Requirements

### Requirement: 错误分类

FFI 错误 MUST 保留可编程区分的类别：`AuthFailed`、`Timeout`、`HostKeyMismatch { stored, presented }`、`UnknownHostKey { host, fingerprint }`、`NotInitialized`、`UnknownHost`、`MissingPassword`、`Core(String)`（兜底）。SHALL NOT 把可区分的 core 错误一律压平为字符串。

#### Scenario: 认证失败可区分

- **WHEN** 密码错误导致连接失败
- **THEN** Swift 侧收到 `AuthFailed`，可与超时、网络错误区分处理

#### Scenario: 主机密钥问题携带指纹

- **WHEN** 发生 Mismatch 或 Reject 策略下的 Unknown
- **THEN** 错误以结构化字段携带相关指纹，UI 可直接展示

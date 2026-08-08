# ffi-bridge Spec Delta

## MODIFIED Requirements

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

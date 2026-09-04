## MODIFIED Requirements

### Requirement: 导出接口

FFI 层 SHALL 导出：`init_store(config_dir)`、`list_hosts`、`save_host`、`delete_host`、`list_groups`、`save_group`、`delete_group`、`move_group`、`save_credential`、`read_credential`、`delete_credential`、`set_credential_protection_key`、`credential_protection_enabled`、`test_connection`、兼容性无状态 `sftp_*`、`host_key_status(host, port)`、`accept_unknown_host_key(host, port, key)`；并 SHALL 导出 `shell_open` / `shell_read` / `shell_write` / `shell_resize` / `shell_close`、`sftp_session_open` / `sftp_session_*` / `sftp_session_close` 以及连接遥测查询接口。连接入口（`test_connection`、无状态 `sftp_*`、`shell_open`、`sftp_session_open`）MUST 接受 `trust_on_first_use: bool` 参数：`false` 时对未知主机密钥使用 `Reject` 策略，`true` 时使用 `AcceptAndStore`。类型以 FFI 友好的 Record/Enum 暴露（`HostConfigRecord`、`AuthMethodEnum`、`RemoteFileRecord`、`GroupRecord`），错误以结构化 `PandaError` 暴露（见「错误分类」）。`save_host` / `save_group` 传入空 id 时 MUST 生成新 UUID。`HostConfigRecord` MUST 携带 `group_id: Option<String>` 表示主机归属分组（`None` 为根级）。`delete_group` MUST 级联清空被删分组（含子分组）下所有主机的 `group_id`，并一并删除子分组；`move_group` MUST 拒绝会造成环的移动（移入自身或后代分组）。

#### Scenario: Swift 绑定可生成

- **WHEN** 运行 `apple/Scripts/build-rust.sh`（手动/CI 验证步骤）
- **THEN** 生成 Swift 绑定源码与 xcframework（macOS / iOS / iOS 模拟器，arm64-only）

#### Scenario: 远程文件管理可达 UI

- **WHEN** Swift 侧调用无状态 `sftp_remove_file` / `sftp_remove_dir` / `sftp_create_dir` 或对应的 `sftp_session_*` 句柄接口
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

### Requirement: 凭据边界

FFI 层 SHALL 将凭据的保存、读取、删除和保护密钥状态管理委托给跨平台核心，且 SHALL NOT 访问系统钥匙串。密码、私钥口令与保护密钥 MUST 仅作为调用参数在内存中传递，MUST NOT 由 Swift 侧落盘。SSH/SFTP 连接入口 SHALL 使用瞬态密码或口令参数为声明的所有者建立独立连接；SFTP 句柄后续操作 SHALL 仅复用该标签自己拥有的会话，MUST NOT 跨所有者复用连接。

#### Scenario: 缺密码时报错

- **WHEN** 对密码认证的主机调用 `test_connection` 但未传 password
- **THEN** 返回 `MissingPassword` 错误

## ADDED Requirements

### Requirement: 显式会话句柄

FFI 层 SHALL 为终端与 SFTP 打开操作返回稳定、FFI 友好的会话句柄；后续读写、文件操作、健康检查与关闭 SHALL 明确指定句柄。句柄 MUST 绑定单一所有者，关闭一个句柄 MUST NOT 按主机关闭其他句柄。异步工作 SHALL 继续在既有全局 tokio runtime 上执行。

#### Scenario: 两个同主机 SFTP 句柄

- **WHEN** Swift 为同一主机打开两个 SFTP 标签
- **THEN** FFI 返回两个不同句柄，任一句柄关闭后另一个仍可执行目录列表

#### Scenario: 已关闭句柄被再次使用

- **WHEN** Swift 使用已关闭或不存在的会话句柄执行操作
- **THEN** FFI 返回可区分的句柄无效错误，MUST NOT 建立新连接或影响其他句柄

### Requirement: 精确关闭契约

FFI SHALL 提供终端和 SFTP 会话的幂等精确关闭接口，并 SHALL NOT 暴露会批量断开某主机全部活动连接的正常工作区关闭路径。

#### Scenario: 精确关闭终端句柄

- **GIVEN** 同一主机有两个活动终端句柄
- **WHEN** Swift 关闭其中一个句柄
- **THEN** 仅对应 Channel 与 Transport 被释放，另一个句柄保持有效

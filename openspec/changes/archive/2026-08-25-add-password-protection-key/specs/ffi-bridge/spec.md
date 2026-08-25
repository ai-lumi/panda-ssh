## MODIFIED Requirements

### Requirement: 凭据边界

FFI 层 SHALL 将凭据的保存、读取、删除和保护密钥状态管理委托给跨平台核心，且 SHALL NOT 访问系统钥匙串。密码、私钥口令与保护密钥 MUST 仅作为调用参数在内存中传递，MUST NOT 由 Swift 侧落盘。骨架阶段每次 SSH/SFTP 调用新建连接，SHALL NOT 做连接池。

#### Scenario: 缺密码时报错

- **WHEN** 对密码认证的主机调用 `test_connection` 但未传 password
- **THEN** 返回 `MissingPassword` 错误

#### Scenario: Swift 保存凭据

- **WHEN** Swift 请求为主机保存密码或私钥口令
- **THEN** 核心将凭据保存到已初始化配置目录中的本地凭据文件，且不调用系统钥匙串

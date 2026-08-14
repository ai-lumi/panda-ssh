# ssh-connection Specification (Delta)

## MODIFIED Requirements

### Requirement: 建立会话

系统 SHALL 支持以 `HostConfig` + `Credentials` 建立 SSH 会话。`Credentials` MUST 为 `Password(明文)` 或 `KeyFile { path, passphrase }` 之一，由调用方从钥匙串取回后传入，核心库 SHALL NOT 直接访问钥匙串。连接与认证 MUST 各有超时（默认 30 秒），空闲超时默认 30 秒。

系统 SHALL 优先从连接池中获取已有可用会话；池中无可用会话时，按原有流程新建连接。新建成功的会话 MUST 自动加入连接池以供后续复用。

#### Scenario: 密码认证

- **WHEN** 以正确密码连接可达的 SSH 服务器
- **THEN** 会话建立成功

#### Scenario: 密钥认证

- **WHEN** 以私钥文件（可选口令）连接可达的 SSH 服务器
- **THEN** 会话建立成功

#### Scenario: 认证失败

- **WHEN** 凭据错误
- **THEN** 返回 `AuthFailed` 错误而非 panic 或挂起

#### Scenario: 复用已有会话

- **WHEN** 针对同一主机的第二次操作发生时，池中已有该主机的存活会话
- **THEN** 直接复用该会话，SHALL NOT 触发新的 TCP 连接或 SSH 握手

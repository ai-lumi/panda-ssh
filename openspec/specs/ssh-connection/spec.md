# ssh-connection Specification

## Purpose

基于 russh 的 SSH 客户端会话：密码与密钥两种认证、命令执行、连接超时控制。本期不做交互式 shell 数据流（终端对接属于后续变更）。
## Requirements
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

### Requirement: 命令执行

系统 SHALL 支持在会话上执行单条命令并收集结果：stdout、stderr、退出码。命令执行 MUST 有超时（默认 60 秒），超时 MUST 返回 `Timeout` 错误并终止等待，SHALL NOT 无限阻塞调用方。

#### Scenario: 执行结果完整

- **WHEN** 执行一条向 stdout/stderr 输出并以非零码退出的命令
- **THEN** 返回的 `ExecOutput` 包含两路输出；服务器报告退出码时 MUST 原样返回

#### Scenario: 命令超时

- **WHEN** 执行的命令在超时时间内不结束
- **THEN** 返回 `Timeout` 错误，调用方线程不被永久阻塞


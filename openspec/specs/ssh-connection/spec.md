# ssh-connection Specification

## Purpose

基于 russh 的 SSH 客户端会话：密码与密钥两种认证、命令执行、连接超时控制、交互式 shell 会话。

## Requirements
### Requirement: 建立会话

系统 SHALL 支持以 `HostConfig` + `Credentials` 建立 SSH 会话。`Credentials` MUST 为 `Password(明文)` 或 `KeyFile { path, passphrase }` 之一，由调用方从本地凭据文件或当前会话输入取回后传入，核心库 SHALL NOT 直接访问平台凭据服务。连接与认证 MUST 各有超时（默认 30 秒）；已认证会话 SHALL NOT 配置基于无业务流量的 inactivity timeout，并 SHALL 使用 SSH keepalive 及有限失败次数检测不可用。

每次连接请求 SHALL 新建一条 `SshSession`，MUST NOT 从全局连接池取得或向不同所有者共享会话。调用方 SHALL 成为该会话的唯一业务所有者，并在自身生命周期结束时释放会话。

#### Scenario: 密码认证

- **WHEN** 以正确密码连接可达的 SSH 服务器
- **THEN** 会话建立成功

#### Scenario: 密钥认证

- **WHEN** 以私钥文件（可选口令）连接可达的 SSH 服务器
- **THEN** 会话建立成功

#### Scenario: 认证失败

- **WHEN** 凭据错误
- **THEN** 返回 `AuthFailed` 错误而非 panic 或挂起

#### Scenario: 私钥缺少口令

- **WHEN** 选择的私钥受口令保护且未提供口令
- **THEN** 返回可区分的 `MissingPassphrase` 错误而非 `Timeout`

#### Scenario: 同一主机独立建立会话

- **WHEN** 两个所有者使用相同凭据连接同一主机
- **THEN** 系统分别建立两条 SSH 会话与底层 Socket，MUST NOT 跨所有者复用

#### Scenario: 已认证会话正常空闲

- **GIVEN** 已认证会话没有业务流量且 keepalive 正常
- **WHEN** 空闲时间超过三十秒
- **THEN** 会话保持存活，MUST NOT 因 inactivity timeout 关闭

### Requirement: 命令执行

系统 SHALL 支持在会话上执行单条命令并收集结果：stdout、stderr、退出码。命令执行 MUST 有超时（默认 60 秒），超时 MUST 返回 `Timeout` 错误并终止等待，SHALL NOT 无限阻塞调用方。

#### Scenario: 执行结果完整

- **WHEN** 执行一条向 stdout/stderr 输出并以非零码退出的命令
- **THEN** 返回的 `ExecOutput` 包含两路输出；服务器报告退出码时 MUST 原样返回

#### Scenario: 命令超时

- **WHEN** 执行的命令在超时时间内不结束
- **THEN** 返回 `Timeout` 错误，调用方线程不被永久阻塞

### Requirement: 交互式 shell 会话

系统 SHALL 支持在已认证的 SSH 会话上建立交互式 shell 会话。Shell 会话 MUST 先分配 PTY（伪终端），再请求远程 shell，使远程 shell 运行在正确的终端语义环境中（ANSI 转义码、行编辑、作业控制）。Shell 会话 MUST 支持双向数据流：客户端输入字节通过 SSH 通道发送到服务端 PTY，服务端 PTY 输出由客户端读取并传递给终端视图。Shell 会话 MUST 支持窗口尺寸动态调整。终端所有者 SHALL 独占该 shell Channel 与 SSH Transport；shell 正常结束、本地关闭或失败后 SHALL 释放所属 Transport，MUST NOT 影响其他所有者。

#### Scenario: 成功建立 shell 会话

- **WHEN** 客户端请求打开交互式 shell
- **THEN** PTY 分配成功，远程 shell 启动，双向数据流就绪

#### Scenario: PTY 分配失败

- **WHEN** 服务端拒绝 PTY 分配
- **THEN** 返回明确的错误，SHALL NOT 建立无 PTY 的 shell 会话

#### Scenario: shell 会话关闭

- **WHEN** 客户端关闭 shell 会话或远端 shell 正常结束
- **THEN** shell 通道与该终端所有者的底层 SSH 连接被释放，其他所有者的连接保持不变

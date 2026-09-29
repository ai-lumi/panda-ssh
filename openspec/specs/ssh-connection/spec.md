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

### Requirement: 跳板机连接

系统 SHALL 支持通过一级或多级跳板机建立 SSH 连接。当 `HostConfig.proxy_jump` 不为 `None` 时，连接流程 MUST：

1. 解析完整跳板链（从第一级跳板到目标主机）
2. 逐跳建立 SSH 连接：第一跳以 `TcpStream` 直连，后续跳通过前一跳的 `direct-tcpip` 通道承载
3. 每跳独立执行主机密钥校验（使用各跳自身的 `(host, port)`）
4. 每跳独立执行认证（使用各跳自身的凭据）
5. 任一跳失败时 MUST 关闭已建立的所有中间连接

跳板链中的中间会话生命周期 MUST 绑定到目标会话，目标会话释放时中间会话 MUST 自动关闭。

#### Scenario: 单跳代理连接

- **WHEN** 目标主机 A 的 `proxy_jump` 指向跳板机 B
- **THEN** 系统先连接 B，再通过 B 的 `direct-tcpip` 通道连接 A

#### Scenario: 多级跳板连接

- **WHEN** A → B → C → 目标 D（3 级跳板）
- **THEN** 系统依次连接 B、C、D，每级通过前一级的 `direct-tcpip` 通道

#### Scenario: 中间跳认证失败

- **WHEN** 跳板链中第 2 跳认证失败
- **THEN** 第 1 跳的连接被关闭，返回 `ProxyJumpFailed` 错误，携带失败跳的位置和原因

#### Scenario: 无跳板时行为不变

- **WHEN** `proxy_jump` 为 `None`
- **THEN** 连接流程与跳板机功能引入前完全一致

#### Scenario: 目标会话释放时中间会话关闭

- **WHEN** 目标会话被 Drop 或显式 disconnect
- **THEN** 所有中间跳板的会话也被关闭

### Requirement: 每跳主机密钥校验

跳板链中的每一跳 MUST 独立执行主机密钥校验。校验使用各跳自身的 `(host, port)` 和共享的 `KnownHosts`，策略由调用方统一传入。

- 跳板的 Unknown 密钥 MUST 返回 `ProxyJumpUnknownHostKey`，携带跳板位置信息、呈现密钥和指纹
- 跳板的 Mismatch 密钥 MUST 阻断连接，行为与直连时一致
- 目标主机的密钥校验行为与无跳板时完全一致

#### Scenario: 跳板机密钥未知

- **WHEN** 跳板机（第 1 跳）的密钥不在 known_hosts 中
- **THEN** 返回 `ProxyJumpUnknownHostKey`，携带 hop_index=0、跳板配置、呈现密钥和指纹

#### Scenario: 跳板机密钥变更

- **WHEN** 跳板机的密钥与 known_hosts 中存储的不匹配
- **THEN** 连接被阻断，返回 `HostKeyMismatch`，行为与直连时一致

#### Scenario: 多级跳板中第二跳密钥未知

- **WHEN** 第 1 跳密钥已确认，第 2 跳密钥不在 known_hosts 中
- **THEN** 第 1 跳连接保持，返回 `ProxyJumpUnknownHostKey`，携带 hop_index=1

### Requirement: 每跳凭据

跳板链中的每一跳 MUST 使用各自 `HostConfig` 的 `auth` 配置获取凭据。调用方 MUST 按链顺序提供 `Vec<Credentials>`，连接函数按位置对应使用。

凭据 MUST NOT 在跳板间共享或传递。凭据 MUST NOT 经 FFI 落盘。

#### Scenario: 混合认证方式

- **WHEN** 跳板机使用密码认证，目标主机使用密钥认证
- **THEN** 跳板机以密码认证通过，目标以密钥认证通过

#### Scenario: 凭据顺序与链一致

- **WHEN** 跳板链为 [B, C, 目标 A]
- **THEN** credentials[0] 用于 B，credentials[1] 用于 C，credentials[2] 用于 A

### Requirement: 自动重连

系统 SHALL 支持终端标签在连接失效后按可配置策略自动重连。重连策略 SHALL 使用指数退避：初始间隔 1 秒、最大间隔 30 秒、最大重试次数默认 10 次、退避乘数 2.0。仅网络类错误（EOF、读写错误、keepalive 超时、连接超时）SHALL 触发自动重连；认证失败（`AuthFailed`）和主机密钥不匹配（`HostKeyMismatch`）SHALL NOT 触发自动重连。

每次重连 SHALL 重新从凭据存储获取凭据，MUST NOT 使用内存缓存的旧凭据。重连 SHALL 重新执行主机密钥检查，密钥变更时阻断并告警。重连成功后 SHALL 重建 shell Channel 并恢复 PTY 尺寸。

#### Scenario: 网络中断后自动重连

- **GIVEN** 终端标签处于已连接状态，自动重连已启用
- **WHEN** 网络中断导致连接失效
- **THEN** 系统自动开始重连，显示重连状态，成功后恢复交互

#### Scenario: 达到最大重试次数

- **GIVEN** 自动重连已进行 10 次尝试均失败
- **WHEN** 第 10 次重试失败
- **THEN** 系统停止自动重连，显示失败状态和手动重试入口

#### Scenario: 认证失败不触发重连

- **WHEN** 连接因凭据错误导致 `AuthFailed`
- **THEN** 系统直接进入失败状态，SHALL NOT 触发自动重连

#### Scenario: 用户取消重连

- **GIVEN** 系统正在自动重连
- **WHEN** 用户点击取消
- **THEN** 系统停止重连，进入失败状态


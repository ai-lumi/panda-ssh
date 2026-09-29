## ADDED Requirements

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

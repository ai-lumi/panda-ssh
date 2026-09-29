## MODIFIED Requirements

### Requirement: 连接期策略

SSH 连接时 MUST 校验服务端密钥：Match 放行；Mismatch MUST 拒绝连接并报 `HostKeyMismatch`（携带已存储与呈现的密钥指纹）；Unknown 按调用方策略处理——`Reject` 拒绝并报 `UnknownHostKey`（MUST 携带服务端呈现的密钥与指纹，供 UI 展示确认），`AcceptAndStore` 写入 known_hosts 后放行。FFI 连接入口的默认策略 SHALL 为 `Reject`（`trust_on_first_use=false`）；UI 层以 `Reject` 探测未知主机、从 `UnknownHostKey` 取得呈现密钥与指纹向用户确认，确认信任后 MUST 存储该次探测呈现的密钥再重连。`AcceptAndStore` 仅允许调用方显式传 `trust_on_first_use=true` 时使用，SHALL NOT 作为默认行为。跳板链中的每跳 SHALL 使用相同的主机密钥校验机制，但各跳 MUST 以自身的 `(host, port)` 独立校验。跳板机的 Unknown 密钥 MUST 通过 `ProxyJumpUnknownHostKey` 错误返回并携带跳板位置信息，UI SHALL 逐跳展示指纹并要求用户确认后才能继续。

#### Scenario: 中间人防护

- **WHEN** 已存储主机的服务端密钥发生变化
- **THEN** 连接被拒绝且 known_hosts 不被覆盖，错误携带两个指纹

#### Scenario: 未知主机 Reject 携带指纹

- **WHEN** 以 Reject 策略连接未知主机
- **THEN** 返回 `UnknownHostKey` 错误且包含呈现密钥的指纹

#### Scenario: 确认后存储呈现密钥

- **GIVEN** UI 以 Reject 策略探测未知主机并取得呈现密钥与指纹
- **WHEN** 用户在确认对话框选择「信任」
- **THEN** 写入 known_hosts 的是该次探测呈现的密钥，重连后判定为 Match 直接放行

#### Scenario: 跳板机密钥未知时逐跳确认

- **WHEN** 跳板链中某一跳的密钥不在 known_hosts 中
- **THEN** UI 展示该跳板位置、主机标识与指纹，要求用户确认信任后才继续后续跳

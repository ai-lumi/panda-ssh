# host-key-verification Specification

## Purpose

SSH 服务端主机密钥校验（known_hosts）：防止中间人攻击，首次连接采用 TOFU（信任首次使用）语义，密钥变更 MUST 被拒绝。
## Requirements
### Requirement: known_hosts 存取

系统 SHALL 以简化的 OpenSSH known_hosts 格式持久化主机密钥：每行 `host keytype base64`；端口非 22 时主机名 MUST 使用 `[host]:port` 形式。同一主机 MUST 允许按 keytype 各存一条记录（如 ed25519 与 rsa 并存）；存储同主机同 keytype 的密钥 MUST 替换旧记录而非追加。写入 MUST 原子完成（临时文件 + rename）。注释、空行与损坏行 MUST 被跳过。重复存储同一主机同一 keytype 同一密钥 SHALL 去重。

#### Scenario: 存储后可读回

- **WHEN** 向 `KnownHosts` 存入某主机密钥后重新加载文件
- **THEN** 对该主机的 check 返回 Match

#### Scenario: 一机多密钥类型并存

- **WHEN** 同一主机分别存储 ed25519 与 rsa 两条密钥记录
- **THEN** 对两种 keytype 的 check 均返回 Match，互不干扰

#### Scenario: 同 keytype 密钥更新

- **WHEN** 对已存主机再次 store 同 keytype 但不同的密钥
- **THEN** 新密钥替换旧记录，之后 check 旧密钥返回 Mismatch、新密钥返回 Match

#### Scenario: 非标准端口

- **WHEN** 存储端口为 2222 的主机密钥
- **THEN** 文件中该行为 `[host]:2222` 形式且 check(host, 2222, …) 返回 Match

### Requirement: 校验判定

系统 SHALL 对 `(host, port, keytype, 公钥)` 给出三态判定：Match / Unknown / Mismatch。同主机同 keytype 有记录时比较密钥内容；主机有记录但无该 keytype 时 MUST 返回 Unknown（视为新密钥类型，走 TOFU 流程），SHALL NOT 误判为 Mismatch。Mismatch MUST 包含已存储的密钥信息以便上层展示。

#### Scenario: 未知主机

- **WHEN** check 一个从未存储过的主机
- **THEN** 返回 Unknown

#### Scenario: 已知主机的新密钥类型

- **WHEN** 主机已存 ed25519 记录，check 其 rsa 密钥
- **THEN** 返回 Unknown 而非 Mismatch

#### Scenario: 密钥变更

- **WHEN** check 一个已存储但同 keytype 公钥不同的主机
- **THEN** 返回 Mismatch 且携带已存储密钥

### Requirement: 连接期策略

SSH 连接时 MUST 校验服务端密钥：Match 放行；Mismatch MUST 拒绝连接并报 `HostKeyMismatch`（携带已存储与呈现的密钥指纹）；Unknown 按调用方策略处理——`Reject` 拒绝并报 `UnknownHostKey`（MUST 携带服务端呈现的密钥与指纹，供 UI 展示确认），`AcceptAndStore` 写入 known_hosts 后放行。FFI 连接入口的默认策略 SHALL 为 `Reject`（`trust_on_first_use=false`）；UI 层以 `Reject` 探测未知主机、从 `UnknownHostKey` 取得呈现密钥与指纹向用户确认，确认信任后 MUST 存储该次探测呈现的密钥再重连。`AcceptAndStore` 仅允许调用方显式传 `trust_on_first_use=true` 时使用，SHALL NOT 作为默认行为。

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

### Requirement: 密钥删除

系统 SHALL 支持删除指定主机（含端口）的全部密钥记录，用于用户确认后更新指纹或清除信任。

#### Scenario: 删除后回到未知

- **WHEN** 删除某主机的密钥记录后再 check
- **THEN** 返回 Unknown


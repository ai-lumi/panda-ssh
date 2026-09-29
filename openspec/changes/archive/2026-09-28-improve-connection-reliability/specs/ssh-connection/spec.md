## ADDED Requirements

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

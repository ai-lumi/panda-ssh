## ADDED Requirements

### Requirement: 缺失凭据错误的呈现

系统 MUST 在 UI 中保留缺失凭据错误与网络超时、认证失败和主机密钥错误的可区分性。通用连接失败页 SHALL 仅在实际连接错误时展示其对应原因，MUST NOT 将缺失凭据表述为网络超时。

#### Scenario: FFI 返回缺少密码

- **WHEN** SSH 连接入口返回可识别的缺少密码错误
- **THEN** UI 返回密码输入流程，而不是展示连接超时页

#### Scenario: 真实网络超时

- **WHEN** TCP 连接或 SSH 握手实际超时
- **THEN** UI 展示连接超时页，并提供重试与关闭标签操作

#### Scenario: 认证失败

- **WHEN** 用户提交的凭据被服务器拒绝
- **THEN** UI 展示认证失败信息，且不将其表述为缺失凭据或网络超时

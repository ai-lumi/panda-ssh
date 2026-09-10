## Purpose

连接前评估能力：在建立 SSH/SFTP 连接之前，系统评估主机的密钥状态和凭据可用性，返回前端应执行的动作（直接连接、确认未知密钥、处理密钥不匹配、输入密码或口令）。同时管理 TOFU（Trust On First Use）的并发序列化，确保同一主机的多个标签页只弹一次确认框。

## ADDED Requirements

### Requirement: 连接前评估 FFI

系统 SHALL 通过 FFI 暴露 `preconnect_evaluate(host_id)` 接口，综合主机密钥状态和凭据可用性返回 `PreconnectAction` 枚举：

- `Proceed`：密钥已知且凭据就绪，可直接连接
- `ConfirmTofu { presented_key }`：未知主机，需用户确认密钥指纹
- `KeyMismatch { stored_fingerprint, presented_fingerprint }`：密钥与已知记录不匹配
- `AskPassword`：需要用户输入密码
- `AskPassphrase`：需要用户输入私钥口令

评估 MUST 按以下顺序：先检查主机密钥状态，再检查凭据可用性。

#### Scenario: 已知主机且凭据就绪

- **GIVEN** 主机密钥已在 known_hosts 中，密码已保存
- **WHEN** 调用 `preconnect_evaluate(host_id)`
- **THEN** 返回 `Proceed`

#### Scenario: 未知主机

- **GIVEN** 主机密钥不在 known_hosts 中
- **WHEN** 调用 `preconnect_evaluate(host_id)`
- **THEN** 返回 `ConfirmTofu`，包含探测到的密钥指纹

#### Scenario: 密钥不匹配

- **GIVEN** 主机密钥与 known_hosts 中记录不一致
- **WHEN** 调用 `preconnect_evaluate(host_id)`
- **THEN** 返回 `KeyMismatch`，包含已存储和当前呈现的指纹

#### Scenario: 需输入密码

- **GIVEN** 主机密钥已知，密码认证但未保存密码
- **WHEN** 调用 `preconnect_evaluate(host_id)`
- **THEN** 返回 `AskPassword`

#### Scenario: 需输入口令

- **GIVEN** 主机密钥已知，公钥认证需要口令但未保存
- **WHEN** 调用 `preconnect_evaluate(host_id)`
- **THEN** 返回 `AskPassphrase`

### Requirement: TOFU 并发序列化

同一主机的多个标签页同时触发 TOFU 确认时，系统 SHALL 只执行一次密钥探测。第一个到达的请求 SHALL 触发探测并返回密钥信息；后续同主机请求 SHALL 挂起等待，直到第一个请求的用户确认结果（信任或取消）广播给所有等待者。

#### Scenario: 多标签同时连接未知主机

- **GIVEN** 3 个标签页同时连接同一未知主机
- **WHEN** 第一个请求触发 TOFU 探测
- **THEN** 后续 2 个请求挂起等待，不重复探测

#### Scenario: 用户确认信任

- **GIVEN** 3 个标签页等待 TOFU 确认
- **WHEN** 用户确认信任密钥
- **THEN** 3 个标签页均收到确认结果，继续连接

#### Scenario: 用户取消

- **GIVEN** 3 个标签页等待 TOFU 确认
- **WHEN** 用户取消
- **THEN** 3 个标签页均收到取消结果，连接终止

### Requirement: 错误分类 FFI

系统 SHALL 通过 FFI 暴露 `connection_failure_classify(error_code)` 接口，将连接错误码映射为结构化的 `ConnectionFailureRecord`，包含 `category`（Timeout / AuthFailed / MissingCredential / HostKeyMismatch / Other）、`title` 和 `detail`。前端 SHALL 根据 category 展示对应的错误 UI，MUST NOT 自行解析错误码。

#### Scenario: 超时错误

- **WHEN** 传入连接超时错误码
- **THEN** 返回 `category: Timeout`，title 为 "连接超时"

#### Scenario: 认证失败

- **WHEN** 传入认证失败错误码
- **THEN** 返回 `category: AuthFailed`，title 为 "认证失败"

#### Scenario: 未知错误

- **WHEN** 传入未分类的错误码
- **THEN** 返回 `category: Other`

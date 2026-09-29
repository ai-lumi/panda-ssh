## ADDED Requirements

### Requirement: 凭据解析 FFI

系统 SHALL 通过 FFI 暴露 `credential_resolve(host_id)` 接口，根据主机认证方式返回已解析的凭据状态。解析优先级：已保存凭据 > 需要手动输入。密码认证时，已保存密码可读则返回 `Available`，否则返回 `NeedsPassword`。公钥认证时，口令为可选——无口令或已保存口令可读均返回 `Available`，需要口令但不可读时返回 `NeedsPassphrase`。

#### Scenario: 密码认证已保存

- **GIVEN** 主机使用密码认证，密码已保存到凭据文件
- **WHEN** 调用 `credential_resolve(host_id)`
- **THEN** 返回 `Available { password: Some(...), passphrase: None }`

#### Scenario: 密码认证未保存

- **GIVEN** 主机使用密码认证，未保存密码
- **WHEN** 调用 `credential_resolve(host_id)`
- **THEN** 返回 `NeedsPassword`

#### Scenario: 公钥认证无需口令

- **GIVEN** 主机使用无口令私钥
- **WHEN** 调用 `credential_resolve(host_id)`
- **THEN** 返回 `Available { password: None, passphrase: None }`

#### Scenario: 公钥认证需口令但未保存

- **GIVEN** 主机使用带口令私钥，口令未保存
- **WHEN** 调用 `credential_resolve(host_id)`
- **THEN** 返回 `NeedsPassphrase`

#### Scenario: 公钥认证口令已保存

- **GIVEN** 主机使用带口令私钥，口令已保存
- **WHEN** 调用 `credential_resolve(host_id)`
- **THEN** 返回 `Available { password: None, passphrase: Some(...) }`

# auth Specification

## Purpose
认证能力：支持密码认证登录并可将密码保存到本地凭据文件；支持密钥认证登录并可从本地选择私钥文件；支持私钥口令并可选保存。主机配置只保存凭据引用，秘密不进入主机配置或日志。
## Requirements
### Requirement: 密码认证

系统 SHALL 支持使用用户名与密码认证登录服务器。

#### Scenario: 密码登录成功

- **GIVEN** 服务器接受密码认证
- **WHEN** 用户输入正确的用户名与密码
- **THEN** 系统成功建立会话

#### Scenario: 密码登录失败

- **WHEN** 用户输入错误密码
- **THEN** 系统提示认证失败，不建立会话

### Requirement: 保存密码

系统 SHALL 允许用户选择保存密码。保存的密码 MUST 存入本地凭据文件，主机配置文件只存引用，MUST NOT 存储密码明文。未设置密码保护密钥时，凭据文件中的密码以明文兼容格式保存；设置保护密钥后，凭据文件中的密码 MUST 处于受保护格式。

#### Scenario: 保存密码并自动填充

- **GIVEN** 用户在登录时开启「保存密码」
- **WHEN** 后续再次连接该主机
- **THEN** 系统从本地凭据文件读取密码并自动填充，无需手动输入

#### Scenario: 修改已保存密码

- **WHEN** 用户重新输入密码并保存
- **THEN** 本地凭据文件中的密码被原子覆盖更新

#### Scenario: 清除已保存密码

- **WHEN** 用户清除该主机的已保存密码
- **THEN** 本地凭据文件中的对应条目被删除，后续登录需手动输入

### Requirement: 手动输入密码的会话作用域

未保存的密码 SHALL 仅在单次会话（单个标签页）内有效，MUST NOT 在多个会话或标签页之间共享。

#### Scenario: 每个会话独立输入密码

- **GIVEN** 某主机未保存密码
- **WHEN** 用户为该主机打开多个标签页
- **THEN** 每个标签页各自提示输入密码，互不共享（用户可能以不同账号登录同一主机）

#### Scenario: 会话结束即丢弃

- **WHEN** 使用手动输入密码的标签页关闭
- **THEN** 该密码随会话销毁，不写入本地凭据文件、配置文件或任何共享存储

### Requirement: 密钥认证

系统 SHALL 支持使用本地私钥文件进行认证登录。

#### Scenario: 密钥登录成功

- **GIVEN** 服务器接受密钥认证
- **WHEN** 用户选择正确的本地私钥
- **THEN** 系统成功建立会话

### Requirement: 本地私钥选择

系统 SHALL 允许用户在 macOS 与 iPadOS 上通过文件选择器选择本地私钥文件，并将选择结果保存到主机配置。

#### Scenario: 在 macOS 选择私钥

- **GIVEN** 用户在 macOS 上编辑主机的认证方式
- **WHEN** 用户通过文件选择器选择私钥文件
- **THEN** 所选私钥路径保存到该主机配置

#### Scenario: 在 iPadOS 选择私钥

- **GIVEN** 用户在 iPadOS 上编辑主机的认证方式
- **WHEN** 用户通过文档选择器选择私钥文件
- **THEN** 所选私钥被复制到 App 容器可访问位置，路径保存到该主机配置

### Requirement: 私钥口令

对于带口令的私钥，系统 SHALL 提示输入口令，且允许将口令保存到本地凭据文件（可选）。凭据文件的保护状态 MUST 同时适用于密码与私钥口令。

#### Scenario: 输入口令完成登录

- **GIVEN** 所选私钥带口令保护
- **WHEN** 用户输入正确口令
- **THEN** 系统用该私钥成功认证

#### Scenario: 保存私钥口令

- **WHEN** 用户开启「保存口令」
- **THEN** 口令保存到本地凭据文件，后续登录自动填充，配置只存引用

### Requirement: 密钥材料保护

密码与私钥口令 MUST NOT 写入主机配置文件或日志。凭据仅可写入配置目录中的专用凭据文件；启用保护密钥时，该文件 MUST 使用经认证的加密格式。在 Unix 平台，Panda SSH 专属配置目录 MUST 仅允许其所有者访问，且凭据文件 MUST 仅允许其所有者读取和写入；系统管理的 iPadOS App Group 容器不属于 Panda SSH 专属配置目录，MUST NOT 修改其目录模式。这些限制 MUST 适用于新建文件及初始化或保存时发现的既有宽松权限。凭据原子写入 MUST 使用独占创建的临时文件，且 MUST NOT 跟随或覆盖既有临时文件的符号链接。非 Unix 平台 MUST 保持可用，且不得假定 Unix 文件权限 API 存在。

#### Scenario: 配置不含明文密钥

- **GIVEN** 用户已保存密码与口令
- **WHEN** 检查该主机配置
- **THEN** 配置文件中只存在凭据引用标识，不存在任何明文密码或口令

#### Scenario: Unix 平台首次保存凭据

- **GIVEN** Unix 平台上尚不存在凭据文件
- **WHEN** 用户保存密码或私钥口令
- **THEN** 系统创建仅所有者可读写的凭据文件
- **AND** 写入秘密的临时文件在包含秘密前即仅所有者可访问
- **AND** 临时文件不得复用或跟随已存在的同名路径

#### Scenario: Unix 平台修复既有宽松权限

- **GIVEN** Unix 平台上的 Panda SSH 配置目录或凭据文件具有允许其他用户访问的权限
- **WHEN** 系统初始化该配置目录或更新凭据
- **THEN** 系统将其收紧为仅所有者可访问的权限
- **AND** 凭据内容与既有加密保护状态保持不变

#### Scenario: 非 Unix 平台兼容

- **WHEN** 系统在不支持 Unix 文件权限的目标平台上构建或保存凭据
- **THEN** 系统保持可构建并完成既有凭据写入语义

#### Scenario: iPadOS App Group 容器

- **GIVEN** iPadOS 将系统管理的 App Group 容器作为配置根
- **WHEN** 系统初始化存储
- **THEN** 系统不得修改该容器的目录权限
- **AND** 系统仍对凭据文件应用可用的最小权限保护

### Requirement: 缺失凭据提示

系统 MUST 将缺少密码或私钥口令识别为可恢复的凭据输入状态，而非连接超时。终端与 SFTP 的行为 MUST 一致；用户输入的凭据仅在当前标签页会话中有效。

#### Scenario: 未保存密码时提示输入

- **GIVEN** 密码认证主机没有可读取的已保存密码
- **WHEN** 用户打开终端或 SFTP 标签
- **THEN** 系统显示密码输入窗口，且不显示连接超时页

#### Scenario: 缺失私钥口令时提示输入

- **GIVEN** 私钥认证需要口令且已保存口令不可读取，或私钥文件要求口令
- **WHEN** 用户打开终端或 SFTP 标签
- **THEN** 系统显示私钥口令输入窗口，且不将该情况显示为连接超时

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

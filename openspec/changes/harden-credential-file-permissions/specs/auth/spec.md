## MODIFIED Requirements

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

## MODIFIED Requirements

### Requirement: 凭据存储

密码与私钥口令 MUST 存入配置目录中的专用本地凭据文件，主机配置文件 SHALL 只存引用 key。系统 SHALL NOT 访问系统钥匙串。删除主机时 MUST 级联删除其关联的本地凭据条目。凭据写入、删除或保护状态迁移失败 MUST 以错误呈现给用户，并不得让主机配置留下指向不存在凭据的引用。

#### Scenario: 新增主机保存密码

- **WHEN** 用户在编辑表单中填写密码并保存
- **THEN** 密码进入本地凭据文件，hosts.toml 中仅出现引用 key

#### Scenario: 凭据写入失败

- **WHEN** 保存时本地凭据文件写入失败
- **THEN** 用户看到错误提示，主机配置不被保存

#### Scenario: 删除主机清理凭据

- **WHEN** 用户删除一台主机
- **THEN** 其密码与私钥口令凭据条目被一并删除

### Requirement: 本地存储位置

两平台的主机、分组、主机密钥和凭据文件 MUST 落在同一配置目录：macOS 为 `~/.panda-ssh/`，iPadOS 为 App Group 容器 `group.com.pandassh.shared`（不可用时回退 Documents），路径由 App 注入 Rust 核心。

#### Scenario: 容器不可用回退

- **WHEN** App Group 容器路径不可得（如未配置签名的开发构建）
- **THEN** 使用 Documents 目录，主机与凭据存储功能不受影响

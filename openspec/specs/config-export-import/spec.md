# config-export-import Specification

## Purpose

允许用户将本地主机配置、分组、代码片段及 known_hosts 打包导出为可移植文件，并在其他设备上导入，作为当前无 iCloud 同步时的跨设备迁移方案。

## Requirements

### Requirement: 导出范围

导出功能 SHALL 包含 hosts.toml、groups.toml、known_hosts 文件以及 snippets 目录下的全部内容。导出包 MUST 包含 manifest.json 记录格式版本与导出时间。导出 SHALL NOT 包含任何明文密码、私钥口令或私钥文件内容；钥匙串凭据仅以引用 key 形式存在于 hosts.toml 中。

#### Scenario: 正常导出

- **WHEN** 用户点击导出按钮并选择保存路径
- **THEN** 系统生成 `.pandassh` 文件，内部包含上述全部配置文件与 manifest

#### Scenario: 导出内容不含密钥材料

- **GIVEN** 某主机已保存密码到钥匙串
- **WHEN** 用户导出配置
- **THEN** 导出包内的 hosts.toml 仅含 `password_ref`，不含密码明文

### Requirement: 导入校验

导入功能 SHALL 读取 `.pandassh` 文件并校验 manifest 格式版本。版本不匹配或文件损坏时 MUST 向用户报错并中止导入。校验通过后，导入 SHALL 将配置写入本地存储目录，覆盖现有文件前先自动备份为 `hosts.toml.backup.<timestamp>` 等。

#### Scenario: 成功导入

- **WHEN** 用户选择有效的 `.pandassh` 文件导入
- **THEN** 本地配置文件被替换，主机列表刷新，旧文件被备份

#### Scenario: 导入版本不匹配

- **WHEN** 用户尝试导入格式版本高于当前支持的 `.pandassh` 文件
- **THEN** 系统提示「配置格式版本过高，请升级 App 后重试」，不修改本地文件

#### Scenario: 导入文件损坏

- **WHEN** 用户选择的 `.pandassh` 文件不是有效 ZIP 或缺少必要文件
- **THEN** 系统提示「配置文件损坏或格式不正确」，不修改本地文件

### Requirement: 导入后凭据处理

导入完成后，密码与私钥口令引用 key 会随 hosts.toml 恢复，但实际凭据仍存于原设备钥匙串。系统 SHALL 在导入后首次连接需要凭据的主机时，若钥匙串读取失败，提示用户手动输入。

#### Scenario: 导入后首次连接需重新录入密码

- **GIVEN** 导入的配置中包含 `password_ref`
- **WHEN** 用户首次连接该主机且钥匙串中无对应密码
- **THEN** 系统提示输入密码，不阻塞连接流程

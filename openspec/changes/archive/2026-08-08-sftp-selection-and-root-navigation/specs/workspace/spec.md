## MODIFIED Requirements

### Requirement: SFTP 文件列表目录进入

SFTP 双栏文件列表 SHALL 支持双击目录进入子目录；文件与目录 SHALL 均支持单击选中。

#### Scenario: 双击目录进入

- **GIVEN** 文件列表中显示目录 `ssh-test`
- **WHEN** 双击 `ssh-test`
- **THEN** 远程面板切换到 `ssh-test` 目录内容

#### Scenario: 单击选中目录

- **WHEN** 单击文件列表中的目录
- **THEN** 该目录高亮，但不进入

#### Scenario: 单击文件选中

- **GIVEN** 文件列表中显示文件 `upload-300m.bin`
- **WHEN** 单击 `upload-300m.bin`
- **THEN** 该行高亮，底部出现下载按钮

## ADDED Requirements

### Requirement: 返回顶级目录

SFTP 双栏顶部标题 SHALL 作为返回顶级目录的入口；点击后当前面板 SHALL 回到根目录。

#### Scenario: 点击标题返回顶级

- **GIVEN** 用户已深入 `ssh-test/sub/dir`
- **WHEN** 点击顶部「远程 — host.name」标题
- **THEN** 远程面板回到 `/share/homes/lwq/ssh-test`（该面板 root）

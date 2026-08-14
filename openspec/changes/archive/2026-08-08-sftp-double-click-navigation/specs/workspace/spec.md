## ADDED Requirements

### Requirement: SFTP 文件列表目录进入

SFTP 双栏文件列表 SHALL 支持双击目录进入子目录；单击 SHALL 用于选中。

#### Scenario: 双击目录进入

- **GIVEN** 文件列表中显示目录 `ssh-test`
- **WHEN** 双击 `ssh-test`
- **THEN** 远程面板切换到 `ssh-test` 目录内容

#### Scenario: 单击选中目录

- **WHEN** 单击文件列表中的目录
- **THEN** 该目录高亮，但不进入

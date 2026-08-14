## MODIFIED Requirements

### Requirement: 侧栏主机行单击选中

侧栏主机行 SHALL 支持单击选中；打开终端等操作通过右键/长按上下文菜单提供。

#### Scenario: 单击主机

- **WHEN** 单击侧栏中的主机行
- **THEN** 该行高亮，右侧显示主机详情

#### Scenario: 双击主机

- **GIVEN** 侧栏中的主机行
- **WHEN** 双击该行
- **THEN** 不触发任何操作；打开终端已移至右键/长按菜单

#### Scenario: 右键主机打开终端

- **GIVEN** 侧栏中显示主机 `web-prod`
- **WHEN** 右键 `web-prod` 并选择「打开终端」
- **THEN** 为该主机新建终端标签页

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

### Requirement: SFTP 文件行上下文菜单

SFTP 文件行 SHALL 支持右键（macOS）或长按（iPadOS）呼出上下文菜单，菜单项根据文件类型与所在面板动态变化。

#### Scenario: 右键远程文件

- **GIVEN** 远程面板中显示文件 `app.log`
- **WHEN** 右键 `app.log`
- **THEN** 弹出菜单，包含「下载」选项

#### Scenario: 右键本地目录

- **GIVEN** 本地面板中显示目录 `Documents`
- **WHEN** 右键 `Documents`
- **THEN** 弹出菜单，包含「进入」和「上传」选项

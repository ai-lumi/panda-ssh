## ADDED Requirements

### Requirement: SFTP 文件列表删除

SFTP 文件列表的每一行 SHALL 在右键（macOS）或长按（iPadOS）菜单中提供「删除」选项；删除前 SHALL 弹出二次确认框；确认后本地条目 SHALL 通过文件系统删除，远程条目 SHALL 通过 SFTP 删除。

#### Scenario: 删除本地文件

- **GIVEN** 本地文件列表中有一个文件 `report.pdf`
- **WHEN** 用户右键/长按该文件并选择「删除」，然后在确认框中确认
- **THEN** `report.pdf` 从本地文件系统删除，本地面板自动刷新

#### Scenario: 删除远程空目录

- **GIVEN** 远程文件列表中有一个空目录 `old-logs`
- **WHEN** 用户右键/长按该目录并选择「删除」，然后在确认框中确认
- **THEN** `old-logs` 从远端删除，远程面板自动刷新

#### Scenario: 取消删除

- **GIVEN** 用户右键/长按某个文件并选择「删除」
- **WHEN** 用户在确认框中选择「取消」
- **THEN** 该文件/目录未被删除

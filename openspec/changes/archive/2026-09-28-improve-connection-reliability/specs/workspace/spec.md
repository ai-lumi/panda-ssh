## ADDED Requirements

### Requirement: 工作区状态恢复

系统 SHALL 在启动时读取持久化的工作区状态，恢复标签页结构并自动发起连接。恢复 SHALL 受 `restore_workspace_on_launch` 设置控制。状态文件不存在或损坏时 SHALL 显示空态，MUST NOT 崩溃。

#### Scenario: 启动时恢复标签页

- **GIVEN** 上次关闭时有两个终端标签和一个 SFTP 标签
- **WHEN** App 启动且 `restore_workspace_on_launch` 为 `true`
- **THEN** 恢复三个标签页结构并自动发起连接

#### Scenario: 恢复设置关闭

- **GIVEN** `restore_workspace_on_launch` 为 `false`
- **WHEN** App 启动
- **THEN** 显示空态，不恢复标签页

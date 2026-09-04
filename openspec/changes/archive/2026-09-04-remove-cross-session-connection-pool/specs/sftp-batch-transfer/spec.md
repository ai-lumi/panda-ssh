## ADDED Requirements

### Requirement: 批量传输连接隔离

每个开始执行的批量传输任务 SHALL 建立并独占自己的 SSH Transport，可在该任务内部复用 SFTP Channel 扫描和传输其项目；任务完成、失败或取消后 SHALL 释放连接。不同批量任务及其来源 SFTP 标签 MUST NOT 共享 Socket。

#### Scenario: 两个批量任务连接同一主机

- **WHEN** 两个批量传输任务并发连接同一主机
- **THEN** 两个任务使用不同运行时连接标识，任一任务终止不影响另一个

#### Scenario: 批量任务取消

- **WHEN** 用户取消正在执行的批量任务
- **THEN** 该任务停止后释放自己的 SFTP Channel 与 SSH Transport


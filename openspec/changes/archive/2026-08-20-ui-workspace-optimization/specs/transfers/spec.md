## ADDED Requirements

### Requirement: 传输任务独立于源标签页

传输任务 SHALL 独立于其来源 SFTP 标签页的生命周期。关闭源 SFTP 标签页 MUST NOT 取消、暂停或标记失败该标签页创建的传输任务；任务 SHALL 继续按原有排队、并发、暂停与重试语义运行至终态。传输任务 SHALL 持有自身建立连接所需的凭据，不依赖源标签页会话持有的凭据。

#### Scenario: 关闭源标签页不取消任务

- **GIVEN** 一个由某 SFTP 标签页创建的 running 传输任务
- **WHEN** 用户关闭该 SFTP 标签页
- **THEN** 该任务状态保持 running，继续传输，MUST NOT 变为 cancelled 或 failed

#### Scenario: 源标签页关闭后排队任务仍被调度

- **GIVEN** 一个由某 SFTP 标签页创建的 queued 传输任务，并发槽位已满
- **WHEN** 用户关闭该 SFTP 标签页，随后一个运行中任务完成释放槽位
- **THEN** 该 queued 任务被正常调度执行

#### Scenario: 传输任务不依赖源标签页凭据

- **GIVEN** 一个由某 SFTP 标签页创建的传输任务正在运行
- **WHEN** 关闭该 SFTP 标签页（其会话凭据被清理）
- **THEN** 该传输任务继续正常运行，MUST NOT 因凭据缺失而失败

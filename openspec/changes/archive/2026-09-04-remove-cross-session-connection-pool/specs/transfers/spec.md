## MODIFIED Requirements

### Requirement: 传输任务独立于源标签页

传输任务 SHALL 独立于其来源 SFTP 标签页的生命周期。关闭源 SFTP 标签页 MUST NOT 取消、暂停或标记失败该标签页创建的传输任务；任务 SHALL 继续按原有排队、并发、暂停与重试语义运行至终态。每个开始运行的单文件传输任务 SHALL 建立并独占自己的 SSH Transport，持有建连所需凭据，并在完成、失败或取消后释放连接。

#### Scenario: 关闭源标签页不取消任务

- **GIVEN** 一个由某 SFTP 标签页创建的 running 传输任务
- **WHEN** 用户关闭该 SFTP 标签页
- **THEN** 该任务状态保持 running，继续使用自己的连接传输，MUST NOT 变为 cancelled 或 failed

#### Scenario: 源标签页关闭后排队任务仍被调度

- **GIVEN** 一个由某 SFTP 标签页创建的 queued 传输任务，并发槽位已满
- **WHEN** 用户关闭该 SFTP 标签页，随后一个运行中任务完成释放槽位
- **THEN** 该 queued 任务被正常调度，开始时建立自己的连接

#### Scenario: 传输任务不依赖源标签页凭据

- **GIVEN** 一个由某 SFTP 标签页创建的传输任务正在运行
- **WHEN** 关闭该 SFTP 标签页并清理其会话凭据
- **THEN** 该传输任务继续正常运行，MUST NOT 因凭据缺失而失败

#### Scenario: 传输进入终态释放连接

- **WHEN** 单文件传输完成、失败或被取消
- **THEN** 系统释放该任务拥有的 SFTP Channel 与 SSH Transport，MUST NOT 影响其他任务或标签


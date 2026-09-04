## MODIFIED Requirements

### Requirement: 标签页会话关联

每个终端或 SFTP 标签 SHALL 基于一台已保存的主机建立并独占自己的 SSH Transport。关闭标签页 SHALL 精确关闭该标签拥有的连接，MUST NOT 按主机断开其他标签或后台传输。后台传输 SHALL 独立拥有连接，不参与标签页连接的延迟释放协调。

#### Scenario: 标签页基于已保存主机打开

- **WHEN** 用户从主机列表选择一台主机打开标签页
- **THEN** 该标签页使用该主机的地址、端口、用户名与认证方式建立自己的会话

#### Scenario: 关闭终端标签精确断开

- **GIVEN** 某主机有两个终端标签
- **WHEN** 用户关闭其中一个标签
- **THEN** 系统立即关闭该标签拥有的连接，另一个标签的连接保持不变

#### Scenario: 关闭 SFTP 标签不影响传输

- **GIVEN** 某 SFTP 标签创建了仍在运行的后台传输
- **WHEN** 用户关闭该 SFTP 标签
- **THEN** 系统关闭该标签自己的 SFTP 连接，后台传输使用自己的连接继续运行

### Requirement: SFTP 标签页关闭与传输延续

关闭 SFTP 标签页 SHALL 精确关闭该标签拥有的 SFTP 会话，且 MUST NOT 取消或中断该主机正在进行或排队的传输任务。传输任务 SHALL 使用自身连接继续按原有并发、暂停、重试语义运行至终态，并在终态释放自己的连接。

#### Scenario: 关闭 SFTP 标签页后传输继续

- **GIVEN** 某 SFTP 标签页有 2 个 running 与 1 个 queued 传输任务
- **WHEN** 用户关闭该 SFTP 标签页
- **THEN** 标签页连接被释放，3 个任务均不被取消，queued 任务随后按并发限制被调度执行

#### Scenario: 全部传输完成后释放任务连接

- **GIVEN** SFTP 标签页已关闭，仍有 1 个 running 传输任务
- **WHEN** 该传输任务完成进入终态
- **THEN** 该任务拥有的 SSH 连接被自动释放

#### Scenario: 传输终态不影响其他标签

- **GIVEN** 某主机仍打开着一个终端标签且最后一个传输任务刚完成
- **WHEN** 传输任务进入终态并释放自己的连接
- **THEN** 终端标签拥有的连接保持不变


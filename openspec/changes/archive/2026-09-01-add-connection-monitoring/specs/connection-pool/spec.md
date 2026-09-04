## ADDED Requirements

### Requirement: 连接生命周期遥测

连接池 SHALL 为每条新建的传输/SSH 连接分配稳定的运行时连接标识，并在连接复用、检测失效、显式断开及最终释放时维护可查询的生命周期状态。连接池 MUST 以实际 Socket I/O、SSH keepalive 与通道打开结果更新状态，MUST NOT 通过另建连接伪造健康状态。连接池移除或判定失效的连接 MUST 不再被报告为健康的活动连接。

#### Scenario: 失效连接状态同步
- **GIVEN** 缓存中的 SSH 连接在复用检测时开通道失败
- **WHEN** 连接池移除该缓存条目
- **THEN** 后续遥测快照将该连接标记为不可用或不再列为活动连接，且 MUST NOT 将其继续报告为健康

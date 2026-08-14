# transfers Specification (delta)

## Requirement: 传输任务暂停与继续

非终态任务 SHALL 支持用户暂停与继续。暂停 SHALL 保留已传输字节数；继续 SHALL 从暂停点恢复传输。运行中任务暂停时 SHALL 保持对并发槽位的占用；排队中任务暂停时 SHALL 不提前占用并发槽位。

#### Scenario: 暂停运行中任务

- **GIVEN** 一个正在传输的大文件任务
- **WHEN** 用户点击「暂停」
- **THEN** 当前缓冲块完成后任务状态变为 `paused`，已传输字节数停止增长，该任务继续占用一个并发槽位

#### Scenario: 继续已暂停任务

- **GIVEN** 一个处于 `paused` 状态的任务
- **WHEN** 用户点击「继续」
- **THEN** 任务状态恢复为 `running`，已传输字节数继续增长

#### Scenario: 暂停排队任务

- **GIVEN** 并发上限为 3 且已有 3 个任务在传输，第 4 个任务处于 `queued`
- **WHEN** 用户对第 4 个任务点击「暂停」
- **THEN** 其状态变为 `paused`，且不会触发它去竞争并发许可证

#### Scenario: 取消暂停中任务

- **GIVEN** 一个处于 `paused` 状态的任务
- **WHEN** 用户点击「取消」
- **THEN** 任务变为 `cancelled`，释放并发槽位

#### Scenario: 重试失败任务不保留暂停

- **GIVEN** 一个失败或已取消的任务曾被暂停过
- **WHEN** 用户点击「重试」
- **THEN** 任务以 `queued` 状态重新调度，不再处于暂停

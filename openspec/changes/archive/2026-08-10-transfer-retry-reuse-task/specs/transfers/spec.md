# transfers Specification (delta)

## Requirement: 失败重试

失败或已取消任务 SHALL 允许用户重试，重试 SHALL 复用原任务 id 并重新执行，SHALL NOT 在任务列表中创建新任务条目。

#### Scenario: 重试失败任务

- **GIVEN** 一个失败的上传任务，id 为 `T1`
- **WHEN** 用户点击「重试」
- **THEN** 同一任务 `T1` 的状态重置为排队并重新调度，任务列表中不新增其他任务

#### Scenario: 重试非终态任务

- **GIVEN** 一个处于排队或传输中的任务
- **WHEN** 调用重试
- **THEN** 操作被拒绝，任务状态保持不变

## ADDED Requirements

### Requirement: 传输任务状态机

单文件传输任务 SHALL 在成功获取并发许可证后才进入 `Running` 状态；等待许可证期间 SHALL 保持 `Queued` 状态。

#### Scenario: 超出并发上限的任务排队

- **GIVEN** 并发上限为 3，已存在 3 个运行中任务
- **WHEN** 添加第 4 个上传任务
- **THEN** 该任务状态为 `Queued`，前 3 个任务之一完成后它才变为 `Running`

#### Scenario: 取消排队任务

- **GIVEN** 一个状态为 `Queued` 的任务
- **WHEN** 调用取消
- **THEN** 任务立即变为 `Cancelled`，不占用许可证

## ADDED Requirements

### Requirement: 速度指标由后端计算

传输速度、总速度和预估剩余时间 SHALL 由 Rust 后端在 `TransferStatusRecord` 中直接提供。后端 SHALL 使用 2 秒滑动窗口计算实时速率，使用任务启动至今的总时间计算平均速率，使用剩余字节量除以实时速率计算 ETA。前端 MUST NOT 自行计算速度指标，SHALL 直接使用后端返回的 `speed`、`total_speed`、`eta_seconds` 字段。

#### Scenario: 后端提供速度字段

- **GIVEN** 一个运行中的传输任务
- **WHEN** 前端调用 `transfer_status(task_id)`
- **THEN** 返回的 Record 包含 `speed`、`total_speed`、`eta_seconds`，前端直接展示

#### Scenario: 前端不做速度计算

- **WHEN** 前端渲染传输面板
- **THEN** 前端 MUST NOT 创建速度计算器实例或维护采样数据，SHALL 直接使用 Record 中的字段

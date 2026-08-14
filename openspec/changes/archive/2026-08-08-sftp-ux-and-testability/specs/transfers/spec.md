## ADDED Requirements

### Requirement: 传输轮询按需启动

`TransferStore` SHALL 仅在存在 running 或 queued 任务时启动轮询 Timer；任务全部完成后 SHALL 立即停止轮询。进度刷新 SHALL 仅在任务列表发生变化时触发视图更新。

#### Scenario: 无传输任务时空转

- **GIVEN** 没有进行中的传输任务
- **WHEN** App 空转
- **THEN** 不启动 100ms 轮询 Timer，不持续触发 SwiftUI 重绘

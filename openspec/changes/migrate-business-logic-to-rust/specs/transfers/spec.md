## ADDED Requirements

### Requirement: 传输任务包含速度指标

`transfer_status()` 与 `transfer_list()` 返回的 `TransferStatusRecord` SHALL 包含 `speed`（实时速率 bytes/s，滑动窗口 2 秒）、`total_speed`（从开始到当前的平均速率）和 `eta_seconds`（预估剩余秒数，无法计算时为 nil）。速度计算 MUST 在 Rust 侧完成，前端 MUST NOT 自行计算。暂停后恢复时滑动窗口 SHALL 重置。

#### Scenario: 运行中任务返回速度

- **GIVEN** 一个正在传输的任务，已传输 1MB，最近 2 秒内传输了 500KB
- **WHEN** 调用 `transfer_status(task_id)`
- **THEN** `speed` 约为 250KB/s，`total_speed` 为总传输量/总时间，`eta_seconds` 为剩余量/speed

#### Scenario: 暂停后恢复重置窗口

- **GIVEN** 任务暂停前 speed 为 100KB/s
- **WHEN** 任务恢复传输
- **THEN** 滑动窗口重置，speed 从恢复后的第一个采样开始计算

#### Scenario: 零字节任务

- **GIVEN** 一个 size 为 0 的任务
- **WHEN** 调用 `transfer_status(task_id)`
- **THEN** `speed` 为 0，`eta_seconds` 为 nil

### Requirement: 传输任务分组聚合 FFI

系统 SHALL 通过 FFI 暴露 `transfer_groups()` 接口，返回按 `group_id` 聚合的任务组列表。每个 `TransferGroupRecord` SHALL 包含 `group_id`、`name`、`total_count`、`completed_count`、`total_bytes`、`transferred_bytes` 和聚合 `status`。聚合状态优先级：running > queued > paused > failed > done > cancelled。无分组任务 MUST NOT 出现在结果中。

#### Scenario: 混合任务分组

- **GIVEN** 3 个上传任务属于组 "docs"（2 done, 1 running），2 个下载任务无分组
- **WHEN** 调用 `transfer_groups()`
- **THEN** 返回 1 个组 "docs"，`total_count: 3`，`completed_count: 2`，`status: running`

#### Scenario: 全部完成的组

- **GIVEN** 组 "images" 的 5 个任务全部 done
- **WHEN** 调用 `transfer_groups()`
- **THEN** 该组 `status` 为 `done`

#### Scenario: 无分组任务

- **GIVEN** 所有任务均无 `group_id`
- **WHEN** 调用 `transfer_groups()`
- **THEN** 返回空列表

### Requirement: 传输状态变更推送

系统 SHALL 支持通过 `transfer_register_observer()` 注册回调观察者。传输任务状态变更（创建、进度更新、暂停、恢复、完成、失败、取消）时 SHALL 主动调用所有已注册观察者的 `on_transfer_changed()` 方法。观察者 MUST 为 `Send + Sync`。取消注册后 SHALL 不再收到通知。

#### Scenario: 注册后收到通知

- **GIVEN** 已注册一个观察者
- **WHEN** 传输任务状态变更
- **THEN** 观察者的 `on_transfer_changed()` 被调用

#### Scenario: 多个观察者

- **GIVEN** 注册了 2 个观察者
- **WHEN** 传输任务完成
- **THEN** 两个观察者的回调均被调用

#### Scenario: 取消注册

- **GIVEN** 已注册一个观察者并取消注册
- **WHEN** 传输任务状态变更
- **THEN** 该观察者的回调不再被调用

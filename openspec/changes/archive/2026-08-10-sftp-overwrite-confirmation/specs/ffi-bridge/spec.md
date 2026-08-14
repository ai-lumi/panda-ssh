## ADDED Requirements

### Requirement: 覆盖确认请求可跨 FFI 边界传递

FFI 层 SHALL 将 `panda-core` 的覆盖确认请求以结构化类型暴露给 Swift，使 UI 可展示源文件与目标文件的大小、最后修改时间，并回传用户决策。

#### Scenario: Swift 收到结构化覆盖确认

- **WHEN** Swift 调用 `sftp_upload` / `sftp_download` 且目标文件已存在
- **THEN** FFI 返回一个可区分的错误/结果变体，携带 `source_size`、`source_mtime`、`target_size`、`target_mtime` 字段，而不是仅返回字符串错误

#### Scenario: 用户决策可回传至 Rust

- **GIVEN** Swift 已收到覆盖确认请求
- **WHEN** 用户在弹窗中选择「覆盖」或「跳过」
- **THEN** Swift 通过 FFI 提供的机制（如同步弹窗返回布尔值，或拆分为 `sftp_upload_with_overwrite` 接口）将决策回传给 Rust 并继续执行

### Requirement: 不破坏现有 FFI 调用语义

新增覆盖确认流程 SHALL 保持现有 FFI 函数对调用方的同步外观；异步逻辑仍 SHALL 在全局 tokio runtime 上 `block_on` 执行。覆盖确认弹窗由 Swift UI 层负责，Rust 侧 SHALL 在需要确认时通过错误/结果变体告知 UI，而不是自行阻塞等待用户输入。

#### Scenario: 未触发覆盖时行为不变

- **WHEN** 目标文件不存在，调用 `sftp_upload` / `sftp_download`
- **THEN** 行为与变更前完全一致，直接完成传输

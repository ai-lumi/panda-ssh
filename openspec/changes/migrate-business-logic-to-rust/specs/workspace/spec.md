## ADDED Requirements

### Requirement: 标签页生命周期由后端管理

标签页的创建、关闭、列表查询 SHALL 由 Rust 后端统一管理。`workspace_tab_list()` 返回的标签页 SHALL 包含已去重的标题（同主机多标签追加序号后缀如 `"server(2)"`）和连接状态。`workspace_host_connection_status()` SHALL 按优先级（connected > connecting > failed > inactive）聚合该主机下所有标签页的连接状态。

#### Scenario: 同主机多标签标题去重

- **GIVEN** 3 个标签页连接到主机 "server"
- **WHEN** 调用 `workspace_tab_list()`
- **THEN** 标题分别为 `"server"`、`"server(2)"`、`"server(3)"`

#### Scenario: 关闭标签页后标题重新编号

- **GIVEN** 标签页 "server"、"server(2)"、"server(3)"
- **WHEN** 关闭 "server(2)"
- **THEN** 剩余标签页标题为 `"server"`、`"server(2)"`

#### Scenario: 主机连接状态聚合

- **GIVEN** 主机 H 有 2 个标签页，一个 connected，一个 failed
- **WHEN** 调用 `workspace_host_connection_status(H)`
- **THEN** 返回 `Connected`（connected 优先级最高）

#### Scenario: 无标签页时状态为 Inactive

- **GIVEN** 主机 H 无任何标签页
- **WHEN** 调用 `workspace_host_connection_status(H)`
- **THEN** 返回 `Inactive`

### Requirement: 标签页关闭确认由后端管理

关闭含有已连接终端的标签页 SHALL 触发后端关闭确认流程。`workspace_close_tab()` 在存在活跃连接时 SHALL 设置 `pending_close_confirmation`，前端查询后展示确认对话框。`workspace_confirm_close()` 执行关闭，`workspace_cancel_close()` 取消。批量关闭（`workspace_close_other_tabs()`、`workspace_close_all_tabs()`）SHALL 聚合需确认的终端数量。

#### Scenario: 关闭已连接终端标签页

- **GIVEN** 标签页有已连接的终端会话
- **WHEN** 调用 `workspace_close_tab(tab_id)`
- **THEN** 标签页不立即关闭，`pending_close_confirmation` 返回该标签页信息

#### Scenario: 确认关闭

- **WHEN** 用户确认并调用 `workspace_confirm_close()`
- **THEN** 标签页关闭，连接释放

#### Scenario: 批量关闭聚合确认

- **GIVEN** 5 个标签页中 3 个有已连接终端
- **WHEN** 调用 `workspace_close_all_tabs()`
- **THEN** `pending_close_confirmation` 显示需确认 3 个终端

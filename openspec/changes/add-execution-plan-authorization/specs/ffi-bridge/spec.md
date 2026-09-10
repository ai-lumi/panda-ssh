# ffi-bridge 变更规格（执行计划 FFI 契约）

## ADDED Requirements

### Requirement: 执行计划 FFI 契约

FFI 层 SHALL 同步导出执行计划管理接口：创建计划（草稿）、查询计划与计划列表、提交审核、批准、拒绝、撤销、暂停、启动执行（经统一执行网关校验后返回运行标识）、查询运行状态（含九态与逐目标状态）、请求停止。导出类型 SHALL 仅使用简单值类型（Record/Enum/Optional/String/整数），计划记录 MUST 携带内容哈希与生命周期状态；启动执行的凭据材料 SHALL 仅作为瞬态调用参数传入，MUST NOT 由 FFI 落盘或写入计划。异步工作 SHALL 在既有全局 tokio runtime 上执行，导出函数对调用方保持同步外观；阻塞型调用由调用方在非主线程执行。错误 SHALL 以结构化 `PandaError` 新变体暴露（至少：未知计划、计划状态不允许该操作、授权失效、计划引用内容已变化、主机密钥未验证、网关拒绝、审计不可用），SHALL NOT 压平为字符串。

#### Scenario: 审核 UI 走 FFI 完成批准

- **GIVEN** Swift 审核界面展示了一条待审核计划
- **WHEN** 用户点击确认
- **THEN** Swift 调用批准接口，返回的批准记录绑定该计划内容哈希，后续启动执行以同一哈希通过网关校验

#### Scenario: 失效计划执行返回可区分错误

- **GIVEN** 一条计划因引用片段内容变化而失效
- **WHEN** Swift 调用启动执行
- **THEN** 返回结构化的授权失效错误（携带原因），而非通用字符串错误

#### Scenario: 启动执行不阻塞主线程

- **WHEN** Swift 在非主线程调用启动执行，网关校验通过后远端执行持续进行
- **THEN** 调用立即返回运行标识，状态经查询接口渐进获取；主线程不被占用

#### Scenario: 未初始化调用被拒绝

- **WHEN** 未调用 `init_store` 直接调用计划管理接口
- **THEN** 返回 `NotInitialized` 错误

#### Scenario: 手动路径行为不变

- **WHEN** Swift 调用 `test_connection`、`shell_open` 或 SFTP 接口
- **THEN** 行为与现有规格一致，不要求计划或授权参数，不出现逐键审批

## ADDED Requirements

### Requirement: 终端连接隔离

每个终端标签 SHALL 独占一条 SSH Transport 和一个 shell Channel。远端 shell 正常结束、本地关闭或连接失败时，系统 SHALL 只终止该标签拥有的 Transport，并向该标签报告可区分的最终状态。

#### Scenario: 远端 exit 正常结束

- **GIVEN** 同一主机有两个可交互终端标签
- **WHEN** 用户在其中一个终端输入 `exit` 且远端 shell 正常结束
- **THEN** 该标签显示已关闭并释放自己的 Socket，另一个标签继续可交互

#### Scenario: Socket 异常关闭

- **WHEN** 某终端的 Socket 发生 EOF、读写错误或 keepalive 连续失败
- **THEN** 该终端立即显示不可交互和失败摘要，并提供重试操作

### Requirement: 终端单飞重试

终端标签的重试流程 SHALL 保证同一标签同一重试代次最多存在一个在途建连请求。重复的 UI 生命周期触发或回调 MUST NOT 为同一代次再次打开 Transport。

#### Scenario: 点击一次重试

- **GIVEN** 终端已进入关闭或失败状态
- **WHEN** 用户点击一次重试且视图同时因状态变化重新执行生命周期任务
- **THEN** 仅一个建连请求生效并生成一个新 Socket


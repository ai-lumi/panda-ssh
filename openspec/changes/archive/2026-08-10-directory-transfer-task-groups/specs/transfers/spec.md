## ADDED Requirements

### Requirement: 任务组元数据

传输任务 SHALL 支持可选的 `groupID` 与 `groupName`。同一目录下的所有文件任务 SHALL 共享同一个 `groupID`。

#### Scenario: 目录上传生成任务组

- **GIVEN** 本地目录 `backup` 包含 `a.sql` 和 `logs/error.log`
- **WHEN** 选中 `backup` 并上传
- **THEN** 上传队列中出现两个任务：`backup/a.sql` 与 `backup/logs/error.log`，二者具有相同的 `groupID`，组名为 `backup`

#### Scenario: 独立文件无任务组

- **GIVEN** 用户多选两个普通文件 `x.txt` 与 `y.txt`
- **WHEN** 点击上传
- **THEN** 队列中出现两个任务，它们的 `groupID` 均为 nil

### Requirement: 任务组批量操作

`TransferStore` SHALL 提供 `cancelGroup` 与 `retryGroup`：前者取消组内所有非终态任务，后者重试组内所有失败任务。

#### Scenario: 批量停止目录传输

- **GIVEN** 目录 `project` 的任务组中有 5 个文件正在排队或运行
- **WHEN** 用户点击该组「停止全部」
- **THEN** 这 5 个任务全部变为 `cancelled`

#### Scenario: 批量重试目录传输

- **GIVEN** 目录 `project` 的任务组中有 3 个任务失败，2 个已完成
- **WHEN** 用户点击该组「重试失败」
- **THEN** 3 个失败任务重新进入 `queued`，2 个已完成任务保持不变

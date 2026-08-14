## ADDED Requirements

### Requirement: 传输面板按任务组展示

传输面板 SHALL 将具有相同 `groupID` 的任务聚合在同一任务组下展示，无 `groupID` 的任务作为独立任务展示。每个任务组 SHALL 显示组名、组内进度汇总与批量操作按钮，组内每个文件任务 SHALL 显示独立进度与操作。

#### Scenario: 目录传输任务组展示

- **GIVEN** 目录 `backup` 的上传生成了 3 个文件任务
- **WHEN** 打开传输面板
- **THEN** 面板中显示一个名为 `backup` 的组，组内列出 3 个文件任务，每个任务有自己的进度条和取消/重试按钮，组头有「停止全部」和「重试失败」按钮

#### Scenario: 独立任务与任务组共存

- **GIVEN** 队列中有一个目录任务组 `backup` 和一个独立文件任务 `report.pdf`
- **WHEN** 打开传输面板
- **THEN** `backup` 组与 `report.pdf` 独立任务均可见，互不影响

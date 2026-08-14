## ADDED Requirements

### Requirement: 侧栏主机行单击选中

侧栏主机行 SHALL 支持单击选中；双击 SHALL 打开终端；两者不得互相阻塞。

#### Scenario: 单击主机

- **WHEN** 单击侧栏中的主机行
- **THEN** 该行高亮，右侧显示主机详情

#### Scenario: 双击主机

- **WHEN** 双击侧栏中的主机行
- **THEN** 为该主机新建终端标签页

### Requirement: 面包屑不重复 rootTitle

SFTP 双栏顶部的面包屑 SHALL 不重复显示已作为栏头标签出现的 rootTitle。

#### Scenario: 在远程根目录

- **GIVEN** 远程 rootTitle 为「远程 — ssh-test」
- **WHEN** 当前路径等于根目录
- **THEN** 面包屑区域为空，仅左侧栏头显示「远程 — ssh-test」

# Delta Spec: workspace

## ADDED Requirements

### Requirement: macOS 侧栏顶部主机管理按钮

macOS 主窗口 SHALL 在左侧栏顶部的标题栏区域（与窗口红绿灯同一水平线、位于侧栏列范围内）放置「添加主机」与「新建分组」按钮。这两个按钮 SHALL NOT 出现在窗口顶部标题栏的导航区（detail 内容区一侧）。按钮 SHALL 随侧栏显隐：侧栏隐藏时按钮不可见。该布局 SHALL 仅适用于 macOS 端，iPadOS 端不出现这两个按钮、布局与入口保持不变。

#### Scenario: 侧栏顶部展示主机管理按钮

- **WHEN** 用户在 macOS 打开主窗口且左侧栏可见
- **THEN** 左侧栏顶部的标题栏区域可见「添加主机」「新建分组」按钮，且窗口顶部标题栏的导航区不出现这两个按钮

#### Scenario: 点击添加主机

- **GIVEN** macOS 主窗口左侧栏可见
- **WHEN** 用户点击侧栏顶部的「添加主机」按钮
- **THEN** 弹出添加主机编辑页

#### Scenario: 点击新建分组

- **GIVEN** macOS 主窗口左侧栏可见
- **WHEN** 用户点击侧栏顶部的「新建分组」按钮
- **THEN** 弹出新建分组输入框

#### Scenario: 侧栏隐藏时按钮不可见

- **WHEN** 用户在 macOS 隐藏左侧栏
- **THEN** 「添加主机」「新建分组」按钮随侧栏一起隐藏，不再出现在窗口任何位置

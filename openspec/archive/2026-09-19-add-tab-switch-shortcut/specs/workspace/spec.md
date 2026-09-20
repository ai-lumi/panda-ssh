## ADDED Requirements

### Requirement: 键盘快捷键切换页签

当焦点位于 SSH 终端或 SFTP 窗口内容区域时，系统 SHALL 支持使用键盘快捷键在页签之间切换。`Ctrl+Tab` SHALL 从左往右依次切换到下一个页签；`Ctrl+Shift+Tab` SHALL 从右往左依次切换到上一个页签。页签切换 SHALL 为循环模式：在最后一个页签按 `Ctrl+Tab` SHALL 切换到第一个页签，在第一个页签按 `Ctrl+Shift+Tab` SHALL 切换到最后一个页签。快捷键 SHALL 仅在页签内容区域（SSH 终端或 SFTP 文件浏览器）获得焦点时生效，MUST NOT 在侧栏、页签栏或其他 UI 区域获得焦点时触发。

#### Scenario: 从左往右切换页签

- **GIVEN** 工作区有三个页签 A、B、C，当前活动页签为 A
- **WHEN** 焦点在 A 的内容区域且用户按下 `Ctrl+Tab`
- **THEN** 活动页签切换为 B

#### Scenario: 从右往左切换页签

- **GIVEN** 工作区有三个页签 A、B、C，当前活动页签为 C
- **WHEN** 焦点在 C 的内容区域且用户按下 `Ctrl+Shift+Tab`
- **THEN** 活动页签切换为 B

#### Scenario: 循环切换到第一个页签

- **GIVEN** 工作区有三个页签 A、B、C，当前活动页签为 C（最后一个）
- **WHEN** 焦点在 C 的内容区域且用户按下 `Ctrl+Tab`
- **THEN** 活动页签循环切换为 A（第一个）

#### Scenario: 循环切换到最后一个页签

- **GIVEN** 工作区有三个页签 A、B、C，当前活动页签为 A（第一个）
- **WHEN** 焦点在 A 的内容区域且用户按下 `Ctrl+Shift+Tab`
- **THEN** 活动页签循环切换为 C（最后一个）

#### Scenario: 单个页签时无切换

- **GIVEN** 工作区只有一个页签
- **WHEN** 用户按下 `Ctrl+Tab` 或 `Ctrl+Shift+Tab`
- **THEN** 当前页签保持活动状态，无变化

#### Scenario: 焦点在侧栏时不触发

- **GIVEN** 工作区有多个页签
- **WHEN** 焦点在侧栏主机列表且用户按下 `Ctrl+Tab`
- **THEN** 页签不发生切换，快捷键由侧栏处理或忽略

#### Scenario: 终端内容区域焦点生效

- **GIVEN** 一个已连接的 SSH 终端页签
- **WHEN** 终端视图获得键盘焦点且用户按下 `Ctrl+Tab`
- **THEN** 活动页签切换到下一个页签

#### Scenario: SFTP 内容区域焦点生效

- **GIVEN** 一个已打开的 SFTP 页签
- **WHEN** SFTP 文件列表视图获得键盘焦点且用户按下 `Ctrl+Tab`
- **THEN** 活动页签切换到下一个页签

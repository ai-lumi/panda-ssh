## MODIFIED Requirements

### Requirement: 标签页右键上下文菜单

标签栏中的每个标签页 SHALL 支持右键（macOS）或长按（iPadOS）呼出上下文菜单，菜单至少包含「重连」「关闭其他标签页」「关闭全部标签页」三项。「重连」SHALL 仅对终端标签页生效，对 SFTP 标签页 SHALL 为禁用态或不展示。「关闭其他标签页」SHALL 关闭除当前右键标签页外的全部标签页。「关闭全部标签页」SHALL 关闭工作区中的全部标签页。批量关闭时，每个被关闭的终端标签页 SHALL 走与单标签关闭一致的连接释放与（终端）二次确认流程。

在 macOS 上，鼠标悬停标签页按钮时 SHALL 额外展示该标签页的内存占用估算 Tooltip；iPadOS 上长按标签页按钮时 SHALL 在上下文菜单旁展示内存估算。内存估算的展示 SHALL 与现有上下文菜单共存，互不干扰。

#### Scenario: 右键终端标签重连

- **GIVEN** 一个已连接的终端标签页
- **WHEN** 右键该标签并选择「重连」
- **THEN** 该终端标签断开当前 shell 会话并重新建立连接

#### Scenario: 关闭其他标签页

- **GIVEN** 工作区有标签页 A、B、C，用户右键 B
- **WHEN** 选择「关闭其他标签页」
- **THEN** A 与 C 被关闭，B 保留为活动标签

#### Scenario: 关闭全部标签页

- **GIVEN** 工作区有标签页 A、B、C
- **WHEN** 用户在任一标签页右键并选择「关闭全部标签页」
- **THEN** A、B、C 全部被关闭，工作区回到无活动标签的空态

#### Scenario: SFTP 标签页重连不可用

- **GIVEN** 一个 SFTP 标签页
- **WHEN** 右键该标签页
- **THEN** 「重连」项为禁用态或不展示

#### Scenario: macOS 悬停显示内存 Tooltip 并仍可右键

- **GIVEN** macOS 上存在一个终端标签页
- **WHEN** 用户将鼠标悬停在该标签页按钮上
- **THEN** 弹出内存估算 Tooltip；鼠标继续右键时，上下文菜单正常展示

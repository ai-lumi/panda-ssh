### Requirement: 标签页右键上下文菜单

标签栏中的每个标签页 SHALL 支持右键（macOS）或长按（iPadOS）呼出上下文菜单。macOS 端 SHALL 使用 `NSMenu` 直接构建，每个菜单项 SHALL 携带 SF Symbol 图标，分组边界 SHALL 使用 `NSMenu.separatorItem` 分隔。iPadOS 端 SHALL 使用 SwiftUI `.contextMenu`，条目集与 macOS 端对齐。

菜单条目 SHALL 包含以下内容，按分隔线分为两组：

**第一组 — 会话操作（仅终端标签展示）：**

| 条目 | 图标 |
|------|------|
| 重连 | `arrow.clockwise` |

**第二组 — 关闭操作（所有标签展示）：**

| 条目 | 图标 |
|------|------|
| 关闭标签页 | `xmark` |
| 关闭其他标签页 | `xmark.circle` |
| 关闭全部标签页 | `xmark.circle.fill` |

「重连」SHALL 仅对终端标签页展示，对 SFTP 标签页 SHALL 不展示（而非禁用态）。「关闭其他标签页」SHALL 关闭除当前右键标签页外的全部标签页。「关闭全部标签页」SHALL 关闭工作区中的全部标签页。批量关闭时，每个被关闭的终端标签页 SHALL 走与单标签关闭一致的连接释放与（终端）二次确认流程。

#### Scenario: 右键终端标签重连

- **GIVEN** 一个已连接的终端标签页
- **WHEN** 右键该标签并选择「重连」
- **THEN** 该终端标签断开当前 shell 会话并重新建立连接

#### Scenario: 右键终端标签菜单结构

- **GIVEN** 一个终端标签页
- **WHEN** 右键该标签
- **THEN** 菜单展示「重连」（带 `arrow.clockwise` 图标），分隔线后展示「关闭标签页」「关闭其他标签页」「关闭全部标签页」

#### Scenario: 右键 SFTP 标签菜单结构

- **GIVEN** 一个 SFTP 标签页
- **WHEN** 右键该标签
- **THEN** 菜单不展示「重连」，仅展示「关闭标签页」「关闭其他标签页」「关闭全部标签页」，带对应图标

#### Scenario: 关闭其他标签页

- **GIVEN** 工作区有标签页 A、B、C，用户右键 B
- **WHEN** 选择「关闭其他标签页」
- **THEN** A 与 C 被关闭，B 保留为活动标签

#### Scenario: 关闭全部标签页

- **GIVEN** 工作区有标签页 A、B、C
- **WHEN** 用户在任一标签页右键并选择「关闭全部标签页」
- **THEN** A、B、C 全部被关闭，工作区回到无活动标签的空态

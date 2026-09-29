## ADDED Requirements

### Requirement: SFTP 视图选择使用 SwiftUI 原生机制

SFTP 文件面板的选择状态 SHALL 由 SwiftUI `List(selection:)` 原生绑定管理，MUST NOT 在 SftpSessionStore 中维护独立的选择属性。选择状态 SHALL 是纯视图层状态，MUST NOT 跨视图生命周期持久化或被其他 View 观察。

#### Scenario: 本地栏原生选择

- **WHEN** 用户在本地文件面板点击一个条目
- **THEN** SwiftUI `List(selection: $localSelection)` 更新选中集合

#### Scenario: 远程栏原生选择

- **WHEN** 用户在远程文件面板点击一个条目
- **THEN** SwiftUI `List(selection: $remoteSelection)` 更新选中集合

### Requirement: 多选与范围选择

SFTP 视图 SHALL 支持 SwiftUI 原生的 Command 追加/移除选择，以及 Shift 范围选择（需手动维护 anchor）。MUST NOT 自定义实现多选状态开关。

#### Scenario: Command 点击追加选择

- **GIVEN** 本地栏已有条目 A 被选中
- **WHEN** 用户 Command 点击条目 B
- **THEN** 选择集包含 A 和 B

#### Scenario: Command 点击移除选择

- **GIVEN** 本地栏已有条目 A 和 B 被选中
- **WHEN** 用户 Command 点击条目 A
- **THEN** 选择集仅包含 B

#### Scenario: Shift 点击范围选择

- **GIVEN** 本地栏条目顺序为 A、B、C、D
- **WHEN** 用户点击 B（设置 anchor），然后 Shift 点击 D
- **THEN** 选择集包含 B、C、D

### Requirement: 右键菜单操作与选择同步

右键菜单展示时，被点击的条目 SHALL 在选择集中；若不在，MUST 自动选中后再展示菜单。菜单操作 SHALL 作用于当前选择集，MUST NOT 被菜单点击隐式修改选择集。

#### Scenario: 右键点击未选中条目

- **GIVEN** 本地栏条目 A、B、C，选择集仅包含 A
- **WHEN** 用户右键点击 B
- **THEN** 选择集变为仅包含 B，菜单操作作用于 B

#### Scenario: 右键点击已选中条目

- **GIVEN** 本地栏选择集包含 A 和 B
- **WHEN** 用户右键点击 B
- **THEN** 选择集保持 A 和 B，菜单操作作用于 A 和 B

### Requirement: macOS 拖拽框选

macOS 目标 SHALL 支持按住鼠标拖拽覆盖多个条目进行批量选择。iPadOS 目标 MUST NOT 支持拖拽框选。

#### Scenario: 拖拽覆盖多条目

- **GIVEN** 本地栏条目 A、B、C、D
- **WHEN** 用户从 A 位置拖拽到 C 位置
- **THEN** 选择集包含 A、B、C

#### Scenario: iPadOS 不支持拖拽框选

- **WHEN** iPadOS 用户尝试拖拽覆盖多个条目
- **THEN** 不触发批量选择，保持原选择状态

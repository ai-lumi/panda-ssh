## Purpose

定义 SFTP 文件栏（本地/远程）中通过 Shift+单击、⌘+Shift+单击进行范围选择的交互规则，包括 anchor 的设立、范围计算、与现有多选模式的协作，以及目录切换后 anchor 的生命周期。

## ADDED Requirements

### Requirement: Shift+单击在文件栏中执行范围选择

系统 SHALL 支持用户在 SFTP 本地或远程文件栏中按住 Shift 键并单击某条目时，选中从当前 anchor 到被单击条目之间的所有条目（含两端）。该操作 SHALL 替换当前栏的已有选中集合。范围选择完成后，系统 SHALL 自动启用该栏的多选模式，以便用户通过复选框确认选中状态。anchor SHALL 保持不变，仍为最近一次非 Shift 点击所设立的条目。

#### Scenario: 正序 Shift+范围选择

- **GIVEN** 本地栏显示条目 `[a.txt, b.txt, c.txt, d.txt]`，用户此前单击 `b.txt` 使其成为 anchor
- **WHEN** 用户按住 Shift 并单击 `d.txt`
- **THEN** 本地栏选中集合变为 `{b.txt, c.txt, d.txt}`，多选模式开启，`b.txt` 仍为 anchor

#### Scenario: 逆序 Shift+范围选择

- **GIVEN** 本地栏显示条目 `[a.txt, b.txt, c.txt, d.txt]`，用户此前单击 `d.txt` 使其成为 anchor
- **WHEN** 用户按住 Shift 并单击 `b.txt`
- **THEN** 本地栏选中集合变为 `{b.txt, c.txt, d.txt}`，多选模式开启，`d.txt` 仍为 anchor

#### Scenario: Shift+单击无 anchor 时不产生范围选择

- **GIVEN** 本地栏无 anchor（例如刚进入目录）
- **WHEN** 用户按住 Shift 并单击 `c.txt`
- **THEN** 系统仅将 `c.txt` 设为单选，并将其设为 anchor，不选中范围

### Requirement: ⌘+Shift+单击将范围追加到当前选中集合

系统 SHALL 支持用户在按住 ⌘ 和 Shift 的同时单击某条目时，把从 anchor 到被单击条目之间的所有条目追加到当前选中集合，而不清除已有选中项。若该范围内部分条目已被选中，则保持选中；未被选中者加入集合。操作完成后，系统 SHALL 保持该栏的多选模式开启。

#### Scenario: 追加范围到已有选中集合

- **GIVEN** 本地栏显示条目 `[a.txt, b.txt, c.txt, d.txt, e.txt]`，anchor 为 `a.txt`，当前选中集合为 `{a.txt, d.txt}`
- **WHEN** 用户按住 ⌘+Shift 并单击 `c.txt`
- **THEN** 本地栏选中集合变为 `{a.txt, b.txt, c.txt, d.txt}`，多选模式保持开启

### Requirement: 普通单击与 ⌘+单击更新 anchor

系统 SHALL 在文件栏发生以下操作时更新 anchor：
- 无修饰键单击某条目：anchor 设为该条目。
- ⌘+单击某条目：anchor 设为该条目，无论该条目是被加入还是移出选中集合。
- 拖拽框选结束后：anchor 设为框选范围内最后与用户交互相关的条目；若框选为空则清除 anchor。
- 切换目录、返回上级、跳转到其他路径后：清除 anchor。

#### Scenario: ⌘+单击后使用 Shift+范围选择

- **GIVEN** 本地栏显示条目 `[a.txt, b.txt, c.txt]`，用户单击 `a.txt` 后按住 ⌘ 单击 `c.txt`
- **THEN** anchor 设为 `c.txt`，选中集合为 `{a.txt, c.txt}`
- **WHEN** 用户按住 Shift 并单击 `b.txt`
- **THEN** 选中集合变为 `{b.txt, c.txt}`，`c.txt` 仍为 anchor

#### Scenario: 进入目录后 anchor 被清除

- **GIVEN** 用户在本地栏选中 `a.txt` 作为 anchor
- **WHEN** 用户双击进入目录 `Documents`
- **THEN** 本地栏 anchor 被清除，选中集合清空

### Requirement: 范围选择仅在同一目录内有效

系统 SHALL 仅在 anchor 与目标条目同处于当前 `FilePaneNavigator.entries` 列表时执行范围选择。若 anchor 条目已不在当前目录列表中（例如被删除、被过滤、或用户已离开该目录），Shift+单击 SHALL 回退为单选行为，并将目标条目设为新的 anchor。

#### Scenario: anchor 条目已不在当前列表

- **GIVEN** 用户曾在根目录将 `a.txt` 设为 anchor，随后进入子目录
- **WHEN** 用户在子目录中按住 Shift 并单击 `readme.md`
- **THEN** 系统仅选中 `readme.md` 并将其设为 anchor，不尝试跨目录范围选择

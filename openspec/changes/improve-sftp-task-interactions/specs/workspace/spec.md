## MODIFIED Requirements

### Requirement: SFTP 文件行上下文菜单

SFTP 文件行 SHALL 支持右键（macOS）或长按（iPadOS）呼出原生上下文菜单，菜单项根据文件类型、所在面板与当前选中状态动态变化。单选模式下菜单作用于被右键的条目；多选模式下右键选中集合内任一条目时，菜单 SHALL 作用于整个选中集合，且右键未选中条目 SHALL 先将该条目置为唯一选中再展示菜单。菜单样式 SHALL 遵循系统原生风格，MUST NOT 使用自定义弹层。

#### Scenario: 右键远程文件

- **GIVEN** 远程面板中显示文件 `app.log`
- **WHEN** 右键 `app.log`
- **THEN** 弹出菜单，包含「下载」选项

#### Scenario: 右键本地目录

- **GIVEN** 本地面板中显示目录 `Documents`
- **WHEN** 右键 `Documents`
- **THEN** 弹出菜单，包含「进入」和「上传」选项

#### Scenario: 多选模式下右键集合内条目

- **GIVEN** 本地面板已多选 `a.txt` 与 `b.txt`
- **WHEN** 右键 `a.txt`
- **THEN** 弹出菜单，其中「上传」作用于 `a.txt` 与 `b.txt` 整个选中集合

#### Scenario: 多选模式下右键未选中条目

- **GIVEN** 本地面板已多选 `a.txt`，未选中 `c.txt`
- **WHEN** 右键 `c.txt`
- **THEN** 选中集合先变为仅 `c.txt`，再弹出作用于 `c.txt` 的菜单

#### Scenario: 单选时右键其他条目
- **GIVEN** 已选中 a，b 未选中
- **WHEN** 用户右键 b
- **THEN** 菜单展示前选中集合变为仅 b，菜单作用于 b

#### Scenario: 多选时右键集合外条目
- **GIVEN** 已选中 a 和 b，c 未选中
- **WHEN** 用户右键 c
- **THEN** 菜单展示前取消 a 和 b 的选中，仅选中 c，菜单作用于 c

#### Scenario: 取消菜单保留选区
- **WHEN** 右键未选中条目后关闭菜单而不执行操作
- **THEN** 新选区保持，不恢复旧选区；不执行文件操作

# groups Specification

## Purpose
服务器分组能力让用户以树形结构组织服务器主机：支持任意层级子分组，主机可归属某个分组或根级，从而在服务器数量增长时保持列表可维护。
## Requirements
### Requirement: 分组与子分组

系统 SHALL 支持服务器分组，并允许分组内嵌套子分组（任意层级，树形结构）。

#### Scenario: 创建子分组

- **GIVEN** 存在一个分组「开发」
- **WHEN** 用户在「开发」下创建子分组「北京」和「上海」
- **THEN** 「开发」下按树形展示「北京」与「上海」两个子分组

#### Scenario: 移动子分组

- **WHEN** 用户将子分组「北京」移动到另一个分组「华东」下
- **THEN** 「北京」及其全部子分组随父级变化而整体移动

### Requirement: 分组管理

系统 SHALL 允许用户创建、重命名、移动与删除分组。

#### Scenario: 重命名分组

- **WHEN** 用户将分组「生产」重命名为「生产环境」
- **THEN** 该分组及其下所有主机与子分组归属不变，名称更新

#### Scenario: 删除分组

- **WHEN** 用户删除一个分组
- **THEN** 该分组从树中移除，其下子分组一并删除

### Requirement: 主机归属分组

每台主机 SHALL 可选归属一个分组，且用户 SHALL 能改变主机的归属分组。

#### Scenario: 将主机移入分组

- **GIVEN** 存在一台主机与一个分组
- **WHEN** 用户将主机移动到该分组
- **THEN** 该主机在分组内展示，并持久化其归属

#### Scenario: 将主机移回根级

- **GIVEN** 一台主机属于某分组
- **WHEN** 用户将其移动到根级
- **THEN** 该主机不再属于任何分组，并在根级展示

#### Scenario: 新建主机默认归属选中分组

- **GIVEN** 用户在侧栏选中了某分组
- **WHEN** 用户点击「添加主机」
- **THEN** 新建表单的「所属分组」默认选中该分组，保存后主机归入该分组

#### Scenario: 新建主机默认归属选中主机所在分组

- **GIVEN** 用户在侧栏选中了一台属于某分组的主机（未选中分组）
- **WHEN** 用户点击「添加主机」
- **THEN** 新建表单的「所属分组」默认选中该主机所在分组

### Requirement: 删除分组不丢失主机

删除分组时 SHALL 将其下所有主机（含子分组内主机）移回根级，MUST NOT 删除或隐藏这些主机。

#### Scenario: 删除含主机的分组

- **GIVEN** 分组「测试」下有一台主机 A 和一个含主机 B 的子分组
- **WHEN** 用户删除「测试」
- **THEN** 主机 A 与主机 B 都出现在根级，且主机配置完整保留

### Requirement: 分组持久化

分组及其嵌套结构 SHALL 持久化，App 重启后保持一致。

#### Scenario: 重启后分组仍在

- **GIVEN** 用户已创建多级分组并将主机移入
- **WHEN** 用户退出并重新打开 App
- **THEN** 分组树结构与主机归属完整恢复

### Requirement: 分组路径查询 FFI

系统 SHALL 通过 FFI 暴露 `group_path(group_id)` 接口，返回指定分组的完整层级路径字符串（如 `"生产 / 华东"`）。路径分隔符 MUST 为 `" / "`。`group_id` 为 nil 或不存在时 SHALL 返回 `"根级"`。路径计算 MUST 防御脏数据中的环（visited 集合），环检测后截断路径。

#### Scenario: 多级分组路径

- **GIVEN** 分组层级为「生产」→「华东」→「上海」
- **WHEN** 调用 `group_path("上海-id")`
- **THEN** 返回 `"生产 / 华东 / 上海"`

#### Scenario: 根级分组

- **GIVEN** 分组「开发」无父级
- **WHEN** 调用 `group_path("开发-id")`
- **THEN** 返回 `"开发"`

#### Scenario: 空或未知 ID

- **WHEN** 调用 `group_path(nil)` 或 `group_path("不存在的id")`
- **THEN** 返回 `"根级"`

### Requirement: 侧栏树组装 FFI

系统 SHALL 通过 FFI 暴露 `sidebar_tree()` 接口，返回已组装好的树形结构 `Vec<SidebarNodeRecord>`。树 MUST 按以下规则组装：根级分组在前（保持存储顺序）、根级主机在后；分组内先子分组后成员主机。孤儿主机（`groupID` 指向不存在的分组）SHALL 降级到根级。每个节点 MUST 包含 `id`（带 `group-` 或 `host-` 前缀）、`is_group`、`name`，以及可选的 `host`/`group` 完整记录和 `children`。

#### Scenario: 标准树组装

- **GIVEN** 两个根级分组 A、B，A 下有子分组 C 和主机 h1，B 下有主机 h2，根级有主机 h3
- **WHEN** 调用 `sidebar_tree()`
- **THEN** 返回 `[A(children: [C, h1]), B(children: [h2]), h3]`

#### Scenario: 孤儿主机降级

- **GIVEN** 主机 h1 的 `groupID` 指向不存在的分组 "ghost"
- **WHEN** 调用 `sidebar_tree()`
- **THEN** h1 出现在根级，与分组同级

#### Scenario: 空数据

- **GIVEN** 无主机无分组
- **WHEN** 调用 `sidebar_tree()`
- **THEN** 返回空列表


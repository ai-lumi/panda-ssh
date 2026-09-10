## ADDED Requirements

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

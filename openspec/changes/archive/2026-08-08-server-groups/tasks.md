## 1. 分组数据模型与持久化（Rust 核心）

- [x] 1.1 先写测试：`Group` 增删改 + `parent_id` 嵌套序列化/反序列化 round-trip。
- [x] 1.2 实现 `Group` 模型与 `GroupStore`（`groups.toml` 原子写，temp + rename）。
- [x] 1.3 先写测试：树展开（任意层级）、悬空 `parent_id` 降级为根级、深度上限保护。
- [x] 1.4 实现树展开与递归安全逻辑。
- [x] 1.5 先写测试：删除分组时其下所有主机（含子分组）`group_id` 被清空，主机数据保留。
- [x] 1.6 实现删除分组级联清理。
- [x] 1.7 修改 `HostConfig` 增加 `group_id`，兼容旧文件缺失该字段（默认根级）；先写测试。

## 2. FFI 与 Swift UI

- [x] 2.1 先写测试：FFI 分组 CRUD、主机归属读写、删除分组级联在 store 层的行为。
- [x] 2.2 新增 FFI 导出：`list_groups`/`save_group`/`delete_group`/`move_group`，`HostConfigRecord` 增加 `group_id`。
- [x] 2.3 Swift 侧分组树侧栏（`OutlineGroup`，可折叠）+ 根级主机；主机可移入/移出分组。
- [x] 2.4 分组增删改 UI 与错误提示。

## 3. 验证

- [x] 3.1 `cargo test` 全绿。
- [x] 3.2 macOS 构建通过；iPadOS 侧栏紧凑布局下分组树可用。
- [x] 3.3 手工验证：创建多级子分组、移动主机、删除含主机分组后主机回到根级。

## 4. 质量门禁

- [x] 4.1 测试用例门禁：本变更所有功能点必须覆盖三类用例——正常流程、意外操作、边界条件。
- [x] 4.2 覆盖率门禁：运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 并通过。

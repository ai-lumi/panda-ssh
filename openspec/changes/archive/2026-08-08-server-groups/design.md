## Context

当前 `HostConfig`（`crates/panda-core/src/config.rs`）只有 `id/name/host/port/username/auth/notes`，无任何分组概念；存储为单一 `hosts.toml`，原子写（临时文件 + rename）。分组需要新增数据结构与持久化位置，同时保持与现有 `TomlConfigStore` 的原子写风格一致，并兼容 iCloud KV 同步（README 规划，尚未实现）。

## Goals / Non-Goals

**Goals:**

- 分组支持任意层级子分组（树），主机可归属任意分组或根级。
- 分组与主机数据都落盘在 `init_store` 注入的配置目录内，跨设备同步路径一致。
- 保持配置原子写（temp + rename）与现有风格一致。
- macOS/iPadOS 双端同一分组树 UI。

**Non-Goals:**

- 分组拖拽排序与自定义顺序持久化。
- 基于分组的批量操作（批量连接/命令）。
- 分组级权限与协作。
- 实现 iCloud KV 同步本身（沿用现有同步框架，属独立事项）。

## Decisions

### 数据模型：独立 `groups.toml` + 主机引用 `group_id`

新增 `Group` 结构：`id`、`name`、`parent_id: Option<String>`、`order`（本次仅用于稳定展示，默认按插入序）。分组树由 `parent_id` 指向关系隐式构成，支持任意深度，递归展开。

分组单独存于配置目录下的 `groups.toml`，与 `hosts.toml` 并列；`HostConfig` 增加 `group_id: Option<String>`。拆分文件的理由：分组是独立聚合根，避免修改主机时反复整体重写分组树；两者都由 `init_store` 注入的同一目录承载，便于后续统一同步。

### 树操作与递归安全

遍历/序列化分组树使用显式栈或限制深度（如 64 层），防止异常数据导致栈溢出；`parent_id` 引用悬空时按根级处理并在 UI 端降级展示。删除分组时，先将被删分组下所有主机（含子分组主机）的 `group_id` 置空，再删除分组记录，保证不丢失主机。

### FFI 与 UI

FFI 新增同步导出：`list_groups`、`save_group`、`delete_group`、`move_group`、以及主机 CRUD 中携带/更新 `group_id`。Swift 侧用 `OutlineGroup`（macOS/iPadOS 均支持）渲染分组树，侧栏为「分组（可折叠）+ 根级主机」，主区为选中分组的主机列表。

## Risks / Trade-offs

- [分组与主机分开存储可能暂时不一致（如主机引用已删分组）] → 读取时以分组为准做降级（悬空引用按根级），删除分组时先清引用，写操作顺序保证一致性。
- [树深度无上限导致递归风险] → 递归展开 + 显式深度上限保护。
- [`groups.toml` 与 `hosts.toml` 无法原子联动] → 单次用户操作（如删除分组）在同一 FFI 调用内完成两次写入，任一步失败则整体回滚到调用前状态。

## Migration Plan

已有 `hosts.toml` 不含分组字段：读取时 `group_id` 缺失即为根级，无需迁移。首次写入分组时创建 `groups.toml`。

## Open Questions

- 分组是否需要在 iPadOS 侧栏常驻还是可折叠抽屉？先按「侧栏可折叠」实现，后续按体验反馈调整。

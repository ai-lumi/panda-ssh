## Why

当前页签栏仅支持按打开顺序线性排列，用户无法自定义页签顺序或将相关页签归组。当打开大量页签（如同时管理多台服务器的终端和 SFTP）时，难以快速定位目标页签。需要支持拖拽排序和手动分组来提升多页签场景的操作效率。

## What Changes

- 新增页签拖拽排序：用户可拖动页签按钮改变其在页签栏中的位置，排序仅在当前会话内保持。
- 新增手动分组：用户可通过右键菜单将页签分配到命名分组，或创建/删除分组。
- 分组视觉区分：同一分组的页签在视觉上聚集，分组之间以分隔线或背景色区分。
- 排序与分组状态仅保存在 Swift 侧 `WorkspaceStore`，不持久化到 Rust，重启后恢复默认。
- 拖拽排序不改变 Rust 侧页签列表顺序，仅在 Swift 侧维护显示顺序映射。

## Non-goals

- 不做排序/分组的持久化（重启后不保留）。
- 不做自动分组（如按主机自动归类）。
- 不修改 Rust 侧工作区管理器的页签顺序逻辑。
- 不支持跨窗口拖拽页签。

## Capabilities

### New Capabilities
- `tab-drag-sort`: 页签拖拽排序能力，包括拖拽手势处理、视觉反馈、排序状态管理。
- `tab-groups`: 手动分组能力，包括分组创建/删除/重命名、页签分配到分组、分组视觉呈现。

### Modified Capabilities
- `workspace`: 页签显示顺序从 Rust 侧固定顺序改为 Swift 侧可重排；页签栏需感知分组信息。

## Impact

- **Swift 侧**：
  - `WorkspaceStore` 新增排序映射和分组数据结构。
  - `UnifiedWorkspaceTabStrip` 新增拖拽手势和分组视觉渲染。
  - 右键菜单新增分组操作项。
- **Rust 侧**：无变更，排序和分组完全在 Swift 侧管理。
- **macOS / iPadOS 双端**：
  - macOS：使用 `onDrag`/`onDrop` 或 `DragGesture` 实现拖拽。
  - iPadOS：同样支持拖拽排序，使用 SwiftUI 原生拖拽 API。
  - 右键菜单在 macOS 使用 `NSMenu`，iPadOS 使用 `.contextMenu`，分组操作需双端适配。
- **测试**：需为排序逻辑、分组操作编写单元测试。

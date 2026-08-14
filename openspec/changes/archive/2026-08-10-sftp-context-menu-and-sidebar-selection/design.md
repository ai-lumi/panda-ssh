## Context

侧栏使用 `List(selection:) + OutlineGroup` 渲染分组与主机。`HostRowView` 上的双击打开终端手势使用 `simultaneousGesture(TapGesture(count: 2))`，但仍与 List 单击选中冲突，导致主机无法被选中。SFTP 文件行此前只有双击进入目录，缺少右键/长按菜单。

## Goals / Non-Goals

**Goals:**

- 侧栏主机单击可稳定选中。
- SFTP 文件/目录支持右键/长按上下文菜单。

**Non-Goals:**

- 不引入 AppKit 原生组件。
- 不实现文件删除、重命名等操作。

## Decisions

### 侧栏主机选中

移除 `HostRowView` 的双击手势，改为显式 `simultaneousGesture(TapGesture(count: 1))` 调用 `model.selectHost(host.id)`。打开终端等操作仍通过 contextMenu 提供。

### SFTP 上下文菜单

在 `fileRow` 上附加 `.contextMenu { fileContextMenu(...) }`：
- 目录显示「进入」。
- 本地 pane 显示「上传」。
- 远程 pane 显示「下载」。

菜单触发前先把当前项设为选中，确保操作对象正确。

## Risks / Trade-offs

- 双击打开终端被移除；用户可通过右键/长按菜单或底部工具栏打开终端。如需恢复双击，可后续单独评估。

## Migration Plan

无数据迁移。

## Open Questions

None.

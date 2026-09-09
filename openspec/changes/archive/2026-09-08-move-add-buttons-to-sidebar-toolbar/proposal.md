# Proposal: move-add-buttons-to-sidebar-toolbar

## Why

macOS 主窗口的「添加主机」「新建分组」按钮当前挂在窗口顶部标题栏的导航区（`ToolbarItem(placement: .navigation)`，红绿灯右侧的窗口级工具栏）。这两个按钮操作的对象是侧栏里的主机/分组树，放在窗口级标题栏语义割裂、且与内容区工具带视觉混杂。用户希望它们出现在左侧栏顶部的标题栏区域，与所操作的内容同列。

## What Changes

- 将「添加主机」「新建分组」两个按钮从 `WorkspaceView` 的窗口级 `.toolbar`（`.navigation` 位置）移到 `SidebarView` 的侧栏列工具栏：按钮显示在左侧栏顶部的标题栏区域（与红绿灯同一水平线、侧栏列范围内）。
- 按钮随侧栏显隐：侧栏隐藏时按钮不可见（弹层状态 `AppModel.sidebarSheet` 与 sheet 挂载位置不变，右键菜单等其他入口不受影响）。
- 按钮动作不变：分别弹出添加主机编辑页与新建分组输入框。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `workspace`: 新增 macOS 侧栏顶部主机管理按钮的位置与显隐要求（按钮位于左侧栏顶部标题栏区域、随侧栏显隐、仅 macOS 端）。

## Impact

- **代码**：`apple/PandaSSH/Workspace/WorkspaceView.swift`（移除窗口级 toolbar 中的两个按钮）、`apple/PandaSSH/SidebarView.swift`（macOS 侧栏列新增 toolbar 按钮）。
- **平台影响**：仅 macOS 端布局变化；iPadOS 端无这两个按钮、布局与入口完全不变。
- **行为权衡**：侧栏隐藏时按钮不可见，用户需先展开侧栏（或走右键菜单）才能添加入口；sheet 仍挂在根视图，弹层机制不受影响。

## Non-goals

- 不改变 iPadOS 端的任何布局与入口。
- 不改变按钮点击后的弹层内容、默认分组推断逻辑与 sheet 挂载机制。
- 不调整内容区页签栏、侧栏切换按钮等其他窗口 chrome。

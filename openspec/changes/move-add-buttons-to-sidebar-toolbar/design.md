# Design: move-add-buttons-to-sidebar-toolbar

## Context

当前实现（`WorkspaceView.swift` macOS body）：两个按钮以 `ToolbarItem(placement: .navigation)` 挂在 `NavigationSplitView` 根视图的 `.toolbar` 上，渲染在窗口顶部标题栏的导航区（红绿灯右侧、跨列的窗口级工具栏）。弹层状态 `AppModel.sidebarSheet` 与 sheet 挂载（`HostListView` 根视图）保持不变，可直接复用。

项目历史上该区域经历过 `NSTitlebarAccessoryViewController` → 侧栏内嵌 `HStack` → 窗口 toolbar 多轮迭代（见 `native-swiftui-chrome`、`fix-macos-sidebar-top-alignment` 变更），本次只调整按钮归属列，不引入 AppKit。

## Goals / Non-Goals

**Goals:**
- 按钮出现在左侧栏顶部的标题栏区域（侧栏列范围内、与红绿灯同一水平线）。
- 纯 SwiftUI 实现，不新增 AppKit 依赖，不改变 iPadOS。

**Non-Goals:**
- 不调整内容区页签栏、侧栏切换按钮、窗口标题栏样式。
- 不改变弹层机制与按钮动作。

## Decisions

1. **把 `.toolbar` 挂到侧栏列内容上，而不是窗口根视图**
   - `NavigationSplitView` 中，声明在 sidebar 列视图内的 `.toolbar` 项会被系统放置到统一标题栏的侧栏区域（侧栏列正上方），这正是「左侧栏顶部的标题栏位置」；侧栏隐藏时这些项随之隐藏，符合规格。
   - 实现：将两个 `ToolbarItem` 从 `WorkspaceView.macOSBody` 根视图的 `.toolbar` 移到 `SidebarView`（macOS 条件编译块内），动作仍写 `model.sidebarSheet`。
   - **Alternative**：侧栏内嵌 `HStack`/`safeAreaInset` 自建工具条（`native-swiftui-chrome` 曾用）。否决：与系统标题栏高度对齐需要手工 padding 避让红绿灯，历史上因此反复返工；`.toolbar` 由系统负责对齐与拖拽区，最省事。
   - **Alternative**：保留在窗口根视图 toolbar 但换 placement。否决：`.navigation` 之外的 placement 都归 detail 列或右上角，无法落入侧栏列范围。

2. **sheet 挂载点不动**
   - sheet 挂在 `HostListView` 根视图，侧栏隐藏时右键菜单等其他入口仍能触发弹层；本次只移动按钮，无需改动。

## Risks / Trade-offs

- **[Risk] 侧栏隐藏时按钮不可见，用户找不到添加入口** → 接受：规格明确「随侧栏显隐」；主机/分组右键菜单仍提供「在此分组添加主机…」「新建子分组」入口。
- **[Risk] 侧栏最小宽度（220pt）下两个图标按钮 + 系统侧栏切换按钮可能拥挤** → 按钮用 `.labelStyle(.iconOnly)`，占用极小；若真机出现 `>>` 折叠，再按 `ui-workspace-optimization` 的思路收紧最小宽度处理（历史变更已验证 220pt 足够）。

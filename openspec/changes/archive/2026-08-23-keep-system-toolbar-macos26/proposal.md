## Why

macOS 26（Tahoe）改变了 `NavigationSplitView` 侧栏的系统行为：窗口**没有可见工具栏**时，系统强制把侧栏浮动面板压在标题栏下方 32pt，侧栏无法融入标题栏；隐藏侧栏时系统还会重建 `NSToolbar` 并注入自带的侧栏切换按钮。现行 workspace spec「主窗口工具栏精简」要求「不显示系统工具栏」，这一要求在 macOS 26 上与「侧栏融入标题栏」不可兼得（经探针实测验证：融合由工具栏项驱动，移除工具栏或剔除工具栏项都会失去融合）。

当前实现已选择「保留系统工具栏换取融合」并验收通过，需要把 spec 更新为与实际行为一致，避免后续按旧 spec 回退。

## What Changes

- 修改「主窗口工具栏精简」需求：macOS 主窗口**保留**系统工具栏（不再要求移除），以获得侧栏标题栏融合。
- 明确接受的行为：
  - 侧栏面板融入标题栏，侧栏顶条按钮（添加主机/新建分组/隐藏侧栏）与红绿灯同一水平线；
  - detail 区顶部存在系统工具栏绘制带（系统行为，无法消除也不自绘遮盖）；
  - 侧栏隐藏时，系统侧栏切换按钮出现在标题栏红绿灯右侧，由系统负责唤回侧栏；不再自绘「显示侧栏」按钮；
  - 主窗口右上角仍不得出现 `>>` 溢出按钮（沿用既有要求，由侧栏最小宽度保证）。
- iPadOS 行为不变。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `workspace`: 修改「主窗口工具栏精简」需求——macOS 26 起保留系统工具栏，明确融合布局、工具栏带与系统侧栏切换按钮的接受行为。

## Impact

- 代码已先行实现并验收（`MainWindowChrome` 不再移除工具栏、侧栏列 `ignoresSafeArea(.top)`、移除自绘「显示侧栏」按钮），本变更只做 spec 同步，无新增代码改动。
- 涉及文件（已改完）：`apple/PandaSSH/MainWindowChrome.swift`、`apple/PandaSSH/SidebarView.swift`、`apple/PandaSSH/Workspace/WorkspaceView.swift`。
- macOS：行为如上述变化；iPadOS：无影响（侧栏入口/布局不变，添加按钮走系统导航栏 toolbar）。

## Non-goals

- 不追求消除 detail 区顶部的系统工具栏带（系统绘制区，内容无法填入；页签栏不改为工具栏项）。
- 不做完全自绘分栏/自绘侧栏面板（已评估并放弃：需重写拖拽调宽与显隐动画，且需对抗 AppKit 布局）。
- 不改变 iPadOS 的任何布局与入口。
- 不处理 macOS 15 及以下系统的表现差异（保留工具栏在旧系统上同样可用，差异仅为标题栏高度）。

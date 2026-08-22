## Why

当前 macOS 主窗口左侧边栏在 `NavigationSplitView` 整体向下偏移 38pt 后，未能延伸至窗口最顶部，且侧栏顶部圆角/留白与目标设计不符；同时内容区顶部工具带（侧栏切换按钮、页签按钮区）通过覆盖层偏移实现，未真正与侧栏右边缘对齐。用户要求左侧边栏顶到最上方，工具带随侧栏宽度自适应对齐。

## What Changes

- 移除 `WorkspaceView` 中 `NavigationSplitView` 的 38pt 向下偏移，使左侧边栏与右侧内容区均延伸至窗口顶部。
- 将窗口拖拽区域从内容区工具带移至左侧边栏顶部的红绿灯避让区，保证侧栏可见时仍可拖拽窗口。
- 调整内容区顶部工具带覆盖层：侧栏可见时其背景/按钮从侧栏右边缘开始，不遮挡侧栏顶部按钮；侧栏隐藏时保留红绿灯避让区。
- 更新 `macos-workspace-toolbar` 规格中关于工具带对齐、侧栏顶部区域、内容区延伸至顶部的要求。
- 补充/更新相关布局测试，验证侧栏隐藏/显示时工具带的偏移与拖拽区域存在性。

## Capabilities

### New Capabilities

（无新能力）

### Modified Capabilities

- `macos-workspace-toolbar`: 修正并细化 macOS 主窗口工具带与左侧边栏顶部对齐规则：侧栏 SHALL 延伸至窗口顶部；工具带按钮区 SHALL 随侧栏宽度自适应，不覆盖侧栏内容；侧栏隐藏时 SHALL 保留红绿灯避让区。

## Impact

- `apple/PandaSSH/Workspace/WorkspaceView.swift`: 移除 38pt 偏移，保留 `MainWindowChrome` 与 `WorkspaceToolbar` 覆盖层。
- `apple/PandaSSH/Workspace/WorkspaceToolbar.swift`: 调整工具带水平布局，根据侧栏显隐切换红绿灯避让区/透明占位；保留 `SidebarWidthPreferenceKey` 读取。
- `apple/PandaSSH/SidebarView.swift`: 在 macOS 侧栏工具栏左侧增加 `WindowDragView`，替代原 `.padding(.leading, 78)` 的纯空白避让。
- `apple/PandaSSHTests/WorkspaceToolbarButtonTests.swift` / `MacOSTabBarLayoutTests.swift`: 补充可见性/布局相关测试。
- iPadOS 端不受影响，保持现有 `NavigationSplitView` 与 `TabView` 布局。

## Non-goals

- 不修改 iPadOS 主窗口布局、工具带或设置结构。
- 不改动页签按钮视觉样式、溢出模式业务逻辑与设置持久化。
- 不改动 Rust/FFI 层、主机配置、SSH、SFTP 业务逻辑。
- 不引入第三方窗口标题栏或分栏控件。

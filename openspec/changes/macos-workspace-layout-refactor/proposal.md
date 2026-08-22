## Why

当前 macOS 主窗口布局经历多轮 `NSTitlebarAccessoryViewController`、`.toolbar` 与 `TabView` 迭代，始终无法同时满足：页签放入标题栏、不覆盖左侧边栏、对齐红绿灯、最大限度保留内容区。用户提供了明确的参考布局，要求把操作按钮归位到正确区域、用自定义按钮实现页签栏，并在设置页提供溢出模式与可视化预览。

## What Changes

- 重新划分 macOS 主窗口三栏结构：左侧边栏、内容区顶部工具带、内容区主区域。
- 左侧边栏顶部（红绿灯同一水平线）放置「添加主机」「添加分组」主机管理按钮。
- 内容区顶部自定义工具带，从左到右依次为：
  - 侧栏切换按钮（三条横线图标）
  - 页签左滚动按钮
  - 自定义页签按钮（彩色状态圆点 + 标题 + 关闭按钮）
  - 页签右滚动按钮
- 工具带高度与红绿灯对齐；主窗口标题栏不再显示 `PandaSSH-macOS` 等文字。
- 不显示系统工具栏空白带与系统自带侧栏切换按钮（窗口工具栏整体移除，内容区延伸到窗口顶部）。
- macOS 工具带不提供「+」新建标签页按钮；新建标签页入口保留在侧栏主机条目（双击/右键菜单）。
- 页签数量超过可用宽度时，默认在工具带内显示左右滚动按钮，支持水平滚动。
- 设置页新增「标签页」标签，提供「标签页溢出模式」选项：
  - 「左右滚动（默认）」
  - 「溢出扩展显示」
  - 选项下方显示可视化预览图
  - 设置变更在下次启动应用时生效
- 主内容区空态更新为：终端图标 + 「尚未连接」+ 副标题 + 「快速连接」「打开连接」按钮。
- iPadOS 端保持现有 `TabView` 布局与设置结构不变。

## Capabilities

### New Capabilities
- `macos-workspace-toolbar`: macOS 主窗口工作区工具带与自定义页签栏布局规则。
- `settings-tab-bar`: 设置页「标签页」标签内的页签栏溢出模式与预览配置。

### Modified Capabilities
- `workspace`: 补充 macOS 端主窗口布局、页签栏位置、侧边栏切换入口、空态内容的新需求；iPadOS 端保持既有行为。

## Non-goals

- 不修改 iPadOS 主窗口布局、页签视觉风格与设置页结构。
- 不修改终端/SFTP 标签页内部业务逻辑（右键菜单、中键粘贴、SFTP 文件操作等）。
- 不引入第三方 tab 控件或浏览器渲染引擎，自定义按钮仍使用 SwiftUI 原生组件。
- 不改动 Rust/FFI 层。

## Impact

- `apple/PandaSSH/Workspace/WorkspaceView.swift`：重构 NavigationSplitView / 自定义工具带布局 / 空态视图。
- `apple/PandaSSH/Workspace/WorkspaceToolbar.swift` / `WorkspaceTabBar.swift` / `WorkspaceTabButton.swift`：新增自定义工具带与页签按钮组件。
- `apple/PandaSSH/Settings/SettingsView.swift`：新增「标签页」设置标签与溢出模式配置。
- `apple/PandaSSH/Workspace/TitlebarTabBarAccessory.swift`、`TabBarToolbar.swift`、`WindowAccessor.swift`、旧 `TabBarView.swift` 将被移除。
- `WorkspaceStore` / `AppSettings` 新增 `tabBarOverflowMode` 用户偏好字段，持久化到 `UserDefaults`。

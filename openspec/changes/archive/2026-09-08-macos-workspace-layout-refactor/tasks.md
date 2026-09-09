## 1. 测试先行：设置与工具带可测逻辑

- [x] 1.1 新增 `WorkspaceToolbarViewModelTests`：验证 `tabBarOverflowMode` 默认值、读写持久化、非法值回退；验证侧栏可见性切换；验证 iPadOS 不暴露页签设置。
- [x] 1.2 新增 `MacOSTabBarLayoutTests`：验证滚动模式下溢出检测、左右滚动按钮可见性与点击滚动；验证扩展显示模式下流式布局行数计算；验证空标签页时工具带状态。
- [x] 1.3 新增 `WorkspaceToolbarButtonTests`：验证「添加主机」「新建分组」「侧栏切换」「新建标签页 +」按钮点击后分别调用对应 `WorkspaceStore` / `AppModel` 方法；验证按钮在 iPadOS 不出现。

## 2. 模型与设置持久化

- [x] 2.1 在 `WorkspaceStore`（或新建 `AppSettings`）新增 `tabBarOverflowMode: TabBarOverflowMode` 枚举（`scroll` / `expand`），默认 `.scroll`，通过 `UserDefaults` 持久化。
- [x] 2.2 在 `SettingsView` 新增「标签页」设置标签（macOS only），内部使用单选 Picker 切换「左右滚动（默认）」与「溢出扩展显示」，绑定到 `tabBarOverflowMode`。
- [x] 2.3 在「标签页」设置标签内添加溢出模式可视化预览图：滚动模式显示单行页签 + 左右箭头；扩展模式显示多行页签。
- [x] 2.4 在「标签页」设置标签底部添加提示文案「更改将在下次启动应用时生效」。
- [x] 2.5 跑 `WorkspaceToolbarViewModelTests` 验证转绿；补充边界测试：非法 UserDefaults 值回退默认值、设置变更后持久化。

## 3. 自定义页签按钮组件

- [x] 3.1 新增 `WorkspaceTabButton`：左侧彩色状态圆点、中间页签标题、右侧关闭按钮；当前活动页签高亮；点击切换活动页签；点击关闭按钮触发 `workspace.close(tabID:)`。
- [x] 3.2 新增 `WorkspaceTabBar`：根据 `tabBarOverflowMode` 选择布局：
  - 滚动模式：`ScrollView(.horizontal)` + 左右滚动按钮，按钮可点击滚动；
  - 扩展模式：流式 `Layout` 或 `HStack` 自动换行，行数由标签数量与宽度决定。
- [x] 3.3 跑 `MacOSTabBarLayoutTests` 转绿；验证溢出检测、滚动偏移、扩展换行行数三类场景。

## 4. 内容区工具带与侧边栏切换

- [x] 4.1 新增 `WorkspaceToolbar`：固定高度容器（约 38pt，对齐红绿灯），从左到右依次为：侧栏切换按钮（三条横线）、左滚动按钮、页签区、右滚动按钮、新建标签页「+」按钮。
- [x] 4.2 修改 `WorkspaceView`：macOS 下使用 `NavigationSplitView`，左侧边栏顶部放置「添加主机」「添加分组」按钮；右侧 detail 列顶部固定 `WorkspaceToolbar`，下方为主内容区。
- [x] 4.3 更新主内容区空态：显示终端图标、「尚未连接」标题、副标题、「快速连接」与「打开连接」按钮。
- [x] 4.4 跑 `WorkspaceToolbarButtonTests` 转绿；验证侧栏切换改变 `NavigationSplitView.columnVisibility`。

## 5. 清理旧实现与回归验证

- [x] 5.1 删除 `TitlebarTabBarAccessory.swift`、`TabBarToolbar.swift`、`WindowAccessor.swift` 及旧 `TabBarView.swift`（若新组件已完全替代）。
- [x] 5.2 跑 `cargo test` 确认 Rust 核心不退化。
- [x] 5.3 跑 `apple/Scripts/build-rust.sh` → `cd apple && xcodegen` → `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS build` → `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-iOS build -destination 'generic/platform=iOS Simulator'`，双端构建通过。
- [x] 5.4 跑全部 macOS + iOS 单元测试，确保删除旧文件不破坏既有功能。
- [x] 5.5 手动验收（macOS 真机）：
  - 添加主机/新建分组按钮在侧栏顶部；
  - 内容区顶部工具带按钮顺序：侧栏切换、左滚动、页签、右滚动、新建「+」；
  - 工具带对齐红绿灯，标题栏无 App 名称文字；
  - 大量标签页时默认出现滚动按钮且可滚动；
  - 设置页「标签页」标签内切换为扩展显示后重启生效，自动换行；
  - 空态显示「尚未连接」+「快速连接」「打开连接」；
  - iPadOS 布局与设置结构无变化。

## 6. 真机反馈修订：移除系统工具栏带、系统侧栏切换按钮与「+」按钮

- [x] 6.1 更新提案/设计/规格：工具带不含「+」新建按钮；窗口不显示系统工具栏空白带与系统侧栏切换按钮；新增 design 决策 8（最小 AppKit 窗口配置）。
- [x] 6.2 新增 `MainWindowChrome`（macOS only，`NSViewRepresentable`，无 observer）：`titleVisibility=.hidden`、`titlebarAppearsTransparent=true`、`fullSizeContentView`、`toolbar=nil`，挂载到主窗口视图树。
- [x] 6.3 `WorkspaceToolbar` 移除「+」新建按钮；侧栏隐藏（detailOnly）时为红绿灯预留左侧空间。
- [x] 6.4 双端构建（macOS + iOS arm64 模拟器）与双端单元测试回归全绿。

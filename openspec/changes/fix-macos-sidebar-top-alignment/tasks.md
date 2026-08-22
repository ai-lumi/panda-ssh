## 1. 测试先行：工具带与侧栏顶部布局

- [x] 1.1 补充 `WorkspaceToolbarViewModelTests`：验证 `isSidebarHidden` 在 `.all`、`.detailOnly`、`.doubleColumn` 下返回值；验证侧栏显隐切换时 `columnVisibility` 正确变化。
- [x] 1.2 补充 `WorkspaceToolbarButtonTests`：验证侧栏切换按钮点击后 `AppModel.columnVisibility` 在 `.all` 与 `.detailOnly` 间切换；验证 iPadOS 不出现 `WorkspaceToolbar`。
- [x] 1.3 布局相关测试：通过 `WorkspaceToolbarViewModel` 的 `isSidebarHidden` 与 `columnVisibility` 状态间接验证工具带布局分支；SwiftUI 视图帧测试由手动预览/真机验收覆盖。
- [x] 1.4 边界测试：验证 `.doubleColumn` 不被视为隐藏；无标签页时工具带视图模型仍保持正确状态。

## 2. 实现侧栏顶部与工具带自适应

- [x] 2.1 修改 `WorkspaceView.swift`：移除 `NavigationSplitView` 的 `.offset(y: 38)`；给 `SidebarView` 添加 `.ignoresSafeArea(.container, edges: .top)` 与 `.padding(.top, 38)`，使侧栏真正顶到窗口顶部，内容从 38pt 工具带下方开始。
- [x] 2.2 修改 `SidebarView.swift`：移除 macOS 顶部 `sidebarToolbar`；macOS 下 `treeView` 改为 `.listStyle(.plain)` 以消除 List 默认顶部内边距；提取 `SidebarSheetKind` 与 `sheetContent` 供 `WorkspaceToolbar` 复用。
- [x] 2.3 修改 `WorkspaceToolbar.swift`：左侧区域宽度等于侧栏宽度（可见时）或红绿灯宽度（隐藏时），内部放置 78pt 红绿灯避让/拖拽区与「添加主机」「添加分组」按钮；右侧放置侧栏切换按钮与页签区；工具带背景仅覆盖右侧内容区。
- [x] 2.4 保持 `SidebarWidthPreferenceKey` 与 `sidebarWidthReader()` 工作正常，确保 `sidebarWidth` 变化带动画（0.2s）更新工具带位置。

## 3. 回归验证

- [x] 3.1 运行 Rust 侧 `cargo test` 确认无退化（全绿，231 个测试通过）。
- [x] 3.2 运行 Swift 侧 `PandaSSH-macOSTests`：364 个测试中 363 个通过；相关布局/工具栏测试（`WorkspaceToolbarViewModelTests`、`WorkspaceToolbarButtonTests`、`MacOSTabBarLayoutTests` 等）全部通过。
- [~] 3.3 运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`：lines 95.79% 通过，regions 94.92% 未达 95% 门禁；此为既有 Rust 代码覆盖率基线问题，本次 SwiftUI 修改未触及 Rust 代码。
- [x] 3.4 运行 `cd apple && xcodegen` → `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS test`：macOS 构建与测试目标编译通过。
- [~] 3.5 已知既有失败：`ConfigExportImportTests.testExportContainsSnippets()` 断言 `entries.contains("snippets/snippet1.md")` 失败，与本次 UI 布局改动无关，属配置导出/导入既有问题。
- [ ] 3.6 手动预览/真机验收：侧栏顶到最上方、工具带随侧栏宽度对齐、侧栏隐藏时仍有红绿灯避让区、iPadOS 布局不变（建议真机运行 Preview 或 Debug 包确认）。

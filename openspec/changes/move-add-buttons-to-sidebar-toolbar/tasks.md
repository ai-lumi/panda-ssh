# Tasks: move-add-buttons-to-sidebar-toolbar

## 1. 测试（先行）

- [x] 1.1 检查 `apple/PandaSSHTests` 中引用「添加主机」「新建分组」工具栏按钮的现有测试，按新位置（侧栏列 toolbar）调整断言；若无覆盖则跳过新增（纯 UI 布局不强制测试，按钮动作仍走既有 `model.sidebarSheet` 状态，可测逻辑不变）

## 2. 实现

- [x] 2.1 修改 `apple/PandaSSH/Workspace/WorkspaceView.swift`：从 macOS body 根视图的 `.toolbar` 中移除「添加主机」「新建分组」两个 `ToolbarItem`，并更新上方注释
- [x] 2.2 修改 `apple/PandaSSH/SidebarView.swift`：macOS 条件编译块内为侧栏视图添加 `.toolbar`，包含「添加主机」（`plus` 图标）与「新建分组」（`folder.badge.plus` 图标）两个按钮，动作分别设置 `model.sidebarSheet = .addHost(defaultGroupID: nil)` 与 `.newGroup(parent: nil)`，图标按钮样式与 `.help` 文案与原实现一致
- [x] 2.3 同步更新注释：`PandaSSHApp.swift` 中 `sidebarSheet` 注释（入口按钮位置描述）、`HostListView.swift` 中 sheet 挂载注释，使其与新布局一致

## 3. 验证

- [x] 3.1 运行 `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS build` 通过
- [x] 3.2 运行 Swift 侧 `PandaSSH-macOSTests`：336 个测试中 335 个通过；唯一失败 `ConfigExportImportTests.testExportContainsSnippets`（导出归档缺少 `snippets/snippet1.md`）属于 config-export-import 在途功能（未跟踪的 `apple/PandaSSH/Config/`）的既有问题，与本变更无关
- [ ] 3.3 真机/预览确认：侧栏可见时按钮在左侧栏顶部标题栏区域；侧栏隐藏时按钮不可见；窗口顶部标题栏导航区不再出现这两个按钮；iPadOS 端无变化

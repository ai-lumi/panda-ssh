## Context

当前 macOS 主窗口经历多次基于 `NSTitlebarAccessoryViewController`、`.toolbar` 与 `TabView` 的迭代，始终无法同时满足：页签放入标题栏、不覆盖左侧边栏、对齐红绿灯、保留最大内容区。用户提供了明确参考图，要求：
- 左侧边栏顶部放「添加主机」「添加分组」；
- 内容区顶部工具带从左到右：侧栏切换（三条横线）、左滚动、页签按钮、右滚动、新建标签页「+」；
- 设置页新增「标签页」标签，含溢出模式单选 + 可视化预览 + 重启生效提示；
- 空态更新为「尚未连接」+「快速连接」「打开连接」。

现有文件 `TitlebarTabBarAccessory.swift`、`TabBarToolbar.swift`、`WindowAccessor.swift`、旧 `TabBarView.swift` 等将被移除或替换，避免历史方案互相冲突。

## Goals / Non-Goals

**Goals:**
- 在 SwiftUI 内完成 macOS 主窗口布局，不依赖 AppKit titlebar accessory 或自定义 NSToolbar。
- 左侧边栏顶部放置添加主机/添加分组按钮。
- 内容区顶部放置完整工具带：侧栏切换、左滚动、页签、右滚动、新建「+」。
- 实现页签溢出水平滚动与扩展显示两种模式，并在设置页提供可视化预览。
- 更新空态视图。
- 保持 iPadOS 布局与设置结构不变。

**Non-Goals:**
- 不修改标签页内部业务逻辑（终端、SFTP）。
- 不引入第三方 tab/浏览器组件。
- 不改动 Rust/FFI 层。

## Decisions

1. **使用 `NavigationSplitView` + 自定义 detail 顶部视图**
   - 左侧边栏为 `NavigationSplitView.sidebar`，顶部用 `.toolbar` 或 `safeAreaInset` 放置主机管理按钮；右侧 detail 列顶部放置自定义 `WorkspaceToolbar`。
   - 理由：SwiftUI 原生分栏布局稳定，避免 AppKit 窗口标题栏注入带来的 observer 崩溃与对齐问题。
   - 替代方案：继续用 `NSTitlebarAccessoryViewController`；已排除，因为对齐与重叠问题无法可靠解决。

2. **工具带按钮顺序固定**
   - 顺序：侧栏切换（三条横线）→ 左滚动 `<` → 页签按钮区 → 右滚动 `>`。
   - 理由：与用户参考图及真机反馈一致；macOS 工具带不放「+」新建按钮（新建入口在侧栏主机条目），避免与页签区争夺右侧空间。

8. **窗口标题栏用最小 AppKit 配置（macOS 14 无 SwiftUI 隐藏窗口工具栏 API）**
   - 新增 `MainWindowChrome`（`NSViewRepresentable`，仅 macOS）：设置 `titleVisibility = .hidden`、`titlebarAppearsTransparent = true`、`styleMask.insert(.fullSizeContentView)`、`toolbar = nil`。
   - 理由：真机验证发现 `.windowStyle(.hiddenTitleBar)` 无法移除 `NavigationSplitView` 自带的系统工具栏带与系统侧栏切换按钮（macOS 14 无 `.toolbar(.hidden, for: .window)`，其为 macOS 15+）。`toolbar = nil` 移除空白工具栏带与系统切换按钮，`fullSizeContentView` 让内容延伸到红绿灯行。
   - 仅做属性设置，不注册 KVO/通知 observer，避免旧 `WindowAccessor` 方案的崩溃问题。

3. **自定义页签按钮使用 `HStack` / `FlowLayout` 切换**
   - 滚动模式：将页签按钮放入 `ScrollView(.horizontal, showsIndicators: false)`，左右两侧固定滚动按钮；通过 `ScrollViewReader` 或 `contentOffset` 模拟控制滚动。
   - 扩展模式：使用 macOS 13+ / iOS 16+ 的 `Layout` 协议实现简单流式布局，或退化为 `VStack` + `HStack` 手工换行。
   - 理由：原生 `TabView` 无法对齐红绿灯且样式受限；自定义按钮可完全控制布局与溢出行为。

4. **溢出模式持久化到 `UserDefaults`，重启生效**
   - 新增 `AppSettings` 或扩展 `WorkspaceStore` 的 `@AppStorage`/`UserDefaults` 字段 `tabBarOverflowMode`。
   - 理由：设置简单，重启后保持，且不影响配置 TOML 文件；与图片中「更改将在下次启动应用时生效」提示一致。

5. **设置页新增「标签页」标签（macOS only）**
   - 在 `SettingsView` 的标签栏中增加「标签页」，内部使用单选 Picker + 预览图。
   - 预览图用简化几何图形表示：滚动模式为单行页签 + 左右箭头；扩展模式为多行页签。

6. **侧栏可见性使用 `NavigationSplitView` 的 `columnVisibility`**
   - macOS 14+ 可用 `NavigationSplitViewVisibility` 控制；侧栏切换按钮绑定到同一状态。
   - 理由：与 SwiftUI 原生分栏状态一致，避免手动维护窗口尺寸。

7. **移除旧文件而非保留兼容代码**
   - `TitlebarTabBarAccessory.swift`、`TabBarToolbar.swift`、`WindowAccessor.swift`、旧 `TabBarView.swift` 将删除。
   - 理由：历史方案互相冲突，保留会导致编译错误与运行时 observer 崩溃。

## Risks / Trade-offs

- **[Risk]** 自定义 `ScrollView` 水平滚动无法精确对齐红绿灯高度。
  - **Mitigation**：使用固定高度工具带容器（约 38pt），与 macOS 标题栏高度对齐；通过 preview 与真机验证。
- **[Risk]** 流式布局在 macOS 13 以下不可用。
  - **Mitigation**：App 目标为 macOS 14+，可安全使用 `Layout` 协议；若需兼容更低版本，可退化为手工 HStack/VStack 组合。
- **[Risk]** 删除旧文件后，如用户仍在其他分支引用这些文件，会产生合并冲突。
  - **Mitigation**：本变更一次性完成，删除前确认这些文件无外部引用。
- **[Risk]** 大量标签页时扩展模式会大幅压缩主内容区。
  - **Mitigation**：默认仍为滚动模式，扩展模式需用户显式选择；可设置最大行数或回到滚动模式。
- **[Risk]** 设置项「重启生效」可能让用户困惑。
  - **Mitigation**：在设置页底部明确提示「更改将在下次启动应用时生效」，与参考图一致。

## Migration Plan

1. 创建新的 `WorkspaceView` 布局与 `WorkspaceToolbar` / `WorkspaceTabBar` / `WorkspaceTabButton` 组件。
2. 在 `SettingsView` 新增「标签页」标签与溢出模式设置项（macOS only），包含预览图。
3. 更新主内容区空态为「尚未连接」。
4. 删除 `TitlebarTabBarAccessory.swift`、`TabBarToolbar.swift`、`WindowAccessor.swift`、旧 `TabBarView.swift`。
5. 跑 `xcodegen` 重新生成工程，跑 `xcodebuild` macOS/iOS 双端构建验证。
6. 跑相关 UI/布局测试与既有回归测试。

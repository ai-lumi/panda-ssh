## Context

见 proposal.md - Why。当前 macOS 使用系统工具栏、`NavigationSplitView` 与内容区页签栏；该组合难以稳定承载 Chromium 式独立页签容器。此前标题栏 accessory/principal item 方案均与系统布局竞争。项目同时要求平台业务规则共享，`#if os()` 只表达 UI 或平台服务差异。

## Goals / Non-Goals

**Goals:**

- 建立一套共享的工作区 shell、页签 viewport 和输入策略。
- 让 macOS 顶行在视觉上与原生标题栏融合，同时保留窗口控制和最大内容高度。
- 将平台代码压缩为薄的窗口 chrome / 安全区 / 导航适配边界。

**Non-Goals:**

- 不将 AppKit 组件传播到共享页签或会话逻辑。
- 不在首个变更删除现有页面或旧页签栏。

## Decisions

### 1. 统一 Shell，薄平台宿主

共享 `WorkspaceShell` 表达“顶部 chrome + 侧栏 + detail”；共享 `TabStripViewportState` 和页签内容组件表达全部页签规则。macOS 宿主仅提供透明标题栏、full-size content、安全矩形与拖拽视图；iPadOS 宿主仅提供安全区与系统导航装配。每个 `#if os()` 必须处于这类边界文件，并附说明。

替代方案：macOS 使用完全独立的 AppKit 页面。否决：页签、会话与测试会重复，长期成本高。

### 2. macOS AppKit 宿主承载唯一顶部 chrome，不使用系统 toolbar

macOS 内容延伸到透明标题栏下方。专用 AppKit 宿主 SHALL 移除工作区
系统 toolbar，读取原生红绿灯与标题栏的实际安全矩形，并把这些矩形和空白拖拽区提供给
唯一的 SwiftUI 顶部 chrome。顶部 chrome 不得以固定侧栏宽度、固定标题栏预留
或额外工具栏行模拟 `NavigationSplitView` 的布局；侧栏操作入口与独立页签容器
只能在这一行出现一次。原生红绿灯保持窗口所有，空白区域仍可拖拽。宿主在移除
工作区 toolbar item 后 MUST 显式保持关闭、最小化与缩放按钮可见；自绘内容只能避让
这些 AppKit 控件，不能以隐藏它们来换取宽度。

统一顶行与 `NavigationSplitView` 的安全区只能结算一次：分栏宿主 SHALL 在自身边界处理
标题栏安全区；侧栏子视图不得以负 padding 或手工高度抵消 inset，因为这会在不同窗口
状态下裁掉搜索区。侧栏上方由统一顶行的操作区占据，而不是留下与任何控件无关的空白。

经实机验证，SwiftUI `NavigationSplitView` 在移除系统 toolbar 后仍会为 sidebar 注入不可由
子视图安全区修改器可靠消除的栏头高度。因此 unified macOS 路径 SHALL 由 AppKit 的
`NSSplitViewController` 承载 sidebar 与 detail 两个独立 hosting controller；该宿主与
标题栏宿主同层，并直接维护收起、恢复和可调整列宽。共享 `SidebarView`、detail 内容、
`WorkspaceStore` 和所有会话规则保持不变。旧 `NavigationSplitView` 仅保留在 legacy
回退路径，iPadOS 继续使用其原生 SwiftUI 分栏。

macOS 鼠标滚轮由薄 AppKit 输入桥接在页签容器命中范围内接收。桥接仅将
`scrollingDeltaX/Y` 与精确度转换为共享 `TabStripScrollInput`，随后仍由无条件
编译的 viewport 状态计算目标偏移；它不得选择、关闭或重建页签。

替代方案：保留系统 toolbar 后在其下方再添加自绘 chrome，或使用 titlebar
accessory/principal toolbar item。否决：前者产生两行竞争 chrome 和宽度重复扣减；
后两者无法可靠获得 detail 专属空间，且历史上有系统溢出与事件竞争。

### 3. 双路径渐进迁移

iPadOS detail 内的顶栏不分配侧栏工具区。工具区宽度为零时不创建其按钮或分隔线，避免 SwiftUI 子视图溢出零宽 frame 后覆盖页签；侧栏可见时使用已有系统操作入口，隐藏时保留恢复入口。

侧栏显隐引起的顶行宽度重分配和页签几何校正不使用动画。主动浏览页签仍可使用滚动动画；重复几何回调且目标偏移不变时不触发滚动。

新 shell 由装配策略选择；旧 `NavigationSplitView` / `WorkspaceTabBar` 路径原样保留。两条路径消费同一 `AppModel`、`WorkspaceStore` 与会话对象，切换不得重建会话。

## Risks / Trade-offs

- [Risk] 自绘顶行降低系统 toolbar 自动适配 → 以窗口宽度、侧栏状态、全屏和最小尺寸的 UI 测试及人工验证覆盖。
- [Risk] 共享 shell 被平台细节污染 → 将所有业务规则放在无条件编译文件，并审查新增条件编译。
- [Risk] 双路径增加短期维护成本 → 将旧路径限定为回退，复用页签数据与纯值 viewport。

## Migration Plan

1. 先测试并建立共享 viewport、输入与 shell contract，不改变默认 UI。
2. 接入 macOS 透明标题栏宿主和 iPadOS 安全区适配，旧路径保留。
3. 验证两端布局、会话连续性与回退后，将新 shell 设为默认。
4. 旧路径只在单独评审的后续变更中决定是否移除。

## Context

参见 [proposal.md](./proposal.md) 的动机。本变更只调整 SwiftUI 工作区的呈现与交互语义；SSH、SFTP、传输任务和凭据仍由现有 `AppModel`、`WorkspaceStore`、`SftpSessionStore`、`TransferStore` 与 Rust/FFI 实现负责。

当前工作区有四项会相互影响的约束：

- macOS 26 的侧栏融合依赖可见的系统工具栏，detail 顶部必须保留系统工具栏绘制带，不能用自绘标题栏覆盖。
- 当前窗口同时使用 SwiftUI `hiddenTitleBar` 与 `MainWindowChrome` 隐藏标题，而会话页签仍作为内容区第一行绘制；这会浪费系统工具栏的原标题位置，也容易让应用名称重新出现或形成双层顶部结构。
- iPadOS 与 macOS 共享会话和文件浏览状态，但横屏全屏、Stage Manager 与分屏可能在运行时改变可用宽度；布局切换不能重建连接或清空路径、选中项和传输任务。
- SwiftUI 视图目前用 `activeTabID` 与 `selectedHostID` 隐式决定右侧内容。在打开会话后选择另一主机时，两个状态可以同时存在，容易出现标签和详情都像“当前内容”的视觉冲突。

## Goals / Non-Goals

**Goals:**

- 用可测试的纯值策略决定工作区呈现模式、SFTP 栏数与传输面板形式，不把尺寸判断散落在多个视图中。
- 让“正在显示主机详情”和“正在显示会话标签”成为明确且互斥的视图状态，同时保留后台会话。
- 让 macOS 使用桌面密度和系统窗口装饰，让 iPadOS 使用触控尺寸及系统导航呈现；共享信息架构和底层状态，不强求共用每一段视图代码。
- 不显示应用名称窗口标题，并让 macOS 会话页签占用系统工具栏原标题位置而不重复占用内容高度。
- 以 SwiftUI 语义颜色、系统材质、系统分隔线、SF Symbols 和 Dynamic Type 建立一致视觉层级，不引入新的 UI 依赖。

**Non-Goals:**

- 不把窗口尺寸、size class 或设备型号写入业务模型、持久化配置或 Rust 核心。
- 不改变 `WorkspaceStore` 对标签生命周期、连接重连和关闭确认的既有规则。
- 不建立跨平台设计令牌框架；本次只提取工作区内确有复用价值的少量语义样式。
- 不做像素截图测试。几何策略和动作路由由 XCTest 覆盖，最终外观通过三种目标尺寸的 Preview/截图验收。

## Decisions

### 1. 以纯值布局策略集中处理响应式分支

新增内部纯值类型 `WorkspaceLayoutPolicy`，输入平台、水平 size class 与实际可用宽度，输出：

- `sidebarPresentation`：并列或系统折叠；
- `sftpPresentation`：双栏或本地/远程单栏；
- `transferPresentation`：桌面抽屉、iPad inspector 或 iPad sheet；
- `tabMetrics` 与最小触控尺寸。

iPadOS 先遵循 `horizontalSizeClass`，再用容器宽度处理 Stage Manager 中 size class 仍为 regular、但内容已不足以容纳双栏的边界。阈值集中为具名常量并由边界测试保护；视图只消费策略结果。macOS 始终使用桌面策略，窗口过窄时由既有最小窗口尺寸和滚动容器降级，不套用 iPad 触控布局。

选择纯值策略而不是在每个视图内重复 `horizontalSizeClass == .compact`，是为了避免 SFTP、页签和传输面板在临界宽度下得出不同结论，也便于先写失败测试。没有选择设备型号判断，因为 iPad 分屏和 Stage Manager 下型号不能代表实际空间。

### 2. 引入互斥的工作区呈现选择，不改变会话生命周期

在 Swift 视图模型层引入 `WorkspacePresentationSelection`：

- `.empty`
- `.hostDetail(hostID)`
- `.tab(tabID)`

`WorkspaceStore` 仍持有标签数组、活动标签和连接资源；`AppModel` 仍持有侧栏主机选择。呈现选择只负责描述 detail 当前显示什么：单击主机切换为 `.hostDetail`，单击标签切换为 `.tab`，删除当前目标后由统一归一化函数回退到可用详情或空态。切换到主机详情不会关闭或重连任何标签。

选择显式枚举而不是继续用 `activeTabID` 与 `selectedHostID` 的优先级推断，是因为两者都可能合法存在；枚举能让高亮、辅助功能选中态与实际内容共享同一事实来源。没有把它移入 Rust 核心，因为它只描述平台界面的导航呈现，不是 SSH 业务规则。

### 3. 保留原生窗口与导航容器，让页签取代标题内容

macOS 继续由 Window、系统 toolbar 与 `NavigationSplitView` 提供红绿灯、侧栏切换、窗口拖拽和全屏行为。Scene 使用 SwiftUI `unifiedCompact(showsTitle: false)` 语义明确隐藏标题文字但保留统一紧凑工具栏；工作区通过单个 `principal` toolbar item 承载 `WorkspaceTabBar`。macOS 26 对 toolbar item 自动施加共享玻璃背景时，principal 页签项使用官方 `sharedBackgroundVisibility(.hidden)` 隐藏连续的大面积玻璃胶囊，同时以可用性判断保持 macOS 14–25 兼容。页签内部自行处理横向滚动或多行布局，MUST NOT 将每个页签注册成独立 toolbar item，以免系统把单个会话移入溢出菜单。内容区直接从系统工具栏下方开始，不再绘制 `macOSTabBar` 第二行、`WindowDragView` 或终端内部重复的主机/状态标题横条。

`NavigationSplitView` 默认侧栏按钮只在侧栏隐藏时承担恢复职责。侧栏可见时通过官方 `toolbar(removing: .sidebarToggle)` 移除该默认项，由侧栏内部按钮负责收起，避免同一状态下出现两个侧栏图标；侧栏进入 `detailOnly` 后停止移除默认项，让系统恢复按钮回到红绿灯右侧。该行为由纯值 chrome 策略覆盖正常、隐藏和无效输入场景。

现有 `.windowStyle(.hiddenTitleBar)`、`MainWindowChrome` 的 `titleVisibility`/透明标题栏/full-size content 配置与新 Scene 样式存在重叠。实现采用渐进迁移：先接入统一紧凑工具栏和 `principal` 页签并验证 macOS 14 与 macOS 26，再删除不再需要的自绘拖拽和重复标题栏配置；若移除 full-size content 会破坏 macOS 26 侧栏融合，则仅保留该必要 AppKit 标志，标题可见性仍以 SwiftUI Scene 样式为主。

iPadOS 继续使用 `NavigationSplitView` 和系统 navigation bar，且不设置应用名称导航标题。常规宽度并列显示侧栏与内容；紧凑宽度让系统负责折叠与恢复侧栏。受 44pt 触控目标和多会话宽度限制，iPad 页签仍由自适应顶部行承载，不强塞进紧凑导航栏中央。平台分支只封装窗口装饰、导航容器、hover 和触控尺寸，符合项目对 `#if os()` 的限制。

没有选择完全移除系统 toolbar 后自绘统一标题栏，因为它会破坏 macOS 26 侧栏融合，并要求应用自行承担红绿灯避让、拖拽、全屏和侧栏恢复；`NSTitlebarAccessoryViewController` 仅作为 SwiftUI `principal` 在支持系统上无法稳定容纳页签时的备用方案，不作为首选实现。

### 4. 视觉语言采用语义表面和单一强调色

工作区定义三层表面：系统侧栏背景、页签/工具带背景、主内容背景；边界用系统 `Divider` 或 separator 语义色表达。选中态使用系统 accent 的低强度填充，并同时保留文字、图标或辅助功能标签。连接状态以 SF Symbol 加状态文案/辅助功能值表达，色彩只作补充。

终端和 SFTP 不增加外围装饰卡片。圆角只用于页签选中态、按钮、徽标和空态操作等具有交互或分组意义的局部元素。字号、行高和间距优先使用系统 text style 与 control size；少量共享尺寸集中在工作区语义样式中，禁止复制一套固定的 Mac 像素值给 iPad。

没有建立全局自定义调色板，因为系统语义色能自然适配浅色、深色、提高对比度与材质变化，且更符合原生 SwiftUI 行为。

### 5. 页签共享语义，分别适配桌面与触控

页签继续共享标题、连接状态、选择、关闭及上下文菜单动作。macOS 保留紧凑高度，关闭按钮可在当前项或 hover 时出现；iPadOS 当前标签始终显示关闭入口，并用不可见 padding/`contentShape` 保证至少 44×44pt 的点击区域。标签栏保持水平滚动，不用把标签压缩到相互遮挡。

页签视觉状态由呈现选择决定，而不只比较 `activeTabID`。因此查看主机详情时所有会话仍存在，但没有标签伪装为当前内容。

没有使用系统 `TabView`，因为工作区需要可关闭、多会话、横向溢出和每个标签的上下文菜单，现有自定义 SwiftUI 标签栏更符合需求。

macOS 滚动模式把左右翻页按钮固定在可视区两端，中间 `NSScrollView` 的 document view 始终采用未压缩的页签理想宽度。滚动状态统一由内容宽度、视口宽度和当前偏移计算：支持左右按钮按页滚动、触控板水平手势、鼠标纵向滚轮转横向滚动，并在活动页签变化时将目标页签滚入可见区域。滚动偏移始终夹取到 `0...maxOffset`，窗口或侧栏宽度变化后重新归一化，避免尾部空白。

没有只依赖 SwiftUI `ScrollView`，因为页签位于 macOS 系统 principal toolbar item 内，需要明确接管滚轮方向、视口变化和按页翻页；但滚动边界与目标偏移提取为纯值计算，并用 AppKit 布局测试覆盖真实 document/clip 尺寸，避免只有实现而无溢出回归保护。

### 6. SFTP 只切换视图组合，不重建状态对象

`SftpTabView` 保持单一 `@StateObject SftpSessionStore`。双栏与单栏使用同一对 `localPane` / `remotePane`，只由布局策略选择同时渲染还是按本地/远程分段选择渲染。当前分段是短生命周期 UI 状态；路径、选中项、加载状态和传输任务继续保存在既有 store 中。

macOS 使用现有右侧抽屉。iPad 常规宽度优先使用系统 inspector（环境不支持时使用 sheet），紧凑宽度使用 sheet；两者共享同一个 `TransferStore`，关闭呈现不会取消任务。紧凑宽度的文件行、路径操作和主要工具按钮使用至少 44pt 的触控区域。

没有创建两套 SFTP session 或复制文件列表状态，因为在宽度切换时会导致重复连接和状态丢失。

### 7. 空态动作通过显式路由，不代替用户选择目标

空态接收 `hasSavedHosts`、`showHostPicker` 与 `addHost` 三项输入。`showHostPicker` 只恢复/聚焦侧栏并进入主机选择语境；`addHost` 复用现有新增主机 sheet。两项动作都不直接调用 `openTerminal`。无已保存主机时不显示无效的“选择主机”。

动作决策提取为可测试的轻量路由值，覆盖有主机、无主机以及主机列表在点击前后发生变化的情况。没有保留“快速连接第一台”，因为排序第一不代表用户确认的连接目标。

### 8. 评审稿与 Preview 是验收基准，不成为运行时依赖

提供 Mac 常规窗口、iPad 横屏常规宽度、iPad 紧凑分屏三种交互评审稿，并在 SwiftUI Preview 中建立同等状态。评审稿用于确认层级、密度和平台差异；实现以规格和系统组件为准，不导入评审稿的 HTML/CSS 或额外资源。

## Risks / Trade-offs

- **[Stage Manager 的 size class 与实际空间不完全一致]** → 布局策略同时接收容器宽度，阈值集中管理，并测试阈值前后 1pt 的边界。
- **[显式呈现选择与旧的 `activeTabID` 短期并存，可能产生状态漂移]** → 所有主机/标签点击与删除入口通过统一动作方法更新；增加归一化测试，视图不直接拼装两个选中状态。
- **[单栏和双栏切换时 SwiftUI 可能销毁子视图的局部 `@State`]** → 路径、选中项和异步加载状态保留在 `SftpSessionStore`/pane store；仅分段选择保留在容器 UI 状态，并以宽度往返测试验证。
- **[iPad 页签 44pt 触控区会降低可见标签数量]** → 使用水平滚动和适度文字截断，不压缩触控目标；macOS 继续采用紧凑指标。
- **[系统 principal 区域宽度由 macOS 决定，页签可能在窄窗口被压缩]** → 把整条可滚动页签栏作为单一 principal item，给出保守 ideal/min width，并在最小窗口、多标签和侧栏显隐状态测试；不足时再评估官方标题栏 accessory 备用方案。
- **[NSHostingView 在 principal 工具栏中可能把页签理想宽度压缩为视口宽度，导致误判为无需滚动]** → document 内容显式采用未压缩理想宽度，同时监听 document 与 clip view 尺寸；以大量页签的 AppKit 测试断言溢出、翻页和首尾夹取。
- **[系统材质在不同系统版本的对比度略有变化]** → 依赖语义 foreground/background 与系统分隔线，并在浅色、深色和提高对比度环境人工验收，不用固定灰度补偿。
- **[现有未归档 UI 提案可能修改相同文件]** → 实现前对照当前 `workspace` 主规格和活动 change；以“保留系统工具栏/侧栏恢复行为”为合并底线，冲突逐项迁移，不回退已归档行为。

## Migration Plan

1. 先以 XCTest 锁定布局策略、呈现选择、空态动作和 iPad 页签指标，再逐项实现纯值类型。
2. 将 `WorkspaceView` 的内容选择迁移到显式呈现选择，验证现有标签关闭、重连和侧栏页面切换测试仍通过。
3. 先把 macOS 页签迁入隐藏标题文字的统一紧凑系统 toolbar，删除内容区重复页签行并验证侧栏融合，再重构页签与工作区语义表面。
4. 让 iPadOS 消费同一布局策略，依次接入页签触控指标、SFTP 单/双栏和传输 sheet/inspector。
5. 补齐三种目标尺寸的 Preview/截图，运行 Swift 双端构建、测试与项目门禁后归档 change。

本变更不迁移持久化数据，也不需要 Rust/FFI 兼容层。若视觉重构需要回滚，可回退 SwiftUI 视图与新增纯值策略；现有标签、连接和传输数据结构不受影响。

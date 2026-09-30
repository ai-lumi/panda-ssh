// =============================================================================
// WorkspaceView.swift
// =============================================================================
// 文件功能说明：
// 本文件实现了应用的主工作区视图 WorkspaceView，是整个应用的核心界面。
// 功能包括：
// 1. 顶部自定义标签栏 —— 纯 SwiftUI 实现，双端（macOS/iPadOS）共享
// 2. 内容区按活动标签类型分发 —— 终端视图或 SFTP 文件浏览器
// 3. 侧栏导航 —— 主机列表、连接监控、传输任务、片段、设置等
// 4. 关闭确认弹窗 —— 关闭已连接的终端时弹出确认对话框
// 5. 快捷键支持 —— Ctrl+Tab 切换下一个标签、Ctrl+Shift+Tab 切换上一个
// 6. 空态视图 —— 无标签且无选中主机时显示引导界面
//
// macOS 和 iPadOS 使用不同的布局策略，但共享同一套标签管理和内容分发逻辑。
// =============================================================================

import SwiftUI
// 导入 SwiftUI 框架
#if os(macOS)
import AppKit
// macOS 平台导入 AppKit（用于 CloseTabKeyInterceptor 等原生组件）
#endif

/// 多标签页工作区容器:顶部自定义标签栏(纯 SwiftUI,双端共享,
/// 不依赖 NSTabView/UITabView),内容区按活动标签类型分发到
/// 终端视图或 SFTP 文件浏览器。
struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    // @EnvironmentObject 从视图树的环境值中获取 AppModel 对象
    // AppModel 是应用的全局状态模型，包含主机列表、侧栏状态、工作区呈现状态等
    // 当 AppModel 的 @Published 属性变化时，依赖它的视图会自动刷新
    @EnvironmentObject private var workspace: WorkspaceStore
    // WorkspaceStore 管理工作区标签页的状态（标签列表、活动标签、分组等）
    /// 传输队列以非订阅环境值取引用（不观察）：传输期间 5Hz 状态发布
    /// 不再使本视图失效，仅向传输页与 SFTP 标签页传参；需要实时
    /// 刷新的叶子视图自行以 `@ObservedObject` 订阅。
    @Environment(\.transferStore) private var transfers
    // 通过自定义 EnvironmentKey 获取 TransferStore（传输队列管理器）
    // 不使用 @EnvironmentObject 是为了避免传输状态频繁变化时刷新整个工作区视图
    #if os(macOS)
    @EnvironmentObject private var chromeMetrics: MacOSWorkspaceChromeMetrics
    // macOS 专属：顶部工具栏的尺寸指标（红绿灯安全宽度、侧栏宽度等）
    #endif
    var body: some View {
        Group {
        #if os(macOS)
        macOSBody
        // macOS 平台使用自定义布局（包含顶部 chrome 工具栏）
        #else
        iOSBody
        // iPadOS 平台使用导航栏集成布局
        #endif
        }
        .onChange(of: workspace.activeTabID) { _, activeTabID in
            // .onChange 监听 workspace.activeTabID 的变化
            // 当活动标签 ID 改变时（如关闭标签、切换标签），执行以下逻辑
            // 仅当当前正在呈现页签时跟随 WorkspaceStore 的关闭/切换结果；
            // 查看主机详情时，后台 activeTabID 不应抢回内容区。
            guard case .tab = model.workspacePresentation else { return }
            // 只有当前正在显示标签页内容时才响应
            // 如果正在显示主机详情或其他页面，不处理
            if let activeTabID {
                model.presentTab(activeTabID)
                // 有新的活动标签 -> 呈现该标签的内容
            } else {
                model.workspacePresentation = .empty
                // 没有活动标签了（全部关闭）-> 显示空态
            }
        }
        .onChange(of: model.hosts.map(\.id)) { _, _ in
            // 监听主机列表 ID 的变化（添加或删除主机时）
            normalizePresentation()
            // 规范化呈现状态：如果当前显示的标签/主机已不存在，回退到有效状态
        }
    }

    /// 规范化呈现状态。
    /// 确保 workspacePresentation 中引用的主机 ID 和标签 ID 都是有效的。
    /// 如果引用了已删除的主机或标签，自动回退到空态或其他有效状态。
    private func normalizePresentation() {
        let normalized = model.workspacePresentation.normalized(
            validHostIDs: Set(model.hosts.map(\.id)),
            // 当前有效的主机 ID 集合
            validTabIDs: Set(workspace.tabs.map(\.id)),
            // 当前有效的标签 ID 集合
            fallbackTabID: workspace.activeTabID
            // 回退标签 ID（如果当前标签无效，使用活动标签）
        )
        if normalized != model.workspacePresentation {
            model.workspacePresentation = normalized
            // 只有规范化结果不同时才更新，避免不必要的视图刷新
        }
    }

    #if os(macOS)
    // MARK: - macOS 平台布局

    /// 退出保护状态：当有未保存的更改时，CMD+Q 退出会被拦截
    @State private var quitProtection = ApplicationQuitCoordinator.shared.quitProtection
    // 从全局退出协调器获取退出保护状态

    /// macOS 主布局：顶部 chrome 工具栏 + 分隔线 + 内容区
    private var macOSBody: some View {
        VStack(spacing: 0) {
            // 垂直栈，无间距（各区域紧密排列）
            UnifiedWorkspaceChrome(
                // 顶部工具栏：包含标签栏、流量统计等
                leadingReservedWidth: chromeMetrics.trafficLightSafeWidth,
                // 右侧不预留额外宽度，让 TabStrip 自动撑满剩余空间。
                // 窗口拖动区域已由左侧安全区（红绿灯）和 TabStrip 内部
                // 的 trailing macOSWindowDragRegion 提供，无需 Chrome 再留 80pt 空白。
                trailingReservedWidth: 0,
                sidebarWidth: chromeMetrics.sidebarWidth
            )
            Divider()
            // 工具栏和内容区之间的分隔线（一条细灰线）
            macOSUnifiedSplitView
            // 下方内容区：侧栏 + 主内容区的分割视图
        }
        // 顶部 chrome 与原生红绿灯处于同一行，由实测安全矩形避让。
        .ignoresSafeArea(.container, edges: .top)
        // .ignoresSafeArea 让视图延伸到屏幕顶部边缘
        // 这样顶部工具栏可以与 macOS 标题栏融为一体
        .modifier(macOSCloseAlerts)
        // .modifier 应用自定义视图修饰器：添加关闭确认弹窗
        .overlay(alignment: .bottom) {
            // .overlay 在视图底部叠加一层内容
            QuitProtectionToast(isVisible: quitProtection.pendingQuit)
            // 退出保护提示条：当有待处理的退出请求时显示
                .padding(.bottom, 24)
                // 距底部 24 点
                .animation(.easeInOut(duration: 0.2), value: quitProtection.pendingQuit)
                // 淡入淡出动画：0.2 秒缓入缓出
        }
        .background {
            // .background 在视图底层放置一个不可见的辅助视图
            // 拦截 CMD+W：在系统菜单处理前截获，关闭活动页签而非关闭窗口。
            CloseTabKeyInterceptor {
                // CloseTabKeyInterceptor 是一个自定义视图，拦截 CMD+W 按键
                if let activeID = workspace.activeTabID {
                    workspace.requestClose(tabID: activeID)
                    // 有活动标签时：关闭活动标签（而非关闭窗口）
                }
            }
            // 拦截 Ctrl+Tab / Ctrl+Shift+Tab：在 AppKit 事件层全局截获，
            // 避免被终端 NSView 抢走焦点导致 SwiftUI .onKeyPress 收不到事件。
            TabSwitchKeyInterceptor(
                onNext: { workspace.selectNextTab() },
                onPrevious: { workspace.selectPreviousTab() }
            )
        }
    }

    /// macOS 分割视图：左侧侧栏 + 右侧主内容区
    private var macOSUnifiedSplitView: some View {
        MacOSUnifiedSplitHost(
            // 自定义分割视图容器
            sidebar: SidebarView(),
            // 左侧：侧栏视图（主机列表、导航入口）
            detail: content.frame(maxWidth: .infinity, maxHeight: .infinity),
            // 右侧：主内容区，撑满可用空间
            policy: .resolve(
                requestedSidebarWidth: chromeMetrics.sidebarWidth,
                // 请求的侧栏宽度
                isSidebarVisible: model.columnVisibility != .detailOnly
                // 侧栏是否可见（当不是"仅详情"模式时显示侧栏）
            )
        )
    }

    /// macOS 关闭确认弹窗修饰器
    private var macOSCloseAlerts: some ViewModifier {
        MacOSCloseAlerts(workspace: workspace, pendingCloseTabTitle: pendingCloseTabTitle)
    }
    #endif

    #if os(macOS)
    /// macOS 关闭确认弹窗集合。
    /// 包含两种弹窗：
    /// 1. 批量关闭确认 —— 关闭多个已连接终端时
    /// 2. 单个关闭确认 —— 关闭单个已连接终端时
    private struct MacOSCloseAlerts: ViewModifier {
        @ObservedObject var workspace: WorkspaceStore
        // 观察工作区状态
        let pendingCloseTabTitle: String
        // 待关闭标签的标题（用于弹窗消息中显示）

        func body(content: Content) -> some View {
            content
        .alert(
            // 批量关闭确认弹窗
            "关闭已连接终端？",
            // 弹窗标题
            isPresented: Binding(
                get: { workspace.pendingBatchClose != nil },
                // 当有批量关闭请求时显示弹窗
                set: { if !$0 { workspace.cancelBatchClose() } }
                // 弹窗关闭时取消批量关闭
            )
        ) {
            Button("关闭并断开", role: .destructive) { workspace.confirmBatchClose() }
            // 确认按钮：红色破坏性样式，执行批量关闭
            Button("取消", role: .cancel) { workspace.cancelBatchClose() }
            // 取消按钮：取消操作
        } message: {
            Text("将关闭并断开 \(workspace.pendingBatchClose?.connectedTerminalCount ?? 0) 个已连接终端会话。")
            // 消息内容：显示将关闭的已连接终端数量
        }
        // 单个已连接终端标签关闭时，使用系统警告框明确呈现断开后果。
        .alert(
            // 单个关闭确认弹窗
            "关闭终端？",
            isPresented: Binding(
                get: { workspace.pendingCloseTabID != nil },
                // 当有单个标签关闭请求时显示
                set: { if !$0 { workspace.cancelClose() } }
                // 关闭弹窗时取消操作
            )
        ) {
            Button("关闭并断开", role: .destructive) { workspace.confirmClose() }
            Button("取消", role: .cancel) { workspace.cancelClose() }
        } message: {
            Text("关闭后将断开与「\(pendingCloseTabTitle)」的 SSH 连接。")
            // 显示将断开的连接名称
        }
        }
    }

    #endif

    #if os(iOS)
    // MARK: - iPadOS 平台布局

    /// iPadOS 页签复用系统导航栏，内容区不再叠加第二行顶部栏。
    /// 标签栏放在导航栏的 .principal 位置（中央区域）。
    private var iOSBody: some View {
        GeometryReader { geometry in
            // GeometryReader 获取父容器的尺寸信息
            content
            // 主内容区
                .alert(
                    // 单个关闭确认弹窗（与 macOS 逻辑相同）
                    "关闭终端？",
                    isPresented: Binding(
                        get: { workspace.pendingCloseTabID != nil },
                        set: { if !$0 { workspace.cancelClose() } }
                    )
                ) {
                    Button("关闭并断开", role: .destructive) { workspace.confirmClose() }
                    Button("取消", role: .cancel) { workspace.cancelClose() }
                } message: {
                    Text("关闭后将断开与「\(pendingCloseTabTitle)」的 SSH 连接。")
                }
                .alert(
                    // 批量关闭确认弹窗
                    "关闭已连接终端？",
                    isPresented: Binding(
                        get: { workspace.pendingBatchClose != nil },
                        set: { if !$0 { workspace.cancelBatchClose() } }
                    )
                ) {
                    Button("关闭并断开", role: .destructive) { workspace.confirmBatchClose() }
                    Button("取消", role: .cancel) { workspace.cancelBatchClose() }
                } message: {
                    Text("将关闭并断开 \(workspace.pendingBatchClose?.connectedTerminalCount ?? 0) 个已连接终端会话。")
                }
                .navigationBarTitleDisplayMode(.inline)
                // 导航栏标题模式：inline（小标题，不显示大标题）
                // 导航栏背景与页签的语义前景色保持同一主题，避免黑色终端透底。
                .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
                // 设置导航栏背景色为系统背景色（浅色模式=白色，深色模式=深灰）
                .toolbarBackground(.visible, for: .navigationBar)
                // 确保导航栏背景始终可见（不透明）
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        // placement: .principal 将内容放在导航栏中央
                        UnifiedWorkspaceTabStrip()
                        // 自定义标签栏视图
                            .frame(
                                width: IPadWorkspaceChromeHostPolicy.navigationTabStripWidth(
                                    availableWidth: geometry.size.width),
                                // 根据屏幕宽度计算标签栏宽度
                                height: 40
                                // 标签栏高度固定 40 点
                            )
                    }
                }
        }
    }

    #endif

    /// 待关闭标签在弹窗中使用当前标题；状态在显示期间失效时安全回退。
    /// 如果待关闭的标签已不存在（被关闭了），返回默认文本"此主机"。
    private var pendingCloseTabTitle: String {
        guard let id = workspace.pendingCloseTabID,
              let tab = workspace.tabs.first(where: { $0.id == id }) else {
            return "此主机"
            // 找不到标签时的默认文本
        }
        return tab.title
        // 返回标签的标题（通常是主机名）
    }

    /// 内容区:先按侧栏入口分支(片段/设置整页替换,与原型一致);
    /// 主机页内:有活动标签时按类型分发;无活动标签时回落到主机详情/空态
    /// (标签栏常驻);活动标签的主机被删除时给出提示。
    ///
    /// @ViewBuilder 允许用自然语法编写条件分支视图。
    @ViewBuilder
    private var content: some View {
        // 会话视图始终位于同一结构位置；切侧栏只隐藏，不能销毁 StateObject。
        ZStack {
            // ZStack 将子视图沿 Z 轴堆叠（后添加的在上面）
            // 使用 ZStack + opacity 而非条件渲染，是为了避免销毁终端视图的 StateObject
            hostsContent
            // 主机内容层（终端标签 + SFTP 标签 + 主机详情 + 空态）
                .opacity(model.sidebarPage == .hosts ? 1 : 0)
                // 当侧栏在"主机"页面时显示，否则透明
                .allowsHitTesting(model.sidebarPage == .hosts)
                // 不在"主机"页面时禁止交互（点击穿透到下层）
                .accessibilityHidden(model.sidebarPage != .hosts)
                // 不在"主机"页面时对 VoiceOver 隐藏
            switch model.sidebarPage {
            // 根据侧栏当前页面显示对应内容
            case .connectionMonitor: ConnectionMonitorView()
            // 连接监控页面
            case .transfers: TransferPageView(store: transfers)
            // 传输任务页面
            case .snippets: SnippetsView()
            // 片段管理页面
            case .settings: Color.clear
            // 设置页面（透明占位，实际设置可能以 sheet 形式呈现）
            case .logs: LogView(logger: Logger.shared)
            // 日志查看页面
            case .hosts: Color.clear.allowsHitTesting(false)
            // 主机页面：透明占位（实际内容由 hostsContent 渲染）
            }
        }
    }

    /// 主机内容区域：包含终端标签页、SFTP 标签页和非终端内容。
    /// 使用 ZStack 堆叠三层内容，通过 opacity 控制可见性。
    @ViewBuilder
    private var hostsContent: some View {
        let terminalPolicy = WorkspaceTerminalTabPolicy(
            tabs: workspace.tabs,
            activeTabID: presentedTabID
        )
        // 终端标签策略：决定哪些终端标签需要保留在视图树中
        let sftpPolicy = WorkspaceSftpTabPolicy(
            tabs: workspace.tabs,
            activeTabID: presentedTabID
        )
        // SFTP 标签策略：同理
        ZStack {
            nonTerminalHostsContent
            // 底层：非终端内容（主机详情、空态等）
            terminalTabs(policy: terminalPolicy)
            // 中层：所有终端标签（不可见的用 opacity=0 隐藏）
            sftpTabs(policy: sftpPolicy)
            // 顶层：所有 SFTP 标签
        }
        .focusable()
        // .focusable() 使视图可以接收键盘焦点（从而接收按键事件）
        .onKeyPress { press in
            // .onKeyPress 监听键盘按键事件
            // 仅在按下 Tab 键且包含 Control 修饰符时处理
            guard press.key == .tab, press.modifiers.contains(.control) else {
                return .ignored
                // 不是 Ctrl+Tab 组合 -> 忽略，让系统处理
            }
            if press.modifiers.contains(.shift) {
                // Ctrl+Shift+Tab: 切换到上一个页签
                workspace.selectPreviousTab()
            } else {
                // Ctrl+Tab: 切换到下一个页签
                workspace.selectNextTab()
            }
            return .handled
            // 返回 .handled 表示事件已被处理，不再传递给其他视图
        }
    }

    /// 当前正在呈现的标签 ID。
    /// 只有当侧栏在"主机"页面且工作区呈现状态为 .tab 时才返回有效值。
    private var presentedTabID: UUID? {
        guard model.sidebarPage == .hosts else { return nil }
        // 不在主机页面 -> 没有呈现的标签
        guard case .tab(let tabID) = model.workspacePresentation else { return nil }
        // 工作区不在标签模式 -> 没有呈现的标签
        return tabID
        // 返回正在呈现的标签 ID
    }

    /// 除终端外的工作区内容。终端由 `terminalTabs` 常驻承载，确保其
    /// `@StateObject` 不会随着活动标签变化而析构。
    ///
    /// 当活动标签是终端类型时，这里返回 Color.clear（透明占位），
    /// 实际的终端视图由 terminalTabs 渲染并保持在视图树中。
    @ViewBuilder
    private var nonTerminalHostsContent: some View {
        switch model.workspacePresentation {
        case .tab(let tabID):
            // 当前呈现某个标签
            if let active = workspace.tabs.first(where: { $0.id == tabID }) {
            // 找到了对应的标签
            if model.hosts.contains(where: { $0.id == active.hostID }) {
                // 标签对应的主机仍然存在
                switch active.kind {
                case .terminal:
                    Color.clear
                    // 终端标签 -> 透明占位（实际由 terminalTabs 渲染）
                case .sftp:
                    Color.clear
                    // SFTP 标签 -> 透明占位（实际由 sftpTabs 渲染）
                }
            } else {
                ContentUnavailableView(
                    // 主机已被删除 -> 显示提示
                    "标签页不可用",
                    systemImage: "questionmark.square.dashed",
                    // 虚线方块问号图标
                    description: Text("对应的主机可能已被删除,请关闭该标签页")
                )
            }
            } else {
                emptyStateView
                // 标签不存在 -> 显示空态
            }
        case .hostDetail(let hostID):
            // 当前呈现主机详情
            if let host = model.hosts.first(where: { $0.id == hostID }) {
                HostDetailView(host: host)
                // 主机存在 -> 显示详情视图
            } else {
                emptyStateView
                // 主机不存在 -> 显示空态
            }
        case .empty:
            emptyStateView
            // 空态 -> 显示引导界面
        }
    }

    /// 终端标签视图集合。
    /// 所有终端标签都保持在视图树中（不可见的用 opacity=0 隐藏），
    /// 这样 StateObject 不会被销毁，终端会话不会丢失。
    @ViewBuilder
    private func terminalTabs(policy: WorkspaceTerminalTabPolicy) -> some View {
        ForEach(policy.retainedTabs) { tab in
            // 遍历策略决定需要保留的终端标签
            if let host = model.hosts.first(where: { $0.id == tab.hostID }) {
                // 找到标签对应的主机
                let isVisible = policy.isVisible(tab.id) && model.sidebarPage == .hosts
                // 判断标签是否可见：策略允许 + 侧栏在主机页面
                TerminalTabView(tab: tab, host: host, isActive: isVisible)
                // 渲染终端标签视图
                    .opacity(isVisible ? 1 : 0)
                    // 可见时不透明，不可见时完全透明
                    .allowsHitTesting(isVisible)
                    // 可见时允许交互，不可见时点击穿透
                    .accessibilityHidden(!isVisible)
                    // 不可见时对 VoiceOver 隐藏
                    .zIndex(isVisible ? 1 : 0)
                    // 可见的标签 z 轴在上层，确保显示在最前面
            }
        }
    }

    /// SFTP 标签视图集合。
    /// 与 terminalTabs 同理，所有 SFTP 标签保持在视图树中。
    @ViewBuilder
    private func sftpTabs(policy: WorkspaceSftpTabPolicy) -> some View {
        ForEach(policy.retainedTabs) { tab in
            if let host = model.hosts.first(where: { $0.id == tab.hostID }) {
                let isVisible = policy.isVisible(tab.id)
                // SFTP 标签不需要检查侧栏页面（策略内部处理）
                SftpTabView(tab: tab, host: host, transfers: transfers)
                // 渲染 SFTP 文件浏览器标签视图
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .accessibilityHidden(!isVisible)
                    .zIndex(isVisible ? 1 : 0)
            }
        }
    }

    /// 主内容区空态:无标签页且无选中主机时显示。
    /// 根据是否有主机显示不同的引导信息：
    /// - 无主机 -> 提示"添加主机"
    /// - 有主机 -> 提示"选择主机"或"添加主机"
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            // 垂直栈，间距 16 点
            Spacer()
            // 上方弹性空间，将内容推到垂直居中
            Image(systemName: model.hosts.isEmpty ? "server.rack" : "rectangle.split.2x1")
            // 根据是否有主机显示不同图标
            // 无主机：服务器机架图标；有主机：分屏矩形图标
                .font(.system(size: 44, weight: .light))
                // 字体：系统字体，44 点大小，light 细体
                .foregroundStyle(.secondary)
                // 次要颜色（灰色）
                .accessibilityHidden(true)
                // 对 VoiceOver 隐藏（装饰性图标，不需要朗读）
            Text(model.hosts.isEmpty ? "还没有主机" : "选择一个主机")
            // 主标题文字
                .font(.title2).bold()
                // title2 字体（约 22pt）+ 粗体
            Text(model.hosts.isEmpty ? "添加主机后即可打开终端或浏览文件" : "从侧栏查看主机详情，再选择终端或 SFTP")
            // 副标题描述文字
                .font(.callout)
                // callout 字体（约 14pt）
                .foregroundStyle(.secondary)
                // 灰色文字
            if model.hosts.isEmpty {
                // 无主机：只显示一个"添加主机"按钮
                Button {
                    performEmptyStateAction(.addHost)
                    // 点击后执行添加主机操作
                } label: {
                    Label("添加主机", systemImage: "plus")
                    // 加号图标 + "添加主机"文字
                }
                .buttonStyle(.borderedProminent)
                // .borderedProminent 使用突出的带边框按钮样式（填充强调色背景）
            } else {
                // 有主机：显示"选择主机"和"添加主机"两个按钮
                HStack(spacing: 12) {
                    // 水平排列，间距 12 点
                    Button {
                        performEmptyStateAction(.chooseHost)
                    } label: {
                        Label("选择主机", systemImage: "sidebar.left")
                        // 侧栏图标 + "选择主机"文字
                    }
                    .buttonStyle(.borderedProminent)
                    // 突出样式（强调色背景）
                    Button {
                        performEmptyStateAction(.addHost)
                    } label: {
                        Label("添加主机", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    // .bordered 普通边框样式（无填充色，只有边框）
                }
            }
            Spacer()
                .frame(height: 4)
            // 底部留 4 点空白
            Spacer()
            // 继续撑满剩余空间
        }
        .frame(maxWidth: .infinity)
        // 水平方向撑满父容器
        .padding(24)
        // 四周内边距 24 点
    }

    /// 执行空态视图中的按钮操作。
    /// 根据操作类型和当前状态，执行显示侧栏或弹出添加主机表单等操作。
    /// - Parameter action: 空态操作类型（.chooseHost 或 .addHost）
    private func performEmptyStateAction(_ action: WorkspaceEmptyStateAction) {
        let command = WorkspaceEmptyStateRouter.command(
            for: action,
            hostCount: model.hosts.count,
            isSidebarVisible: model.columnVisibility != .detailOnly
        )
        // 通过路由器决定具体执行什么命令
        switch command {
        case .revealHostList, .focusHostList:
            withAnimation { model.columnVisibility = .all }
            // 显示侧栏（带动画），.all 表示同时显示侧栏和内容区
        case .addHost:
            model.sidebarSheet = .addHost(defaultGroupID: nil)
            // 弹出添加主机的 sheet 表单
        }
    }
}

#if DEBUG
// #if DEBUG 确保预览代码只在调试构建中编译，不会进入正式发布
#Preview("工作区(含同主机多标签)") {
    // Xcode 预览：展示工作区视图，包含同主机多标签的场景
    WorkspaceView()
        .environmentObject(AppModel.previewModel())
        // 注入预览用的 AppModel（包含示例数据）
        .environmentObject(WorkspaceStore.previewStore())
        // 注入预览用的 WorkspaceStore（包含示例标签）
        .transferStore(TransferStore())
        // 注入空的传输队列
        .environmentObject(ToastCenter())
        // 注入 Toast 通知中心
}
#endif

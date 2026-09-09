import SwiftUI

/// 多标签页工作区容器:顶部自定义标签栏(纯 SwiftUI,双端共享,
/// 不依赖 NSTabView/UITabView),内容区按活动标签类型分发到
/// 终端视图或 SFTP 文件浏览器。
struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    /// 传输队列以非订阅环境值取引用（不观察）：传输期间 5Hz 状态发布
    /// 不再使本视图失效，仅向传输页与 SFTP 标签页传参；需要实时
    /// 刷新的叶子视图自行以 `@ObservedObject` 订阅。
    @Environment(\.transferStore) private var transfers
    #if os(macOS)
    @EnvironmentObject private var chromeMetrics: MacOSWorkspaceChromeMetrics
    #endif
    var body: some View {
        Group {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
        }
        .onChange(of: workspace.activeTabID) { _, activeTabID in
            // 仅当当前正在呈现页签时跟随 WorkspaceStore 的关闭/切换结果；
            // 查看主机详情时，后台 activeTabID 不应抢回内容区。
            guard case .tab = model.workspacePresentation else { return }
            if let activeTabID {
                model.presentTab(activeTabID)
            } else {
                model.workspacePresentation = .empty
            }
        }
        .onChange(of: model.hosts.map(\.id)) { _, _ in
            normalizePresentation()
        }
    }

    private func normalizePresentation() {
        let normalized = model.workspacePresentation.normalized(
            validHostIDs: Set(model.hosts.map(\.id)),
            validTabIDs: Set(workspace.tabs.map(\.id)),
            fallbackTabID: workspace.activeTabID
        )
        if normalized != model.workspacePresentation {
            model.workspacePresentation = normalized
        }
    }

    #if os(macOS)
    private var macOSBody: some View {
        VStack(spacing: 0) {
            UnifiedWorkspaceChrome(
                leadingReservedWidth: chromeMetrics.trafficLightSafeWidth,
                sidebarWidth: chromeMetrics.sidebarWidth
            )
            .background(WindowDragView())
            Divider()
            macOSUnifiedSplitView
        }
        // 顶部 chrome 与原生红绿灯处于同一行，由实测安全矩形避让。
        .ignoresSafeArea(.container, edges: .top)
        .modifier(macOSCloseAlerts)
    }

    private var macOSUnifiedSplitView: some View {
        MacOSUnifiedSplitHost(
            sidebar: SidebarView(),
            detail: content.frame(maxWidth: .infinity, maxHeight: .infinity),
            policy: .resolve(
                requestedSidebarWidth: chromeMetrics.sidebarWidth,
                isSidebarVisible: model.columnVisibility != .detailOnly
            )
        )
    }

    private var macOSCloseAlerts: some ViewModifier {
        MacOSCloseAlerts(workspace: workspace, pendingCloseTabTitle: pendingCloseTabTitle)
    }
    #endif

    #if os(macOS)
    private struct MacOSCloseAlerts: ViewModifier {
        @ObservedObject var workspace: WorkspaceStore
        let pendingCloseTabTitle: String

        func body(content: Content) -> some View {
            content
        .alert(
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
        // 单个已连接终端标签关闭时，使用系统警告框明确呈现断开后果。
        .alert(
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
        }
    }

    #endif

    #if os(iOS)
    /// iPadOS 页签复用系统导航栏，内容区不再叠加第二行顶部栏。
    private var iOSBody: some View {
        GeometryReader { geometry in
            content
                .alert(
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
                // 导航栏背景与页签的语义前景色保持同一主题，避免黑色终端透底。
                .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        UnifiedWorkspaceTabStrip()
                            .frame(
                                width: IPadWorkspaceChromeHostPolicy.navigationTabStripWidth(
                                    availableWidth: geometry.size.width),
                                height: 40
                            )
                    }
                }
        }
    }

    #endif

    /// 待关闭标签在弹窗中使用当前标题；状态在显示期间失效时安全回退。
    private var pendingCloseTabTitle: String {
        guard let id = workspace.pendingCloseTabID,
              let tab = workspace.tabs.first(where: { $0.id == id }) else {
            return "此主机"
        }
        return tab.title
    }

    /// 内容区:先按侧栏入口分支(片段/设置整页替换,与原型一致);
    /// 主机页内:有活动标签时按类型分发;无活动标签时回落到主机详情/空态
    /// (标签栏常驻);活动标签的主机被删除时给出提示。
    @ViewBuilder
    private var content: some View {
        // 会话视图始终位于同一结构位置；切侧栏只隐藏，不能销毁 StateObject。
        ZStack {
            hostsContent
                .opacity(model.sidebarPage == .hosts ? 1 : 0)
                .allowsHitTesting(model.sidebarPage == .hosts)
                .accessibilityHidden(model.sidebarPage != .hosts)
            switch model.sidebarPage {
            case .connectionMonitor: ConnectionMonitorView()
            case .transfers: TransferPageView(store: transfers)
            case .snippets: SnippetsView()
            case .settings:
                #if os(iOS)
                SettingsView()
                #else
                Color.clear
                #endif
            case .logs: LogView(logger: Logger.shared)
            case .hosts: Color.clear.allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var hostsContent: some View {
        let terminalPolicy = WorkspaceTerminalTabPolicy(
            tabs: workspace.tabs,
            activeTabID: presentedTabID
        )
        let sftpPolicy = WorkspaceSftpTabPolicy(
            tabs: workspace.tabs,
            activeTabID: presentedTabID
        )
        ZStack {
            nonTerminalHostsContent
            terminalTabs(policy: terminalPolicy)
            sftpTabs(policy: sftpPolicy)
        }
    }

    private var presentedTabID: UUID? {
        guard model.sidebarPage == .hosts else { return nil }
        guard case .tab(let tabID) = model.workspacePresentation else { return nil }
        return tabID
    }

    /// 除终端外的工作区内容。终端由 `terminalTabs` 常驻承载，确保其
    /// `@StateObject` 不会随着活动标签变化而析构。
    @ViewBuilder
    private var nonTerminalHostsContent: some View {
        switch model.workspacePresentation {
        case .tab(let tabID):
            if let active = workspace.tabs.first(where: { $0.id == tabID }) {
            if model.hosts.contains(where: { $0.id == active.hostID }) {
                switch active.kind {
                case .terminal:
                    Color.clear
                case .sftp:
                    Color.clear
                }
            } else {
                ContentUnavailableView(
                    "标签页不可用",
                    systemImage: "questionmark.square.dashed",
                    description: Text("对应的主机可能已被删除,请关闭该标签页")
                )
            }
            } else {
                emptyStateView
            }
        case .hostDetail(let hostID):
            if let host = model.hosts.first(where: { $0.id == hostID }) {
                HostDetailView(host: host)
            } else {
                emptyStateView
            }
        case .empty:
            emptyStateView
        }
    }

    @ViewBuilder
    private func terminalTabs(policy: WorkspaceTerminalTabPolicy) -> some View {
        ForEach(policy.retainedTabs) { tab in
            if let host = model.hosts.first(where: { $0.id == tab.hostID }) {
                let isVisible = policy.isVisible(tab.id) && model.sidebarPage == .hosts
                TerminalTabView(tab: tab, host: host, isActive: isVisible)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .accessibilityHidden(!isVisible)
                    .zIndex(isVisible ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func sftpTabs(policy: WorkspaceSftpTabPolicy) -> some View {
        ForEach(policy.retainedTabs) { tab in
            if let host = model.hosts.first(where: { $0.id == tab.hostID }) {
                let isVisible = policy.isVisible(tab.id)
                SftpTabView(tab: tab, host: host, transfers: transfers)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .accessibilityHidden(!isVisible)
                    .zIndex(isVisible ? 1 : 0)
            }
        }
    }

    /// 主内容区空态:无标签页且无选中主机时显示。
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: model.hosts.isEmpty ? "server.rack" : "rectangle.split.2x1")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.hosts.isEmpty ? "还没有主机" : "选择一个主机")
                .font(.title2).bold()
            Text(model.hosts.isEmpty ? "添加主机后即可打开终端或浏览文件" : "从侧栏查看主机详情，再选择终端或 SFTP")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.hosts.isEmpty {
                Button {
                    performEmptyStateAction(.addHost)
                } label: {
                    Label("添加主机", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 12) {
                    Button {
                        performEmptyStateAction(.chooseHost)
                    } label: {
                        Label("选择主机", systemImage: "sidebar.left")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        performEmptyStateAction(.addHost)
                    } label: {
                        Label("添加主机", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer()
                .frame(height: 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func performEmptyStateAction(_ action: WorkspaceEmptyStateAction) {
        let command = WorkspaceEmptyStateRouter.command(
            for: action,
            hostCount: model.hosts.count,
            isSidebarVisible: model.columnVisibility != .detailOnly
        )
        switch command {
        case .revealHostList, .focusHostList:
            withAnimation { model.columnVisibility = .all }
        case .addHost:
            model.sidebarSheet = .addHost(defaultGroupID: nil)
        }
    }
}

#if DEBUG
#Preview("工作区(含同主机多标签)") {
    WorkspaceView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .transferStore(TransferStore())
        .environmentObject(ToastCenter())
}
#endif

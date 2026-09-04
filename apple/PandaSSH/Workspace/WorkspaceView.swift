import SwiftUI

/// 多标签页工作区容器:顶部自定义标签栏(纯 SwiftUI,双端共享,
/// 不依赖 NSTabView/UITabView),内容区按活动标签类型分发到
/// 终端视图或 SFTP 文件浏览器。
struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var transfers: TransferStore

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
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if !workspace.tabs.isEmpty {
                    macOSTabBar
                    Divider()
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 「添加主机 / 新建分组」入口在侧栏顶部工具条(见 SidebarView.sidebarTopBar);
        // 弹层状态在 AppModel.sidebarSheet,sheet 由 HostListView 统一挂载。
        // 批量关闭含已连接终端时，使用系统警告框明确呈现断开后果。
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

    private var macOSTabBar: some View {
        WorkspaceTabBar()
            .environmentObject(model)
            .environmentObject(workspace)
            .frame(maxWidth: .infinity)
    }
    #endif

    #if os(iOS)
    private var iOSBody: some View {
        VStack(spacing: 0) {
            // 批量关闭含已连接终端的聚合确认挂在标签栏上。
            iosTabBar
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
            Divider()
            // 单个已连接终端标签关闭二次确认挂在内容区上。
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

    /// 横向滚动的标签栏;标签过多时可滑动,iPadOS 紧凑宽度下不拥挤。
    private var iosTabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        WorkspaceTabItemView(
                            tab: tab,
                            isActive: model.workspacePresentation == .tab(tabID: tab.id),
                            onSelect: {
                                workspace.select(tabID: tab.id)
                                model.presentTab(tab.id)
                            },
                            onClose: { workspace.requestClose(tabID: tab.id) }
                        )
                        // 右键菜单(macOS)/长按菜单(iPadOS):重连 / 关闭其他 / 关闭全部(item 2)
                        .contextMenu {
                            if tab.kind == .terminal {
                                Button {
                                    workspace.reconnectTerminal(tabID: tab.id)
                                } label: {
                                    Label("重连", systemImage: "arrow.clockwise")
                                }
                                Divider()
                            }
                            Button {
                                workspace.requestCloseOthers(keeping: tab.id)
                            } label: {
                                Label("关闭其他标签页", systemImage: "xmark")
                            }
                            Button(role: .destructive) {
                                workspace.requestCloseAll()
                            } label: {
                                Label("关闭全部标签页", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
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
                let isVisible = policy.isVisible(tab.id)
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

/// 单个标签:浏览器风格胶囊标签,hover 显关闭按钮,选中态有背景。
struct WorkspaceTabItemView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let tab: WorkspaceTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    private var metrics: WorkspaceTabPresentationMetrics {
        WorkspaceTabPresentationMetrics.resolve(
            platform: .iPadOS,
            isActive: isActive,
            isHovered: hovering,
            availableWidth: WorkspaceTabPresentationMetrics.maximumTitleWidth,
            titleCharacterCount: tab.title.count
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Image(systemName: tab.kind == .terminal ? "terminal" : "folder")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: metrics.maximumTitleWidth, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: metrics.minimumHitTarget, height: metrics.minimumHitTarget)
                    .contentShape(
                        RoundedRectangle(cornerRadius: metrics.closeButtonCornerRadius, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(
                hovering ? Color.primary.opacity(0.12) : Color.clear,
                in: Circle()
            )
            .opacity(metrics.showsCloseButton ? 1 : 0)
            .allowsHitTesting(metrics.showsCloseButton)
            .accessibilityLabel("关闭 \(tab.title)")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: metrics.minimumTabHeight)
        .background(
            isActive ? Color.primary.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .gesture(
            TapGesture().onEnded(onSelect),
            including: metrics.selectionGestureIncludesSubviews ? .all : .gesture
        )
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityValue(statusLabel)
        .accessibilityHint("切换到此标签页")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
        .accessibilityElement(children: .contain)
    }

    private var dotColor: Color {
        switch workspace.connectionStatus(forTabID: tab.id) {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .inactive: return Color(.gray).opacity(0.6)
        }
    }

    private var statusLabel: String {
        switch workspace.connectionStatus(forTabID: tab.id) {
        case .connected: return "SSH 会话已连接"
        case .connecting: return "正在建立 SSH 会话"
        case .failed: return "SSH 会话已断开或连接失败"
        case .inactive: return "SSH 会话未建立"
        }
    }
}

#if DEBUG
#Preview("工作区(含同主机多标签)") {
    WorkspaceView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .environmentObject(TransferStore())
        .environmentObject(ToastCenter())
}
#endif

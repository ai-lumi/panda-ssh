import SwiftUI

/// 多标签页工作区容器:顶部自定义标签栏(纯 SwiftUI,双端共享,
/// 不依赖 NSTabView/UITabView),内容区按活动标签类型分发到
/// 终端视图或 SFTP 文件浏览器。
struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var transfers: TransferStore

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 400)
        } detail: {
        VStack(spacing: 0) {
            macOSTabBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        }
        // 「添加主机 / 新建分组」入口在侧栏顶部工具条(见 SidebarView.sidebarTopBar);
        // 弹层状态在 AppModel.sidebarSheet,sheet 由 HostListView 统一挂载。
        // 批量关闭含已连接终端的聚合确认(item 2.5)。
        .confirmationDialog(
            workspace.pendingBatchClose.map { "关闭 \($0.connectedTerminalCount) 个已连接终端会话，是否继续？" } ?? "",
            isPresented: Binding(
                get: { workspace.pendingBatchClose != nil },
                set: { if !$0 { workspace.cancelBatchClose() } }
            ),
            titleVisibility: .visible
        ) {
            Button("关闭", role: .destructive) { workspace.confirmBatchClose() }
            Button("取消", role: .cancel) { workspace.cancelBatchClose() }
        }
        // 单个已连接终端标签关闭二次确认(item 3)。
        .confirmationDialog(
            "关闭终端将断开会话，是否继续？",
            isPresented: Binding(
                get: { workspace.pendingCloseTabID != nil },
                set: { if !$0 { workspace.cancelClose() } }
                ),
            titleVisibility: .visible
        ) {
            Button("关闭", role: .destructive) { workspace.confirmClose() }
            Button("取消", role: .cancel) { workspace.cancelClose() }
        }
        // 移除 NavigationSplitView 自动注入的 `>>` 侧栏切换按钮(workspace spec「主窗口工具栏精简」)。
        .toolbar(removing: .sidebarToggle)
    }
    #endif

    #if os(iOS)
    private var iOSBody: some View {
        VStack(spacing: 0) {
            // 批量关闭含已连接终端的聚合确认(item 2.5)挂在标签栏上。
            iosTabBar
                .confirmationDialog(
                    workspace.pendingBatchClose.map { "关闭 \($0.connectedTerminalCount) 个已连接终端会话，是否继续？" } ?? "",
                    isPresented: Binding(
                        get: { workspace.pendingBatchClose != nil },
                        set: { if !$0 { workspace.cancelBatchClose() } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("关闭", role: .destructive) { workspace.confirmBatchClose() }
                    Button("取消", role: .cancel) { workspace.cancelBatchClose() }
                }
            Divider()
            // 单个已连接终端标签关闭二次确认(item 3)挂在内容区上。
            content
                .confirmationDialog(
                    "关闭终端将断开会话，是否继续？",
                    isPresented: Binding(
                        get: { workspace.pendingCloseTabID != nil },
                        set: { if !$0 { workspace.cancelClose() } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("关闭", role: .destructive) { workspace.confirmClose() }
                    Button("取消", role: .cancel) { workspace.cancelClose() }
                }
        }
    }
    #endif

    #if os(macOS)
    private var macOSTabBar: some View {
        // 系统工具栏已由 MainWindowChrome 移除:侧栏隐藏时在此提供
        // 「显示侧栏」按钮(侧栏可见时切换按钮在侧栏顶部工具条);
        // 整行背景挂 WindowDragView,空白处可拖拽窗口。
        HStack(spacing: 4) {
            if model.columnVisibility == .detailOnly {
                Button {
                    withAnimation { model.columnVisibility = .all }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .help("显示侧栏")
                .padding(.horizontal, 8)
            }
            WorkspaceTabBar()
                .environmentObject(model)
                .environmentObject(workspace)
        }
        .background(WindowDragView())
    }
    #endif

    /// 横向滚动的标签栏;标签过多时可滑动,iPadOS 紧凑宽度下不拥挤。
    private var iosTabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        WorkspaceTabItemView(
                            tab: tab,
                            isActive: tab.id == workspace.activeTabID,
                            onSelect: {
                                workspace.select(tabID: tab.id)
                                // 点击标签回到主机页(片段/设置页整页替换工作区内容)
                                model.sidebarPage = .hosts
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
        switch model.sidebarPage {
        case .snippets:
            SnippetsView()
        case .settings:
            #if os(iOS)
            SettingsView()
            #else
            // macOS 走原生 Settings Scene(cmd+,),侧栏无设置入口
            hostsContent
            #endif
        case .logs:
            LogView(logger: Logger.shared)
        case .hosts:
            hostsContent
        }
    }

    @ViewBuilder
    private var hostsContent: some View {
        if let active = workspace.tabs.first(where: { $0.id == workspace.activeTabID }) {
            if let host = model.hosts.first(where: { $0.id == active.hostID }) {
                // 终端/SFTP 标签内部按 preconnectAction 走连接门控(TOFU/告警/密码)
                // .id(active.id) 强制 SwiftUI 按标签身份管理视图生命周期:
                // 切换同类型标签时销毁旧视图(释放 Metal 渲染器/SwiftTerm 缓冲区/SSH 连接),
                // 创建新视图(重新连接),避免资源堆积导致内存持续增长。
                switch active.kind {
                case .terminal:
                    TerminalTabView(tab: active, host: host)
                        .id(active.id)
                case .sftp:
                    SftpTabView(tab: active, host: host, transfers: transfers)
                        .id(active.id)
                }
            } else {
                ContentUnavailableView(
                    "标签页不可用",
                    systemImage: "questionmark.square.dashed",
                    description: Text("对应的主机可能已被删除,请关闭该标签页")
                )
            }
        } else if let id = model.selectedHostID,
                  let host = model.hosts.first(where: { $0.id == id }) {
            HostDetailView(host: host)
        } else {
            emptyStateView
        }
    }

    /// 主内容区空态:无标签页且无选中主机时显示。
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            Text("尚未连接")
                .font(.title2).bold()
            Text("选择一个主机或打开一个已有的连接")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    // 快速连接:选中第一个可用主机并打开终端
                    if let firstHost = model.hosts.first {
                        model.selectHost(firstHost.id)
                        workspace.openTerminal(hostID: firstHost.id)
                    }
                } label: {
                    Label("快速连接", systemImage: "bolt")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    // 打开连接:聚焦侧栏搜索或选中第一台主机
                    if let firstHost = model.hosts.first {
                        model.selectHost(firstHost.id)
                    }
                } label: {
                    Label("打开连接", systemImage: "server.rack")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// 单个标签:浏览器风格胶囊标签,hover 显关闭按钮,选中态有背景。
struct WorkspaceTabItemView: View {
    let tab: WorkspaceTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.kind == .terminal ? "terminal" : "folder")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(
                hovering ? Color.primary.opacity(0.12) : Color.clear,
                in: Circle()
            )
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("关闭标签页")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isActive ? Color.primary.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
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

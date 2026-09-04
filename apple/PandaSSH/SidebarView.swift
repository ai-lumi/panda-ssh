import SwiftUI

/// 侧栏弹层枚举,供 SidebarView 与相关 sheet 共享。
enum SidebarSheetKind: Identifiable {
    /// defaultGroupID 为 nil 表示按当前选中态自动推断(选中分组 > 选中主机所在分组)
    case addHost(defaultGroupID: String?)
    case editHost(HostEntry)
    case copyHost(HostEntry)
    /// parent 为 nil 表示在根级新建
    case newGroup(parent: HostGroup?)
    case renameGroup(HostGroup)

    var id: String {
        switch self {
        case .addHost(let gid): "addHost-\(gid ?? "auto")"
        case .editHost(let host): "editHost-\(host.id)"
        case .copyHost(let host): "copyHost-\(host.id)"
        case .newGroup(let parent): "newGroup-\(parent?.id ?? "root")"
        case .renameGroup(let group): "renameGroup-\(group.id)"
        }
    }
}

extension SidebarSheetKind {
    /// 根据弹层类型生成对应的 sheet 内容视图。
    @MainActor
    @ViewBuilder
    func sheetContent(model: AppModel, workspace: WorkspaceStore, toast: ToastCenter) -> some View {
        switch self {
        case .addHost(let defaultGroupID):
            HostEditView(host: nil, defaultGroupID: defaultGroupID ?? model.groupIDForNewHost)
        case .editHost(let host):
            HostEditView(host: host)
        case .copyHost(let host):
            HostEditView(copySource: host)
        case .newGroup(let parent):
            GroupNameSheet(
                title: parent == nil ? "新建分组" : "新建子分组",
                message: parent.map { "在「\($0.name)」下创建子分组：" } ?? "在根级创建新分组："
            ) { name in
                model.createGroup(name: name, parentID: parent?.id)
                toast.show("分组已创建")
            }
        case .renameGroup(let group):
            GroupNameSheet(title: "重命名分组", initial: group.name) { name in
                model.renameGroup(id: group.id, name: name)
                toast.show("分组已重命名")
            }
        }
    }
}

/// 侧栏:搜索框 + 分组树 + 底部固定入口(代码片段/设置)。
/// 布局与交互参照 prototype/index.html;右键菜单 macOS/iPadOS 统一走 contextMenu
/// (macOS 右键、iPadOS 长按)。
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var toast: ToastCenter
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var searchText = ""
    @State private var hostPendingDelete: HostEntry?
    @State private var groupPendingDelete: HostGroup?

    private var callbacks: SidebarCallbacks {
        SidebarCallbacks(
            openTerminal: { model.presentTab(workspace.openTerminal(hostID: $0.id)) },
            openSFTP: { model.presentTab(workspace.openSFTP(hostID: $0.id)) },
            editHost: { model.sidebarSheet = .editHost($0) },
            copyHost: { model.sidebarSheet = .copyHost($0) },
            deleteHost: { hostPendingDelete = $0 },
            newSubgroup: { model.sidebarSheet = .newGroup(parent: $0) },
            renameGroup: { model.sidebarSheet = .renameGroup($0) },
            deleteGroup: { groupPendingDelete = $0 },
            addHostInGroup: { model.sidebarSheet = .addHost(defaultGroupID: $0.id) }
        )
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var matchedHosts: [HostEntry] {
        HostSearch.filter(hosts: model.hosts, groups: model.groups, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            searchField
            #endif
            treeView
            Divider()
            bottomEntries
        }
        #if os(macOS)
        // 让侧栏表面延伸进统一系统工具栏，与 macOS 26 浮动侧栏保持连续。
        .ignoresSafeArea(.container, edges: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.sidebarSheet = .addHost(defaultGroupID: nil)
                } label: {
                    Label("添加主机", systemImage: "plus")
                }
                .help("添加主机")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.sidebarSheet = .newGroup(parent: nil)
                } label: {
                    Label("新建分组", systemImage: "folder.badge.plus")
                }
                .help("新建分组")
            }
        }
        #endif
        #if os(iOS)
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索主机")
        // iPadOS 添加入口:macOS 在侧栏顶部自绘工具条,iPadOS 用系统导航栏按钮。
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.sidebarSheet = .addHost(defaultGroupID: nil)
                } label: {
                    Label("添加主机", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.sidebarSheet = .newGroup(parent: nil)
                } label: {
                    Label("新建分组", systemImage: "folder.badge.plus")
                }
            }
        }
        #endif
        .alert("删除主机", isPresented: hasPendingHost, presenting: hostPendingDelete) { host in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                model.deleteHost(id: host.id)
                workspace.closeTabs(forHostID: host.id)
                toast.show("主机已删除")
            }
        } message: { host in
            Text("确定删除「\(host.name)」吗？此操作不可撤销。")
        }
        .alert("删除分组", isPresented: hasPendingGroup, presenting: groupPendingDelete) { group in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                model.deleteGroup(id: group.id)
                toast.show("分组已删除，主机已移回根级")
            }
        } message: { group in
            Text("确定删除分组「\(group.name)」吗？组内主机将移回根级，子分组将一并删除。")
        }
    }

    private var hasPendingHost: Binding<Bool> {
        Binding(get: { hostPendingDelete != nil }, set: { if !$0 { hostPendingDelete = nil } })
    }

    private var hasPendingGroup: Binding<Bool> {
        Binding(get: { groupPendingDelete != nil }, set: { if !$0 { groupPendingDelete = nil } })
    }

    #if os(macOS)
    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索主机", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
    #endif

    // MARK: 分组树

    /// 节点树(分组 + 主机),由 SidebarTree 纯函数构建,OutlineGroup 渲染。
    private var treeNodes: [SidebarNode] {
        SidebarTree.build(hosts: model.hosts, groups: model.groups)
    }

    /// List 选中态与 AppModel 的双向映射:节点 id 带 group-/host- 前缀,
    /// 选中主机/分组走各自的 select 方法(互斥,单一选中语义)。
    private var nodeSelection: Binding<String?> {
        Binding(
            get: {
                if let hostID = model.selectedHostID { return SidebarNode.hostID(hostID) }
                if let groupID = model.selectedGroupID { return SidebarNode.groupID(groupID) }
                return nil
            },
            set: { newValue in
                guard let raw = newValue, let parsed = SidebarNode.parse(id: raw) else { return }
                if parsed.isGroup {
                    model.selectGroup(parsed.rawID)
                } else {
                    model.selectHost(parsed.rawID)
                }
            }
        )
    }

    /// 原生树形组件:OutlineGroup 负责缩进、展开三角与层级渲染,
    /// List 负责选中高亮与滚动;搜索模式下平铺匹配结果。
    private var treeView: some View {
        List(selection: nodeSelection) {
            if isSearching {
                if matchedHosts.isEmpty {
                    Text("无匹配主机")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                } else {
                    ForEach(matchedHosts) { host in
                        HostRowView(host: host, callbacks: callbacks)
                            .tag(SidebarNode.hostID(host.id))
                    }
                }
            } else {
                OutlineGroup(treeNodes, children: \.children) { node in
                    if let group = node.group {
                        GroupRowView(group: group, callbacks: callbacks)
                            .tag(node.id)
                    } else if let host = node.host {
                        HostRowView(host: host, callbacks: callbacks)
                            .tag(node.id)
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.plain)
        #else
        .listStyle(.sidebar)
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部固定入口

    private var bottomEntries: some View {
        VStack(spacing: 2) {
            #if os(macOS)
            SideEntryButton(
                title: "连接监控",
                systemImage: "network",
                isActive: false,
                action: {
                    model.showConnectionMonitor()
                    openConnectionMonitorWindow()
                }
            )
            #else
            SideEntryButton(
                title: "连接监控",
                systemImage: "network",
                isActive: model.sidebarPage == .connectionMonitor,
                action: model.showConnectionMonitor
            )
            #endif
            SideEntryButton(
                title: "代码片段",
                systemImage: "chevron.left.forwardslash.chevron.right",
                isActive: model.sidebarPage == .snippets,
                action: model.showSnippets
            )
            #if os(iOS)
            SideEntryButton(
                title: "设置",
                systemImage: "gearshape",
                isActive: model.sidebarPage == .settings,
                action: model.showSettings
            )
            #endif
            #if os(macOS)
            SideEntryButton(
                title: "日志",
                systemImage: "list.bullet.rectangle",
                isActive: false,
                action: { openLogWindow() }
            )
            #else
            SideEntryButton(
                title: "日志",
                systemImage: "list.bullet.rectangle",
                isActive: model.sidebarPage == .logs,
                action: model.showLogs
            )
            #endif
        }
        .padding(6)
    }

    #if os(macOS)
    private func openConnectionMonitorWindow() {
        // 与日志入口一致：优先激活已有窗口，避免重复打开。
        for window in NSApp.windows where window.title == ConnectionMonitorWindow.title {
            window.makeKeyAndOrderFront(nil)
            return
        }
        openWindow(id: ConnectionMonitorWindow.id)
    }

    private func openLogWindow() {
        // 优先激活已存在的日志窗口,否则由 SwiftUI 创建新窗口
        for window in NSApp.windows where window.title == "日志" {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 窗口不存在时通过环境值打开
        openWindow(id: "panda-log")
    }
    #endif
}

/// 侧栏行的动作回调集合,供递归节点视图向上传递菜单动作。
struct SidebarCallbacks {
    var openTerminal: (HostEntry) -> Void
    var openSFTP: (HostEntry) -> Void
    var editHost: (HostEntry) -> Void
    var copyHost: (HostEntry) -> Void
    var deleteHost: (HostEntry) -> Void
    var newSubgroup: (HostGroup) -> Void
    var renameGroup: (HostGroup) -> Void
    var deleteGroup: (HostGroup) -> Void
    var addHostInGroup: (HostGroup) -> Void
}

/// 主机行:状态圆点 + 两行(名称粗体 + user@host:port 灰小字)。
/// 作为 List/OutlineGroup 的行使用:单击选中由 List 负责,双击打开终端。
struct HostRowView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    let host: HostEntry
    let callbacks: SidebarCallbacks

    /// 状态圆点只表达当前已打开会话的可达性；主机密钥验证状态是独立安全信息，
    /// 不再以绿色伪装为“可连接”。
    private var dotColor: Color {
        workspace.connectionStatus(forHostID: host.id) == .connected
            ? .green
            : Color(.gray).opacity(0.6)
    }

    private var dotTip: String {
        switch workspace.connectionStatus(forHostID: host.id) {
        case .connected: return "当前存在可用 SSH 会话"
        case .connecting: return "正在建立 SSH 会话"
        case .failed: return "当前 SSH 会话不可达"
        case .inactive: return "当前未建立 SSH 会话"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .help(dotTip)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(host.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // 显式处理单击选中,避免 OutlineGroup 中行手势与 List 选中冲突。
        .simultaneousGesture(TapGesture(count: 1).onEnded { model.selectHost(host.id) })
        .contextMenu { hostMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host.name)，\(host.subtitle)")
        .accessibilityValue(dotTip)
    }

    /// 主机右键/长按菜单(与原型 hostMenu 一致)
    @ViewBuilder
    private var hostMenu: some View {
        Button { callbacks.openTerminal(host) } label: {
            Label("打开终端", systemImage: "terminal")
        }
        Button { callbacks.openSFTP(host) } label: {
            Label("浏览文件 (SFTP)", systemImage: "folder")
        }
        Divider()
        Button { callbacks.editHost(host) } label: {
            Label("编辑…", systemImage: "pencil")
        }
        Button { callbacks.copyHost(host) } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Menu("移至分组") {
            Button("根级（无分组）") { model.moveHost(host.id, toGroup: nil) }
            ForEach(model.groups) { group in
                Button(GroupTree.path(of: group.id, in: model.groups)) {
                    model.moveHost(host.id, toGroup: group.id)
                }
            }
        }
        Divider()
        Button(role: .destructive) { callbacks.deleteHost(host) } label: {
            Label("删除主机", systemImage: "trash")
        }
    }
}

/// 分组行:文件夹图标 + 名称;作为 OutlineGroup 的行使用,
/// 展开/折叠三角与缩进由 OutlineGroup 负责,单击选中由 List 负责。
struct GroupRowView: View {
    let group: HostGroup
    let callbacks: SidebarCallbacks

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(group.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { groupMenu }
    }

    /// 分组右键/长按菜单(与原型 groupMenu 一致,另加「在此分组添加主机」)
    @ViewBuilder
    private var groupMenu: some View {
        Button { callbacks.addHostInGroup(group) } label: {
            Label("在此分组添加主机…", systemImage: "plus")
        }
        Divider()
        Button { callbacks.newSubgroup(group) } label: {
            Label("新建子分组", systemImage: "folder.badge.plus")
        }
        Button { callbacks.renameGroup(group) } label: {
            Label("重命名", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) { callbacks.deleteGroup(group) } label: {
            Label("删除分组", systemImage: "trash")
        }
    }
}

/// 侧栏底部固定入口按钮，使用与系统侧栏一致的选中和悬停层级。
private struct SideEntryButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isActive ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.05) : .clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
    }
}

#if DEBUG
#Preview("侧栏") {
    NavigationStack {
        SidebarView()
    }
    .environmentObject(AppModel.previewModel())
    .environmentObject(WorkspaceStore.previewStore())
    .environmentObject(ToastCenter())
}
#endif

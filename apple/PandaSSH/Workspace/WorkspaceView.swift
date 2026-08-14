import SwiftUI

/// 多标签页工作区容器:顶部自定义标签栏(纯 SwiftUI,双端共享,
/// 不依赖 NSTabView/UITabView),内容区按活动标签类型分发到
/// 终端视图或 SFTP 文件浏览器。
struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var transfers: TransferStore

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
    }

    /// 横向滚动的标签栏;标签过多时可滑动,iPadOS 紧凑宽度下不拥挤。
    /// 右侧「+」对当前选中主机新建终端/SFTP 标签(与原型一致),未选中主机时禁用。
    private var tabBar: some View {
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
                            onClose: { workspace.close(tabID: tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            newTabMenu
                .padding(.trailing, 8)
        }
    }

    /// 「+」新建入口:对侧栏当前选中的主机新建终端或 SFTP 标签页。
    private var newTabMenu: some View {
        Menu {
            Button {
                if let id = model.selectedHostID { workspace.openTerminal(hostID: id) }
            } label: {
                Label("新建终端", systemImage: "terminal")
            }
            Button {
                if let id = model.selectedHostID { workspace.openSFTP(hostID: id) }
            } label: {
                Label("新建 SFTP", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .padding(6)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.selectedHostID == nil)
        .accessibilityLabel("新建标签页")
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
            ContentUnavailableView(
                "未选择主机",
                systemImage: "server.rack",
                description: Text("从左侧选择一台主机，或点击「＋ 添加主机」新建。")
            )
        }
    }
}

/// 单个标签:类型图标 + 标题 + 关闭按钮,点击切换活动标签。
/// 选中态用底边强调线(系统标签风格),非圆角胶囊。
private struct WorkspaceTabItemView: View {
    let tab: WorkspaceTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.kind == .terminal ? "terminal" : "folder")
            Text(tab.title)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭标签页")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hovering && !isActive ? Color.primary.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
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

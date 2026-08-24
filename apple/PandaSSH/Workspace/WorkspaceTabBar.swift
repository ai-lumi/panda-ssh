import SwiftUI

#if os(macOS)
/// macOS 页签栏：根据溢出模式在滚动与多行布局间切换，高度均随内容自适应。
struct WorkspaceTabBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @StateObject private var scrollController = TabBarScrollController()

    private static let documentCoordinateSpace = "workspace-tab-document"

    init(scrollController: TabBarScrollController = TabBarScrollController()) {
        _scrollController = StateObject(wrappedValue: scrollController)
    }

    var body: some View {
        Group {
            if workspace.tabBarOverflowMode == .scroll {
                scrollModeContent
            } else {
                expandModeContent
            }
        }
        .onAppear {
            synchronizeScrollTargets()
        }
        .onChange(of: workspace.tabs.map(\.id)) { _, _ in
            synchronizeScrollTargets()
        }
        .onChange(of: workspace.tabBarOverflowMode) { _, _ in
            synchronizeScrollTargets()
        }
        .onChange(of: presentedTabID) { _, tabID in
            if let tabID {
                scrollController.reveal(tabID: tabID)
            }
        }
    }

    // MARK: - 滚动模式

    private var scrollModeContent: some View {
        HStack(spacing: 0) {
            scrollButton(systemName: "chevron.left", accessibilityLabel: "向左翻页",
                         action: scrollController.scrollLeft,
                         isEnabled: scrollController.canScrollLeft)
            HorizontalWheelScrollView(controller: scrollController) {
                HStack(spacing: 4) {
                    tabsContent
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .fixedSize(horizontal: true, vertical: false)
                .coordinateSpace(name: Self.documentCoordinateSpace)
            }
            scrollButton(systemName: "chevron.right", accessibilityLabel: "向右翻页",
                         action: scrollController.scrollRight,
                         isEnabled: scrollController.canScrollRight)
        }
    }

    private func scrollButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        isEnabled: Bool
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(scrollController.needsScroll ? 1 : 0)
        .allowsHitTesting(scrollController.needsScroll)
        .frame(width: 20)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHidden(!scrollController.needsScroll)
    }

    // MARK: - 多行模式

    private var expandModeContent: some View {
        FlowLayout(spacing: 4) {
            tabsContent
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 页签按钮

    private var tabsContent: some View {
        ForEach(workspace.tabs) { tab in
            WorkspaceTabButton(
                tab: tab,
                dotColor: dotColor(for: tab.hostID),
                statusLabel: statusLabel(for: tab.hostID),
                isActive: model.workspacePresentation == .tab(tabID: tab.id),
                onSelect: {
                    workspace.select(tabID: tab.id)
                    model.presentTab(tab.id)
                },
                onClose: { workspace.requestClose(tabID: tab.id) }
            )
            .id(tab.id)
            .background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(Self.documentCoordinateSpace))
                    Color.clear
                        .onAppear {
                            scrollController.updateTabFrame(frame, for: tab.id)
                        }
                        .onChange(of: frame) { _, newFrame in
                            scrollController.updateTabFrame(newFrame, for: tab.id)
                        }
                }
            }
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

    private var presentedTabID: UUID? {
        guard case .tab(let tabID) = model.workspacePresentation else { return nil }
        return tabID
    }

    private func synchronizeScrollTargets() {
        scrollController.retainTabIDs(Set(workspace.tabs.map(\.id)))
        if let presentedTabID {
            scrollController.reveal(tabID: presentedTabID)
        }
    }

    private func dotColor(for hostID: String) -> Color {
        guard let host = model.hosts.first(where: { $0.id == hostID }) else {
            return Color(.gray).opacity(0.6)
        }
        switch host.demo {
        case .mismatch: return .red
        case .unknown: return .yellow
        default: return host.fingerprint != nil ? .green : Color(.gray).opacity(0.6)
        }
    }

    private func statusLabel(for hostID: String) -> String {
        guard let host = model.hosts.first(where: { $0.id == hostID }) else { return "主机不可用" }
        switch host.demo {
        case .mismatch: return "主机密钥不匹配"
        case .unknown: return "主机密钥未验证"
        default: return host.fingerprint != nil ? "主机密钥已记录" : "主机密钥未记录"
        }
    }
}
#endif

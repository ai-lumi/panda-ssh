import SwiftUI

#if os(macOS)
/// macOS 页签栏：根据溢出模式在滚动与多行布局间切换，高度均随内容自适应。
struct WorkspaceTabBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @StateObject private var scrollController = TabBarScrollController()

    var body: some View {
        Group {
            if workspace.tabBarOverflowMode == .scroll {
                scrollModeContent
            } else {
                expandModeContent
            }
        }
    }

    // MARK: - 滚动模式

    private var scrollModeContent: some View {
        HStack(spacing: 0) {
            scrollButton(systemName: "chevron.left", action: scrollController.scrollLeft,
                         isEnabled: scrollController.canScrollLeft)
            HorizontalWheelScrollView(controller: scrollController) {
                HStack(spacing: 4) {
                    tabsContent
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            scrollButton(systemName: "chevron.right", action: scrollController.scrollRight,
                         isEnabled: scrollController.canScrollRight)
        }
    }

    private func scrollButton(systemName: String, action: @escaping () -> Void, isEnabled: Bool) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(scrollController.needsScroll ? 1 : 0)
        .frame(width: 20)
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
                isActive: tab.id == workspace.activeTabID,
                onSelect: {
                    workspace.select(tabID: tab.id)
                    model.sidebarPage = .hosts
                },
                onClose: { workspace.requestClose(tabID: tab.id) }
            )
            .id(tab.id)
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
}
#endif

import SwiftUI

/// 跨平台共享的工作区顶部 chrome。
/// 平台宿主仅传入窗口安全预留宽度；页签、侧栏入口与业务状态均不分叉。
struct UnifiedWorkspaceChrome: View {
    @EnvironmentObject private var model: AppModel
    let leadingReservedWidth: Double
    let trailingReservedWidth: Double
    let showsCustomSidebarRecovery: Bool
    let sidebarWidth: Double

    init(
        leadingReservedWidth: Double = 0,
        trailingReservedWidth: Double = 0,
        sidebarWidth: Double = 0,
        showsCustomSidebarRecovery: Bool = true
    ) {
        self.leadingReservedWidth = leadingReservedWidth
        self.trailingReservedWidth = trailingReservedWidth
        self.sidebarWidth = sidebarWidth
        self.showsCustomSidebarRecovery = showsCustomSidebarRecovery
    }

    var body: some View {
        GeometryReader { proxy in
            let isSidebarVisible = model.columnVisibility != .detailOnly
            let layout = UnifiedWorkspaceChromeLayout.resolve(
                windowWidth: proxy.size.width,
                sidebarWidth: sidebarWidth,
                isSidebarVisible: isSidebarVisible,
                leadingReservedWidth: leadingReservedWidth,
                trailingReservedWidth: trailingReservedWidth,
                isFullScreen: false,
                showsCustomSidebarRecovery: showsCustomSidebarRecovery
            )

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: layout.leadingSafeWidth)
                    .macOSWindowDragRegion()

                if layout.showsSidebarTools {
                    sidebarTools
                        .frame(width: layout.sidebarToolsWidth, alignment: .leading)
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(width: 1, height: 22)
                        }
                } else if layout.showsSidebarRecovery {
                    sidebarRecovery
                        .frame(width: layout.sidebarRecoveryWidth)
                }

                UnifiedWorkspaceTabStrip()
                    .frame(width: layout.tabStripWidth)

                // 窗口拖动只绑定到明确的空白区；不得覆盖页签或按钮，
                // 否则 AppKit 会在 SwiftUI 拖放启动前接管鼠标拖动。
                Color.clear
                    .frame(width: layout.trailingSafeWidth)
                    .macOSWindowDragRegion()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 40)
        // 侧栏显隐只重新分配顶行宽度，不对页签和工具入口做插入、位移动画。
        .animation(nil, value: model.columnVisibility)
        .background(.bar)
        .accessibilityIdentifier("unified-workspace-chrome")
    }

    private var sidebarTools: some View {
        HStack(spacing: 4) {
            Button {
                model.sidebarSheet = .addHost(defaultGroupID: nil)
            } label: {
                Label("添加主机", systemImage: "plus")
            }
            Button {
                model.sidebarSheet = .newGroup(parent: nil)
            } label: {
                Label("新建分组", systemImage: "folder.badge.plus")
            }
            Button {
                withAnimation { model.columnVisibility = .detailOnly }
            } label: {
                Label("隐藏侧栏", systemImage: "sidebar.left")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var sidebarRecovery: some View {
        Button {
            withAnimation { model.columnVisibility = .all }
        } label: {
            Image(systemName: "sidebar.left")
                .frame(width: 40, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("显示侧栏")
    }
}

#if os(macOS)
extension View {
    func macOSWindowDragRegion() -> some View {
        // 拖窗视图必须位于透明占位视图的命中测试前景。放在 background
        // 时，SwiftUI 的前景宿主可能先命中，导致 DragView 收不到鼠标按下。
        overlay(WindowDragView())
    }
}
#else
extension View {
    func macOSWindowDragRegion() -> some View { self }
}
#endif

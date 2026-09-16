import Foundation

/// 统一顶部 chrome 的共享空间分配。
/// 平台宿主只提供安全预留宽度；页签与侧栏的布局规则不因平台而分叉。
struct UnifiedWorkspaceChromeLayout: Equatable {
    /// 标题栏原生控件占用的左侧安全区，由 macOS 宿主实测提供。
    let leadingSafeWidth: Double
    /// 仅用于窗口拖动的尾部空白区，不承载页签或按钮。
    let trailingSafeWidth: Double
    let availableWidth: Double
    let sidebarToolsWidth: Double
    /// detail 内的顶栏没有侧栏空间，不能创建溢出零宽 frame 的工具按钮。
    var showsSidebarTools: Bool { sidebarToolsWidth > 0 }
    let tabStripWidth: Double
    let showsSidebarRecovery: Bool
    let sidebarRecoveryWidth: Double
    let drawsDetailTabBar: Bool

    static func resolve(
        windowWidth: Double,
        sidebarWidth: Double,
        isSidebarVisible: Bool,
        leadingReservedWidth: Double,
        trailingReservedWidth: Double,
        isFullScreen _: Bool,
        showsCustomSidebarRecovery: Bool = true
    ) -> UnifiedWorkspaceChromeLayout {
        let safeWindowWidth = finiteNonnegative(windowWidth)
        let safeLeadingWidth = min(finiteNonnegative(leadingReservedWidth), safeWindowWidth)
        let safeTrailingWidth = min(
            finiteNonnegative(trailingReservedWidth),
            max(0, safeWindowWidth - safeLeadingWidth)
        )
        let availableWidth = max(0, safeWindowWidth - safeLeadingWidth - safeTrailingWidth)
        let sidebarToolsWidth = isSidebarVisible
            ? min(max(0, finiteNonnegative(sidebarWidth) - safeLeadingWidth), availableWidth)
            : 0
        let showsSidebarRecovery = !isSidebarVisible && showsCustomSidebarRecovery
        let sidebarRecoveryWidth = showsSidebarRecovery ? min(40, availableWidth) : 0

        return UnifiedWorkspaceChromeLayout(
            leadingSafeWidth: safeLeadingWidth,
            trailingSafeWidth: safeTrailingWidth,
            availableWidth: availableWidth,
            sidebarToolsWidth: sidebarToolsWidth,
            tabStripWidth: max(0, availableWidth - sidebarToolsWidth - sidebarRecoveryWidth),
            showsSidebarRecovery: showsSidebarRecovery,
            sidebarRecoveryWidth: sidebarRecoveryWidth,
            drawsDetailTabBar: false
        )
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

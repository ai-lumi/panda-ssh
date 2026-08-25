import Foundation

/// 窗口顶部结构的纯值约束，防止 macOS 同时出现系统标题、principal 页签和
/// 内容区页签三层互相冲突的 chrome。
struct WorkspaceChromePolicy: Equatable {
    enum Platform {
        case macOS
        case iPadOS
    }

    enum TabPlacement: Equatable {
        case principalToolbar
        case adaptiveContentRow
    }

    static let maximumPrincipalWidth = 760.0
    private static let nonPrincipalWindowWidth = 360.0

    let showsApplicationTitle: Bool
    let usesSystemToolbar: Bool
    let tabPlacement: TabPlacement
    let drawsContentTabRow: Bool
    let preservesSystemWindowControls: Bool
    let providesSystemSidebarRecovery: Bool
    let removesDefaultSidebarToggle: Bool
    let visibleTabCount: Int
    let tabRowCount: Int
    let principalWidth: Double

    static func resolve(
        platform: Platform,
        tabCount: Int,
        isSidebarVisible: Bool,
        windowWidth: Double
    ) -> WorkspaceChromePolicy {
        let visibleTabCount = max(0, tabCount)
        let safeWindowWidth = windowWidth.isFinite && windowWidth > 0 ? windowWidth : 0
        let principalWidth = min(
            maximumPrincipalWidth,
            max(0, safeWindowWidth - nonPrincipalWindowWidth)
        )

        switch platform {
        case .macOS:
            return WorkspaceChromePolicy(
                showsApplicationTitle: false,
                usesSystemToolbar: true,
                tabPlacement: .principalToolbar,
                drawsContentTabRow: false,
                preservesSystemWindowControls: true,
                providesSystemSidebarRecovery: true,
                removesDefaultSidebarToggle: shouldRemoveDefaultSidebarToggle(
                    platform: platform,
                    isSidebarVisible: isSidebarVisible
                ),
                visibleTabCount: visibleTabCount,
                tabRowCount: visibleTabCount == 0 ? 0 : 1,
                principalWidth: principalWidth
            )
        case .iPadOS:
            return WorkspaceChromePolicy(
                showsApplicationTitle: false,
                usesSystemToolbar: true,
                tabPlacement: .adaptiveContentRow,
                drawsContentTabRow: true,
                preservesSystemWindowControls: false,
                providesSystemSidebarRecovery: true,
                removesDefaultSidebarToggle: shouldRemoveDefaultSidebarToggle(
                    platform: platform,
                    isSidebarVisible: isSidebarVisible
                ),
                visibleTabCount: visibleTabCount,
                tabRowCount: visibleTabCount == 0 ? 0 : 1,
                principalWidth: 0
            )
        }
    }

    /// 系统侧栏按钮持续承担显示与隐藏职责，避免状态切换时跨位置重建控件。
    static func shouldRemoveDefaultSidebarToggle(
        platform: Platform,
        isSidebarVisible: Bool
    ) -> Bool {
        false
    }
}

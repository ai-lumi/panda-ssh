import Foundation

/// 仅描述工作区的呈现方式，不承载 SSH/SFTP 业务状态。
struct WorkspaceLayoutPolicy: Equatable {
    enum Platform: Equatable {
        case macOS
        case iPadOS
    }

    enum HorizontalSizeClass: Equatable {
        case compact
        case regular
        case unspecified
    }

    enum SidebarPresentation: Equatable {
        case sideBySide
        case systemCollapsed
    }

    enum SFTPPresentation: Equatable {
        case dualPane
        case singlePane
    }

    enum TransferPresentation: Equatable {
        case drawer
        case inspector
        case sheet
    }

    static let regularWidthThreshold = 700.0

    let sidebarPresentation: SidebarPresentation
    let sftpPresentation: SFTPPresentation
    let transferPresentation: TransferPresentation
    let minimumInteractiveLength: Double

    static func resolve(
        platform: Platform,
        horizontalSizeClass: HorizontalSizeClass,
        availableWidth: Double
    ) -> WorkspaceLayoutPolicy {
        if platform == .macOS {
            return WorkspaceLayoutPolicy(
                sidebarPresentation: .sideBySide,
                sftpPresentation: .dualPane,
                transferPresentation: .drawer,
                minimumInteractiveLength: 24
            )
        }

        let hasUsableWidth = availableWidth.isFinite && availableWidth > 0
        let usesCompactPresentation = horizontalSizeClass == .compact
            || !hasUsableWidth
            || availableWidth < regularWidthThreshold

        if usesCompactPresentation {
            return WorkspaceLayoutPolicy(
                sidebarPresentation: .systemCollapsed,
                sftpPresentation: .singlePane,
                transferPresentation: .sheet,
                minimumInteractiveLength: 44
            )
        }

        return WorkspaceLayoutPolicy(
            sidebarPresentation: .sideBySide,
            sftpPresentation: .dualPane,
            transferPresentation: .inspector,
            minimumInteractiveLength: 44
        )
    }
}

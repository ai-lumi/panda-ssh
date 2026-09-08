import Foundation

/// 新旧工作区 chrome 的装配选择。它不拥有 AppModel 或 WorkspaceStore，
/// 因而路径切换不会重建已打开的终端或 SFTP 会话。
enum WorkspaceChromeStrategy: Equatable {
    case unified
    case legacy

    static func resolve(isUnifiedChromeAvailable: Bool, isExplicitlyDisabled: Bool) -> WorkspaceChromeStrategy {
        isUnifiedChromeAvailable && !isExplicitlyDisabled ? .unified : .legacy
    }
}

/// 路由只选择 chrome 呈现路径，始终透传同一份工作区状态。
/// 这使回退不触及终端或 SFTP 会话、页签顺序与关闭确认状态。
struct WorkspaceChromeRoute: Equatable {
    let strategy: WorkspaceChromeStrategy
    let shell: WorkspaceShell

    static func resolve(
        shell: WorkspaceShell,
        isUnifiedChromeAvailable: Bool,
        isExplicitlyDisabled: Bool
    ) -> WorkspaceChromeRoute {
        WorkspaceChromeRoute(
            strategy: .resolve(
                isUnifiedChromeAvailable: isUnifiedChromeAvailable,
                isExplicitlyDisabled: isExplicitlyDisabled
            ),
            shell: shell
        )
    }

    func switching(
        isUnifiedChromeAvailable: Bool,
        isExplicitlyDisabled: Bool
    ) -> WorkspaceChromeRoute {
        .resolve(
            shell: shell,
            isUnifiedChromeAvailable: isUnifiedChromeAvailable,
            isExplicitlyDisabled: isExplicitlyDisabled
        )
    }
}

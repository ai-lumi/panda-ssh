import Foundation

enum WorkspaceEmptyStateAction: CaseIterable {
    case chooseHost
    case addHost
}

/// 空态允许发出的界面命令。这里刻意不提供“打开终端”，避免空态绕过主机详情与
/// 连接前确认流程。
enum WorkspaceEmptyStateCommand: Hashable {
    case revealHostList
    case focusHostList
    case addHost
}

struct WorkspaceEmptyStateRouter {
    static func command(
        for action: WorkspaceEmptyStateAction,
        hostCount: Int,
        isSidebarVisible: Bool
    ) -> WorkspaceEmptyStateCommand {
        switch action {
        case .addHost:
            return .addHost
        case .chooseHost:
            guard hostCount > 0 else { return .addHost }
            return isSidebarVisible ? .focusHostList : .revealHostList
        }
    }
}

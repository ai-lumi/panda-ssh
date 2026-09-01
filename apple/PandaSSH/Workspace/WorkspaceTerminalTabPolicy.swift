import Foundation

/// 终端标签页的保留与可见性规则。
/// 所有已打开终端都必须留在工作区视图树中，避免切换标签时析构其 SSH shell；
/// 只有当前活动终端可见且接收交互。
struct WorkspaceTerminalTabPolicy {
    let retainedTabs: [WorkspaceTab]
    let visibleTabID: UUID?

    init(tabs: [WorkspaceTab], activeTabID: UUID?) {
        retainedTabs = tabs.filter { $0.kind == .terminal }
        visibleTabID = retainedTabs.contains(where: { $0.id == activeTabID }) ? activeTabID : nil
    }

    var retainedTabIDs: [UUID] {
        retainedTabs.map(\.id)
    }

    func isVisible(_ tabID: UUID) -> Bool {
        visibleTabID == tabID
    }
}

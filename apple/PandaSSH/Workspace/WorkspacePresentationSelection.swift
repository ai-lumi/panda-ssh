import Foundation

/// 主内容区当前呈现的对象。
///
/// 该状态与 `WorkspaceStore.activeTabID` 分离：用户查看主机详情时，后台页签与
/// SSH/SFTP 会话继续存在，但没有页签被误认为是当前显示内容。
enum WorkspacePresentationSelection: Equatable {
    case empty
    case hostDetail(hostID: String)
    case tab(tabID: UUID)

    /// 数据删除或页签关闭后，把失效选择归一化到仍有效的活动页签；若没有可靠
    /// 回退则进入空态。有效的 `.empty` 不会因为后台存在页签而自动切换内容。
    func normalized(
        validHostIDs: Set<String>,
        validTabIDs: Set<UUID>,
        fallbackTabID: UUID?
    ) -> WorkspacePresentationSelection {
        switch self {
        case .empty:
            return .empty
        case .hostDetail(let hostID):
            guard validHostIDs.contains(hostID) else {
                return Self.validFallback(fallbackTabID, validTabIDs: validTabIDs)
            }
            return self
        case .tab(let tabID):
            guard validTabIDs.contains(tabID) else {
                return Self.validFallback(fallbackTabID, validTabIDs: validTabIDs)
            }
            return self
        }
    }

    private static func validFallback(
        _ fallbackTabID: UUID?,
        validTabIDs: Set<UUID>
    ) -> WorkspacePresentationSelection {
        guard let fallbackTabID, validTabIDs.contains(fallbackTabID) else { return .empty }
        return .tab(tabID: fallbackTabID)
    }
}

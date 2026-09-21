// =============================================================================
// WorkspacePresentationSelection.swift
// =============================================================================
// 文件功能说明：
// 定义工作区主内容区当前正在显示的对象（枚举类型）。
//
// 工作区可能同时存在多个后台标签页（终端、SFTP），但用户屏幕上实际看到的
// 内容只有一种：要么是空态页面、要么是某台主机的详情页、要么是某个标签页。
// 这个枚举把「当前显示什么」和「后台有哪些标签页」两个概念分离开来，
// 避免混淆。
//
// 还提供了一个 normalized 方法：当数据被删除或标签页被关闭后，
// 把已经失效的显示选择「归一化」到一个仍然有效的选择。
// =============================================================================

import Foundation
// 导入 Foundation，提供 UUID 等基础类型

/// 主内容区当前呈现的对象。
///
/// 该状态与 `WorkspaceStore.activeTabID` 分离：用户查看主机详情时，后台页签与
/// SSH/SFTP 会话继续存在，但没有页签被误认为是当前显示内容。
enum WorkspacePresentationSelection: Equatable {
    // Equatable 让两个显示选择可以比较是否相同，
    // SwiftUI 借此判断主内容区是否需要刷新

    case empty
    // 空态：主内容区没有显示任何具体内容，通常展示引导页面

    case hostDetail(hostID: String)
    // 主机详情页：显示指定主机的配置信息和连接选项。
    // hostID 是主机的唯一标识符（字符串类型）

    case tab(tabID: UUID)
    // 标签页：显示指定的终端或 SFTP 标签页。
    // tabID 是标签页的唯一标识符（UUID 类型）

    /// 数据删除或页签关闭后，把失效选择归一化到仍有效的活动页签；若没有可靠
    /// 回退则进入空态。有效的 `.empty` 不会因为后台存在页签而自动切换内容。
    func normalized(
        validHostIDs: Set<String>,
        // 当前仍然有效的主机 ID 集合（已删除的主机不在此集合中）
        validTabIDs: Set<UUID>,
        // 当前仍然有效的标签页 ID 集合（已关闭的标签页不在此集合中）
        fallbackTabID: UUID?
        // 备用的标签页 ID：当当前选择失效时，优先回退到这个标签页
    ) -> WorkspacePresentationSelection {
        // 返回归一化后的有效显示选择

        switch self {
        // 根据当前的显示选择类型进行分支处理

        case .empty:
            return .empty
            // 如果当前就是空态，保持不变。
            // 注释强调：即使后台有标签页存在，空态也不会自动切换成显示某个标签页

        case .hostDetail(let hostID):
            // 当前显示的是主机详情页，let hostID 提取关联的主机 ID

            guard validHostIDs.contains(hostID) else {
                // 如果该主机 ID 已经不在有效集合中（主机被删除了）

                return Self.validFallback(fallbackTabID, validTabIDs: validTabIDs)
                // 尝试回退到备用标签页；如果备用标签页也无效，则进入空态
            }
            return self
            // 主机 ID 仍然有效，保持当前显示不变

        case .tab(let tabID):
            // 当前显示的是某个标签页，let tabID 提取关联的标签页 ID

            guard validTabIDs.contains(tabID) else {
                // 如果该标签页 ID 已经不在有效集合中（标签页被关闭了）

                return Self.validFallback(fallbackTabID, validTabIDs: validTabIDs)
                // 尝试回退到备用标签页
            }
            return self
            // 标签页 ID 仍然有效，保持当前显示不变
        }
    }

    private static func validFallback(
        _ fallbackTabID: UUID?,
        // 备用标签页 ID（可选）
        validTabIDs: Set<UUID>
        // 有效标签页 ID 集合
    ) -> WorkspacePresentationSelection {
        // 辅助方法：尝试找到一个有效的备用标签页来显示

        guard let fallbackTabID, validTabIDs.contains(fallbackTabID) else { return .empty }
        // Swift 的 guard-let 语法：
        // 1. 先解包 fallbackTabID（如果不是 nil）
        // 2. 再检查它是否在有效集合中
        // 任一条件不满足 → 返回 .empty（空态）

        return .tab(tabID: fallbackTabID)
        // 备用标签页有效 → 返回显示该标签页
    }
}

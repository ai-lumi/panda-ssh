import Foundation

/// 页签分组：将相关页签组织在一起，便于视觉区分和管理。
/// 分组状态仅在当前会话内保持，不持久化。
struct TabGroup: Identifiable, Equatable {
    /// 分组唯一标识
    let id: UUID
    /// 分组名称，用户可编辑
    var name: String
    /// 组内页签 ID 列表，有序
    var tabIDs: [UUID]

    /// 分组是否为空（无页签）
    var isEmpty: Bool {
        tabIDs.isEmpty
    }
}

// =============================================================================
// SidebarTree.swift — 侧栏树节点模型
// =============================================================================
// 本文件定义了侧栏（Sidebar）树形列表的数据模型。
// 侧栏用于展示主机分组和主机的树形结构，支持多级嵌套和展开/折叠。
//
// 核心设计：
//   - SidebarNode：统一的树节点，既可以表示"分组"也可以表示"主机"。
//   - 节点 id 使用带前缀的字符串（"group-xxx" / "host-xxx"），
//     通过前缀区分节点类型，选中时反解回原始 id 以查找对应数据。
//   - 提供从 FFI 层（Rust 后端）返回的记录到 UI 节点的转换方法。
// =============================================================================

// 引入 Foundation 框架，提供基础数据类型（String、Optional 等）
import Foundation

/// 侧栏树节点:供 `List` + `OutlineGroup` 渲染的统一节点(分组或主机)。
/// 节点 id 带前缀(`group-`/`host-`),选中态据此反解回分组或主机。
///
/// 设计说明：
///   SwiftUI 的 `OutlineGroup` 要求所有节点类型统一，因此分组和主机
///   都用 SidebarNode 表示。通过 id 前缀区分类型，避免引入枚举的复杂性。
struct SidebarNode: Identifiable {
    /// 节点的唯一标识符，格式为 "group-<原始id>" 或 "host-<原始id>"。
    /// Identifiable 协议要求，SwiftUI 的 List/ForEach 用它来追踪行的身份。
    let id: String

    /// 如果本节点是分组，则包含对应的 HostGroup 数据；如果是主机节点则为 nil。
    /// HostGroup 包含分组名称、排序等信息。
    let group: HostGroup?

    /// 如果本节点是主机，则包含对应的 HostEntry 数据；如果是分组节点则为 nil。
    /// HostEntry 包含主机地址、端口、认证方式等连接信息。
    let host: HostEntry?

    /// 子节点;nil 表示无子节点(OutlineGroup 不显示展开三角)
    ///
    /// 重要区分：
    ///   - nil → OutlineGroup 认为没有子节点，不显示展开箭头（用于叶子节点如主机）
    ///   - 空数组 [] → OutlineGroup 认为有子节点但为空，仍显示展开箭头（空分组）
    var children: [SidebarNode]?

    /// 生成分组节点的 id：在原始 id 前添加 "group-" 前缀。
    /// 例如：原始 id "abc" → "group-abc"
    /// - Parameter rawID: 分组的原始唯一标识符
    /// - Returns: 带前缀的节点 id 字符串
    // 字符串插值拼接前缀
    static func groupID(_ rawID: String) -> String { "group-\(rawID)" }

    /// 生成主机节点的 id：在原始 id 前添加 "host-" 前缀。
    /// 例如：原始 id "xyz" → "host-xyz"
    /// - Parameter rawID: 主机的原始唯一标识符
    /// - Returns: 带前缀的节点 id 字符串
    // 字符串插值拼接前缀
    static func hostID(_ rawID: String) -> String { "host-\(rawID)" }

    /// 反解节点 id:(是否分组, 原始 id);无法识别返回 nil。
    ///
    /// 当用户在侧栏选中一个节点时，通过此方法从带前缀的 id 中
    /// 还原出节点类型（分组 or 主机）和原始 id，以便查找对应数据。
    /// - Parameter id: 带前缀的节点 id（如 "group-abc" 或 "host-xyz"）
    /// - Returns: 元组 (isGroup: 是否为分组, rawID: 去掉前缀后的原始 id)；前缀不匹配则返回 nil
    static func parse(id: String) -> (isGroup: Bool, rawID: String)? {
        // 前缀 "group-" 长度 6，去掉前缀得到原始 id
        if id.hasPrefix("group-") { return (true, String(id.dropFirst(6))) }
        // 前缀 "host-" 长度 5，去掉前缀得到原始 id
        if id.hasPrefix("host-") { return (false, String(id.dropFirst(5))) }
        // 前缀不匹配任何已知类型，返回 nil 表示无法识别
        return nil
    }
}

/// 从 FFI 返回的侧栏树记录转换为 UI 节点。
///
/// 此扩展提供工厂方法，将 Rust 后端通过 FFI（Foreign Function Interface）
/// 返回的 SidebarNodeFfiRecord 转换为 SwiftUI 可直接渲染的 SidebarNode。
/// 转换过程中会递归处理子节点，构建完整的树形结构。
extension SidebarNode {
    /// 将 FFI 记录递归转换为 UI 侧栏节点。
    ///
    /// 转换过程：
    ///   1. 如果 FFI 记录包含主机数据（host），将其包装为 HostEntry 模型
    ///   2. 如果 FFI 记录包含分组数据（group），将其包装为 HostGroup 模型
    ///   3. 如果有子节点记录，递归调用自身转换每个子节点
    ///   4. 组装成 SidebarNode 返回
    ///
    /// - Parameter ffiRecord: 从 Rust FFI 层返回的原始侧栏节点记录
    /// - Returns: 转换后的 UI 侧栏节点，可直接用于 SwiftUI 渲染
    static func from(ffiRecord: SidebarNodeFfiRecord) -> SidebarNode {
        // 可选映射：如果 ffiRecord.host 有值，用 FFI 记录初始化 HostEntry 模型
        let host = ffiRecord.host.map { HostEntry(record: $0) }
        // 可选映射：如果 ffiRecord.group 有值，用 FFI 记录初始化 HostGroup 模型
        let group = ffiRecord.group.map { HostGroup(record: $0) }
        // 递归转换：如果有子节点数组，对每个子记录递归调用 from()
        let children = ffiRecord.children?.map { SidebarNode.from(ffiRecord: $0) }
        return SidebarNode(
            // 直接使用 FFI 记录中的 id（已包含 group-/host- 前缀）
            id: ffiRecord.id,
            // 分组数据（主机节点时为 nil）
            group: group,
            // 主机数据（分组节点时为 nil）
            host: host,
            // 子节点数组（叶子节点时为 nil）
            children: children
        )
    }
}

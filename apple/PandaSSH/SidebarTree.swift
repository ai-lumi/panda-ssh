import Foundation

/// 侧栏树节点:供 `List` + `OutlineGroup` 渲染的统一节点(分组或主机)。
/// 节点 id 带前缀(`group-`/`host-`),选中态据此反解回分组或主机。
struct SidebarNode: Identifiable {
    let id: String
    let group: HostGroup?
    let host: HostEntry?
    /// 子节点;nil 表示无子节点(OutlineGroup 不显示展开三角)
    var children: [SidebarNode]?

    static func groupID(_ rawID: String) -> String { "group-\(rawID)" }
    static func hostID(_ rawID: String) -> String { "host-\(rawID)" }

    /// 反解节点 id:(是否分组, 原始 id);无法识别返回 nil。
    static func parse(id: String) -> (isGroup: Bool, rawID: String)? {
        if id.hasPrefix("group-") { return (true, String(id.dropFirst(6))) }
        if id.hasPrefix("host-") { return (false, String(id.dropFirst(5))) }
        return nil
    }
}

/// 从 FFI 返回的侧栏树记录转换为 UI 节点。
extension SidebarNode {
    static func from(ffiRecord: SidebarNodeFfiRecord) -> SidebarNode {
        let host = ffiRecord.host.map { HostEntry(record: $0) }
        let group = ffiRecord.group.map { HostGroup(record: $0) }
        let children = ffiRecord.children?.map { SidebarNode.from(ffiRecord: $0) }
        return SidebarNode(
            id: ffiRecord.id,
            group: group,
            host: host,
            children: children
        )
    }
}

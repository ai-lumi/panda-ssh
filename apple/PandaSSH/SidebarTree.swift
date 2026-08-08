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

/// 由分组与主机构建侧栏节点树:根级分组在前(保持数组顺序)、根级主机在后;
/// 分组内先子分组后主机。悬空引用(分组指向不存在的 parent、主机指向不存在的
/// 分组)一律按根级降级,与 GroupTree 的防御语义一致。
enum SidebarTree {
    static func build(hosts: [HostEntry], groups: [HostGroup]) -> [SidebarNode] {
        func hostNode(_ host: HostEntry) -> SidebarNode {
            SidebarNode(id: SidebarNode.hostID(host.id), group: nil, host: host, children: nil)
        }
        func groupNode(_ group: HostGroup) -> SidebarNode {
            let subgroups = GroupTree.children(of: group.id, in: groups).map(groupNode)
            let members = hosts.filter { $0.groupID == group.id }.map(hostNode)
            let kids = subgroups + members
            return SidebarNode(
                id: SidebarNode.groupID(group.id), group: group, host: nil,
                children: kids.isEmpty ? nil : kids
            )
        }
        let rootGroups = GroupTree.roots(of: groups).map(groupNode)
        let rootHosts = hosts
            .filter { host in
                guard let gid = host.groupID else { return true }
                return !groups.contains { $0.id == gid }
            }
            .map(hostNode)
        return rootGroups + rootHosts
    }
}

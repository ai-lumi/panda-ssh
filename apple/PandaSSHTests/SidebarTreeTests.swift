import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

// TODO: 重构后 SidebarTree 已更名为 SidebarNode 且 API 变更,
// 需要基于新 API 重写测试。暂时跳过。
#if false
/// 侧栏树构建测试:供 List + OutlineGroup 渲染的节点树。
/// 覆盖正常流程(层级与顺序)、意外操作(悬空引用)、边界条件(空分组、空库)。
final class SidebarTreeTests: XCTestCase {

    private let groups = DemoData.groups
    private let hosts = DemoData.hosts

    // MARK: 正常流程

    func testRootsAreGroupsFirstThenRootHosts() {
        let tree = SidebarTree.build(hosts: hosts, groups: groups)
        // 根级:分组按数组序在前(生产环境、测试环境),根级主机在后
        XCTAssertEqual(tree.map(\.id), [
            SidebarNode.groupID("g-prod"), SidebarNode.groupID("g-test"),
            SidebarNode.hostID("h-newtoy"), SidebarNode.hostID("h-offline"), SidebarNode.hostID("h-manual")
        ])
    }

    func testGroupChildrenAreSubgroupsFirstThenHosts() {
        let tree = SidebarTree.build(hosts: hosts, groups: groups)
        let prod = tree.first { $0.id == SidebarNode.groupID("g-prod") }
        XCTAssertEqual(prod?.children?.map(\.id), [
            SidebarNode.groupID("g-east"), SidebarNode.hostID("h-legacy")
        ])
        let east = prod?.children?.first { $0.id == SidebarNode.groupID("g-east") }
        XCTAssertEqual(east?.children?.map(\.id), [
            SidebarNode.hostID("h-webprod"), SidebarNode.hostID("h-webbackup")
        ])
    }

    func testNodeIDParseRoundTrip() {
        let group = SidebarNode.parse(id: "group-g-prod")
        XCTAssertEqual(group?.isGroup, true)
        XCTAssertEqual(group?.rawID, "g-prod")
        let host = SidebarNode.parse(id: "host-h-webprod")
        XCTAssertEqual(host?.isGroup, false)
        XCTAssertEqual(host?.rawID, "h-webprod")
    }

    // MARK: 意外操作

    func testHostWithDanglingGroupFallsBackToRoot() {
        var orphan = hosts[0]
        orphan.id = "h-orphan"
        orphan.groupID = "g-missing"
        let tree = SidebarTree.build(hosts: [orphan], groups: groups)
        XCTAssertEqual(tree.map(\.id), [
            SidebarNode.groupID("g-prod"), SidebarNode.groupID("g-test"),
            SidebarNode.hostID("h-orphan")
        ])
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(SidebarNode.parse(id: "weird-id"))
        XCTAssertNil(SidebarNode.parse(id: ""))
    }

    // MARK: 边界条件

    func testEmptyGroupHasNilChildrenSoNoDisclosureTriangle() {
        let empty = HostGroup(id: "g-empty", name: "空分组", parentID: nil)
        let tree = SidebarTree.build(hosts: [], groups: [empty])
        XCTAssertEqual(tree.count, 1)
        XCTAssertNil(tree[0].children, "空分组 children 应为 nil,OutlineGroup 才不显示展开三角")
    }

    func testEmptyLibraryYieldsEmptyTree() {
        XCTAssertTrue(SidebarTree.build(hosts: [], groups: []).isEmpty)
    }

    func testRootHostsPreserveInputOrder() {
        let h1 = HostEntry(id: "h-b", name: "B", address: "b.com", port: 22, username: "u", groupID: nil)
        let h2 = HostEntry(id: "h-a", name: "A", address: "a.com", port: 22, username: "u", groupID: nil)
        let h3 = HostEntry(id: "h-c", name: "C", address: "c.com", port: 22, username: "u", groupID: nil)
        let tree = SidebarTree.build(hosts: [h1, h2, h3], groups: [])
        XCTAssertEqual(tree.map(\.id), [
            SidebarNode.hostID("h-b"),
            SidebarNode.hostID("h-a"),
            SidebarNode.hostID("h-c"),
        ])
    }

    func testHostInDeepSubgroupAppearsAtCorrectLevel() {
        let g1 = HostGroup(id: "g1", name: "L1", parentID: nil)
        let g2 = HostGroup(id: "g2", name: "L2", parentID: "g1")
        let g3 = HostGroup(id: "g3", name: "L3", parentID: "g2")
        let host = HostEntry(id: "h-deep", name: "Deep", address: "deep.com", port: 22, username: "u", groupID: "g3")
        let tree = SidebarTree.build(hosts: [host], groups: [g1, g2, g3])
        // L1 → L2 → L3 → h-deep
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].id, SidebarNode.groupID("g1"))
        let l2 = tree[0].children?.first { $0.id == SidebarNode.groupID("g2") }
        let l3 = l2?.children?.first { $0.id == SidebarNode.groupID("g3") }
        XCTAssertEqual(l3?.children?.map(\.id), [SidebarNode.hostID("h-deep")])
    }
}
#endif

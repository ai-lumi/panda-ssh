import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

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
}

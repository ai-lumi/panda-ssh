import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// Mock 后端与分组树测试:覆盖正常流程(增删改查、移动、信任指纹)、
/// 意外操作(对不存在的 id 操作)、边界条件(删除分组级联、悬空 parent
/// 降级、空库)三类用例。
final class MockBackendTests: XCTestCase {

    private func makeBackend() -> MockBackend { MockBackend.demo() }

    // MARK: - 演示数据完整性(与原型一致)

    func testDemoDataMatchesPrototype() {
        let backend = makeBackend()

        XCTAssertEqual(backend.allHosts().count, 7)
        XCTAssertEqual(backend.allGroups().count, 3)
        XCTAssertEqual(backend.allSnippets().count, 3)
        // 演示标记:unknown / mismatch / offline / manual 各一台
        let flags = backend.allHosts().compactMap(\.demo)
        XCTAssertTrue(flags.contains(.unknown))
        XCTAssertTrue(flags.contains(.mismatch))
        XCTAssertTrue(flags.contains(.offline))
        XCTAssertTrue(flags.contains(.manual))
        // 分组树:生产环境 → 华东
        let east = backend.allGroups().first { $0.name == "华东" }
        let prod = backend.allGroups().first { $0.name == "生产环境" }
        XCTAssertEqual(east?.parentID, prod?.id)
    }

    // MARK: - 主机 CRUD(内存)

    func testSaveNewHostAppends() {
        let backend = makeBackend()
        let host = HostEntry(id: "h-new", name: "box", address: "10.0.0.1", port: 22, username: "root")

        backend.saveHost(host, password: nil, passphrase: nil)

        XCTAssertEqual(backend.allHosts().count, 8)
        XCTAssertEqual(backend.allHosts().first { $0.id == "h-new" }?.name, "box")
    }

    func testSaveExistingHostUpdatesInPlace() {
        let backend = makeBackend()
        var host = backend.allHosts().first { $0.id == "h-webprod" }!
        host.note = "改过的备注"

        backend.saveHost(host, password: nil, passphrase: nil)

        XCTAssertEqual(backend.allHosts().count, 7)
        XCTAssertEqual(backend.allHosts().first { $0.id == "h-webprod" }?.note, "改过的备注")
    }

    func testDeleteHostRemoves() {
        let backend = makeBackend()

        backend.deleteHost(id: "h-webprod")

        XCTAssertEqual(backend.allHosts().count, 6)
        XCTAssertNil(backend.allHosts().first { $0.id == "h-webprod" })
    }

    func testDeleteUnknownHostIsNoOp() {
        let backend = makeBackend()

        backend.deleteHost(id: "ghost")

        XCTAssertEqual(backend.allHosts().count, 7)
    }

    // MARK: - 主机移动分组

    func testMoveHostToGroup() {
        let backend = makeBackend()

        backend.moveHost(id: "h-newtoy", toGroup: "g-test")

        XCTAssertEqual(backend.allHosts().first { $0.id == "h-newtoy" }?.groupID, "g-test")
    }

    func testMoveHostBackToRoot() {
        let backend = makeBackend()

        backend.moveHost(id: "h-webprod", toGroup: nil)

        XCTAssertNil(backend.allHosts().first { $0.id == "h-webprod" }?.groupID)
    }

    // MARK: - TOFU 信任

    func testTrustHostRecordsFingerprintAndClearsDemo() {
        let backend = makeBackend()
        let presented = backend.presentedFingerprint(for: "h-newtoy")
        XCTAssertNotNil(presented)

        backend.trustHost(id: "h-newtoy")

        let host = backend.allHosts().first { $0.id == "h-newtoy" }
        XCTAssertEqual(host?.fingerprint, presented)
        XCTAssertNil(host?.demo)
    }

    // MARK: - 分组增删改

    func testCreateRootAndChildGroup() {
        let backend = makeBackend()

        let g = backend.createGroup(name: "灾备", parentID: nil)
        let child = backend.createGroup(name: "异地", parentID: g.id)

        XCTAssertEqual(backend.allGroups().count, 5)
        XCTAssertEqual(child.parentID, g.id)
    }

    func testRenameGroupKeepsMembership() {
        let backend = makeBackend()

        backend.renameGroup(id: "g-east", name: "华东一区")

        XCTAssertEqual(backend.allGroups().first { $0.id == "g-east" }?.name, "华东一区")
        // 归属不变:web-prod 仍在该组
        XCTAssertEqual(backend.allHosts().first { $0.id == "h-webprod" }?.groupID, "g-east")
    }

    func testDeleteGroupMovesHostsToRootAndCascadesSubgroups() {
        let backend = makeBackend()

        backend.deleteGroup(id: "g-prod")

        // 子分组「华东」一并删除
        XCTAssertNil(backend.allGroups().first { $0.id == "g-prod" })
        XCTAssertNil(backend.allGroups().first { $0.id == "g-east" })
        // 组内与子分组内主机全部移回根级,配置保留
        let names = ["h-webprod", "h-webbackup", "h-legacy"]
        for id in names {
            let host = backend.allHosts().first { $0.id == id }
            XCTAssertNotNil(host)
            XCTAssertNil(host?.groupID)
        }
        // 其他分组不受影响
        XCTAssertNotNil(backend.allGroups().first { $0.id == "g-test" })
    }

    func testDeleteUnknownGroupIsNoOp() {
        let backend = makeBackend()

        backend.deleteGroup(id: "ghost")

        XCTAssertEqual(backend.allGroups().count, 3)
        XCTAssertEqual(backend.allHosts().count, 7)
    }

    // MARK: - 分组树工具(悬空 parent 降级 / 路径 / 级联 id)

    func testGroupPathRendersNestedNames() {
        let backend = makeBackend()

        XCTAssertEqual(GroupTree.path(of: "g-east", in: backend.allGroups()), "生产环境 / 华东")
        XCTAssertEqual(GroupTree.path(of: "g-test", in: backend.allGroups()), "测试环境")
        XCTAssertEqual(GroupTree.path(of: nil, in: backend.allGroups()), "根级")
        XCTAssertEqual(GroupTree.path(of: "ghost", in: backend.allGroups()), "根级")
    }

    func testGroupPathRendersThreeOrMoreLevels() {
        let groups = [
            HostGroup(id: "l1", name: "生产", parentID: nil),
            HostGroup(id: "l2", name: "华东", parentID: "l1"),
            HostGroup(id: "l3", name: "上海", parentID: "l2"),
            HostGroup(id: "l4", name: "机房A", parentID: "l3"),
        ]
        XCTAssertEqual(GroupTree.path(of: "l4", in: groups), "生产 / 华东 / 上海 / 机房A")
        XCTAssertEqual(GroupTree.path(of: "l1", in: groups), "生产")
    }

    func testGroupPathWithCycleDoesNotInfiniteLoop() {
        let groups = [
            HostGroup(id: "a", name: "A", parentID: "b"),
            HostGroup(id: "b", name: "B", parentID: "a"),
        ]
        // 环防御:visited 集合保证终止,不崩溃
        let path = GroupTree.path(of: "a", in: groups)
        XCTAssertFalse(path.isEmpty)
    }

    func testDescendantIDsIncludesAllNestedLevels() {
        let backend = makeBackend()
        let deep = backend.createGroup(name: "深层", parentID: "g-east")

        let ids = GroupTree.descendantIDs(of: "g-prod", in: backend.allGroups())

        XCTAssertEqual(ids, ["g-prod", "g-east", deep.id])
    }

    // MARK: - 代码片段 CRUD

    func testSnippetCrud() {
        let backend = makeBackend()
        var s = Snippet(id: "s-new", title: "新片段", tags: ["测试"], summary: "说明", code: "ls")

        backend.saveSnippet(s)
        XCTAssertEqual(backend.allSnippets().count, 4)

        s.title = "改名"
        backend.saveSnippet(s)
        XCTAssertEqual(backend.allSnippets().count, 4)
        XCTAssertEqual(backend.allSnippets().first { $0.id == "s-new" }?.title, "改名")

        backend.deleteSnippet(id: "s-new")
        XCTAssertEqual(backend.allSnippets().count, 3)

        // 意外操作:删除不存在的片段是 no-op
        backend.deleteSnippet(id: "ghost")
        XCTAssertEqual(backend.allSnippets().count, 3)
    }

    // MARK: - 连接前检查(阶段二接线用)

    func testPreconnectActionFollowsDemoFlag() {
        let backend = makeBackend()
        let hosts = backend.allHosts()

        XCTAssertEqual(AppModel.preconnectAction(for: hosts.first { $0.id == "h-newtoy" }!), .confirmTofu)
        XCTAssertEqual(AppModel.preconnectAction(for: hosts.first { $0.id == "h-legacy" }!), .keyMismatch)
        XCTAssertEqual(AppModel.preconnectAction(for: hosts.first { $0.id == "h-manual" }!), .askPassword)
        XCTAssertEqual(AppModel.preconnectAction(for: hosts.first { $0.id == "h-webprod" }!), .proceed)
    }

    // MARK: - 提供 HostConfigRecord(阶段二终端/SFTP 视图用)

    func testConfigRecordSynthesizedFromEntry() {
        let backend = makeBackend()

        let record = backend.configRecord(for: "h-webprod")

        XCTAssertEqual(record?.name, "web-prod")
        XCTAssertEqual(record?.host, "203.0.113.10")
        XCTAssertEqual(record?.port, 22)
        XCTAssertNil(backend.configRecord(for: "ghost"))
    }
}

import XCTest
import Combine

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// WorkspaceStore 分组状态测试：覆盖正常流程（创建/删除/重命名分组）、
/// 意外操作（删除不存在的分组）、边界条件（空分组自动清理）三类用例。
@MainActor
final class WorkspaceStoreGroupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        workspaceReset()
    }

    override func tearDown() {
        workspaceReset()
        super.tearDown()
    }

    // MARK: - 正常流程

    func testCreateGroupWithDefaultName() {
        let store = makeStore()
        let tabID = store.openTerminal(hostID: "h1")

        let groupID = store.createGroup(forTabID: tabID)

        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups.first?.id, groupID)
        XCTAssertEqual(store.groups.first?.name, "分组 1")
        XCTAssertEqual(store.groups.first?.tabIDs, [tabID])
        store.closeAll()
    }

    func testCreateGroupWithCustomName() {
        let store = makeStore()
        let tabID = store.openTerminal(hostID: "h1")

        let groupID = store.createGroup(forTabID: tabID, name: "开发环境")

        XCTAssertEqual(store.groups.first?.name, "开发环境")
        store.closeAll()
    }

    func testDeleteEmptyGroup() {
        let store = makeStore()
        let tabID = store.openTerminal(hostID: "h1")
        let groupID = store.createGroup(forTabID: tabID)
        store.removeTabFromGroup(tabID)

        XCTAssertTrue(store.groups.first?.isEmpty ?? false)

        store.deleteGroup(id: groupID)

        XCTAssertTrue(store.groups.isEmpty)
        store.closeAll()
    }

    func testDeleteNonEmptyGroupMovesTabsToUngrouped() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let groupID = store.createGroup(forTabID: tab1)
        store.moveTab(tab2, toGroup: groupID)

        XCTAssertEqual(store.groups.first?.tabIDs.count, 2)

        store.deleteGroup(id: groupID)

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertEqual(store.ungroupedTabIDs.count, 2)
        XCTAssertTrue(store.ungroupedTabIDs.contains(tab1))
        XCTAssertTrue(store.ungroupedTabIDs.contains(tab2))
        store.closeAll()
    }

    func testRenameGroup() {
        let store = makeStore()
        let tabID = store.openTerminal(hostID: "h1")
        let groupID = store.createGroup(forTabID: tabID)

        store.renameGroup(id: groupID, to: "新名称")

        XCTAssertEqual(store.groups.first?.name, "新名称")
        store.closeAll()
    }

    func testMoveTabToExistingGroup() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let groupID = store.createGroup(forTabID: tab1)

        store.moveTab(tab2, toGroup: groupID)

        XCTAssertEqual(store.groups.first?.tabIDs, [tab1, tab2])
        store.closeAll()
    }

    func testRemoveTabFromGroup() {
        let store = makeStore()
        let tabID = store.openTerminal(hostID: "h1")
        _ = store.createGroup(forTabID: tabID)

        store.removeTabFromGroup(tabID)

        XCTAssertTrue(store.groups.first?.isEmpty ?? false)
        XCTAssertEqual(store.ungroupedTabIDs, [tabID])
        store.closeAll()
    }

    // MARK: - 意外操作

    func testDeleteNonExistentGroupIsNoOp() {
        let store = makeStore()
        _ = store.openTerminal(hostID: "h1")

        store.deleteGroup(id: UUID())

        XCTAssertTrue(store.groups.isEmpty)
        store.closeAll()
    }

    func testRenameNonExistentGroupIsNoOp() {
        let store = makeStore()
        _ = store.openTerminal(hostID: "h1")

        store.renameGroup(id: UUID(), to: "新名称")

        XCTAssertTrue(store.groups.isEmpty)
        store.closeAll()
    }

    func testMoveTabToNonExistentGroupIsNoOp() {
        let store = makeStore()
        let tabID = store.openTerminal(hostID: "h1")

        store.moveTab(tabID, toGroup: UUID())

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(store.ungroupedTabIDs.contains(tabID))
        store.closeAll()
    }

    func testRemoveUngroupedTabFromGroupIsNoOp() {
        let store = makeStore()
        let tabID = store.openTerminal(hostID: "h1")
        // tabID 默认未分组

        store.removeTabFromGroup(tabID)

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(store.ungroupedTabIDs.contains(tabID))
        store.closeAll()
    }

    // MARK: - 边界条件

    func testCreateMultipleGroupsAutoIncrementName() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        _ = store.createGroup(forTabID: tab1)
        _ = store.createGroup(forTabID: tab2)
        _ = store.createGroup(forTabID: tab3)

        XCTAssertEqual(store.groups.map(\.name), ["分组 1", "分组 2", "分组 3"])
        store.closeAll()
    }

    func testEmptyGroupAutoCleanupOnTabClose() {
        let store = makeStore()
        let tabID = store.openTerminal(hostID: "h1")
        let groupID = store.createGroup(forTabID: tabID)

        XCTAssertEqual(store.groups.count, 1)

        store.close(tabID: tabID)

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertFalse(store.groups.contains(where: { $0.id == groupID }))
    }

    func testDisplayedTabsRespectsGroupOrder() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")
        let groupID = store.createGroup(forTabID: tab2)
        store.moveTab(tab3, toGroup: groupID)

        let displayed = store.displayedTabs
        // tab1 未分组，应在最后；tab2, tab3 在分组中
        XCTAssertEqual(displayed.map(\.id), [tab2, tab3, tab1])
        store.closeAll()
    }

    // MARK: - Helpers

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(hostNameProvider: { id in
            id == "h1" ? "web" : nil
        })
    }
}

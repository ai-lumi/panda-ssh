import XCTest
import Combine

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// WorkspaceStore 拖放事务测试：覆盖正常流程（未分组/同组重排提交）、
/// 意外操作（取消、来源/目标关闭）、边界条件（单页签、无效 ID、首尾位置、重复进入目标）。
@MainActor
final class WorkspaceTabDragTransactionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        workspaceReset()
    }

    override func tearDown() {
        workspaceReset()
        super.tearDown()
    }

    // MARK: - 正常流程

    func testUngroupedReorderCommittedOnDrop() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.commitTabReorder(snapshot)

        XCTAssertEqual(store.ungroupedTabIDs, [tab3, tab1, tab2])
        XCTAssertEqual(store.displayedTabs.map(\.id), [tab3, tab1, tab2])
        store.closeAll()
    }

    func testGroupedReorderCommittedOnDrop() {
        let store = makeStore()
        let (groupID, tab1, tab2, tab3) = makeGroupedTabs(store: store)

        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.commitTabReorder(snapshot)

        let group = store.groups.first(where: { $0.id == groupID })!
        XCTAssertEqual(group.tabIDs, [tab3, tab1, tab2])
        store.closeAll()
    }

    func testGroupedReorderUpdatesDisplayedOrder() {
        let store = makeStore()
        let (groupID, tab1, tab2, tab3) = makeGroupedTabs(store: store)

        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.commitTabReorder(snapshot)

        XCTAssertEqual(store.displayedTabs.map(\.id), [tab3, tab1, tab2])
        _ = groupID
        store.closeAll()
    }

    // MARK: - 意外操作

    func testCancelRestoresUngroupedOrder() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.rollbackTabReorder(snapshot)

        XCTAssertEqual(store.ungroupedTabIDs, [tab1, tab2, tab3])
        store.closeAll()
    }

    func testCancelRestoresGroupedOrder() {
        let store = makeStore()
        let (groupID, tab1, tab2, tab3) = makeGroupedTabs(store: store)

        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.rollbackTabReorder(snapshot)

        let group = store.groups.first(where: { $0.id == groupID })!
        XCTAssertEqual(group.tabIDs, [tab1, tab2, tab3])
        store.closeAll()
    }

    func testSourceClosedDuringDragDoesNotDuplicateOrLose() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.close(tabID: tab3)
        store.rollbackTabReorder(snapshot)

        let displayedIDs = store.displayedTabs.map(\.id)
        XCTAssertEqual(displayedIDs, [tab1, tab2])
        XCTAssertEqual(Set(displayedIDs), Set([tab1, tab2]))
        store.closeAll()
    }

    func testTargetClosedDuringDragRestoresSafely() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.close(tabID: tab1)
        store.rollbackTabReorder(snapshot)

        let displayedIDs = store.displayedTabs.map(\.id)
        XCTAssertEqual(displayedIDs, [tab2, tab3])
        store.closeAll()
    }

    // MARK: - 边界条件

    func testSingleTabReorderIsNoOp() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")

        let snapshot = store.beginTabReorder(for: tab1)
        store.commitTabReorder(snapshot)

        XCTAssertEqual(store.ungroupedTabIDs, [tab1])
        store.closeAll()
    }

    func testInvalidTabIDBeginIsNoOp() {
        let store = makeStore()
        _ = store.openTerminal(hostID: "h1")

        let fakeID = UUID()
        let snapshot = store.beginTabReorder(for: fakeID)
        store.commitTabReorder(snapshot)

        XCTAssertEqual(store.displayedTabs.count, 1)
        store.closeAll()
    }

    func testMoveToFirstPosition() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.commitTabReorder(snapshot)

        XCTAssertEqual(store.ungroupedTabIDs, [tab3, tab1, tab2])
        store.closeAll()
    }

    func testMoveToLastPosition() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        let snapshot = store.beginTabReorder(for: tab1)
        store.previewTabMove(tab1, before: tab3)
        store.commitTabReorder(snapshot)

        XCTAssertEqual(store.ungroupedTabIDs, [tab2, tab1, tab3])
        store.closeAll()
    }

    func testRepeatedEnterSameTargetIsIdempotent() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.previewTabMove(tab3, before: tab1)
        store.previewTabMove(tab3, before: tab1)
        store.commitTabReorder(snapshot)

        XCTAssertEqual(store.ungroupedTabIDs, [tab3, tab1, tab2])
        store.closeAll()
    }

    func testPreviewThenRollbackLeavesNoTrace() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        let original = store.ungroupedTabIDs
        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.rollbackTabReorder(snapshot)

        XCTAssertEqual(store.ungroupedTabIDs, original)
        XCTAssertFalse(store.hasPendingTabReorder)
        store.closeAll()
    }

    func testCancelPendingReorderRestoresOrderWithoutCallerSnapshot() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        _ = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        store.cancelPendingTabReorder()

        XCTAssertEqual(store.ungroupedTabIDs, [tab1, tab2, tab3])
        XCTAssertFalse(store.hasPendingTabReorder)
        store.closeAll()
    }

    func testCommitClearsPendingState() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        let snapshot = store.beginTabReorder(for: tab3)
        store.previewTabMove(tab3, before: tab1)
        XCTAssertTrue(store.hasPendingTabReorder)
        store.commitTabReorder(snapshot)

        XCTAssertFalse(store.hasPendingTabReorder)
        store.closeAll()
    }

    func testCrossGroupPreviewDoesNotCommit() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let groupA = store.createGroup(forTabID: tab1)
        let groupB = store.createGroup(forTabID: tab2)
        _ = groupB

        let originalGroupA = store.groups.first(where: { $0.id == groupA })!.tabIDs
        let snapshot = store.beginTabReorder(for: tab1)
        store.previewTabMove(tab1, before: tab2)
        store.commitTabReorder(snapshot)

        let groupAAfter = store.groups.first(where: { $0.id == groupA })!
        XCTAssertEqual(groupAAfter.tabIDs, originalGroupA, "跨组预览不应修改源分组")
        store.closeAll()
    }

    // MARK: - Helpers

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(hostNameProvider: { id in
            id == "h1" ? "web" : nil
        })
    }

    private func makeGroupedTabs(store: WorkspaceStore) -> (UUID, UUID, UUID, UUID) {
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")
        let groupID = store.createGroup(forTabID: tab1)
        store.moveTab(tab2, toGroup: groupID)
        store.moveTab(tab3, toGroup: groupID)
        return (groupID, tab1, tab2, tab3)
    }
}

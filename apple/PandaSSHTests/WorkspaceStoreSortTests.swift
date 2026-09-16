import XCTest
import Combine

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// WorkspaceStore 排序映射测试：覆盖正常流程（displayOrder 维护、新页签追加、
/// 关闭页签移除）、意外操作（拖拽到无效位置）、边界条件（单页签排序）三类用例。
@MainActor
final class WorkspaceStoreSortTests: XCTestCase {
    override func setUp() {
        super.setUp()
        workspaceReset()
    }

    override func tearDown() {
        workspaceReset()
        super.tearDown()
    }

    // MARK: - 正常流程

    func testNewTabAppendedToDisplayOrder() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        let displayed = store.displayedTabs
        XCTAssertEqual(displayed.map(\.id), [tab1, tab2, tab3])
        store.closeAll()
    }

    func testClosedTabRemovedFromDisplayOrder() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        store.close(tabID: tab2)

        let displayed = store.displayedTabs
        XCTAssertEqual(displayed.map(\.id), [tab1, tab3])
        _ = tab2 // suppress warning
        store.closeAll()
    }

    func testMoveTabChangesDisplayOrder() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        store.moveTabInDisplayOrder(tab3, toIndex: 0)

        let displayed = store.displayedTabs
        XCTAssertEqual(displayed.map(\.id), [tab3, tab1, tab2])
        store.closeAll()
    }

    func testMoveTabToMiddlePosition() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")
        let tab3 = store.openTerminal(hostID: "h1")

        store.moveTabInDisplayOrder(tab3, toIndex: 1)

        let displayed = store.displayedTabs
        XCTAssertEqual(displayed.map(\.id), [tab1, tab3, tab2])
        store.closeAll()
    }

    // MARK: - 意外操作

    func testMoveNonExistentTabIsNoOp() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")

        store.moveTabInDisplayOrder(UUID(), toIndex: 0)

        let displayed = store.displayedTabs
        XCTAssertEqual(displayed.map(\.id), [tab1, tab2])
        store.closeAll()
    }

    func testMoveToInvalidIndexIsNoOp() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")

        store.moveTabInDisplayOrder(tab1, toIndex: 100)

        let displayed = store.displayedTabs
        XCTAssertEqual(displayed.map(\.id), [tab1, tab2])
        store.closeAll()
    }

    func testMoveToNegativeIndexIsNoOp() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")

        store.moveTabInDisplayOrder(tab1, toIndex: -1)

        let displayed = store.displayedTabs
        XCTAssertEqual(displayed.map(\.id), [tab1, tab2])
        store.closeAll()
    }

    // MARK: - 边界条件

    func testSingleTabDisplayOrder() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")

        let displayed = store.displayedTabs
        XCTAssertEqual(displayed.map(\.id), [tab1])
        store.closeAll()
    }

    func testEmptyDisplayOrder() {
        let store = makeStore()

        let displayed = store.displayedTabs
        XCTAssertTrue(displayed.isEmpty)
    }

    func testMoveTabToSameIndexIsNoOp() {
        let store = makeStore()
        let tab1 = store.openTerminal(hostID: "h1")
        let tab2 = store.openTerminal(hostID: "h1")

        store.moveTabInDisplayOrder(tab1, toIndex: 0)

        let displayed = store.displayedTabs
        XCTAssertEqual(displayed.map(\.id), [tab1, tab2])
        store.closeAll()
    }

    // MARK: - Helpers

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(hostNameProvider: { id in
            id == "h1" ? "web" : nil
        })
    }
}

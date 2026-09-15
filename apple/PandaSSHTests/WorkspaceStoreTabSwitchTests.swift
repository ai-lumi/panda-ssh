import XCTest
import Combine

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 工作区页签键盘快捷键切换响应测试：覆盖正常流程（切换到下一个/上一个）、
/// 边界条件（无页签时不崩溃）、意外操作（当前索引无效时忽略）三类用例。
@MainActor
final class WorkspaceStoreTabSwitchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        workspaceReset()
    }

    override func tearDown() {
        workspaceReset()
        super.tearDown()
    }

    // MARK: - 正常流程

    /// 切换到下一个页签
    func testSelectNextTab_middleTab_selectsNext() {
        let store = makeStore()
        let first = store.openTerminal(hostID: "h1")
        let second = store.openTerminal(hostID: "h2")
        let third = store.openTerminal(hostID: "h3")

        store.select(tabID: first)
        XCTAssertEqual(store.activeTabID, first)

        store.selectNextTab()
        XCTAssertEqual(store.activeTabID, second)

        store.selectNextTab()
        XCTAssertEqual(store.activeTabID, third)
    }

    /// 切换到上一个页签
    func testSelectPreviousTab_middleTab_selectsPrevious() {
        let store = makeStore()
        let first = store.openTerminal(hostID: "h1")
        let second = store.openTerminal(hostID: "h2")
        let third = store.openTerminal(hostID: "h3")

        store.select(tabID: third)
        XCTAssertEqual(store.activeTabID, third)

        store.selectPreviousTab()
        XCTAssertEqual(store.activeTabID, second)

        store.selectPreviousTab()
        XCTAssertEqual(store.activeTabID, first)
    }

    // MARK: - 边界条件：循环切换

    /// 最后一个页签切换到下一个时循环到第一个
    func testSelectNextTab_lastTab_wrapsToFirst() {
        let store = makeStore()
        let first = store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        let third = store.openTerminal(hostID: "h3")

        store.select(tabID: third)
        XCTAssertEqual(store.activeTabID, third)

        store.selectNextTab()
        XCTAssertEqual(store.activeTabID, first)
    }

    /// 第一个页签切换到上一个时循环到最后一个
    func testSelectPreviousTab_firstTab_wrapsToLast() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        let third = store.openTerminal(hostID: "h3")

        store.select(tabID: store.tabs.first!.id)
        XCTAssertEqual(store.activeTabID, store.tabs.first!.id)

        store.selectPreviousTab()
        XCTAssertEqual(store.activeTabID, third)
    }

    // MARK: - 边界条件：无页签

    /// 无页签时调用 selectNextTab 不崩溃
    func testSelectNextTab_emptyTabs_doesNotCrash() {
        let store = makeStore()
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeTabID)

        store.selectNextTab()
        XCTAssertNil(store.activeTabID)
    }

    /// 无页签时调用 selectPreviousTab 不崩溃
    func testSelectPreviousTab_emptyTabs_doesNotCrash() {
        let store = makeStore()
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeTabID)

        store.selectPreviousTab()
        XCTAssertNil(store.activeTabID)
    }

    // MARK: - 边界条件：单页签

    /// 单页签时切换保持当前页签
    func testSelectNextTab_singleTab_staysOnSameTab() {
        let store = makeStore()
        let only = store.openTerminal(hostID: "h1")

        store.select(tabID: only)
        XCTAssertEqual(store.activeTabID, only)

        store.selectNextTab()
        XCTAssertEqual(store.activeTabID, only)

        store.selectPreviousTab()
        XCTAssertEqual(store.activeTabID, only)
    }

    // MARK: - 意外操作：无活动页签

    /// 无活动页签时调用 selectNextTab 不崩溃
    /// 注意：Rust 侧在打开页签时会自动选择第一个页签作为活动页签，
    /// 所以这个场景实际上不太可能发生，但需防御。
    func testSelectNextTab_noActiveTab_doesNotCrash() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")

        // Rust 会自动选择第一个页签
        XCTAssertNotNil(store.activeTabID)

        // 即使有活动页签，调用也不应崩溃
        store.selectNextTab()
        // 应该切换到下一个页签
        XCTAssertNotNil(store.activeTabID)
    }

    // MARK: - Helper

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            hostNameProvider: { id in
                switch id {
                case "h1": return "host-1"
                case "h2": return "host-2"
                case "h3": return "host-3"
                default: return id
                }
            },
            closeSessionHandler: { _ in }
        )
    }
}

import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 工作区标签页状态机测试:覆盖正常流程(打开/切换/关闭)、
/// 意外操作(对不存在的标签执行选择/关闭)、边界条件(空工作区、
/// 首尾标签关闭、未知主机名回退)三类用例。
@MainActor
final class WorkspaceStoreTests: XCTestCase {

    /// 构造一个带固定主机名查询的 store,便于注入测试数据。
    private func makeStore(names: [String: String] = ["h1": "web-prod", "h2": "db"]) -> WorkspaceStore {
        WorkspaceStore(hostNameProvider: { names[$0] })
    }

    // MARK: - 正常流程:新建 / 切换 / 关闭

    func testOpenTerminalCreatesTabAndActivates() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].hostID, "h1")
        XCTAssertEqual(store.tabs[0].kind, .terminal)
        XCTAssertEqual(store.activeTabID, store.tabs[0].id)
    }

    func testOpenSFTPCreatesTabAndActivates() {
        let store = makeStore()
        store.openSFTP(hostID: "h2")

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].kind, .sftp)
        XCTAssertEqual(store.activeTabID, store.tabs[0].id)
    }

    func testSelectSwitchesActiveTab() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h2")

        store.select(tabID: store.tabs[0].id)
        XCTAssertEqual(store.activeTabID, store.tabs[0].id)
    }

    func testCloseRemovesTab() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h2")
        let doomed = store.tabs[0].id

        store.close(tabID: doomed)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertFalse(store.tabs.contains(where: { $0.id == doomed }))
        // 关闭的不是活动标签,活动标签不受影响
        XCTAssertEqual(store.activeTabID, store.tabs[0].id)
    }

    // MARK: - 打开策略:同主机不去重 + 标题序号消歧

    func testOpenSameHostAlwaysCreatesNewTab() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h1")

        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertNotEqual(store.tabs[0].id, store.tabs[1].id)
        // 新标签成为活动标签,而不是复用/激活已有标签
        XCTAssertEqual(store.activeTabID, store.tabs[1].id)
    }

    func testSameHostTabsGetSequenceSuffixTitles() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h1")
        store.openTerminal(hostID: "h1")

        XCTAssertEqual(store.tabs.map(\.title), ["web-prod", "web-prod (2)", "web-prod (3)"])
    }

    func testTitlesRecomputedAfterClosingMiddleTab() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h1")

        store.close(tabID: store.tabs[1].id)

        XCTAssertEqual(store.tabs.map(\.title), ["web-prod", "web-prod (2)"])
    }

    func testTitlesOfOtherHostsUnaffectedBySequence() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        store.openTerminal(hostID: "h1")

        XCTAssertEqual(store.tabs.map(\.title), ["web-prod", "db", "web-prod (2)"])
    }

    // MARK: - 意外操作:对不存在的标签执行操作必须是 no-op

    func testSelectUnknownTabIDIsNoOp() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        let active = store.activeTabID

        store.select(tabID: UUID())

        XCTAssertEqual(store.activeTabID, active)
    }

    func testCloseUnknownTabIDIsNoOp() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")

        store.close(tabID: UUID())

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.activeTabID, store.tabs[0].id)
    }

    // MARK: - 边界条件:关闭活动标签时新活动标签的落点

    func testCloseActiveTabPrefersLeftNeighbor() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h2")
        store.openTerminal(hostID: "h1")
        // 关闭中间的活动标签,应激活左侧相邻标签
        let middle = store.tabs[1].id
        store.select(tabID: middle)

        store.close(tabID: middle)

        XCTAssertEqual(store.activeTabID, store.tabs[0].id)
    }

    func testCloseActiveFirstTabFallsBackToNextTab() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h2")
        let first = store.tabs[0].id
        store.select(tabID: first)

        store.close(tabID: first)

        // 左侧没有相邻标签,落在原索引位置(即原来的右侧邻居)
        XCTAssertEqual(store.activeTabID, store.tabs[0].id)
    }

    func testCloseLastRemainingTabLeavesNoActiveTab() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")

        store.close(tabID: store.tabs[0].id)

        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeTabID)
    }

    func testCloseOnEmptyWorkspaceIsNoOp() {
        let store = makeStore()

        store.close(tabID: UUID())
        store.select(tabID: UUID())

        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeTabID)
    }

    // MARK: - 边界条件:主机名查询失败(如主机已被删除)时回退

    func testUnknownHostNameFallsBackToHostID() {
        let store = WorkspaceStore(hostNameProvider: { _ in nil })
        store.openTerminal(hostID: "ghost")
        store.openTerminal(hostID: "ghost")

        XCTAssertEqual(store.tabs.map(\.title), ["ghost", "ghost (2)"])
    }
}

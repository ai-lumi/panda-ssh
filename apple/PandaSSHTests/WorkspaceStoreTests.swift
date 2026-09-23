import XCTest
import Combine

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
    override func setUp() {
        super.setUp()
        workspaceReset()
    }

    override func tearDown() {
        workspaceReset()
        super.tearDown()
    }

    /// 真实 FFI 往返：确认与取消前不能释放 SSH；确认后只关闭目标页签。
    func testCloseConfirmationRoundTripPreservesOtherSession() {
        var released: [UUID] = []
        let store = WorkspaceStore(hostNameProvider: { _ in "web" },
                                   closeSessionHandler: { released.append($0.id) })
        let first = store.openTerminal(hostID: "h1")
        let second = store.openTerminal(hostID: "h1")
        let host = HostEntry(id: "h1", name: "web", address: "example.test", port: 22,
                             username: "test")
        let a = TerminalSessionStore(host: host)
        let b = TerminalSessionStore(host: host)
        a.finishConnecting()
        b.finishConnecting()
        store.registerTerminal(a, for: first)
        store.registerTerminal(b, for: second)
        store.reportConnectionStatus(.connected, forTabID: first)
        store.reportConnectionStatus(.connected, forTabID: second)

        store.requestClose(tabID: first)

        XCTAssertEqual(store.pendingCloseTabID, first)
        XCTAssertEqual(store.tabs.map(\.id), [first, second])
        XCTAssertEqual(a.phase, .shell)
        XCTAssertNotNil(a.connection)
        XCTAssertTrue(released.isEmpty)
        XCTAssertEqual(store.activeTabID, second, "关闭请求不选择其他页签")

        store.cancelClose()
        XCTAssertNil(store.pendingCloseTabID)
        XCTAssertNil(workspacePendingClose())
        XCTAssertEqual(store.connectionStatus(forTabID: first), .connected)
        XCTAssertEqual(a.phase, .shell)

        store.requestClose(tabID: first)
        store.confirmClose()

        XCTAssertEqual(store.tabs.map(\.id), [second])
        XCTAssertEqual(workspaceTabList().compactMap { UUID(uuidString: $0.id) }, [second])
        XCTAssertNil(store.pendingCloseTabID)
        XCTAssertNil(workspacePendingClose())
        XCTAssertEqual(released, [first])
        XCTAssertNil(a.connection)
        XCTAssertEqual(b.phase, .shell)
        XCTAssertNotNil(b.connection)
        XCTAssertEqual(store.connectionStatus(forHostID: "h1"), .connected)

        store.confirmClose()
        store.requestClose(tabID: first)
        XCTAssertEqual(released, [first], "重复确认或关闭不得重复释放")
        store.requestCloseAll()
    }

    func testFailurePageCloseRemovesLastTabAndIgnoresLateStatus() {
        var released: [UUID] = []
        let store = WorkspaceStore(hostNameProvider: { _ in "web" },
                                   closeSessionHandler: { released.append($0.id) })
        let id = store.openTerminal(hostID: "h1")
        store.reportConnectionStatus(.failed, forTabID: id)

        // 与失败页「关闭标签」按钮相同的执行入口。
        store.close(tabID: id)
        store.close(tabID: id)
        store.requestClose(tabID: UUID())
        store.reportConnectionStatus(.connected, forTabID: id)

        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertTrue(workspaceTabList().isEmpty)
        XCTAssertNil(store.activeTabID)
        XCTAssertNil(workspaceActiveTabId())
        XCTAssertNil(store.pendingCloseTabID)
        XCTAssertEqual(store.connectionStatus(forTabID: id), .inactive)
        XCTAssertEqual(released, [id])
    }

    func testTabSelectionRoundTripsThroughRust() {
        let store = makeStore()
        let first = store.openTerminal(hostID: "h1")
        _ = store.openTerminal(hostID: "h2")

        store.select(tabID: first)

        XCTAssertEqual(store.activeTabID, first)
        XCTAssertEqual(workspaceActiveTabId().flatMap(UUID.init(uuidString:)), first)
        store.select(tabID: UUID())
        XCTAssertEqual(store.activeTabID, first)
    }

    func testClosingTabImmediatelyClosesOnlyItsRegisteredTerminal() {
        let store = WorkspaceStore(hostNameProvider: { _ in "web" })
        let first = store.openTerminal(hostID: "h1")
        let second = store.openTerminal(hostID: "h1")
        let host = HostEntry(id: "h1", name: "web", address: "example.test", port: 22,
                             username: "test", groupID: nil, fingerprint: "test", demo: nil)
        let a = TerminalSessionStore(host: host)
        let b = TerminalSessionStore(host: host)
        a.finishConnecting()
        b.finishConnecting()
        store.registerTerminal(a, for: first)
        store.registerTerminal(b, for: second)
        store.close(tabID: first)
        XCTAssertEqual(a.phase, .failed)
        XCTAssertNil(a.connection)
        XCTAssertEqual(b.phase, .shell)
        XCTAssertNotNil(b.connection)
        store.requestCloseAll()
        XCTAssertEqual(b.phase, .failed)
    }

    func testSftpTabsRemainRetainedWhenAnotherTabIsActive() {
        let store = WorkspaceStore(hostNameProvider: { $0 })
        let first = store.openSFTP(hostID: "h1")
        _ = store.openTerminal(hostID: "h2")

        let policy = WorkspaceSftpTabPolicy(tabs: store.tabs, activeTabID: store.activeTabID)

        XCTAssertEqual(policy.retainedTabIDs, [first])
        XCTAssertFalse(policy.isVisible(first))
    }

    /// 构造一个带固定主机名查询的 store,便于注入测试数据。
    private func makeStore(names: [String: String] = ["h1": "web-prod", "h2": "db"]) -> WorkspaceStore {
        WorkspaceStore(hostNameProvider: { names[$0] })
    }

    // MARK: - 终端页签会话保持策略

    func test终端页签策略在切换时保留全部终端() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h2")
        store.openTerminal(hostID: "h2")
        let firstTerminal = store.tabs[0].id

        let policy = WorkspaceTerminalTabPolicy(tabs: store.tabs, activeTabID: firstTerminal)

        XCTAssertEqual(policy.retainedTabIDs, [store.tabs[0].id, store.tabs[2].id])
        XCTAssertEqual(policy.visibleTabID, firstTerminal)
    }

    func test终端页签策略遇到未知活动标签仍保留会话() {
        let store = makeStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")

        let policy = WorkspaceTerminalTabPolicy(tabs: store.tabs, activeTabID: UUID())

        XCTAssertEqual(policy.retainedTabIDs, store.tabs.map(\.id))
        XCTAssertNil(policy.visibleTabID)
    }

    func test终端页签策略处理空和单终端边界() {
        XCTAssertEqual(WorkspaceTerminalTabPolicy(tabs: [], activeTabID: nil).retainedTabIDs, [])

        let store = makeStore()
        store.openTerminal(hostID: "h1")
        let policy = WorkspaceTerminalTabPolicy(tabs: store.tabs, activeTabID: store.tabs[0].id)
        XCTAssertEqual(policy.retainedTabIDs, [store.tabs[0].id])
        XCTAssertEqual(policy.visibleTabID, store.tabs[0].id)
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

        XCTAssertEqual(store.tabs.map(\.title), ["web-prod", "web-prod (3)"])
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

    // MARK: - 组1: 标签页右键批量关闭

    /// 构造带连接释放记录、重连记录与终端已连接判断的 store。
    private func makeLifecycleStore(
        names: [String: String] = ["h1": "web-prod", "h2": "db"],
        transfers: TransferStore? = nil
    ) -> (store: WorkspaceStore, disconnected: Box<[String]>, reconnected: Box<[UUID]>) {
        let disconnected = Box<[String]>([])
        let reconnected = Box<[UUID]>([])
        let store = WorkspaceStore(
            hostNameProvider: { names[$0] },
            closeSessionHandler: { disconnected.value.append($0.hostID) },
            transferStore: transfers,
            reconnectHandler: { reconnected.value.append($0) }
        )
        return (store, disconnected, reconnected)
    }

    func testCloseOthersKeepsTargetAndActivatesIt() {
        let (store, disconnected, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h2")
        store.openTerminal(hostID: "h1")
        let keep = store.tabs[1].id

        store.requestCloseOthers(keeping: keep)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs.first?.id, keep)
        XCTAssertEqual(store.activeTabID, keep)
        // 两个 h1 标签分别释放，不是合并成一次主机级断开。
        XCTAssertEqual(disconnected.value, ["h1", "h1"])
    }

    func testCloseAllClearsTabsAndDisconnectsEachHost() {
        let (store, disconnected, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h2")

        store.requestCloseAll()

        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeTabID)
        XCTAssertEqual(disconnected.value.sorted(), ["h1", "h2"])
    }

    func testReconnectTerminalInvokesHandlerForTerminalOnly() {
        let (store, _, reconnected) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h1")
        let terminalID = store.tabs[0].id
        let sftpID = store.tabs[1].id

        store.reconnectSession(tabID: terminalID)
        store.reconnectSession(tabID: sftpID)

        XCTAssertEqual(reconnected.value, [terminalID])
    }

    // MARK: - 组2: SSH 终端关闭二次确认

    func testRequestCloseConnectedTerminalSetsPendingWithoutClosing() {
        let (store, disconnected, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.reportConnectionStatus(.connected, forTabID: store.tabs[0].id)
        let id = store.tabs[0].id

        store.requestClose(tabID: id)

        XCTAssertEqual(store.pendingCloseTabID, id)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertTrue(disconnected.value.isEmpty)
    }

    func testRequestCloseConnectingTerminalClosesDirectly() {
        let (store, disconnected, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")

        store.requestClose(tabID: store.tabs[0].id)

        XCTAssertNil(store.pendingCloseTabID)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(disconnected.value, ["h1"])
    }

    func testRequestCloseSFTPTabClosesDirectly() {
        let (store, disconnected, _) = makeLifecycleStore()
        store.openSFTP(hostID: "h1")
        store.reportConnectionStatus(.connected, forTabID: store.tabs[0].id)

        store.requestClose(tabID: store.tabs[0].id)

        XCTAssertNil(store.pendingCloseTabID)
        XCTAssertTrue(store.tabs.isEmpty)
    }

    func testConfirmCloseClosesPendingTab() {
        let (store, disconnected, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.reportConnectionStatus(.connected, forTabID: store.tabs[0].id)
        store.requestClose(tabID: store.tabs[0].id)
        XCTAssertEqual(store.pendingCloseTabID, store.tabs[0].id)

        store.confirmClose()

        XCTAssertNil(store.pendingCloseTabID)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(disconnected.value, ["h1"])
    }

    func testCancelCloseKeepsPendingTab() {
        let (store, disconnected, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.reportConnectionStatus(.connected, forTabID: store.tabs[0].id)
        let id = store.tabs[0].id
        store.requestClose(tabID: id)

        store.cancelClose()

        XCTAssertNil(store.pendingCloseTabID)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].id, id)
        XCTAssertTrue(disconnected.value.isEmpty)
    }

    // MARK: - 组3: SFTP 关闭与传输延续 + 连接释放协调

    /// 构造一个可控状态的 TransferStore:tasks 直接反映注入的记录。
    private func makeControlledTransfers(_ records: [TransferRecord]) -> (store: TransferStore, source: ControlledTransferSource) {
        let source = ControlledTransferSource(records: records)
        let store = TransferStore(source: source, batchSource: nil)
        store.tick()
        return (store, source)
    }

    /// 版本号单调递增,确保 TransferStore 的 version 增量检测能识别状态变化。
    private var recordVersion: UInt64 = 0
    private func record(hostID: String, status: TransferStatus) -> TransferRecord {
        recordVersion += 1
        return TransferRecord(
            id: UUID(), direction: .upload, name: "f", size: 100,
            transferred: 0, status: status, source: "/l/f", destination: "/r/f",
            hostID: hostID, error: nil, version: recordVersion, failAt: nil,
            isBatch: false, batchSources: [], batchDestDir: "",
            groupID: nil, groupName: nil, pendingConflict: nil
        )
    }

    func testCloseLastTabWithActiveTransfersReleasesOnlyTabImmediately() {
        let (transfers, _) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, disconnected, _) = makeLifecycleStore(transfers: transfers)
        store.openSFTP(hostID: "h1")

        store.close(tabID: store.tabs[0].id)

        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(disconnected.value, ["h1"])
        XCTAssertEqual(transfers.tasks.first?.status, .running)
    }

    func testCloseLastTabWithoutActiveTransfersDisconnectsImmediately() {
        let (transfers, _) = makeControlledTransfers([record(hostID: "h1", status: .done)])
        let (store, disconnected, _) = makeLifecycleStore(transfers: transfers)
        store.openSFTP(hostID: "h1")

        store.close(tabID: store.tabs[0].id)

        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(disconnected.value, ["h1"])
        XCTAssertEqual(transfers.tasks.first?.status, .done)
    }

    func testTransfersFinishingDoesNotCloseTabAgain() {
        let (transfers, source) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, disconnected, _) = makeLifecycleStore(transfers: transfers)
        store.openSFTP(hostID: "h1")
        store.close(tabID: store.tabs[0].id)
        XCTAssertEqual(disconnected.value, ["h1"])

        // 任务进入终态
        source.records = [record(hostID: "h1", status: .done)]
        transfers.tick()

        XCTAssertEqual(disconnected.value, ["h1"])
        XCTAssertEqual(transfers.tasks.first?.status, .done)
    }

    func testTransfersStillActiveAfterTabConnectionReleased() {
        let (transfers, source) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, disconnected, _) = makeLifecycleStore(transfers: transfers)
        store.openSFTP(hostID: "h1")
        store.close(tabID: store.tabs[0].id)

        source.records = [record(hostID: "h1", status: .running)]
        transfers.tick()

        XCTAssertEqual(transfers.tasks.first?.status, .running)
        XCTAssertEqual(disconnected.value, ["h1"])
    }

    func testStillHasTerminalTabNoDisconnectAfterTransferDone() {
        let (transfers, source) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, disconnected, _) = makeLifecycleStore(transfers: transfers)
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h1")
        let sftpID = store.tabs[1].id

        store.close(tabID: sftpID)
        source.records = [record(hostID: "h1", status: .done)]
        transfers.tick()

        XCTAssertEqual(disconnected.value, ["h1"], "只释放已关闭的 SFTP 标签，不再触碰终端")
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs.first?.kind, .terminal)
    }

    func testCloseSFTPTabDoesNotCancelTransfers() {
        let (transfers, source) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, _, _) = makeLifecycleStore(transfers: transfers)
        store.openSFTP(hostID: "h1")

        store.close(tabID: store.tabs[0].id)

        // 传输任务状态不变(仍 running)
        XCTAssertEqual(transfers.tasks.first?.status, .running)
        XCTAssertEqual(transfers.tasks.count, 1)
        _ = source
    }

    // MARK: - 组2.5: 批量关闭聚合确认

    func testRequestCloseOthersWithConnectedTerminalsSetsPendingWithoutClosing() {
        let (store, _, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        store.openSFTP(hostID: "h1")
        let keep = store.tabs[1].id
        store.reportConnectionStatus(.connected, forTabID: store.tabs[0].id) // 第一个终端已连接,会被关闭

        store.requestCloseOthers(keeping: keep)

        XCTAssertEqual(store.pendingBatchClose?.scope, .others(keeping: keep))
        XCTAssertEqual(store.pendingBatchClose?.connectedTerminalCount, 1)
        XCTAssertEqual(store.tabs.count, 3, "未实际关闭")
    }

    func testRequestCloseOthersWithoutConnectedTerminalsClosesDirectly() {
        let (store, _, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        let keep = store.tabs[1].id

        store.requestCloseOthers(keeping: keep)

        XCTAssertNil(store.pendingBatchClose)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs.first?.id, keep)
    }

    func testRequestCloseAllWithConnectedTerminalsSetsPendingWithoutClosing() {
        let (store, _, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        store.reportConnectionStatus(.connected, forTabID: store.tabs[0].id)
        store.reportConnectionStatus(.connected, forTabID: store.tabs[1].id)

        store.requestCloseAll()

        XCTAssertEqual(store.pendingBatchClose?.scope, .all)
        XCTAssertEqual(store.pendingBatchClose?.connectedTerminalCount, 2)
        XCTAssertEqual(store.tabs.count, 2, "未实际关闭")
    }

    func testRequestCloseAllWithoutConnectedTerminalsClosesDirectly() {
        let (store, _, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")

        store.requestCloseAll()

        XCTAssertNil(store.pendingBatchClose)
        XCTAssertTrue(store.tabs.isEmpty)
    }

    func testConfirmBatchCloseOthersExecutesClose() {
        let (store, disconnected, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        store.openSFTP(hostID: "h1")
        let keep = store.tabs[1].id
        store.reportConnectionStatus(.connected, forTabID: store.tabs[0].id)
        store.requestCloseOthers(keeping: keep)
        XCTAssertNotNil(store.pendingBatchClose)

        store.confirmBatchClose()

        XCTAssertNil(store.pendingBatchClose)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs.first?.id, keep)
        XCTAssertEqual(store.activeTabID, keep)
        XCTAssertEqual(disconnected.value, ["h1", "h1"])
    }

    func testConfirmBatchCloseAllExecutesClose() {
        let (store, disconnected, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        store.reportConnectionStatus(.connected, forTabID: store.tabs[0].id)
        store.reportConnectionStatus(.connected, forTabID: store.tabs[1].id)
        store.requestCloseAll()
        XCTAssertNotNil(store.pendingBatchClose)

        store.confirmBatchClose()

        XCTAssertNil(store.pendingBatchClose)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeTabID)
        XCTAssertEqual(disconnected.value.sorted(), ["h1", "h2"])
    }

    func testCancelBatchCloseKeepsTabs() {
        let (store, _, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        let tabID = store.tabs[0].id
        store.reportConnectionStatus(.connected, forTabID: tabID)
        store.requestCloseAll()
        XCTAssertNotNil(store.pendingBatchClose)

        store.cancelBatchClose()

        XCTAssertNil(store.pendingBatchClose)
        XCTAssertEqual(store.tabs.count, 1)
    }

    // MARK: - 终端连接态独立于视图生命周期(修复:非活动终端标签的关闭确认)

    /// 通过真实工作区 FFI 上报连接状态。
    /// 模拟:终端标签已连接但当前不在屏幕上(SFTP 为活动标签),
    /// 在 SFTP 标签上右键「关闭其他」→ 应弹聚合确认。
    func testMarkTerminalConnectedTriggersBatchCloseConfirmation() {
        let disconnected = Box<[String]>([])
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            closeSessionHandler: { disconnected.value.append($0.hostID) }
        )
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h1")
        let terminalID = store.tabs[0].id
        let sftpID = store.tabs[1].id

        // 终端已连接(视图可能已因切到 SFTP 而销毁,但 store 仍记录连接态)
        store.reportConnectionStatus(.connected, forTabID: terminalID)

        store.requestCloseOthers(keeping: sftpID)

        XCTAssertEqual(store.pendingBatchClose?.scope, .others(keeping: sftpID))
        XCTAssertEqual(store.pendingBatchClose?.connectedTerminalCount, 1)
        XCTAssertEqual(store.tabs.count, 2, "确认前不实际关闭")
    }

    /// reportConnectionStatus(.failed) 后不再视为已连接 → 关闭其他不弹确认。
    func testMarkTerminalDisconnectedClearsConfirmation() {
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            closeSessionHandler: { _ in }
        )
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h1")
        let terminalID = store.tabs[0].id
        let sftpID = store.tabs[1].id

        store.reportConnectionStatus(.connected, forTabID: terminalID)
        store.reportConnectionStatus(.failed, forTabID: terminalID)

        store.requestCloseOthers(keeping: sftpID)

        XCTAssertNil(store.pendingBatchClose, "终端已断开,不需要确认")
        XCTAssertEqual(store.tabs.count, 1)
    }

    /// 关闭标签后,该终端不再视为已连接(防止幽灵确认)。
    func testCloseRemovesTerminalFromConnectedSet() {
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            closeSessionHandler: { _ in }
        )
        store.openTerminal(hostID: "h1")
        let terminalID = store.tabs[0].id
        store.reportConnectionStatus(.connected, forTabID: terminalID)

        store.close(tabID: terminalID)

        // 关闭后打开 SFTP,关闭其他不应弹确认(终端已不在集合中)
        store.openSFTP(hostID: "h1")
        store.requestCloseOthers(keeping: store.tabs[0].id)
        XCTAssertNil(store.pendingBatchClose)
    }

    /// 单标签关闭:真实 FFI 状态上报后 requestClose 弹确认。
    func testRequestCloseUsesReportedConnectionStatus() {
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            closeSessionHandler: { _ in }
        )
        store.openTerminal(hostID: "h1")
        let id = store.tabs[0].id

        // 未标记连接 → 直接关闭
        store.requestClose(tabID: id)
        XCTAssertEqual(store.tabs.count, 0, "未连接终端直接关闭")

        // 重新打开并标记连接
        store.openTerminal(hostID: "h1")
        let newID = store.tabs[0].id
        store.reportConnectionStatus(.connected, forTabID: newID)

        store.requestClose(tabID: newID)
        XCTAssertEqual(store.pendingCloseTabID, newID, "已连接终端需确认")
    }

    // MARK: - 页签与主机连接状态

    func testTerminalConnectionStatusTracksConnectingConnectedAndFailure() {
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            closeSessionHandler: { _ in }
        )
        let id = store.openTerminal(hostID: "h1")

        XCTAssertEqual(store.connectionStatus(forTabID: id), .connecting)
        XCTAssertEqual(store.connectionStatus(forHostID: "h1"), .connecting)

        store.reportConnectionStatus(.connected, forTabID: id)
        XCTAssertEqual(store.connectionStatus(forTabID: id), .connected)
        XCTAssertEqual(store.connectionStatus(forHostID: "h1"), .connected)

        store.reportConnectionStatus(.failed, forTabID: id)
        XCTAssertEqual(store.connectionStatus(forTabID: id), .failed)
        XCTAssertEqual(store.connectionStatus(forHostID: "h1"), .failed)
    }

    func testHostIsReachableWhenAnyOfItsTabsIsConnected() {
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            closeSessionHandler: { _ in }
        )
        let failed = store.openTerminal(hostID: "h1")
        let connected = store.openSFTP(hostID: "h1")

        store.reportConnectionStatus(.failed, forTabID: failed)
        store.reportConnectionStatus(.connected, forTabID: connected)

        XCTAssertEqual(store.connectionStatus(forHostID: "h1"), .connected)
    }

    func testClosingTabRemovesItsConnectionStatus() {
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            closeSessionHandler: { _ in }
        )
        let id = store.openTerminal(hostID: "h1")
        store.reportConnectionStatus(.connected, forTabID: id)

        store.close(tabID: id)

        XCTAssertEqual(store.connectionStatus(forTabID: id), .inactive)
        XCTAssertEqual(store.connectionStatus(forHostID: "h1"), .inactive)
    }

    func testRemoteTerminalExitOnlyUpdatesWorkspaceStatus() {
        let disconnected = Box<[String]>([])
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            closeSessionHandler: { disconnected.value.append($0.hostID) }
        )
        let id = store.openTerminal(hostID: "h1")
        store.reportConnectionStatus(.connected, forTabID: id)

        store.handleTerminalSessionEnded(tabID: id)

        XCTAssertEqual(store.connectionStatus(forTabID: id), .failed)
        XCTAssertTrue(disconnected.value.isEmpty, "会话自行释放，工作区不得二次按主机断开")
    }

    func testRemoteTerminalExitKeepsHostConnectionForOtherActiveTab() {
        let disconnected = Box<[String]>([])
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            closeSessionHandler: { disconnected.value.append($0.hostID) }
        )
        let ended = store.openTerminal(hostID: "h1")
        let active = store.openSFTP(hostID: "h1")
        store.reportConnectionStatus(.connected, forTabID: ended)
        store.reportConnectionStatus(.connected, forTabID: active)

        store.handleTerminalSessionEnded(tabID: ended)

        XCTAssertEqual(store.connectionStatus(forTabID: ended), .failed)
        XCTAssertTrue(disconnected.value.isEmpty)
    }

    func testRemoteTerminalExitAndTransferCompletionDoNotTriggerHostDisconnect() {
        let (transfers, source) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, disconnected, _) = makeLifecycleStore(transfers: transfers)
        let id = store.openTerminal(hostID: "h1")
        store.reportConnectionStatus(.connected, forTabID: id)

        store.handleTerminalSessionEnded(tabID: id)

        XCTAssertTrue(disconnected.value.isEmpty)
        XCTAssertEqual(transfers.tasks.first?.status, .running)

        source.records = [record(hostID: "h1", status: .done)]
        transfers.tick()

        XCTAssertTrue(disconnected.value.isEmpty)
        XCTAssertEqual(transfers.tasks.first?.status, .done)
    }
}

/// 使用真实工作区 FFI 验证视图观察契约，不建立网络连接。
@MainActor
final class WorkspaceConnectionStatusObservationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        workspaceReset()
    }

    override func tearDown() {
        workspaceReset()
        super.tearDown()
    }

    func testConnectionTransitionsNotifyWithoutTabOrSelectionChanges() {
        let store = WorkspaceStore(hostNameProvider: { _ in "web" })
        let id = store.openTerminal(hostID: "h1")
        let tabs = store.tabs
        var notifications = 0
        let subscription = store.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        let transitions: [WorkspaceConnectionStatus] = [
            .connected, .failed, .connecting, .connected, .inactive
        ]
        for (index, status) in transitions.enumerated() {
            store.reportConnectionStatus(status, forTabID: id)

            XCTAssertEqual(notifications, index + 1, "状态变化必须直接通知界面，不依赖其他操作")
            XCTAssertEqual(store.connectionStatus(forTabID: id), status)
            XCTAssertEqual(store.connectionStatus(forHostID: "h1"), status)
            XCTAssertEqual(store.tabs, tabs)
            XCTAssertEqual(store.activeTabID, id)
        }
    }

    func testConnectionFailureNotifiesBeforeAnySuccessfulConnection() {
        let store = WorkspaceStore(hostNameProvider: { _ in "web" })
        let id = store.openTerminal(hostID: "h1")
        var notifications = 0
        let subscription = store.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        store.reportConnectionStatus(.failed, forTabID: id)

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.connectionStatus(forTabID: id), .failed)
        XCTAssertEqual(store.connectionStatus(forHostID: "h1"), .failed)
    }

    func testRemoteExitNotifiesForBackgroundTabAndPreservesOtherConnection() {
        let store = WorkspaceStore(hostNameProvider: { _ in "web" })
        let ended = store.openTerminal(hostID: "h1")
        let active = store.openTerminal(hostID: "h1")
        store.reportConnectionStatus(.connected, forTabID: ended)
        store.reportConnectionStatus(.connected, forTabID: active)
        var notifications = 0
        let subscription = store.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        store.handleTerminalSessionEnded(tabID: ended)

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.connectionStatus(forTabID: ended), .failed)
        XCTAssertEqual(store.connectionStatus(forTabID: active), .connected)
        XCTAssertEqual(store.connectionStatus(forHostID: "h1"), .connected)
        XCTAssertEqual(store.activeTabID, active)

        store.handleTerminalSessionEnded(tabID: active)

        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(store.connectionStatus(forHostID: "h1"), .failed)
        XCTAssertEqual(store.tabs.count, 2, "远端退出不自动移除页签")
    }

    func testSftpConnectionStatusAlsoNotifiesObservers() {
        let store = WorkspaceStore(hostNameProvider: { _ in "web" })
        let id = store.openSFTP(hostID: "h1")
        var notifications = 0
        let subscription = store.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        store.reportConnectionStatus(.connected, forTabID: id)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.connectionStatus(forTabID: id), .connected)

        store.reportConnectionStatus(.failed, forTabID: id)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(store.connectionStatus(forTabID: id), .failed)
    }

    func testRepeatedStatusDoesNotNotifyAgain() {
        let store = WorkspaceStore(hostNameProvider: { _ in "web" })
        let id = store.openTerminal(hostID: "h1")
        var notifications = 0
        let subscription = store.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        for status: WorkspaceConnectionStatus in [.connecting, .connected, .failed, .inactive] {
            store.reportConnectionStatus(status, forTabID: id)
            let count = notifications
            store.reportConnectionStatus(status, forTabID: id)
            XCTAssertEqual(notifications, count, "视图重复上报相同状态不应触发刷新循环")
        }
    }

    func testUnknownAndClosedTabReportsDoNotNotifyOrRestoreState() {
        let store = WorkspaceStore(hostNameProvider: { _ in "web" })
        let closed = store.openTerminal(hostID: "h1")
        store.close(tabID: closed)
        var notifications = 0
        let subscription = store.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        store.reportConnectionStatus(.connected, forTabID: closed)
        store.reportConnectionStatus(.failed, forTabID: UUID())
        store.handleTerminalSessionEnded(tabID: closed)

        XCTAssertEqual(notifications, 0)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(store.connectionStatus(forTabID: closed), .inactive)
        XCTAssertEqual(store.connectionStatus(forHostID: "h1"), .inactive)
    }

    /// 应用停机必须关闭全部标签，并拒绝停机开始后的新连接注册。
    func testBeginApplicationShutdown_closesTabsAndRejectsNewTabs() {
        var closed: [UUID] = []
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            closeSessionHandler: { closed.append($0.id) }
        )
        let terminal = store.openTerminal(hostID: "h1")
        let sftp = store.openSFTP(hostID: "h2")
        let host = HostEntry(id: "h1", name: "web", address: "example.test", port: 22, username: "test")
        let terminalSession = TerminalSessionStore(host: host)
        terminalSession.finishConnecting()
        store.registerTerminal(terminalSession, for: terminal)

        store.beginApplicationShutdown()
        let rejected = store.openTerminal(hostID: "h3")

        XCTAssertFalse(store.isAcceptingNewConnections)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(Set(closed), Set([terminal, sftp]))
        XCTAssertEqual(terminalSession.phase, .failed)
        XCTAssertNil(terminalSession.connection)
        XCTAssertFalse(closed.contains(rejected))
    }
}

/// 测试用引用盒子,便于在闭包中收集结果。
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// 可控传输源:直接返回注入的记录,便于精确控制任务状态。
private final class ControlledTransferSource: TransferSource {
    var records: [TransferRecord]
    init(records: [TransferRecord]) { self.records = records }

    func enqueueTransfer(
        direction: TransferDirection, hostID: String, localPath: String,
        remotePath: String, size: UInt64, password: String?, passphrase: String?,
        groupID: String?, groupName: String?
    ) -> String { UUID().uuidString }

    func cancelTransfer(id: String) {}
    func pauseTransfer(id: String) {}
    func resumeTransfer(id: String) {}
    func retryTransfer(id: String) -> String { id }
    func listTransfers() -> [TransferRecord] { records }
    func tick() {}
}

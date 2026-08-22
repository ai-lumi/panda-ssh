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

    // MARK: - 组1: 标签页右键批量关闭

    /// 构造带连接释放记录、重连记录与终端已连接判断的 store。
    private func makeLifecycleStore(
        names: [String: String] = ["h1": "web-prod", "h2": "db"],
        connectedTerminals: Set<UUID> = [],
        transfers: TransferStore? = nil
    ) -> (store: WorkspaceStore, disconnected: Box<[String]>, reconnected: Box<[UUID]>) {
        let disconnected = Box<[String]>([])
        let reconnected = Box<[UUID]>([])
        let store = WorkspaceStore(
            hostNameProvider: { names[$0] },
            disconnectHandler: { disconnected.value.append($0) },
            transferStore: transfers,
            terminalConnectedChecker: { connectedTerminals.contains($0) },
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

        store.closeOthers(keeping: keep)

        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs.first?.id, keep)
        XCTAssertEqual(store.activeTabID, keep)
        // h1 的最后一个标签被关闭 → 断开 h1
        XCTAssertEqual(disconnected.value, ["h1"])
    }

    func testCloseAllClearsTabsAndDisconnectsEachHost() {
        let (store, disconnected, _) = makeLifecycleStore()
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h2")

        store.closeAll()

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

        store.reconnectTerminal(tabID: terminalID)
        store.reconnectTerminal(tabID: sftpID)

        XCTAssertEqual(reconnected.value, [terminalID])
    }

    // MARK: - 组2: SSH 终端关闭二次确认

    func testRequestCloseConnectedTerminalSetsPendingWithoutClosing() {
        let (store, disconnected, _) = makeLifecycleStoreConnected(alwaysConnected: true)
        store.openTerminal(hostID: "h1")
        let id = store.tabs[0].id

        store.requestClose(tabID: id)

        XCTAssertEqual(store.pendingCloseTabID, id)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertTrue(disconnected.value.isEmpty)
    }

    /// checker 恒返回 always 的 store 工厂,避免 id 绑定问题。
    private func makeLifecycleStoreConnected(
        alwaysConnected: Bool,
        transfers: TransferStore? = nil
    ) -> (store: WorkspaceStore, disconnected: Box<[String]>, reconnected: Box<[UUID]>) {
        let disconnected = Box<[String]>([])
        let reconnected = Box<[UUID]>([])
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            disconnectHandler: { disconnected.value.append($0) },
            transferStore: transfers,
            terminalConnectedChecker: { _ in alwaysConnected },
            reconnectHandler: { reconnected.value.append($0) }
        )
        return (store, disconnected, reconnected)
    }

    func testRequestCloseConnectingTerminalClosesDirectly() {
        let (store, disconnected, _) = makeLifecycleStoreConnected(alwaysConnected: false)
        store.openTerminal(hostID: "h1")

        store.requestClose(tabID: store.tabs[0].id)

        XCTAssertNil(store.pendingCloseTabID)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(disconnected.value, ["h1"])
    }

    func testRequestCloseSFTPTabClosesDirectly() {
        let (store, disconnected, _) = makeLifecycleStoreConnected(alwaysConnected: true)
        store.openSFTP(hostID: "h1")

        store.requestClose(tabID: store.tabs[0].id)

        XCTAssertNil(store.pendingCloseTabID)
        XCTAssertTrue(store.tabs.isEmpty)
    }

    func testConfirmCloseClosesPendingTab() {
        let (store, disconnected, _) = makeLifecycleStoreConnected(alwaysConnected: true)
        store.openTerminal(hostID: "h1")
        store.requestClose(tabID: store.tabs[0].id)
        XCTAssertEqual(store.pendingCloseTabID, store.tabs[0].id)

        store.confirmClose()

        XCTAssertNil(store.pendingCloseTabID)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(disconnected.value, ["h1"])
    }

    func testCancelCloseKeepsPendingTab() {
        let (store, disconnected, _) = makeLifecycleStoreConnected(alwaysConnected: true)
        store.openTerminal(hostID: "h1")
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

    func testCloseLastTabWithActiveTransfersDefersDisconnect() {
        let (transfers, _) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, disconnected, _) = makeLifecycleStoreConnected(alwaysConnected: false, transfers: transfers)
        store.openSFTP(hostID: "h1")

        store.close(tabID: store.tabs[0].id)

        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertTrue(disconnected.value.isEmpty, "仍有活跃传输时不应断开")
        XCTAssertTrue(store.pendingDisconnectHosts.contains("h1"))
    }

    func testCloseLastTabWithoutActiveTransfersDisconnectsImmediately() {
        let (transfers, _) = makeControlledTransfers([record(hostID: "h1", status: .done)])
        let (store, disconnected, _) = makeLifecycleStoreConnected(alwaysConnected: false, transfers: transfers)
        store.openSFTP(hostID: "h1")

        store.close(tabID: store.tabs[0].id)

        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(disconnected.value, ["h1"])
        XCTAssertFalse(store.pendingDisconnectHosts.contains("h1"))
    }

    func testTransfersChangeReleasesDeferredDisconnect() {
        let (transfers, source) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, disconnected, _) = makeLifecycleStoreConnected(alwaysConnected: false, transfers: transfers)
        store.openSFTP(hostID: "h1")
        store.close(tabID: store.tabs[0].id)
        XCTAssertTrue(store.pendingDisconnectHosts.contains("h1"))

        // 任务进入终态
        source.records = [record(hostID: "h1", status: .done)]
        transfers.tick()

        XCTAssertEqual(disconnected.value, ["h1"])
        XCTAssertFalse(store.pendingDisconnectHosts.contains("h1"))
    }

    func testTransfersStillActiveKeepsDeferred() {
        let (transfers, source) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, disconnected, _) = makeLifecycleStoreConnected(alwaysConnected: false, transfers: transfers)
        store.openSFTP(hostID: "h1")
        store.close(tabID: store.tabs[0].id)

        source.records = [record(hostID: "h1", status: .running)]
        transfers.tick()

        XCTAssertTrue(store.pendingDisconnectHosts.contains("h1"))
        XCTAssertTrue(disconnected.value.isEmpty)
    }

    func testStillHasTerminalTabNoDisconnectAfterTransferDone() {
        let (transfers, source) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, disconnected, _) = makeLifecycleStoreConnected(alwaysConnected: false, transfers: transfers)
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h1")
        let sftpID = store.tabs[1].id

        store.close(tabID: sftpID)
        source.records = [record(hostID: "h1", status: .done)]
        transfers.tick()

        XCTAssertTrue(disconnected.value.isEmpty, "仍有终端标签时不应断开")
    }

    func testCloseSFTPTabDoesNotCancelTransfers() {
        let (transfers, source) = makeControlledTransfers([record(hostID: "h1", status: .running)])
        let (store, _, _) = makeLifecycleStoreConnected(alwaysConnected: false, transfers: transfers)
        store.openSFTP(hostID: "h1")

        store.close(tabID: store.tabs[0].id)

        // 传输任务状态不变(仍 running)
        XCTAssertEqual(transfers.tasks.first?.status, .running)
        XCTAssertEqual(transfers.tasks.count, 1)
        _ = source
    }

    // MARK: - 组2.5: 批量关闭聚合确认

    /// 构造 store,其 terminalConnectedChecker 读取可变 connectedBox.value,
    /// 便于测试在 openTerminal 后再标记某些终端为「已连接」。
    private func makeBatchStore(
        connectedBox: Box<Set<UUID>>
    ) -> (store: WorkspaceStore, disconnected: Box<[String]>, reconnected: Box<[UUID]>) {
        let disconnected = Box<[String]>([])
        let reconnected = Box<[UUID]>([])
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            disconnectHandler: { disconnected.value.append($0) },
            transferStore: nil,
            terminalConnectedChecker: { connectedBox.value.contains($0) },
            reconnectHandler: { reconnected.value.append($0) }
        )
        return (store, disconnected, reconnected)
    }

    func testRequestCloseOthersWithConnectedTerminalsSetsPendingWithoutClosing() {
        let connected = Box<Set<UUID>>([])
        let (store, _, _) = makeBatchStore(connectedBox: connected)
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        store.openSFTP(hostID: "h1")
        let keep = store.tabs[1].id
        connected.value = [store.tabs[0].id] // 第一个终端已连接,会被关闭

        store.requestCloseOthers(keeping: keep)

        XCTAssertEqual(store.pendingBatchClose?.scope, .others(keeping: keep))
        XCTAssertEqual(store.pendingBatchClose?.connectedTerminalCount, 1)
        XCTAssertEqual(store.tabs.count, 3, "未实际关闭")
    }

    func testRequestCloseOthersWithoutConnectedTerminalsClosesDirectly() {
        let connected = Box<Set<UUID>>([])
        let (store, _, _) = makeBatchStore(connectedBox: connected)
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        let keep = store.tabs[1].id

        store.requestCloseOthers(keeping: keep)

        XCTAssertNil(store.pendingBatchClose)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs.first?.id, keep)
    }

    func testRequestCloseAllWithConnectedTerminalsSetsPendingWithoutClosing() {
        let connected = Box<Set<UUID>>([])
        let (store, _, _) = makeBatchStore(connectedBox: connected)
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        connected.value = [store.tabs[0].id, store.tabs[1].id]

        store.requestCloseAll()

        XCTAssertEqual(store.pendingBatchClose?.scope, .all)
        XCTAssertEqual(store.pendingBatchClose?.connectedTerminalCount, 2)
        XCTAssertEqual(store.tabs.count, 2, "未实际关闭")
    }

    func testRequestCloseAllWithoutConnectedTerminalsClosesDirectly() {
        let connected = Box<Set<UUID>>([])
        let (store, _, _) = makeBatchStore(connectedBox: connected)
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")

        store.requestCloseAll()

        XCTAssertNil(store.pendingBatchClose)
        XCTAssertTrue(store.tabs.isEmpty)
    }

    func testConfirmBatchCloseOthersExecutesClose() {
        let connected = Box<Set<UUID>>([])
        let (store, disconnected, _) = makeBatchStore(connectedBox: connected)
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        store.openSFTP(hostID: "h1")
        let keep = store.tabs[1].id
        connected.value = [store.tabs[0].id]
        store.requestCloseOthers(keeping: keep)
        XCTAssertNotNil(store.pendingBatchClose)

        store.confirmBatchClose()

        XCTAssertNil(store.pendingBatchClose)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs.first?.id, keep)
        XCTAssertEqual(store.activeTabID, keep)
        // h1 的 SFTP 标签被关闭、h1 无剩余标签 → 断开 h1
        XCTAssertEqual(disconnected.value, ["h1"])
    }

    func testConfirmBatchCloseAllExecutesClose() {
        let connected = Box<Set<UUID>>([])
        let (store, disconnected, _) = makeBatchStore(connectedBox: connected)
        store.openTerminal(hostID: "h1")
        store.openTerminal(hostID: "h2")
        connected.value = [store.tabs[0].id, store.tabs[1].id]
        store.requestCloseAll()
        XCTAssertNotNil(store.pendingBatchClose)

        store.confirmBatchClose()

        XCTAssertNil(store.pendingBatchClose)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeTabID)
        XCTAssertEqual(disconnected.value.sorted(), ["h1", "h2"])
    }

    func testCancelBatchCloseKeepsTabs() {
        let connected = Box<Set<UUID>>([])
        let (store, _, _) = makeBatchStore(connectedBox: connected)
        store.openTerminal(hostID: "h1")
        connected.value = [store.tabs[0].id]
        store.requestCloseAll()
        XCTAssertNotNil(store.pendingBatchClose)

        store.cancelBatchClose()

        XCTAssertNil(store.pendingBatchClose)
        XCTAssertEqual(store.tabs.count, 1)
    }

    // MARK: - 终端连接态独立于视图生命周期(修复:非活动终端标签的关闭确认)

    /// 不注入 terminalConnectedChecker,使用默认实现(读 connectedTerminalTabs)。
    /// 模拟:终端标签已连接但当前不在屏幕上(SFTP 为活动标签),
    /// 在 SFTP 标签上右键「关闭其他」→ 应弹聚合确认。
    func testMarkTerminalConnectedTriggersBatchCloseConfirmation() {
        let disconnected = Box<[String]>([])
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            disconnectHandler: { disconnected.value.append($0) }
        )
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h1")
        let terminalID = store.tabs[0].id
        let sftpID = store.tabs[1].id

        // 终端已连接(视图可能已因切到 SFTP 而销毁,但 store 仍记录连接态)
        store.markTerminalConnected(tabID: terminalID)

        store.requestCloseOthers(keeping: sftpID)

        XCTAssertEqual(store.pendingBatchClose?.scope, .others(keeping: sftpID))
        XCTAssertEqual(store.pendingBatchClose?.connectedTerminalCount, 1)
        XCTAssertEqual(store.tabs.count, 2, "确认前不实际关闭")
    }

    /// markTerminalDisconnected 后不再视为已连接 → 关闭其他不弹确认。
    func testMarkTerminalDisconnectedClearsConfirmation() {
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            disconnectHandler: { _ in }
        )
        store.openTerminal(hostID: "h1")
        store.openSFTP(hostID: "h1")
        let terminalID = store.tabs[0].id
        let sftpID = store.tabs[1].id

        store.markTerminalConnected(tabID: terminalID)
        store.markTerminalDisconnected(tabID: terminalID)

        store.requestCloseOthers(keeping: sftpID)

        XCTAssertNil(store.pendingBatchClose, "终端已断开,不需要确认")
        XCTAssertEqual(store.tabs.count, 1)
    }

    /// 关闭标签后,该终端不再视为已连接(防止幽灵确认)。
    func testCloseRemovesTerminalFromConnectedSet() {
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            disconnectHandler: { _ in }
        )
        store.openTerminal(hostID: "h1")
        let terminalID = store.tabs[0].id
        store.markTerminalConnected(tabID: terminalID)

        store.close(tabID: terminalID)

        // 关闭后打开 SFTP,关闭其他不应弹确认(终端已不在集合中)
        store.openSFTP(hostID: "h1")
        store.requestCloseOthers(keeping: store.tabs[0].id)
        XCTAssertNil(store.pendingBatchClose)
    }

    /// 单标签关闭:默认 checker 识别 markTerminalConnected → requestClose 弹确认。
    func testRequestCloseUsesDefaultCheckerAfterMarkConnected() {
        let store = WorkspaceStore(
            hostNameProvider: { _ in "web" },
            disconnectHandler: { _ in }
        )
        store.openTerminal(hostID: "h1")
        let id = store.tabs[0].id

        // 未标记连接 → 直接关闭
        store.requestClose(tabID: id)
        XCTAssertEqual(store.tabs.count, 0, "未连接终端直接关闭")

        // 重新打开并标记连接
        store.openTerminal(hostID: "h1")
        let newID = store.tabs[0].id
        store.markTerminalConnected(tabID: newID)

        store.requestClose(tabID: newID)
        XCTAssertEqual(store.pendingCloseTabID, newID, "已连接终端需确认")
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
        remotePath: String, size: UInt64, password: String?, passphrase: String?
    ) -> String { UUID().uuidString }

    func cancelTransfer(id: String) {}
    func pauseTransfer(id: String) {}
    func resumeTransfer(id: String) {}
    func retryTransfer(id: String) -> String { id }
    func listTransfers() -> [TransferRecord] { records }
    func tick() {}
}

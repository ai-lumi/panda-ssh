import Combine
import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

@MainActor
final class ConnectionMonitorStoreTests: XCTestCase {
    private func record(
        id: UInt64 = 1,
        transport: ConnectionStateEnum = .idle,
        health: HealthStateEnum = .healthy,
        received: UInt64 = 0,
        sent: UInt64 = 0,
        error: String? = nil
    ) -> ConnectionTelemetryRecord {
        ConnectionTelemetryRecord(
            id: id,
            hostId: "host-1",
            address: "example.test:22",
            ownerKind: "终端标签",
            ownerId: "tab-1",
            createdAtMs: 1,
            lastActivityAtMs: 2,
            transportState: transport,
            sshState: .authenticated,
            healthState: health,
            lastHealthCheckAtMs: nil,
            receivedBytes: received,
            sentBytes: sent,
            receiveBytesPerSecond: 0,
            sendBytesPerSecond: 0,
            lastError: error,
            channels: [
                ChannelTelemetryRecord(
                    id: 2,
                    kind: .shell,
                    state: .open,
                    createdAtMs: 1,
                    lastActivityAtMs: 2,
                    receivedBytes: received,
                    sentBytes: sent
                )
            ]
        )
    }

    func testRefreshMapsConnectionAndChannelSnapshot() async {
        let expected = record(received: 42, sent: 24)
        let store = ConnectionMonitorStore(
            snapshotLoader: { [expected] in .init(revision: 1, records: [expected]) },
            healthChecker: { _ in .healthy }
        )

        await store.refresh()

        XCTAssertEqual(store.records, [expected])
        XCTAssertEqual(store.records[0].channels.first?.kind, .shell)
        XCTAssertNil(store.errorMessage)
    }

    func testManualHealthCheckUpdatesOnlyExistingRecord() async {
        let original = record(health: .unknown)
        let checked = record(health: .healthy)
        final class HealthBox: @unchecked Sendable { var checked = false }
        let box = HealthBox()
        let store = ConnectionMonitorStore(
            snapshotLoader: { .init(revision: box.checked ? 2 : 1, records: [box.checked ? checked : original]) },
            healthChecker: { id in
                XCTAssertEqual(id, 1)
                box.checked = true
                return .healthy
            }
        )
        await store.refresh()

        await store.checkHealth(connectionID: 1)

        XCTAssertEqual(store.records[0].healthState, .healthy)
        XCTAssertFalse(store.checkingConnectionIDs.contains(1))
    }

    func testHealthCheckPresentsAuthoritativeSnapshotAfterLaterFailure() async {
        let original = record(health: .unknown)
        let latest = record(transport: .failed, health: .unavailable)
        final class HealthBox: @unchecked Sendable { var checked = false }
        let box = HealthBox()
        let store = ConnectionMonitorStore(
            snapshotLoader: { .init(revision: box.checked ? 2 : 1, records: [box.checked ? latest : original]) },
            healthChecker: { _ in
                box.checked = true
                // 探测曾成功，但在 UI 收到结果前核心又记录了连接失败。
                return .healthy
            }
        )
        await store.refresh()
        await store.checkHealth(connectionID: 1)
        XCTAssertEqual(store.records, [latest], "探测返回值不能覆盖核心的较新状态")
    }

    func testRefreshFailureKeepsLastGoodSnapshotAndShowsSummary() async {
        enum TestError: Error { case unavailable }
        let original = record()
        final class LoaderBox: @unchecked Sendable {
            var shouldFail = false
        }
        let box = LoaderBox()
        let store = ConnectionMonitorStore(
            snapshotLoader: {
                if box.shouldFail { throw TestError.unavailable }
                return .init(revision: 1, records: [original])
            },
            healthChecker: { _ in .healthy }
        )
        await store.refresh()
        box.shouldFail = true

        await store.refresh()

        XCTAssertEqual(store.records, [original], "刷新失败不得清空仍可用的上次快照")
        XCTAssertNotNil(store.errorMessage)
    }

    func testUnknownConnectionHealthErrorIsDistinct() async {
        let original = record()
        let store = ConnectionMonitorStore(
            snapshotLoader: { .init(revision: 1, records: [original]) },
            healthChecker: { id in throw PandaError.UnknownConnection(id) }
        )
        await store.refresh()

        await store.checkHealth(connectionID: 1)

        XCTAssertEqual(store.errorMessage, "连接 #1 不存在或已结束")
    }

    func testEmptyAndRepeatedRefreshAreSafe() async {
        let store = ConnectionMonitorStore(
            snapshotLoader: { .init(revision: 1, records: []) },
            healthChecker: { _ in .unknown }
        )
        await store.refresh()
        await store.refresh()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(store.isRefreshing)
    }

    func testRepeatedIdenticalSnapshotDoesNotPublishRecordsAgain() async {
        let expected = record(received: 42, sent: 24)
        let store = ConnectionMonitorStore(
            snapshotLoader: { [expected] in .init(revision: 1, records: [expected]) },
            healthChecker: { _ in .healthy }
        )
        var publications = 0
        let subscription = store.$records
            .dropFirst()
            .sink { _ in publications += 1 }
        defer { subscription.cancel() }

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(publications, 1, "相同快照不应再次发布 records")
    }

    func testRefreshMergesChangedAddedAndRemovedRecordsInStableIDOrder() async {
        final class SnapshotBox: @unchecked Sendable {
            var snapshot: [ConnectionTelemetryRecord] = []
        }
        let box = SnapshotBox()
        let first = record(id: 1, received: 1)
        let unchanged = record(id: 2, received: 2)
        box.snapshot = [unchanged, first]
        let store = ConnectionMonitorStore(
            snapshotLoader: { .init(revision: 1, records: box.snapshot) },
            healthChecker: { _ in .healthy }
        )

        await store.refresh()
        XCTAssertEqual(store.records.map(\.id), [1, 2])

        let changed = record(id: 1, received: 10)
        let added = record(id: 3, received: 3)
        box.snapshot = [added, unchanged, changed]
        await store.refresh()
        XCTAssertEqual(store.records.map(\.id), [1, 2, 3])
        XCTAssertEqual(store.records.first(where: { $0.id == 1 })?.receivedBytes, 10)
        XCTAssertEqual(store.records.first(where: { $0.id == 2 }), unchanged)

        box.snapshot = []
        await store.refresh()
        XCTAssertTrue(store.records.isEmpty)
    }

    func testOverlappingRefreshesOnlyLoadOneSnapshot() async {
        final class LoaderBox: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var calls = 0

            func load() -> ConnectionTelemetrySnapshotRecord {
                lock.lock()
                calls += 1
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
                return .init(revision: 1, records: [])
            }
        }
        let box = LoaderBox()
        let store = ConnectionMonitorStore(
            snapshotLoader: { box.load() },
            healthChecker: { _ in .unknown }
        )

        let firstRefresh = Task { await store.refresh() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await store.refresh()
        await firstRefresh.value

        XCTAssertEqual(box.calls, 1, "刷新进行中时不得启动第二次快照读取")
    }

    func testTrafficFormatterCoversZeroAndLargestCounter() {
        XCTAssertEqual(ConnectionMonitorFormatter.bytes(0), "0 B")
        XCTAssertEqual(ConnectionMonitorFormatter.rate(0), "0 B/s")
        XCTAssertEqual(ConnectionMonitorFormatter.bytes(UInt64.max), "16.0 EiB")
        XCTAssertEqual(ConnectionMonitorFormatter.rate(1_536), "1.5 KiB/s")
    }

    func testObservationUpdatesFromEventsAndCancelsOnExit() async {
        let started = expectation(description: "订阅已建立")
        let cancelled = expectation(description: "订阅已取消")
        let changed = expectation(description: "事件已呈现")
        let feed = MonitorTestFeed(started: started, cancelled: cancelled)
        let store = ConnectionMonitorStore(snapshotSubscriber: { feed.subscribe($0) })
        let expected = record(received: 42)
        let sink = store.$records.dropFirst().sink { records in
            if records == [expected] { changed.fulfill() }
        }
        let observation = Task { await store.observe() }
        await fulfillment(of: [started], timeout: 2)
        feed.send([expected])
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(store.records, [expected])
        XCTAssertTrue(store.hasLoadedSnapshot)
        XCTAssertFalse(store.isRefreshing)
        observation.cancel()
        await observation.value
        await fulfillment(of: [cancelled], timeout: 2)
        feed.send([])
        await Task.yield()
        XCTAssertEqual(store.records, [expected], "取消后的迟到回调不能清空页面")
        sink.cancel()
    }

    func testEmptyObservationStaysLoadedAndDoesNotPublishDuplicates() async {
        let started = expectation(description: "订阅已建立")
        let cancelled = expectation(description: "订阅已取消")
        let loaded = expectation(description: "首次空快照结束加载")
        let feed = MonitorTestFeed(started: started, cancelled: cancelled)
        let store = ConnectionMonitorStore(snapshotSubscriber: { feed.subscribe($0) })
        let sink = store.$hasLoadedSnapshot.dropFirst().sink { if $0 { loaded.fulfill() } }
        let observation = Task { await store.observe() }
        await fulfillment(of: [started], timeout: 2)
        feed.send([])
        await fulfillment(of: [loaded], timeout: 2)
        let unexpected = expectation(description: "稳定空态不得发布加载或数据变化")
        unexpected.isInverted = true
        let changes = store.objectWillChange.sink { unexpected.fulfill() }
        feed.send([])
        feed.send([])
        await fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertTrue(store.hasLoadedSnapshot)
        XCTAssertFalse(store.isRefreshing)
        changes.cancel()
        sink.cancel()
        observation.cancel()
        await observation.value
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testOldSubscriptionCannotOverwriteRemountedPage() async {
        let firstStarted = expectation(description: "旧订阅")
        let firstCancelled = expectation(description: "旧订阅取消")
        let secondStarted = expectation(description: "新订阅")
        let secondCancelled = expectation(description: "新订阅取消")
        let feed = MonitorTestFeed(started: firstStarted, cancelled: firstCancelled)
        let store = ConnectionMonitorStore(snapshotSubscriber: { feed.subscribe($0) })
        let first = Task { await store.observe() }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.cancel()
        await first.value
        await fulfillment(of: [firstCancelled], timeout: 2)
        feed.resetExpectations(started: secondStarted, cancelled: secondCancelled)
        let second = Task { await store.observe() }
        await fulfillment(of: [secondStarted], timeout: 2)
        let expected = record(id: 9)
        let changed = expectation(description: "新快照")
        let sink = store.$records.dropFirst().sink { if $0 == [expected] { changed.fulfill() } }
        feed.send([expected], index: 1)
        await fulfillment(of: [changed], timeout: 2)
        feed.send([record(id: 1)], index: 0)
        await Task.yield()
        XCTAssertEqual(store.records, [expected])
        second.cancel()
        await second.value
        await fulfillment(of: [secondCancelled], timeout: 2)
        sink.cancel()
    }

    func testSlowManualRefreshCannotOverwriteNewEvent() async {
        let started = expectation(description: "订阅")
        let cancelled = expectation(description: "取消")
        let reading = expectation(description: "旧快照正在读取")
        let changed = expectation(description: "事件已更新")
        let feed = MonitorTestFeed(started: started, cancelled: cancelled)
        let gate = DispatchSemaphore(value: 0)
        let old = record(received: 1)
        let newest = record(received: 99)
        let store = ConnectionMonitorStore(snapshotLoader: {
            reading.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return .init(revision: 1, records: [old])
        }, snapshotSubscriber: { feed.subscribe($0) })
        let observation = Task { await store.observe() }
        await fulfillment(of: [started], timeout: 2)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [reading], timeout: 2)
        let sink = store.$records.dropFirst().sink { if $0 == [newest] { changed.fulfill() } }
        feed.send([newest])
        await fulfillment(of: [changed], timeout: 2)
        gate.signal()
        await refresh.value
        XCTAssertEqual(store.records, [newest])
        observation.cancel()
        await observation.value
        await fulfillment(of: [cancelled], timeout: 2)
        sink.cancel()
    }

    func testRealFFISubscriptionDeliversInitialSnapshot() async {
        let loaded = expectation(description: "真实 Rust 回调穿过 UniFFI")
        let store = ConnectionMonitorStore()
        let sink = store.$hasLoadedSnapshot.dropFirst().sink { if $0 { loaded.fulfill() } }
        let observation = Task { await store.observe() }
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertFalse(store.isRefreshing)
        observation.cancel()
        await observation.value
        sink.cancel()
    }

    func testDelayedEventCannotOverwriteNewerManualSnapshot() async {
        let started = expectation(description: "订阅")
        let cancelled = expectation(description: "取消")
        let feed = MonitorTestFeed(started: started, cancelled: cancelled)
        let newest = record(received: 99)
        let store = ConnectionMonitorStore(
            snapshotLoader: { .init(revision: 3, records: [newest]) }, snapshotSubscriber: { feed.subscribe($0) }
        )
        let observation = Task { await store.observe() }
        await fulfillment(of: [started], timeout: 2)
        await store.refresh()
        let regressed = expectation(description: "迟到的旧快照不得回退页面")
        regressed.isInverted = true
        let sink = store.$records.dropFirst().sink { _ in regressed.fulfill() }
        feed.send([record(received: 1)])
        await fulfillment(of: [regressed], timeout: 0.05)
        XCTAssertEqual(store.records, [newest])
        sink.cancel()
        observation.cancel()
        await observation.value
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testTransportLabelsExplicitlySeparateIdleFromFailure() {
        XCTAssertEqual(ConnectionMonitorFormatter.transport(.idle), "Socket 空闲（正常）")
        XCTAssertEqual(ConnectionMonitorFormatter.transport(.failed), "Socket 异常")
        XCTAssertNotEqual(
            ConnectionMonitorFormatter.transport(.idle),
            ConnectionMonitorFormatter.transport(.failed)
        )
    }
}

/// 保留旧回调，允许主动注入取消后迟到的事件。
private final class MonitorTestFeed: @unchecked Sendable {
    typealias Receiver = @Sendable (ConnectionTelemetrySnapshotRecord) -> Void
    private let lock = NSLock()
    private var receivers: [Receiver] = []
    private var started: XCTestExpectation
    private var cancelled: XCTestExpectation

    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
    }

    func resetExpectations(started: XCTestExpectation, cancelled: XCTestExpectation) {
        lock.lock()
        defer { lock.unlock() }
        self.started = started
        self.cancelled = cancelled
    }

    func subscribe(_ receive: @escaping Receiver) -> (@Sendable () -> Void) {
        lock.lock()
        receivers.append(receive)
        let started = started
        let cancelled = cancelled
        lock.unlock()
        started.fulfill()
        return { cancelled.fulfill() }
    }

    func send(_ records: [ConnectionTelemetryRecord], index: Int = 0) {
        lock.lock()
        let receive = receivers[index]
        lock.unlock()
        receive(.init(revision: 2, records: records))
    }
}

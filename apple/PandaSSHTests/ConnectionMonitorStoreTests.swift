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
            snapshotLoader: { [expected] in [expected] },
            healthChecker: { _ in .healthy }
        )

        await store.refresh()

        XCTAssertEqual(store.records, [expected])
        XCTAssertEqual(store.records[0].channels.first?.kind, .shell)
        XCTAssertNil(store.errorMessage)
    }

    func testManualHealthCheckUpdatesOnlyExistingRecord() async {
        let original = record(health: .unknown)
        let store = ConnectionMonitorStore(
            snapshotLoader: { [original] in [original] },
            healthChecker: { id in
                XCTAssertEqual(id, 1)
                return .healthy
            }
        )
        await store.refresh()

        await store.checkHealth(connectionID: 1)

        XCTAssertEqual(store.records[0].healthState, .healthy)
        XCTAssertFalse(store.checkingConnectionIDs.contains(1))
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
                return [original]
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
            snapshotLoader: { [original] },
            healthChecker: { id in throw PandaError.UnknownConnection(id) }
        )
        await store.refresh()

        await store.checkHealth(connectionID: 1)

        XCTAssertEqual(store.errorMessage, "连接 #1 不存在或已结束")
    }

    func testEmptyAndRepeatedRefreshAreSafe() async {
        let store = ConnectionMonitorStore(
            snapshotLoader: { [] },
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
            snapshotLoader: { [expected] in [expected] },
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
            snapshotLoader: { box.snapshot },
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

            func load() -> [ConnectionTelemetryRecord] {
                lock.lock()
                calls += 1
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
                return []
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

    func testTransportLabelsExplicitlySeparateIdleFromFailure() {
        XCTAssertEqual(ConnectionMonitorFormatter.transport(.idle), "Socket 空闲（正常）")
        XCTAssertEqual(ConnectionMonitorFormatter.transport(.failed), "Socket 异常")
        XCTAssertNotEqual(
            ConnectionMonitorFormatter.transport(.idle),
            ConnectionMonitorFormatter.transport(.failed)
        )
    }
}

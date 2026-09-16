import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 终端会话状态机测试：覆盖连接流程（connecting → shell/failed）、
/// 重试、关闭、mock 连接欢迎信息与回显行为。
@MainActor
final class TerminalSessionTests: XCTestCase {

    private func makeHost(demo: DemoFlag? = nil) -> HostEntry {
        HostEntry(
            id: "h1", name: "web-prod", address: "203.0.113.10", port: 22,
            username: "luowenqiang", groupID: nil,
            fingerprint: "SHA256:test", demo: demo
        )
    }

    // MARK: - 连接阶段

    private var record: HostConfigRecord {
        HostConfigRecord(id: "h1", name: "web-prod", host: "203.0.113.10", port: 22,
                         username: "test", auth: .password(passwordRef: nil), notes: nil, groupId: nil)
    }

    func testRepeatedConnectInSameAttemptOpensOnlyOnce() async throws {
        let store = TerminalSessionStore(host: makeHost())
        let opened = LockedCounter()
        store.connectionOpener = { _, _, _, _ in
            opened.increment()
            Thread.sleep(forTimeInterval: 0.1)
            return 123
        }
        store.connect(record: record, password: nil, passphrase: nil)
        store.connect(record: record, password: nil, passphrase: nil)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(opened.value, 1)
        XCTAssertEqual(store.phase, .shell)
        store.close()
    }

    func testCloseDuringHandshakeCannotResurrectSession() async throws {
        let store = TerminalSessionStore(host: makeHost())
        store.connectionOpener = { _, _, _, _ in
            Thread.sleep(forTimeInterval: 0.1)
            return 123
        }
        store.connect(record: record, password: nil, passphrase: nil)
        store.close()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(store.phase, .failed)
        XCTAssertNil(store.connection, "关闭后的迟到握手结果必须释放，不能重新装入标签")
    }

    func testOldHandshakeFailureCannotFailNewAttempt() async throws {
        let store = TerminalSessionStore(host: makeHost())
        let started = expectation(description: "旧握手已开始")
        let release = DispatchSemaphore(value: 0)
        store.connectionOpener = { _, _, _, _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 2)
            throw NSError(domain: "旧握手失败", code: 1)
        }
        store.connect(record: record, password: nil, passphrase: nil)
        await fulfillment(of: [started], timeout: 2)
        store.retry()
        store.connectionOpener = { _, _, _, _ in 124 }
        store.connect(record: record, password: nil, passphrase: nil)
        try await Task.sleep(for: .milliseconds(100))
        release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.phase, .shell)
        XCTAssertEqual((store.connection as? PandaShellConnection)?.handleForTesting, 124)
        store.close()
    }

    func testLateSuccessIsClosedAndCannotReplaceNewConnection() async throws {
        let store = TerminalSessionStore(host: makeHost())
        let started = expectation(description: "旧握手已开始")
        let released = expectation(description: "迟到的句柄已释放")
        let gate = DispatchSemaphore(value: 0)
        store.connectionOpener = { _, _, _, _ in
            started.fulfill()
            _ = gate.wait(timeout: .now() + 2)
            return 123
        }
        store.staleConnectionCloser = { handle in
            XCTAssertEqual(handle, 123)
            released.fulfill()
        }
        store.connect(record: record, password: nil, passphrase: nil)
        await fulfillment(of: [started], timeout: 2)
        store.retry()
        store.retry()
        store.connectionOpener = { _, _, _, _ in 124 }
        store.connect(record: record, password: nil, passphrase: nil)
        gate.signal()
        await fulfillment(of: [released], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual((store.connection as? PandaShellConnection)?.handleForTesting, 124)
        store.close()
    }

    func testOldReadFailureCannotCloseRetriedSession() {
        let store = TerminalSessionStore(host: makeHost())
        store.finishConnecting()
        let oldAttempt = store.attempt
        store.retry()
        store.finishConnecting()
        XCTAssertFalse(store.handleSessionEnd(PandaError.ShellSessionClosed, attempt: oldAttempt))
        XCTAssertEqual(store.phase, .shell)
        XCTAssertNotNil(store.connection)
    }

    func testReadFailureDistinguishesNormalExitFromTransportError() {
        let store = TerminalSessionStore(host: makeHost())
        store.finishConnecting()
        XCTAssertTrue(store.handleSessionEnd(PandaError.ShellSessionClosed, attempt: store.attempt))
        XCTAssertEqual(store.phase, .ended)
        XCTAssertNil(store.connection)
        store.retry()
        store.finishConnecting()
        XCTAssertTrue(store.handleSessionEnd(NSError(domain: "read", code: 1), attempt: store.attempt))
        XCTAssertEqual(store.failure, .other("SSH 连接异常，无法继续通信。"))
    }

    func testConnectFailureDoesNotLogRawErrorContents() async throws {
        let store = TerminalSessionStore(host: makeHost())
        let privateDetail = "fixture-private-key-path-should-not-be-logged"
        store.connectionOpener = { _, _, _, _ in
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: privateDetail])
        }
        store.connect(record: record, password: nil, passphrase: nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.phase, .failed)
        XCTAssertFalse(Logger.shared.entries.contains { $0.message.contains(privateDetail) })
    }

    func testInitialPhaseIsConnectingWithoutConnection() {
        let store = TerminalSessionStore(host: makeHost())

        XCTAssertEqual(store.phase, .connecting)
        XCTAssertNil(store.connection)
    }

    func testFinishConnectingEntersShellWithConnection() {
        let store = TerminalSessionStore(host: makeHost())

        store.finishConnecting()

        XCTAssertEqual(store.phase, .shell)
        XCTAssertNotNil(store.connection)
    }

    func testFinishConnectingOfflineHostFails() {
        let store = TerminalSessionStore(host: makeHost(demo: .offline))

        store.finishConnecting()

        XCTAssertEqual(store.phase, .failed)
        XCTAssertNil(store.connection)
    }

    func testRetryAfterFailureReturnsToConnecting() {
        let store = TerminalSessionStore(host: makeHost(demo: .offline))
        store.finishConnecting()
        XCTAssertEqual(store.phase, .failed)

        store.retry()

        XCTAssertEqual(store.phase, .connecting)
        XCTAssertNil(store.connection)
    }

    func testRetryIncrementsAttempt() {
        let store = TerminalSessionStore(host: makeHost(demo: .offline))
        store.finishConnecting()

        store.retry()

        XCTAssertEqual(store.attempt, 1)
    }

    func testRetryOnlyAdvancesAttemptAndDoesNotOpenConnectionDirectly() async throws {
        let store = TerminalSessionStore(host: makeHost())
        let opened = LockedCounter()
        store.connectionOpener = { _, _, _, _ in
            opened.increment()
            return 123
        }
        let record = HostConfigRecord(
            id: "h1", name: "web-prod", host: "203.0.113.10", port: 22,
            username: "luowenqiang",
            auth: .password(passwordRef: nil), notes: nil, groupId: nil
        )
        store.connect(record: record, password: nil, passphrase: nil)
        let deadline = Date().addingTimeInterval(2)
        while store.phase != .shell && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        store.markFailed()

        store.retry()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(opened.value, 1, "重试按钮只应推进代次，建连由视图任务唯一触发")
        XCTAssertEqual(store.phase, .connecting)
    }

    func testMissingCredentialRetryWaitsForNewInputInsteadOfReusingOldPassword() {
        let store = TerminalSessionStore(host: makeHost())
        store.markFailed()

        store.waitForCredentialInput()

        XCTAssertEqual(store.phase, .connecting)
        XCTAssertEqual(store.attempt, 1)
        XCTAssertNil(store.connection)
    }

    func testMarkFailedSetsFailedPhase() {
        let store = TerminalSessionStore(host: makeHost())

        store.markFailed()

        XCTAssertEqual(store.phase, .failed)
    }

    func testRemoteShellExitReleasesConnectionAndMarksEnded() {
        let store = TerminalSessionStore(host: makeHost())
        store.finishConnecting()

        store.handleRemoteShellExit()

        XCTAssertEqual(store.phase, .ended)
        XCTAssertNil(store.connection)
    }

    func testCloseReleasesConnection() {
        let store = TerminalSessionStore(host: makeHost())
        store.finishConnecting()
        XCTAssertNotNil(store.connection)

        store.close()

        XCTAssertEqual(store.phase, .failed)
        XCTAssertNil(store.connection)
    }

    // MARK: - Mock 连接数据流

    func testMockConnectionContainsWelcomeMessage() throws {
        let store = TerminalSessionStore(host: makeHost())
        store.finishConnecting()

        guard let conn = store.connection else {
            XCTFail("连接不应为 nil")
            return
        }
        let data = try conn.read(max: 4096)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("已建立连接"), "欢迎信息应包含「已建立连接」，实际：\(text)")
        XCTAssertTrue(text.contains("Welcome to web-prod"), "欢迎信息应包含主机名")
    }

    func testMockConnectionEchoesInput() throws {
        let store = TerminalSessionStore(host: makeHost())
        store.finishConnecting()

        guard let conn = store.connection else {
            XCTFail("连接不应为 nil")
            return
        }
        // 先读走欢迎信息
        _ = try? conn.read(max: 4096)

        // 写入数据后读回应原样返回
        let payload = "ls -la\n".data(using: .utf8)!
        try conn.write(payload)
        let echoed = try conn.read(max: 4096)
        XCTAssertEqual(echoed, payload)
    }

    func testMockConnectionReadEmptyReturnsNoData() throws {
        let store = TerminalSessionStore(host: makeHost())
        store.finishConnecting()

        guard let conn = store.connection else {
            XCTFail("连接不应为 nil")
            return
        }
        // 读走所有数据
        _ = try? conn.read(max: 4096)

        let data = try conn.read(max: 4096)
        XCTAssertTrue(data.isEmpty)
    }

    // MARK: - 后台连接调度

    /// connect 期间主线程不被占用：注入慢速 opener，connect 调用应立即返回
    /// （不阻塞主线程），phase 在后台完成后才更新为 .shell。
    func testConnectDoesNotBlockMainThreadAndPhaseUpdatesAsync() async throws {
        let store = TerminalSessionStore(host: makeHost())
        var openerThreadIsMain: Bool?
        store.connectionOpener = { _, _, _, _ in
            openerThreadIsMain = Thread.isMainThread
            Thread.sleep(forTimeInterval: 0.5)
            return 123
        }
        let record = HostConfigRecord(
            id: "h1", name: "web-prod", host: "203.0.113.10", port: 22,
            username: "luowenqiang",
            auth: .password(passwordRef: nil), notes: nil, groupId: nil
        )

        let start = Date()
        store.connect(record: record, password: nil, passphrase: nil)
        let elapsed = Date().timeIntervalSince(start)
        // 主线程不应被 0.5s 的慢连接阻塞。
        XCTAssertLessThan(elapsed, 0.3, "connect 应在后台执行，主线程调用应立即返回（实测 \(elapsed)s）")

        // 后台完成前 phase 仍为 connecting（0.5s 慢连接 > 0.1s 观察窗口）。
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.phase, .connecting, "慢连接未完成时不应进入 shell")

        // 等待后台完成。
        let deadline = Date().addingTimeInterval(3)
        while store.phase != .shell && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(store.phase, .shell, "后台连接完成后应进入 shell")
        XCTAssertEqual(openerThreadIsMain, false, "opener 应在非主线程执行")
        XCTAssertEqual((store.connection as? PandaShellConnection)?.handleForTesting, 123)
    }

    /// 连接失败时 phase 进入 failed，错误回主线程呈现。
    func testConnectFailureUpdatesPhaseAfterBackgroundOpenerThrows() async throws {
        let store = TerminalSessionStore(host: makeHost())
        store.connectionOpener = { _, _, _, _ in
            throw NSError(domain: "test", code: 1)
        }
        let record = HostConfigRecord(
            id: "h1", name: "web-prod", host: "203.0.113.10", port: 22,
            username: "luowenqiang",
            auth: .password(passwordRef: nil), notes: nil, groupId: nil
        )

        store.connect(record: record, password: nil, passphrase: nil)

        let deadline = Date().addingTimeInterval(3)
        while store.phase != .failed && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(store.phase, .failed)
        XCTAssertNil(store.connection)
    }

    /// 两个慢速连接同时建立互不排队：总耗时应显著小于串行和（1s × 2）。
    func testTwoConnectionsRunInParallel() async throws {
        func makeStore() -> TerminalSessionStore {
            let store = TerminalSessionStore(host: makeHost())
            store.connectionOpener = { _, _, _, _ in
                Thread.sleep(forTimeInterval: 1.0)
                // hashValue 可为负数，直接转 UInt64 会触发运行时陷阱并让整个
                // XCTest 进程崩溃；保留位模式即可生成互不相关的测试句柄。
                return UInt64(bitPattern: Int64(UUID().hashValue))
            }
            return store
        }
        let storeA = makeStore()
        let storeB = makeStore()
        let recordA = HostConfigRecord(
            id: "a", name: "a", host: "203.0.113.10", port: 22,
            username: "u", auth: .password(passwordRef: nil), notes: nil, groupId: nil
        )
        let recordB = HostConfigRecord(
            id: "b", name: "b", host: "203.0.113.11", port: 22,
            username: "u", auth: .password(passwordRef: nil), notes: nil, groupId: nil
        )

        let start = Date()
        storeA.connect(record: recordA, password: nil, passphrase: nil)
        storeB.connect(record: recordB, password: nil, passphrase: nil)

        let deadline = Date().addingTimeInterval(5)
        while (storeA.phase != .shell || storeB.phase != .shell) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(storeA.phase, .shell)
        XCTAssertEqual(storeB.phase, .shell)
        XCTAssertLessThan(elapsed, 1.8, "两个 1s 连接应并行完成（实测 \(elapsed)s，串行需 ~2s）")
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

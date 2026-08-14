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

    func testMarkFailedSetsFailedPhase() {
        let store = TerminalSessionStore(host: makeHost())

        store.markFailed()

        XCTAssertEqual(store.phase, .failed)
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
}

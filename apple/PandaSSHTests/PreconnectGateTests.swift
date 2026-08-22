import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 连接门控测试:标签打开时按 preconnectAction 决定弹窗,
/// 通过后才进入连接流程;密码仅由门控对象持有(随标签销毁)。
/// 真实模式下门控会异步探测未知主机密钥,并由 AppModel 层对同一主机
/// 的多个并发确认请求做串行化,只弹一次确认框。
@MainActor
final class PreconnectGateTests: XCTestCase {

    private func makeHost(demo: DemoFlag?, fingerprint: String? = "SHA256:x") -> HostEntry {
        HostEntry(
            id: "h1", name: "srv", address: "203.0.113.10", port: 22,
            username: "ops", groupID: nil, auth: .password,
            passwordSaved: true, fingerprint: fingerprint, demo: demo
        )
    }

    // MARK: Mock 模式

    func testTrustedHostUnlocksImmediately() {
        let gate = PreconnectGate()

        let action = gate.evaluate(host: makeHost(demo: nil))

        XCTAssertEqual(action, .proceed)
        XCTAssertTrue(gate.unlocked)
        XCTAssertNil(gate.sheet)
    }

    func testUnknownHostAsksTofu() {
        let gate = PreconnectGate()

        let action = gate.evaluate(host: makeHost(demo: .unknown, fingerprint: nil))

        XCTAssertEqual(action, .confirmTofu)
        XCTAssertFalse(gate.unlocked)
        XCTAssertEqual(gate.sheet, .tofu)
    }

    func testMismatchHostShowsAlertAndStaysLocked() {
        let gate = PreconnectGate()

        let action = gate.evaluate(host: makeHost(demo: .mismatch))

        XCTAssertEqual(action, .keyMismatch)
        XCTAssertEqual(gate.sheet, .mismatch)
        XCTAssertFalse(gate.unlocked)
    }

    func testManualAuthHostAsksPassword() {
        let gate = PreconnectGate()

        let action = gate.evaluate(host: makeHost(demo: .manual))

        XCTAssertEqual(action, .askPassword)
        XCTAssertEqual(gate.sheet, .password)
        XCTAssertFalse(gate.unlocked)
    }

    func testUnlockWithPasswordHoldsItPerSession() {
        let gate = PreconnectGate()
        gate.evaluate(host: makeHost(demo: .manual))

        gate.unlock(password: "s3cret")

        XCTAssertTrue(gate.unlocked)
        XCTAssertEqual(gate.password, "s3cret")
    }

    func testEvaluateTwiceDoesNotReopenSheet() {
        let gate = PreconnectGate()
        gate.evaluate(host: makeHost(demo: .manual))
        gate.unlock(password: "pw")

        gate.evaluate(host: makeHost(demo: .manual))

        // 第二次评估是 no-op:已解锁状态不被打回
        XCTAssertTrue(gate.unlocked)
        XCTAssertNil(gate.sheet)
    }

    // MARK: 真实模式异步评估

    func testKnownHostUnlocksImmediatelyInRealMode() async {
        let backend = FakeBackend()
        backend.hostKeyStatusValue = .known
        let model = AppModel(backend: backend)
        let gate = PreconnectGate()
        let keychain = InMemoryKeychain()
        keychain.save(secret: "s3cret", for: "host.h1.password")
        gate.credentialResolver = CredentialResolver(keychain: keychain)

        await gate.evaluateAsync(host: makeHost(demo: nil), in: model) {}

        XCTAssertTrue(gate.unlocked)
        XCTAssertNil(gate.sheet)
    }

    func testUnknownHostShowsTofuSheet() async {
        let backend = FakeBackend()
        let model = AppModel(backend: backend)
        let gate = PreconnectGate()

        await gate.evaluateAsync(host: makeHost(demo: nil), in: model) {}

        XCTAssertFalse(gate.unlocked)
        XCTAssertEqual(gate.sheet, .tofu)
        XCTAssertEqual(gate.presentedKey?.fingerprint, backend.probeResult?.fingerprint)
    }

    func testTrustingTofuUnlocksGate() async {
        let backend = FakeBackend()
        let model = AppModel(backend: backend)
        let gate = PreconnectGate()

        await gate.evaluateAsync(host: makeHost(demo: nil), in: model) {}
        XCTAssertEqual(gate.sheet, .tofu)

        // UI 层点击「信任」:先广播结果,再 unlock 当前门控。
        model.resolveTofuConfirmation(for: "h1", trusted: true)
        gate.unlock()

        XCTAssertTrue(gate.unlocked)
        XCTAssertNil(gate.sheet)
    }

    func testCancellingTofuClosesWaitingGate() async {
        let backend = FakeBackend()
        backend.probeDelay = .milliseconds(10)
        let model = AppModel(backend: backend)
        let host = makeHost(demo: nil)
        var closedLeading = false
        var closedWaiting = false

        let gate1 = PreconnectGate()
        let gate2 = PreconnectGate()

        // gate1 先成为 leading 并弹出 tofu。
        let task1 = Task {
            await gate1.evaluateAsync(host: host, in: model) { closedLeading = true }
        }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(gate1.sheet, .tofu)

        // gate2 后启动,进入等待队列。
        let task2 = Task {
            await gate2.evaluateAsync(host: host, in: model) { closedWaiting = true }
        }
        try? await Task.sleep(for: .milliseconds(50))

        // UI 层点击「取消」广播,false 会让等待 gate 执行 onClose。
        model.resolveTofuConfirmation(for: host.id, trusted: false)

        await task1.value
        await task2.value

        XCTAssertFalse(gate1.unlocked)
        XCTAssertFalse(gate2.unlocked)
        // leading gate 的关闭由 sheet onDismiss 负责,evaluateAsync 不重复触发。
        XCTAssertFalse(closedLeading)
        XCTAssertTrue(closedWaiting)
    }

    func testConcurrentGatesForSameHostShowOneSheet() async {
        let backend = FakeBackend()
        backend.probeDelay = .milliseconds(20)
        let model = AppModel(backend: backend)
        let host = makeHost(demo: nil)
        let gate1 = PreconnectGate()
        let gate2 = PreconnectGate()
        var closed1 = false
        var closed2 = false

        let task1 = Task {
            await gate1.evaluateAsync(host: host, in: model) { closed1 = true }
        }
        let task2 = Task {
            await gate2.evaluateAsync(host: host, in: model) { closed2 = true }
        }

        // 等待两个 probe 都完成并进入确认队列
        try? await Task.sleep(for: .milliseconds(50))

        let leading = [gate1, gate2].first { $0.sheet == .tofu }!
        let waiting = (leading === gate1) ? gate2 : gate1
        XCTAssertNotNil(leading)
        XCTAssertNil(waiting.sheet)

        // UI 层在 leading gate 上点击「信任」并广播,等待 gate 自动解锁。
        model.resolveTofuConfirmation(for: host.id, trusted: true)
        leading.unlock()

        await task1.value
        await task2.value

        XCTAssertTrue(gate1.unlocked)
        XCTAssertTrue(gate2.unlocked)
        XCTAssertFalse(closed1)
        XCTAssertFalse(closed2)
    }

}

// MARK: - 测试专用后端

/// 只支撑 preconnect 决策的最小后端,其余方法为空实现。
private final class FakeBackend: AppBackend {
    let startupError: String? = nil

    var hostKeyStatusValue: HostKeyGateStatus = .unknown
    var probeResult: PresentedHostKey? = PresentedHostKey(
        key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGateTest",
        fingerprint: "SHA256:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66"
    )
    var probeDelay: Duration?

    func allHosts() -> [HostEntry] { [] }
    @discardableResult
    func saveHost(_ host: HostEntry, password: String?, passphrase: String?) -> Bool { true }
    func deleteHost(id: String) {}
    func moveHost(id: String, toGroup groupID: String?) {}
    func trustHost(id: String) {}
    func presentedFingerprint(for hostID: String) -> String? { probeResult?.fingerprint }
    func hostKeyStatus(for hostID: String) -> HostKeyGateStatus { hostKeyStatusValue }
    func probePresentedKey(for hostID: String) async throws -> PresentedHostKey? {
        if let probeDelay { try? await Task.sleep(for: probeDelay) }
        return probeResult
    }
    func configRecord(for hostID: String) -> HostConfigRecord? { nil }
    func clearKeychainCredentials(for hostID: String, auth: AuthKind) {}

    func allGroups() -> [HostGroup] { [] }
    @discardableResult
    func createGroup(name: String, parentID: String?) -> HostGroup { HostGroup(id: "", name: "", parentID: nil) }
    func renameGroup(id: String, name: String) {}
    func deleteGroup(id: String) {}

    func allSnippets() -> [Snippet] { [] }
    func saveSnippet(_ snippet: Snippet) {}
    func deleteSnippet(id: String) {}
}

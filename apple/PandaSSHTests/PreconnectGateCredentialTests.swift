import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

@MainActor
final class PreconnectGateCredentialTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreconnectGateCredentialTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try initStore(configDir: directory.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingPrivateKeyShowsNativePickerWithoutResolvingCredential() {
        let gate = PreconnectGate()
        let host = HostEntry(
            id: "key", name: "密钥主机", address: "example.test", port: 22, username: "panda",
            auth: .publicKey, keyPath: ""
        )

        gate.checkCredentials(host: host)

        XCTAssertEqual(gate.sheet, .keyPicker)
        XCTAssertFalse(gate.unlocked)
    }

    func testUnavailableCredentialShowsInputSheet() {
        let gate = PreconnectGate()
        let host = HostEntry(
            id: "missing", name: "密码主机", address: "example.test", port: 22, username: "panda",
            auth: .password
        )

        gate.checkCredentials(host: host)

        XCTAssertEqual(gate.sheet, .password)
        XCTAssertFalse(gate.unlocked)
    }

    func testCoreInputRequestIsShownAndItsResponseUnlocksOnlyThisGate() throws {
        let host = HostEntry(
            id: "missing", name: "密码主机", address: "example.test", port: 22, username: "panda",
            auth: .password
        )
        try saveHost(host: HostConfigRecord(
            id: host.id, name: host.name, host: host.address, port: host.port, username: host.username,
            auth: .password(passwordRef: nil), notes: nil, groupId: nil
        ))
        let gate = PreconnectGate()

        gate.checkCredentials(host: host)

        XCTAssertEqual(gate.sheet, .password)
        XCTAssertFalse(gate.unlocked)

        gate.unlock(secret: "会话密码")

        XCTAssertTrue(gate.unlocked)
        XCTAssertNil(gate.sheet)
        XCTAssertEqual(gate.resolvedSecrets?.password, "会话密码")
        XCTAssertNil(gate.resolvedSecrets?.passphrase)
    }
}

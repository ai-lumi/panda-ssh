import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 真实后端的主机/凭据完整用例契约。每个测试在 Rust 侧切换到独立临时目录，
/// 不使用 App 的实际配置目录。
@MainActor
final class PandaCoreBackendHostTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PandaCoreBackendHostTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try initStore(configDir: directory.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testBackendSavesEditsAndDeletesThroughCompleteCoreEntry() {
        let backend = PandaCoreBackend()
        let host = HostEntry(
            id: "host-1", name: "原始", address: "example.test", port: 22, username: "panda",
            passwordSaved: true
        )

        XCTAssertTrue(backend.saveHost(host, password: "秘密", passphrase: nil))
        var edited = host
        edited.name = "已编辑"
        XCTAssertTrue(backend.saveHost(edited, password: nil, passphrase: nil))
        XCTAssertEqual(backend.allHosts().first?.name, "已编辑")
        XCTAssertEqual(try readCredential(reference: "host.host-1.password"), "秘密")

        backend.deleteHost(id: "host-1")
        XCTAssertTrue(backend.allHosts().isEmpty)
        XCTAssertNil(try readCredential(reference: "host.host-1.password"))
    }

    func testBackendExposesCoreSaveError() {
        let backend = PandaCoreBackend()
        let invalid = HostEntry(
            id: "", name: "无效", address: "example.test", port: 22, username: "panda",
            passwordSaved: true
        )

        XCTAssertFalse(backend.saveHost(invalid, password: "秘密", passphrase: nil))
        XCTAssertNotNil(backend.startupError)
        XCTAssertTrue(backend.allHosts().isEmpty)
    }

    func testBackendDoesNotRemoveSavedCredentialForUneditedForm() throws {
        let backend = PandaCoreBackend()
        let host = HostEntry(
            id: "host-1", name: "主机", address: "example.test", port: 22, username: "panda",
            passwordSaved: true
        )
        XCTAssertTrue(backend.saveHost(host, password: "秘密", passphrase: nil))
        XCTAssertTrue(backend.saveHost(host, password: nil, passphrase: nil))
        XCTAssertEqual(try readCredential(reference: "host.host-1.password"), "秘密")
    }
}

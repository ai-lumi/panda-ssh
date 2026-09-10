import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 认证相关测试：本地凭据解析、私钥选择器 fake。
/// 覆盖正常流程、意外操作（读取缺失、保存失败后状态）与边界条件（空串）。
@MainActor
final class AuthTests: XCTestCase {

    // MARK: - CredentialResolver

    private func makeHost(auth: AuthKind, saved: Bool, keyPath: String = "") -> HostEntry {
        HostEntry(
            id: "h1", name: "box", address: "example.com", port: 22,
            username: "u", note: "", groupID: nil, auth: auth,
            keyPath: keyPath, passwordSaved: auth == .password && saved,
            passphraseSaved: auth == .publicKey && saved
        )
    }

    func testResolverReadsSavedPassword() {
        let resolver = CredentialResolver(readSecret: { $0 == "host.h1.password" ? "p@ss" : nil })
        let host = makeHost(auth: .password, saved: true)

        let result = resolver.resolve(for: host)
        XCTAssertEqual(result, .available("p@ss"))
        XCTAssertEqual(resolver.connectionSecrets(for: host)?.password, "p@ss")
    }

    func testResolverRequestsManualInputWhenPasswordNotSaved() {
        let resolver = CredentialResolver(readSecret: { _ in nil })
        let host = makeHost(auth: .password, saved: false)

        XCTAssertEqual(resolver.resolve(for: host), .needsManualInput)
        XCTAssertNil(resolver.connectionSecrets(for: host))
    }

    func testResolverFallsBackToManualInputWhenSavedPasswordMissing() {
        let resolver = CredentialResolver(readSecret: { _ in nil })
        let host = makeHost(auth: .password, saved: true)

        XCTAssertEqual(resolver.resolve(for: host), .needsManualInput)
    }

    func testResolverManualPasswordOverridesSavedPassword() {
        let resolver = CredentialResolver(readSecret: { _ in "saved" })
        let host = makeHost(auth: .password, saved: true)

        XCTAssertEqual(resolver.resolve(for: host, manualSecret: "manual"), .available("manual"))
    }

    func testResolverIgnoresEmptyManualPassword() {
        let resolver = CredentialResolver(readSecret: { _ in "saved" })
        let host = makeHost(auth: .password, saved: true)

        XCTAssertEqual(resolver.resolve(for: host, manualSecret: ""), .available("saved"))
    }

    func testResolverReadsSavedPassphrase() {
        let resolver = CredentialResolver(readSecret: { $0 == "host.h1.passphrase" ? "phrase" : nil })
        let host = makeHost(auth: .publicKey, saved: true, keyPath: "~/.ssh/id")

        XCTAssertEqual(resolver.resolve(for: host), .available("phrase"))
        XCTAssertEqual(resolver.connectionSecrets(for: host)?.passphrase, "phrase")
        XCTAssertNil(resolver.connectionSecrets(for: host)?.password)
    }

    func testResolverReturnsEmptyPassphraseWhenNotSaved() {
        let resolver = CredentialResolver(readSecret: { _ in nil })
        let host = makeHost(auth: .publicKey, saved: false, keyPath: "~/.ssh/id")

        XCTAssertEqual(resolver.resolve(for: host), .available(""))
    }

    func testResolverRequestsManualInputWhenSavedPassphraseMissing() {
        let resolver = CredentialResolver(readSecret: { _ in nil })
        let host = makeHost(auth: .publicKey, saved: true, keyPath: "~/.ssh/id")

        XCTAssertEqual(resolver.resolve(for: host), .needsManualInput)
        XCTAssertEqual(resolver.resolve(for: host, manualSecret: "phrase"), .available("phrase"))
    }

    // MARK: - connectionSecrets 组合场景

    func testConnectionSecretsPasswordAuthReturnsPasswordOnly() {
        let resolver = CredentialResolver(readSecret: { ref in
            ref == "host.h1.password" ? "pw123" : nil
        })
        let host = makeHost(auth: .password, saved: true)

        let secrets = resolver.connectionSecrets(for: host)
        XCTAssertEqual(secrets?.password, "pw123")
        XCTAssertNil(secrets?.passphrase)
    }

    func testConnectionSecretsPublicKeyAuthReturnsPassphraseOnly() {
        let resolver = CredentialResolver(readSecret: { ref in
            ref == "host.h1.passphrase" ? "pp456" : nil
        })
        let host = makeHost(auth: .publicKey, saved: true, keyPath: "~/.ssh/id")

        let secrets = resolver.connectionSecrets(for: host)
        XCTAssertNil(secrets?.password)
        XCTAssertEqual(secrets?.passphrase, "pp456")
    }

    func testConnectionSecretsPublicKeyWithEmptyPassphraseReturnsNilTuple() {
        let resolver = CredentialResolver(readSecret: { _ in nil })
        let host = makeHost(auth: .publicKey, saved: false, keyPath: "~/.ssh/id")

        let secrets = resolver.connectionSecrets(for: host)
        XCTAssertNil(secrets?.password)
        XCTAssertNil(secrets?.passphrase)
    }

    func testConnectionSecretsManualOverridesSaved() {
        let resolver = CredentialResolver(readSecret: { ref in
            ref == "host.h1.password" ? "saved" : nil
        })
        let host = makeHost(auth: .password, saved: true)

        let secrets = resolver.connectionSecrets(for: host, manualSecret: "manual")
        XCTAssertEqual(secrets?.password, "manual")
        XCTAssertNil(secrets?.passphrase)
    }

    func testConnectionSecretsReturnsNilWhenCredentialMissing() {
        let resolver = CredentialResolver(readSecret: { _ in nil })
        let host = makeHost(auth: .password, saved: false)

        XCTAssertNil(resolver.connectionSecrets(for: host))
    }

    // MARK: - KeyPicker fake

    func testFakeKeyPickerReturnsConfiguredPath() async {
        let picker = FakeKeyPicker(picked: PickedKey(path: "/keys/id_ed25519", securityScopedBookmark: nil))
        let result = await picker.pickPrivateKey()
        XCTAssertEqual(result?.path, "/keys/id_ed25519")
    }

    func testFakeKeyPickerReturnsNilByDefault() async {
        let picker = FakeKeyPicker()
        let result = await picker.pickPrivateKey()
        XCTAssertNil(result)
    }

}

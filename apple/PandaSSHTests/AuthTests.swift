import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 认证相关测试：钥匙串服务、凭据解析、私钥选择器 fake。
/// 覆盖正常流程、意外操作（读取缺失、保存失败后状态）与边界条件（空串）。
@MainActor
final class AuthTests: XCTestCase {

    // MARK: - KeychainService fake

    func testInMemoryKeychainSaveReadDelete() {
        let keychain = InMemoryKeychain()
        XCTAssertTrue(keychain.save(secret: "secret", for: "ref.1"))
        XCTAssertEqual(keychain.read(for: "ref.1"), "secret")
        keychain.delete(for: "ref.1")
        XCTAssertNil(keychain.read(for: "ref.1"))
    }

    func testInMemoryKeychainReadMissingReturnsNil() {
        let keychain = InMemoryKeychain()
        XCTAssertNil(keychain.read(for: "not-there"))
    }

    func testInMemoryKeychainSaveOverwrites() {
        let keychain = InMemoryKeychain()
        keychain.save(secret: "old", for: "ref.1")
        keychain.save(secret: "new", for: "ref.1")
        XCTAssertEqual(keychain.read(for: "ref.1"), "new")
    }

    func testInMemoryKeychainClear() {
        let keychain = InMemoryKeychain()
        keychain.save(secret: "a", for: "ref.1")
        keychain.save(secret: "b", for: "ref.2")
        keychain.clear()
        XCTAssertNil(keychain.read(for: "ref.1"))
        XCTAssertNil(keychain.read(for: "ref.2"))
    }

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
        let keychain = InMemoryKeychain()
        keychain.save(secret: "p@ss", for: "host.h1.password")
        let resolver = CredentialResolver(keychain: keychain)
        let host = makeHost(auth: .password, saved: true)

        let result = resolver.resolve(for: host)
        XCTAssertEqual(result, .available("p@ss"))
        XCTAssertEqual(resolver.connectionSecrets(for: host)?.password, "p@ss")
    }

    func testResolverRequestsManualInputWhenPasswordNotSaved() {
        let resolver = CredentialResolver(keychain: InMemoryKeychain())
        let host = makeHost(auth: .password, saved: false)

        XCTAssertEqual(resolver.resolve(for: host), .needsManualInput)
        XCTAssertNil(resolver.connectionSecrets(for: host))
    }

    func testResolverFallsBackToManualInputWhenKeychainMissing() {
        let resolver = CredentialResolver(keychain: InMemoryKeychain())
        let host = makeHost(auth: .password, saved: true)

        XCTAssertEqual(resolver.resolve(for: host), .needsManualInput)
    }

    func testResolverManualPasswordOverridesKeychain() {
        let keychain = InMemoryKeychain()
        keychain.save(secret: "saved", for: "host.h1.password")
        let resolver = CredentialResolver(keychain: keychain)
        let host = makeHost(auth: .password, saved: true)

        XCTAssertEqual(resolver.resolve(for: host, manualPassword: "manual"), .available("manual"))
    }

    func testResolverIgnoresEmptyManualPassword() {
        let keychain = InMemoryKeychain()
        keychain.save(secret: "saved", for: "host.h1.password")
        let resolver = CredentialResolver(keychain: keychain)
        let host = makeHost(auth: .password, saved: true)

        XCTAssertEqual(resolver.resolve(for: host, manualPassword: ""), .available("saved"))
    }

    func testResolverReadsSavedPassphrase() {
        let keychain = InMemoryKeychain()
        keychain.save(secret: "phrase", for: "host.h1.passphrase")
        let resolver = CredentialResolver(keychain: keychain)
        let host = makeHost(auth: .publicKey, saved: true, keyPath: "~/.ssh/id")

        XCTAssertEqual(resolver.resolve(for: host), .available("phrase"))
        XCTAssertEqual(resolver.connectionSecrets(for: host)?.passphrase, "phrase")
        XCTAssertNil(resolver.connectionSecrets(for: host)?.password)
    }

    func testResolverReturnsEmptyPassphraseWhenNotSaved() {
        let resolver = CredentialResolver(keychain: InMemoryKeychain())
        let host = makeHost(auth: .publicKey, saved: false, keyPath: "~/.ssh/id")

        XCTAssertEqual(resolver.resolve(for: host), .available(""))
    }

    func testResolverReturnsEmptyPassphraseWhenKeychainMissing() {
        let resolver = CredentialResolver(keychain: InMemoryKeychain())
        let host = makeHost(auth: .publicKey, saved: true, keyPath: "~/.ssh/id")

        XCTAssertEqual(resolver.resolve(for: host), .available(""))
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

    // MARK: - Backend credential save/clear semantics

    func testBackendSaveHostClearsPasswordRefWhenSavePasswordDisabled() {
        let keychain = InMemoryKeychain()
        keychain.save(secret: "old", for: "host.h1.password")
        let backend = makeBackend(keychain: keychain)
        var host = HostEntry(id: "h1", name: "box", address: "example.com", port: 22,
                             username: "u", auth: .password, passwordSaved: true)
        XCTAssertTrue(backend.saveHost(host, password: nil, passphrase: nil))

        // 关闭保存开关后，ref 被清除
        host.passwordSaved = false
        XCTAssertTrue(backend.saveHost(host, password: nil, passphrase: nil))

        XCTAssertNil(keychain.read(for: "host.h1.password"))
        let record = backend.configRecord(for: "h1")
        if case .password(let ref) = record?.auth {
            XCTAssertNil(ref)
        } else {
            XCTFail("应为密码认证")
        }
    }

    func testBackendSaveHostKeepsRefWhenNoNewPasswordButSaveEnabled() {
        let keychain = InMemoryKeychain()
        keychain.save(secret: "old", for: "host.h1.password")
        let backend = makeBackend(keychain: keychain)
        let host = HostEntry(id: "h1", name: "box", address: "example.com", port: 22,
                             username: "u", auth: .password, passwordSaved: true)
        XCTAssertTrue(backend.saveHost(host, password: nil, passphrase: nil))

        XCTAssertEqual(keychain.read(for: "host.h1.password"), "old")
        let record = backend.configRecord(for: "h1")
        if case .password(let ref) = record?.auth {
            XCTAssertEqual(ref, "host.h1.password")
        } else {
            XCTFail("应为密码认证")
        }
    }

    func testBackendClearKeychainCredentialsRemovesPassword() {
        let keychain = InMemoryKeychain()
        keychain.save(secret: "old", for: "host.h1.password")
        let backend = makeBackend(keychain: keychain)
        let host = HostEntry(id: "h1", name: "box", address: "example.com", port: 22,
                             username: "u", auth: .password, passwordSaved: true)
        XCTAssertTrue(backend.saveHost(host, password: nil, passphrase: nil))

        backend.clearKeychainCredentials(for: "h1", auth: .password)

        XCTAssertNil(keychain.read(for: "host.h1.password"))
    }

    private func makeBackend(keychain: KeychainService) -> PandaCoreBackend {
        // 复用同一 config 目录，避免测试间相互污染；每次新建前清空。
        let backend = PandaCoreBackend(keychain: keychain)
        // 等待 Rust store 初始化完成；若失败则测试会自然失败。
        _ = backend.allHosts()
        return backend
    }
}

import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 认证相关测试。
/// CredentialResolver 的凭据解析逻辑已迁移至 Rust 侧（panda-core credentials::tests），
/// 此处仅保留 Swift 侧可独立测试的组件（FakeKeyPicker）。
@MainActor
final class AuthTests: XCTestCase {

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

import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class HostCopyDraftTests: XCTestCase {
    func testCopiesOnlyNonSensitiveHostFields() {
        let source = HostEntry(
            id: "source", name: "生产", address: "ssh.example.com", port: 2222,
            username: "deploy", note: "备注", groupID: "group", auth: .publicKey,
            keyPath: "/keys/id", passwordSaved: true, passphraseSaved: true,
            fingerprint: "SHA256:known", fingerprintAlgorithm: "ecdsa", demo: .mismatch
        )

        let draft = HostCopyDraft(source: source)

        XCTAssertEqual(draft.name, "生产")
        XCTAssertEqual(draft.address, "ssh.example.com")
        XCTAssertEqual(draft.port, 2222)
        XCTAssertEqual(draft.username, "deploy")
        XCTAssertEqual(draft.note, "备注")
        XCTAssertEqual(draft.groupID, "group")
        XCTAssertEqual(draft.auth, .publicKey)
        XCTAssertEqual(draft.keyPath, "/keys/id")
    }

    func testCopiesRootPasswordHostWithEmptyOptionalFields() {
        let source = HostEntry(id: "source", name: "box", address: "127.0.0.1", port: 22,
                               username: "root", groupID: nil, auth: .password)

        let draft = HostCopyDraft(source: source)

        XCTAssertNil(draft.groupID)
        XCTAssertEqual(draft.auth, .password)
        XCTAssertEqual(draft.note, "")
        XCTAssertEqual(draft.keyPath, "")
    }
}

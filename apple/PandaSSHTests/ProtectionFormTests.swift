import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 任务 5.1：密码保护表单状态与验证测试。
///
/// 正常：四种可信展示状态及状态转换；
/// 意外：读取错误状态、验证失败；
/// 边界：空值、确认不一致。
final class ProtectionFormTests: XCTestCase {

    // MARK: - ProtectionDisplayState 状态测试

    func test未保护状态可创建() {
        let state: ProtectionDisplayState = .unprotected
        XCTAssertEqual(state, .unprotected)
    }

    func test锁定状态可创建() {
        let state: ProtectionDisplayState = .locked
        XCTAssertEqual(state, .locked)
    }

    func test已解锁状态可创建() {
        let state: ProtectionDisplayState = .unlocked
        XCTAssertEqual(state, .unlocked)
    }

    func test读取错误状态携带消息() {
        let state: ProtectionDisplayState = .readError("文件损坏")
        if case .readError(let msg) = state {
            XCTAssertEqual(msg, "文件损坏")
        } else {
            XCTFail("期望 readError 状态")
        }
    }

    func test处理中状态可创建() {
        let state: ProtectionDisplayState = .processing
        XCTAssertEqual(state, .processing)
    }

    func test不同状态互不相等() {
        let states: [ProtectionDisplayState] = [
            .unprotected, .locked, .unlocked, .processing, .readError("err")
        ]
        for i in 0..<states.count {
            for j in (i + 1)..<states.count {
                XCTAssertNotEqual(states[i], states[j], "状态 \(i) 和 \(j) 不应相等")
            }
        }
    }

    func test相同错误消息的状态相等() {
        XCTAssertEqual(ProtectionDisplayState.readError("abc"), .readError("abc"))
    }

    func test不同错误消息的状态不相等() {
        XCTAssertNotEqual(ProtectionDisplayState.readError("a"), .readError("b"))
    }

    // MARK: - FFI 验证函数测试

    func test启用保护验证通过() throws {
        let action = try validateCredentialProtectionInput(
            currentKey: nil, newKey: "secret", confirmKey: "secret", isProtected: false
        )
        XCTAssertEqual(action, .enable)
    }

    func test更换密钥验证通过() throws {
        let action = try validateCredentialProtectionInput(
            currentKey: "old", newKey: "new", confirmKey: "new", isProtected: true
        )
        XCTAssertEqual(action, .changeKey)
    }

    func test移除保护验证通过() throws {
        let action = try validateCredentialProtectionInput(
            currentKey: "old", newKey: nil, confirmKey: nil, isProtected: true
        )
        XCTAssertEqual(action, .remove)
    }

    func test确认不一致被拒绝() {
        XCTAssertThrowsError(
            try validateCredentialProtectionInput(
                currentKey: nil, newKey: "a", confirmKey: "b", isProtected: false
            )
        )
    }

    func test启用时空新密钥被拒绝() {
        XCTAssertThrowsError(
            try validateCredentialProtectionInput(
                currentKey: nil, newKey: "", confirmKey: "", isProtected: false
            )
        )
    }

    func test更换时缺失当前密钥被拒绝() {
        XCTAssertThrowsError(
            try validateCredentialProtectionInput(
                currentKey: nil, newKey: "new", confirmKey: "new", isProtected: true
            )
        )
    }

    // MARK: - FFI 状态查询测试

    func test保护状态查询返回有效枚举() throws {
        let status = try credentialProtectionStatus()
        XCTAssertTrue(
            status == .unprotected || status == .protectedLocked || status == .protectedUnlocked
        )
    }

    // MARK: - SettingsTab 分类验证

    func test设置分类仅含通用和终端() {
        let tabs = SettingsTab.allCases
        XCTAssertEqual(tabs.count, 2)
        XCTAssertTrue(tabs.contains(.general))
        XCTAssertTrue(tabs.contains(.terminal))
    }
}

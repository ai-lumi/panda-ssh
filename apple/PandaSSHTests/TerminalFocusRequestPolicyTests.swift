import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#elseif os(iOS)
@testable import PandaSSH_iOS
#endif

final class TerminalFocusRequestPolicyTests: XCTestCase {
    func test活动终端请求输入焦点() {
        XCTAssertTrue(TerminalFocusRequestPolicy.shouldRequestFocus(isVisible: true, wasVisible: false))
    }

    func test隐藏终端不请求输入焦点() {
        XCTAssertFalse(TerminalFocusRequestPolicy.shouldRequestFocus(isVisible: false, wasVisible: true))
    }

    func test仍处于活动状态时不重复抢占焦点() {
        XCTAssertFalse(TerminalFocusRequestPolicy.shouldRequestFocus(isVisible: true, wasVisible: true))
    }
}

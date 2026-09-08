import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class IPadWorkspaceChromeHostPolicyTests: XCTestCase {
    func test导航页签宽度保留控件空间并适应窄屏() {
        for (width, expected) in [(800.0, 704.0), (320, 224), (96, 0), (20, 0), (0, 0), (-1, 0), (Double.nan, 0), (Double.infinity, 0)] {
            XCTAssertEqual(IPadWorkspaceChromeHostPolicy.navigationTabStripWidth(availableWidth: width), expected)
        }
    }

    func test安全区和系统导航由薄适配层提供() {
        let policy = IPadWorkspaceChromeHostPolicy.resolve(topSafeArea: 24, isCompact: false)

        XCTAssertTrue(policy.usesSystemNavigation)
        XCTAssertEqual(policy.topInset, 24)
        XCTAssertFalse(policy.compactsTopChrome)
    }

    func test旋转紧凑宽度和异常安全区保持非负() {
        for input in [(0.0, true), (Double.nan, true), (-1.0, false)] {
            let policy = IPadWorkspaceChromeHostPolicy.resolve(
                topSafeArea: input.0,
                isCompact: input.1
            )

            XCTAssertGreaterThanOrEqual(policy.topInset, 0)
            XCTAssertEqual(policy.compactsTopChrome, input.1)
        }
    }
}

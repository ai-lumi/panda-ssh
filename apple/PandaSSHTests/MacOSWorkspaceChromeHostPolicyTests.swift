import XCTest

#if os(macOS)
@testable import PandaSSH_macOS

final class MacOSWorkspaceChromeHostPolicyTests: XCTestCase {
    func testAppKit分栏宿主在侧栏显示和隐藏之间保留可恢复状态() {
        let visible = MacOSUnifiedSplitHostPolicy.resolve(
            requestedSidebarWidth: 250,
            isSidebarVisible: true
        )
        let hidden = MacOSUnifiedSplitHostPolicy.resolve(
            requestedSidebarWidth: -.infinity,
            isSidebarVisible: false
        )

        XCTAssertTrue(visible.usesAppKitSplitViewController)
        XCTAssertFalse(visible.isSidebarCollapsed)
        XCTAssertEqual(visible.sidebarWidth, 250)
        XCTAssertTrue(hidden.usesAppKitSplitViewController)
        XCTAssertTrue(hidden.isSidebarCollapsed)
        XCTAssertGreaterThanOrEqual(hidden.sidebarWidth, 220)
    }

    func test正常窗口使用透明标题栏和全尺寸内容并避让红绿灯() {
        let policy = MacOSWorkspaceChromeHostPolicy.resolve(
            windowWidth: 1_200,
            isFullScreen: false,
            isSidebarVisible: true,
            trafficLightSafeWidth: 76
        )

        XCTAssertTrue(policy.usesTransparentTitlebar)
        XCTAssertTrue(policy.usesFullSizeContent)
        XCTAssertFalse(policy.usesPrincipalToolbarItem)
        XCTAssertFalse(policy.usesSystemToolbar)
        XCTAssertTrue(policy.providesWindowDragRegion)
        XCTAssertTrue(policy.keepsStandardWindowButtonsVisible)
        XCTAssertEqual(policy.leadingReservedWidth, 76)
        XCTAssertEqual(policy.trailingReservedWidth, 0)
        XCTAssertFalse(policy.showsSidebarRecovery)
    }

    func test最小窗口全屏和隐藏侧栏保留可用安全区() {
        for input in [(320.0, false), (320.0, true), (Double.nan, true)] {
            let policy = MacOSWorkspaceChromeHostPolicy.resolve(
                windowWidth: input.0,
                isFullScreen: input.1,
                isSidebarVisible: false,
                trafficLightSafeWidth: -.infinity
            )

            XCTAssertGreaterThanOrEqual(policy.leadingReservedWidth, 0)
            XCTAssertGreaterThanOrEqual(policy.trailingReservedWidth, 0)
            XCTAssertTrue(policy.showsSidebarRecovery)
            XCTAssertTrue(policy.providesWindowDragRegion)
        }
    }
}
#endif

import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class UnifiedWorkspaceChromeLayoutTests: XCTestCase {
    func test系统提供恢复入口时不重复绘制或占位() {
        for width in [800.0, 320, 20, 0, -1, Double.nan, Double.infinity] {
            for visible in [true, false, true, false] {
                let layout = UnifiedWorkspaceChromeLayout.resolve(
                    windowWidth: width, sidebarWidth: 0, isSidebarVisible: visible,
                    leadingReservedWidth: 0, trailingReservedWidth: 0, isFullScreen: false,
                    showsCustomSidebarRecovery: false)
                XCTAssertFalse(layout.showsSidebarRecovery)
                XCTAssertEqual(layout.sidebarRecoveryWidth, 0)
                XCTAssertFalse(layout.showsSidebarTools)
                XCTAssertEqual(layout.tabStripWidth, width.isFinite ? max(0, width) : 0)
            }
        }
    }

    func testIPad详情顶栏没有侧栏工具区时不得绘制按钮() {
        let layout = UnifiedWorkspaceChromeLayout.resolve(
            windowWidth: 800, sidebarWidth: 0, isSidebarVisible: true,
            leadingReservedWidth: 0, trailingReservedWidth: 0, isFullScreen: false)
        XCTAssertFalse(layout.showsSidebarTools)
        XCTAssertEqual(layout.tabStripWidth, 800)
        XCTAssertFalse(layout.showsSidebarRecovery)
    }
    func test侧栏展开时工具区与页签区不重叠() {
        let layout = UnifiedWorkspaceChromeLayout.resolve(
            windowWidth: 1_200,
            sidebarWidth: 260,
            isSidebarVisible: true,
            leadingReservedWidth: 76,
            trailingReservedWidth: 0,
            isFullScreen: false
        )

        XCTAssertGreaterThan(layout.sidebarToolsWidth, 0)
        XCTAssertGreaterThan(layout.tabStripWidth, 0)
        XCTAssertEqual(layout.leadingSafeWidth + layout.sidebarToolsWidth + layout.tabStripWidth, 1_200)
        XCTAssertFalse(layout.showsSidebarRecovery)
        XCTAssertFalse(layout.drawsDetailTabBar)
    }

    /// macOS 只应在显式保留的空白区域启动窗口拖动；页签和按钮区域
    /// 不得再由覆盖整个 chrome 的背景拖动视图接管鼠标按下事件。
    func test尾部窗口拖动保留区与页签区分离() {
        let layout = UnifiedWorkspaceChromeLayout.resolve(
            windowWidth: 1_200,
            sidebarWidth: 260,
            isSidebarVisible: true,
            leadingReservedWidth: 76,
            trailingReservedWidth: 80,
            isFullScreen: false
        )

        XCTAssertEqual(layout.trailingSafeWidth, 80)
        XCTAssertEqual(
            layout.leadingSafeWidth + layout.sidebarToolsWidth
                + layout.tabStripWidth + layout.trailingSafeWidth,
            1_200
        )
        XCTAssertEqual(layout.tabStripWidth, 860)
    }

    func test侧栏隐藏时保留恢复入口并把空间交给页签栏() {
        let layout = UnifiedWorkspaceChromeLayout.resolve(
            windowWidth: 1_200,
            sidebarWidth: 260,
            isSidebarVisible: false,
            leadingReservedWidth: 76,
            trailingReservedWidth: 0,
            isFullScreen: false
        )

        XCTAssertEqual(layout.sidebarToolsWidth, 0)
        XCTAssertTrue(layout.showsSidebarRecovery)
        XCTAssertEqual(layout.leadingSafeWidth, 76)
        XCTAssertGreaterThan(layout.tabStripWidth, 1_000)
        XCTAssertFalse(layout.drawsDetailTabBar)
    }

    func test窄窗口隐藏侧栏时页签栏取得红绿灯和恢复入口以外的全部空间() {
        let layout = UnifiedWorkspaceChromeLayout.resolve(
            windowWidth: 400,
            sidebarWidth: 250,
            isSidebarVisible: false,
            leadingReservedWidth: 76,
            trailingReservedWidth: 0,
            isFullScreen: false
        )

        XCTAssertEqual(layout.leadingSafeWidth, 76)
        XCTAssertEqual(layout.sidebarRecoveryWidth, 40)
        XCTAssertEqual(layout.tabStripWidth, 284)
    }

    func test窄窗口全屏和无效宽度仍产生非负布局() {
        for input in [
            (320.0, 260.0, true, 84.0, 96.0, false),
            (Double.nan, 260.0, false, 84.0, 96.0, true),
            (500.0, Double.infinity, true, -1.0, -1.0, true),
        ] {
            let layout = UnifiedWorkspaceChromeLayout.resolve(
                windowWidth: input.0,
                sidebarWidth: input.1,
                isSidebarVisible: input.2,
                leadingReservedWidth: input.3,
                trailingReservedWidth: input.4,
                isFullScreen: input.5
            )

            XCTAssertGreaterThanOrEqual(layout.availableWidth, 0)
            XCTAssertGreaterThanOrEqual(layout.sidebarToolsWidth, 0)
            XCTAssertGreaterThanOrEqual(layout.tabStripWidth, 0)
            XCTAssertFalse(layout.drawsDetailTabBar)
        }
    }
}

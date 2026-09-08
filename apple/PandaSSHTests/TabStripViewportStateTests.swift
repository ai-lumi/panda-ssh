import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class TabStripViewportStateTests: XCTestCase {
    func test共享Shell保留页签顺序与有效活动页签() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let shell = WorkspaceShell.resolve(
            tabIDs: [first, second, third],
            activeTabID: second
        )

        XCTAssertEqual(shell.tabIDs, [first, second, third])
        XCTAssertEqual(shell.activeTabID, second)
    }

    func test空页签和无效活动页签安全归一化() {
        let unknownTab = UUID()
        let shell = WorkspaceShell.resolve(tabIDs: [], activeTabID: unknownTab)
        let viewport = TabStripViewportState.resolve(
            contentWidth: .nan,
            viewportWidth: -.infinity,
            offset: .infinity
        )

        XCTAssertTrue(shell.tabIDs.isEmpty)
        XCTAssertNil(shell.activeTabID)
        XCTAssertEqual(viewport.contentWidth, 0)
        XCTAssertEqual(viewport.viewportWidth, 0)
        XCTAssertEqual(viewport.offset, 0)
        XCTAssertEqual(viewport.maximumOffset, 0)
        XCTAssertFalse(viewport.needsScroll)
    }

    func test大量页签的视口偏移和活动页签显露始终夹取() {
        let viewport = TabStripViewportState.resolve(
            contentWidth: 100_000,
            viewportWidth: 320,
            offset: 99_999
        )

        XCTAssertEqual(viewport.maximumOffset, 99_680)
        XCTAssertEqual(viewport.offset, 99_680)
        XCTAssertTrue(viewport.needsScroll)
        XCTAssertEqual(
            viewport.revealedOffset(itemMinX: 99_700, itemMaxX: 99_760),
            99_680
        )
        XCTAssertEqual(
            viewport.revealedOffset(itemMinX: -100, itemMaxX: 100),
            0
        )
    }

    func test鼠标滚轮被归一化为离散页签步进() {
        XCTAssertEqual(
            TabStripScrollInput.normalize(
                horizontalDelta: 0,
                verticalDelta: -1,
                isPrecise: false
            ),
            .discrete(.forward)
        )
        XCTAssertEqual(
            TabStripScrollInput.normalize(
                horizontalDelta: 10,
                verticalDelta: -9,
                isPrecise: false
            ),
            .discrete(.backward)
        )
    }

    func test缺失或无效滚轮delta不移动而触控板保留连续值() {
        XCTAssertNil(
            TabStripScrollInput.normalize(
                horizontalDelta: 0,
                verticalDelta: 0,
                isPrecise: false
            )
        )
        XCTAssertNil(
            TabStripScrollInput.normalize(
                horizontalDelta: .infinity,
                verticalDelta: 4,
                isPrecise: true
            )
        )
        XCTAssertEqual(
            TabStripScrollInput.normalize(
                horizontalDelta: 2.5,
                verticalDelta: 1,
                isPrecise: true
            ),
            .continuous(delta: 2.5)
        )
    }

    func test离散滚轮按可见页宽浏览且不越过首尾() {
        let viewport = TabStripViewportState.resolve(
            contentWidth: 1_000,
            viewportWidth: 300,
            offset: 200
        )

        XCTAssertEqual(viewport.targetOffset(after: .discrete(.forward)), 500)
        XCTAssertEqual(viewport.targetOffset(after: .discrete(.backward)), 0)

        let trailing = TabStripViewportState.resolve(
            contentWidth: 1_000,
            viewportWidth: 300,
            offset: 700
        )
        XCTAssertEqual(trailing.targetOffset(after: .discrete(.forward)), 700)
    }

    func test连续滚动和惯性值被夹取而不影响共享Shell活动页签() {
        let activeTab = UUID()
        let shell = WorkspaceShell.resolve(tabIDs: [activeTab], activeTabID: activeTab)
        let viewport = TabStripViewportState.resolve(
            contentWidth: 1_000,
            viewportWidth: 300,
            offset: 200
        )

        XCTAssertEqual(viewport.targetOffset(after: .continuous(delta: -60)), 260)
        XCTAssertEqual(viewport.targetOffset(after: .continuous(delta: 999)), 0)
        XCTAssertEqual(viewport.targetOffset(after: .continuous(delta: -999)), 700)
        XCTAssertEqual(shell.activeTabID, activeTab)
    }

    #if os(macOS)
    func testAppKit滚轮桥接复用共享输入归一化而不选择页签() {
        XCTAssertEqual(
            MacOSTabStripWheelInput.resolve(
                horizontalDelta: 0,
                verticalDelta: -1,
                isPrecise: false
            ),
            .discrete(.forward)
        )
        XCTAssertEqual(
            MacOSTabStripWheelInput.resolve(
                horizontalDelta: 3,
                verticalDelta: 1,
                isPrecise: true
            ),
            .continuous(delta: 3)
        )
    }
    #endif
}

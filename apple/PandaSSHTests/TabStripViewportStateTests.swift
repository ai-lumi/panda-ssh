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

    func test内容宽度计算包含尾部填充且空页签返回零() {
        let tab = UUID()
        let frames = [tab: CGRect(x: 8, y: 0, width: 100, height: 30)]
        XCTAssertEqual(TabStripViewportState.contentWidth(from: frames), 116)
        XCTAssertEqual(TabStripViewportState.contentWidth(from: [:]), 0)
    }

    func test最右侧页签宽于视口时滚动目标使用TrailingAnchor显露完整页签() {
        let tab = UUID()
        let frames = [tab: CGRect(x: 300, y: 0, width: 500, height: 30)]
        let viewport = TabStripViewportState.resolve(contentWidth: 808, viewportWidth: 400, offset: 0)
        let target = viewport.scrollTarget(for: 408, among: frames)
        XCTAssertEqual(target?.tabID, tab)
        XCTAssertEqual(target?.anchorX ?? -1, 1.0, accuracy: 0.001)
    }

    func test宽页签目标偏移在可视范围内时使用线性插值Anchor() {
        let tab = UUID()
        let frames = [tab: CGRect(x: 100, y: 0, width: 500, height: 30)]
        let viewport = TabStripViewportState.resolve(contentWidth: 608, viewportWidth: 200, offset: 0)
        let target = viewport.scrollTarget(for: 250, among: frames)
        XCTAssertEqual(target?.tabID, tab)
        XCTAssertEqual(target?.anchorX ?? -1, (250 - 100) / (500 - 200), accuracy: 0.001)
    }

    func test窄于视口的页签使用LeadingAnchor() {
        let tab = UUID()
        let frames = [tab: CGRect(x: 500, y: 0, width: 100, height: 30)]
        let viewport = TabStripViewportState.resolve(contentWidth: 608, viewportWidth: 300, offset: 0)
        let target = viewport.scrollTarget(for: 308, among: frames)
        XCTAssertEqual(target?.tabID, tab)
        XCTAssertEqual(target?.anchorX ?? -1, 0, accuracy: 0.001)
    }

    func test滚动到内容末端时以最后页签为目标完整显露最右页签() {
        // 根因：scrollTo 以单个页签为锚点时，实际落点不会超过该页签前缘；
        // 跨在最大偏移上的页签会把落点卡在 maximumOffset 之前，最右页签永远只显露一半。
        // 期望：末端目标直接选最后页签，窄页签经 ScrollView 末端夹取精确抵达。
        let last = UUID()
        let frames = [last: CGRect(x: 400, y: 0, width: 120, height: 30)]
        let viewport = TabStripViewportState.resolve(contentWidth: 528, viewportWidth: 300, offset: 0)
        let target = viewport.scrollTarget(for: 228, among: frames) // 228 = 528 - 300
        XCTAssertEqual(target?.tabID, last)
        XCTAssertEqual(target?.anchorX ?? -1, 0, accuracy: 0.001)
    }

    func test滚动到内容末端时宽页签使用TrailingAnchor贴住视口右缘() {
        // 最后一个页签宽于视口：以 trailing anchor 露出其右缘（受尾部 padding 限制差 8pt，但页签完整可见）。
        let last = UUID()
        let frames = [last: CGRect(x: 50, y: 0, width: 600, height: 30)]
        let viewport = TabStripViewportState.resolve(contentWidth: 658, viewportWidth: 400, offset: 0)
        let target = viewport.scrollTarget(for: 258, among: frames) // 258 = 658 - 400
        XCTAssertEqual(target?.tabID, last)
        XCTAssertEqual(target?.anchorX ?? -1, 1.0, accuracy: 0.001)
    }
}

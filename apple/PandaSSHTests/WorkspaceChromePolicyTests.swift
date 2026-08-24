import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class WorkspaceChromePolicyTests: XCTestCase {
    func testMac隐藏应用标题并把整条页签栏放到Principal() {
        let policy = WorkspaceChromePolicy.resolve(
            platform: .macOS,
            tabCount: 3,
            isSidebarVisible: true,
            windowWidth: 1180
        )

        XCTAssertFalse(policy.showsApplicationTitle)
        XCTAssertTrue(policy.usesSystemToolbar)
        XCTAssertEqual(policy.tabPlacement, .principalToolbar)
        XCTAssertFalse(policy.drawsContentTabRow)
        XCTAssertTrue(policy.preservesSystemWindowControls)
    }

    func testIPad不显示应用标题且页签保留在自适应内容行() {
        let policy = WorkspaceChromePolicy.resolve(
            platform: .iPadOS,
            tabCount: 3,
            isSidebarVisible: true,
            windowWidth: 1024
        )

        XCTAssertFalse(policy.showsApplicationTitle)
        XCTAssertEqual(policy.tabPlacement, .adaptiveContentRow)
        XCTAssertTrue(policy.drawsContentTabRow)
    }

    func test零标签时Mac标题位置保持安静且不增加内容页签行() {
        let policy = WorkspaceChromePolicy.resolve(
            platform: .macOS,
            tabCount: 0,
            isSidebarVisible: true,
            windowWidth: 900
        )

        XCTAssertEqual(policy.visibleTabCount, 0)
        XCTAssertEqual(policy.tabPlacement, .principalToolbar)
        XCTAssertFalse(policy.drawsContentTabRow)
        XCTAssertFalse(policy.showsApplicationTitle)
    }

    func test侧栏隐藏不改变系统工具栏与窗口控件策略() {
        let policy = WorkspaceChromePolicy.resolve(
            platform: .macOS,
            tabCount: 1,
            isSidebarVisible: false,
            windowWidth: 900
        )

        XCTAssertTrue(policy.usesSystemToolbar)
        XCTAssertTrue(policy.preservesSystemWindowControls)
        XCTAssertTrue(policy.providesSystemSidebarRecovery)
        XCTAssertFalse(policy.removesDefaultSidebarToggle)
    }

    func test侧栏可见时移除系统默认按钮避免与侧栏内部按钮重复() {
        let policy = WorkspaceChromePolicy.resolve(
            platform: .macOS,
            tabCount: 1,
            isSidebarVisible: true,
            windowWidth: 900
        )

        XCTAssertTrue(policy.removesDefaultSidebarToggle)
    }

    func testIPad不移除系统侧栏恢复入口() {
        let policy = WorkspaceChromePolicy.resolve(
            platform: .iPadOS,
            tabCount: 1,
            isSidebarVisible: true,
            windowWidth: 900
        )

        XCTAssertFalse(policy.removesDefaultSidebarToggle)
    }

    func test最小窗口和无效宽度安全限制Principal宽度() {
        for width in [Double.nan, -Double.infinity, -1, 0, 420] {
            let policy = WorkspaceChromePolicy.resolve(
                platform: .macOS,
                tabCount: 2,
                isSidebarVisible: true,
                windowWidth: width
            )
            XCTAssertGreaterThanOrEqual(policy.principalWidth, 0)
            XCTAssertLessThanOrEqual(policy.principalWidth, WorkspaceChromePolicy.maximumPrincipalWidth)
        }
    }

    func test大量标签依然只有一条可滚动Principal页签栏() {
        let policy = WorkspaceChromePolicy.resolve(
            platform: .macOS,
            tabCount: 10_000,
            isSidebarVisible: true,
            windowWidth: 1600
        )

        XCTAssertEqual(policy.visibleTabCount, 10_000)
        XCTAssertEqual(policy.tabRowCount, 1)
        XCTAssertEqual(policy.principalWidth, WorkspaceChromePolicy.maximumPrincipalWidth)
        XCTAssertFalse(policy.drawsContentTabRow)
    }

    func test负标签数量按零处理() {
        let policy = WorkspaceChromePolicy.resolve(
            platform: .macOS,
            tabCount: -4,
            isSidebarVisible: true,
            windowWidth: 1000
        )

        XCTAssertEqual(policy.visibleTabCount, 0)
        XCTAssertEqual(policy.tabRowCount, 0)
    }
}

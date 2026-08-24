import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class WorkspaceLayoutPolicyTests: XCTestCase {
    func testMac始终使用桌面工作区() {
        let policy = WorkspaceLayoutPolicy.resolve(
            platform: .macOS,
            horizontalSizeClass: .compact,
            availableWidth: 480
        )

        XCTAssertEqual(policy.sidebarPresentation, .sideBySide)
        XCTAssertEqual(policy.sftpPresentation, .dualPane)
        XCTAssertEqual(policy.transferPresentation, .drawer)
        XCTAssertEqual(policy.minimumInteractiveLength, 24)
    }

    func testIPad常规宽度使用并列布局() {
        let policy = WorkspaceLayoutPolicy.resolve(
            platform: .iPadOS,
            horizontalSizeClass: .regular,
            availableWidth: 1024
        )

        XCTAssertEqual(policy.sidebarPresentation, .sideBySide)
        XCTAssertEqual(policy.sftpPresentation, .dualPane)
        XCTAssertEqual(policy.transferPresentation, .inspector)
        XCTAssertEqual(policy.minimumInteractiveLength, 44)
    }

    func testIPadCompactSizeClass即使宽度较大也使用紧凑布局() {
        let policy = WorkspaceLayoutPolicy.resolve(
            platform: .iPadOS,
            horizontalSizeClass: .compact,
            availableWidth: 900
        )

        XCTAssertEqual(policy.sidebarPresentation, .systemCollapsed)
        XCTAssertEqual(policy.sftpPresentation, .singlePane)
        XCTAssertEqual(policy.transferPresentation, .sheet)
    }

    func testIPadRegularSizeClass在实际宽度不足时安全降级() {
        let policy = WorkspaceLayoutPolicy.resolve(
            platform: .iPadOS,
            horizontalSizeClass: .regular,
            availableWidth: 520
        )

        XCTAssertEqual(policy.sidebarPresentation, .systemCollapsed)
        XCTAssertEqual(policy.sftpPresentation, .singlePane)
        XCTAssertEqual(policy.transferPresentation, .sheet)
    }

    func test无效宽度采用保守紧凑回退() {
        for width in [Double.nan, .infinity, -.infinity, 0, -1] {
            let policy = WorkspaceLayoutPolicy.resolve(
                platform: .iPadOS,
                horizontalSizeClass: .unspecified,
                availableWidth: width
            )

            XCTAssertEqual(policy.sidebarPresentation, .systemCollapsed)
            XCTAssertEqual(policy.sftpPresentation, .singlePane)
            XCTAssertEqual(policy.transferPresentation, .sheet)
        }
    }

    func test常规宽度阈值边界() {
        let below = WorkspaceLayoutPolicy.resolve(
            platform: .iPadOS,
            horizontalSizeClass: .regular,
            availableWidth: WorkspaceLayoutPolicy.regularWidthThreshold - 1
        )
        let atThreshold = WorkspaceLayoutPolicy.resolve(
            platform: .iPadOS,
            horizontalSizeClass: .regular,
            availableWidth: WorkspaceLayoutPolicy.regularWidthThreshold
        )
        let above = WorkspaceLayoutPolicy.resolve(
            platform: .iPadOS,
            horizontalSizeClass: .regular,
            availableWidth: WorkspaceLayoutPolicy.regularWidthThreshold + 1
        )

        XCTAssertEqual(below.sftpPresentation, .singlePane)
        XCTAssertEqual(atThreshold.sftpPresentation, .dualPane)
        XCTAssertEqual(above.sftpPresentation, .dualPane)
    }
}

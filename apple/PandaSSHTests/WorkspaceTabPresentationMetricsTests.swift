import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class WorkspaceTabPresentationMetricsTests: XCTestCase {
    func testMac当前项与悬停项显示关闭入口() {
        XCTAssertTrue(metrics(platform: .macOS, active: true, hovered: false).showsCloseButton)
        XCTAssertTrue(metrics(platform: .macOS, active: false, hovered: true).showsCloseButton)
        XCTAssertFalse(metrics(platform: .macOS, active: false, hovered: false).showsCloseButton)
        XCTAssertEqual(metrics(platform: .macOS, active: true, hovered: false).minimumHitTarget, 24)
        XCTAssertEqual(metrics(platform: .macOS, active: true, hovered: false).closeButtonCornerRadius, 4)
    }

    func testIPad当前页签无需指针也显示关闭入口() {
        let value = metrics(platform: .iPadOS, active: true, hovered: false)

        XCTAssertTrue(value.showsCloseButton)
        XCTAssertEqual(value.minimumHitTarget, 44)
        XCTAssertEqual(value.minimumTabHeight, 44)
    }

    func testIPad非当前页签在无指针环境隐藏关闭入口() {
        XCTAssertFalse(metrics(platform: .iPadOS, active: false, hovered: false).showsCloseButton)
        XCTAssertTrue(metrics(platform: .iPadOS, active: false, hovered: true).showsCloseButton)
    }

    func test页签父选择手势不包含关闭子控件() {
        for platform in [WorkspaceTabPresentationMetrics.Platform.macOS, .iPadOS] {
            let value = metrics(platform: platform, active: true, hovered: false)

            XCTAssertFalse(value.selectionGestureIncludesSubviews)
        }
    }

    func test超长标题被限制但仍保留正宽度() {
        let value = WorkspaceTabPresentationMetrics.resolve(
            platform: .iPadOS,
            isActive: true,
            isHovered: false,
            availableWidth: 1_000,
            titleCharacterCount: 10_000
        )

        XCTAssertEqual(value.maximumTitleWidth, WorkspaceTabPresentationMetrics.maximumTitleWidth)
        XCTAssertGreaterThan(value.maximumTitleWidth, 0)
    }

    func test中文短标题使用完整可用宽度而非字符数估算() {
        let value = WorkspaceTabPresentationMetrics.resolve(
            platform: .macOS,
            isActive: true,
            isHovered: false,
            availableWidth: WorkspaceTabPresentationMetrics.maximumTitleWidth,
            titleCharacterCount: 3
        )

        XCTAssertEqual(value.maximumTitleWidth, WorkspaceTabPresentationMetrics.maximumTitleWidth)
    }

    func test零宽和无效宽度不会生成负尺寸() {
        for width in [Double.nan, -Double.infinity, -1, 0] {
            let value = WorkspaceTabPresentationMetrics.resolve(
                platform: .iPadOS,
                isActive: true,
                isHovered: false,
                availableWidth: width,
                titleCharacterCount: 12
            )
            XCTAssertEqual(value.maximumTitleWidth, 0)
        }
    }

    func test空标题仍保留统一最大可用宽度() {
        let value = WorkspaceTabPresentationMetrics.resolve(
            platform: .macOS,
            isActive: false,
            isHovered: false,
            availableWidth: 500,
            titleCharacterCount: 0
        )

        XCTAssertEqual(value.maximumTitleWidth, WorkspaceTabPresentationMetrics.maximumTitleWidth)
    }

    private func metrics(
        platform: WorkspaceTabPresentationMetrics.Platform,
        active: Bool,
        hovered: Bool
    ) -> WorkspaceTabPresentationMetrics {
        WorkspaceTabPresentationMetrics.resolve(
            platform: platform,
            isActive: active,
            isHovered: hovered,
            availableWidth: 500,
            titleCharacterCount: 12
        )
    }
}

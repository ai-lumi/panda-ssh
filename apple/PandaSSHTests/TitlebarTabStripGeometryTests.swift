import XCTest

#if os(macOS)
@testable import PandaSSH_macOS

final class TitlebarTabStripGeometryTests: XCTestCase {
    func test侧栏可见时标题栏容器从detail起点开始并避让右侧控件() {
        let geometry = TitlebarTabStripGeometry.resolve(
            windowWidth: 1_180,
            detailMinX: 250,
            leadingReservedWidth: 0,
            trailingReservedWidth: 96,
            titlebarHeight: 38
        )

        XCTAssertEqual(geometry.frame.minX, 250)
        XCTAssertEqual(geometry.frame.maxX, 1_084)
        XCTAssertEqual(geometry.frame.height, 38)
        XCTAssertTrue(geometry.isUsable)
    }

    func test侧栏隐藏时避让系统恢复按钮与红绿灯区域() {
        let geometry = TitlebarTabStripGeometry.resolve(
            windowWidth: 900,
            detailMinX: 0,
            leadingReservedWidth: 132,
            trailingReservedWidth: 96,
            titlebarHeight: 38
        )

        XCTAssertEqual(geometry.frame.minX, 132)
        XCTAssertEqual(geometry.frame.maxX, 804)
        XCTAssertTrue(geometry.isUsable)
    }

    func test最小窗口和无效输入不会生成覆盖控件的候选矩形() {
        for values in [
            (320.0, 0.0, 132.0, 220.0, 38.0),
            (Double.nan, 0.0, 132.0, 96.0, 38.0),
            (800.0, -1.0, -10.0, Double.infinity, -1.0),
        ] {
            let geometry = TitlebarTabStripGeometry.resolve(
                windowWidth: values.0,
                detailMinX: values.1,
                leadingReservedWidth: values.2,
                trailingReservedWidth: values.3,
                titlebarHeight: values.4
            )

            XCTAssertGreaterThanOrEqual(geometry.frame.minX, 0)
            XCTAssertGreaterThanOrEqual(geometry.frame.width, 0)
            XCTAssertFalse(geometry.frame.maxX.isNaN)
            XCTAssertFalse(geometry.frame.height.isNaN)
        }
    }
}
#endif

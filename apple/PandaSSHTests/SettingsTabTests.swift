import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class SettingsTabTests: XCTestCase {
    func test设置标签仅保留已实现分类() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.title),
            ["通用", "终端"]
        )
    }

    func test设置标签均有稳定的系统图标() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.systemImage),
            ["gear", "terminal"]
        )
    }

    func test占位分类已移除() {
        let titles = SettingsTab.allCases.map(\.rawValue)
        XCTAssertFalse(titles.contains("appearance"))
        XCTAssertFalse(titles.contains("connection"))
        XCTAssertFalse(titles.contains("advanced"))
    }
}

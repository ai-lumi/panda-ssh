import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class SettingsTabTests: XCTestCase {
    func test设置标签目录在双端一致() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.title),
            ["通用", "外观", "连接", "终端", "高级"]
        )
    }

    func test设置标签均有稳定的系统图标() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.systemImage),
            ["gear", "paintbrush", "link", "terminal", "gearshape.2"]
        )
    }
}

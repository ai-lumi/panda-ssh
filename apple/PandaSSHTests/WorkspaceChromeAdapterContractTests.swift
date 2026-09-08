import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class WorkspaceChromeAdapterContractTests: XCTestCase {
    func testMac适配仅提供标题栏安全矩形和窗口拖拽能力() {
        let contract = WorkspaceChromeAdapterContract.resolve(
            platform: .macOS,
            leadingReservedWidth: 132,
            trailingReservedWidth: 96,
            topSafeArea: 0
        )

        XCTAssertTrue(contract.usesTitlebarSafeRectangle)
        XCTAssertTrue(contract.providesWindowDragRegion)
        XCTAssertFalse(contract.usesSystemNavigation)
        XCTAssertEqual(contract.leadingReservedWidth, 132)
        XCTAssertEqual(contract.trailingReservedWidth, 96)
        XCTAssertEqual(contract.topInset, 0)
    }

    func testIPad适配仅提供安全区和系统导航入口() {
        let contract = WorkspaceChromeAdapterContract.resolve(
            platform: .iPadOS,
            leadingReservedWidth: 132,
            trailingReservedWidth: 96,
            topSafeArea: 24
        )

        XCTAssertFalse(contract.usesTitlebarSafeRectangle)
        XCTAssertFalse(contract.providesWindowDragRegion)
        XCTAssertTrue(contract.usesSystemNavigation)
        XCTAssertEqual(contract.leadingReservedWidth, 0)
        XCTAssertEqual(contract.trailingReservedWidth, 0)
        XCTAssertEqual(contract.topInset, 24)
    }

    func test无效平台输入不能产生负安全区() {
        let contract = WorkspaceChromeAdapterContract.resolve(
            platform: .macOS,
            leadingReservedWidth: -.infinity,
            trailingReservedWidth: .nan,
            topSafeArea: -1
        )

        XCTAssertEqual(contract.leadingReservedWidth, 0)
        XCTAssertEqual(contract.trailingReservedWidth, 0)
        XCTAssertEqual(contract.topInset, 0)
    }
}

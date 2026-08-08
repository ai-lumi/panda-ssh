import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 分组选中与「新建主机默认归属分组」测试:
/// 正常流程(选中分组/主机决定默认分组)、意外操作(删除选中的分组)、
/// 边界条件(无选中、选中根级主机)三类用例。
@MainActor
final class AppModelSelectionTests: XCTestCase {

    private var model: AppModel!

    override func setUp() {
        model = AppModel(backend: MockBackend.demo())
    }

    // MARK: 正常流程

    func testSelectGroupSetsSelectionAndClearsHost() {
        model.selectHost("h-webprod")
        model.selectGroup("g-east")
        XCTAssertEqual(model.selectedGroupID, "g-east")
        XCTAssertNil(model.selectedHostID, "选中分组后主机选中态应清除(单一选中语义)")
    }

    func testSelectHostClearsGroupSelection() {
        model.selectGroup("g-east")
        model.selectHost("h-webprod")
        XCTAssertNil(model.selectedGroupID)
        XCTAssertEqual(model.selectedHostID, "h-webprod")
    }

    func testNewHostDefaultsToSelectedGroup() {
        model.selectGroup("g-east")
        XCTAssertEqual(model.groupIDForNewHost, "g-east")
    }

    func testNewHostDefaultsToGroupOfSelectedHost() {
        model.selectHost("h-webprod") // 属于 g-east
        XCTAssertEqual(model.groupIDForNewHost, "g-east", "选中分组内主机时,默认归属该主机所在分组")
    }

    func testSelectedGroupWinsOverSelectedHost() {
        model.selectHost("h-webprod")
        model.selectGroup("g-test")
        XCTAssertEqual(model.groupIDForNewHost, "g-test")
    }

    // MARK: 意外操作

    func testDeleteSelectedGroupClearsSelection() {
        model.selectGroup("g-east")
        model.deleteGroup(id: "g-east")
        XCTAssertNil(model.selectedGroupID, "删除选中的分组后选中态应清除")
        XCTAssertNil(model.groupIDForNewHost)
    }

    // MARK: 边界条件

    func testNoSelectionDefaultsToRoot() {
        XCTAssertNil(model.groupIDForNewHost)
    }

    func testRootLevelHostSelectionDefaultsToRoot() {
        model.selectHost("h-newtoy") // 根级主机,无分组
        XCTAssertNil(model.groupIDForNewHost)
    }
}

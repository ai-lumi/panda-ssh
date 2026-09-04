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
        XCTAssertEqual(model.workspacePresentation, .empty)
    }

    func testSelectHostClearsGroupSelection() {
        model.selectGroup("g-east")
        model.selectHost("h-webprod")
        XCTAssertNil(model.selectedGroupID)
        XCTAssertEqual(model.selectedHostID, "h-webprod")
        XCTAssertEqual(model.workspacePresentation, .hostDetail(hostID: "h-webprod"))
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

    func testPresentTab切回主机页并记录互斥呈现选择() {
        let tabID = UUID()
        model.showSnippets()

        model.presentTab(tabID)

        XCTAssertEqual(model.sidebarPage, .hosts)
        XCTAssertEqual(model.workspacePresentation, .tab(tabID: tabID))
    }

    func testConnectionMonitorPresentationPreservesCurrentWorkspaceSelection() {
        model.selectHost("h-webprod")
        let presentation = model.workspacePresentation

        model.showConnectionMonitor()

        #if os(macOS)
        XCTAssertEqual(model.sidebarPage, .hosts, "macOS 应由独立窗口呈现监控，不覆盖主工作区")
        #else
        XCTAssertEqual(model.sidebarPage, .connectionMonitor)
        #endif
        XCTAssertEqual(model.workspacePresentation, presentation)
        XCTAssertEqual(model.selectedHostID, "h-webprod")
    }

    func testRepeatedConnectionMonitorPresentationDoesNotMutateExistingSelection() {
        model.selectGroup("g-prod")
        let presentation = model.workspacePresentation

        model.showConnectionMonitor()
        model.showConnectionMonitor()

        #if os(macOS)
        XCTAssertEqual(model.sidebarPage, .hosts)
        #else
        XCTAssertEqual(model.sidebarPage, .connectionMonitor)
        #endif
        XCTAssertEqual(model.workspacePresentation, presentation)
        XCTAssertEqual(model.selectedGroupID, "g-prod")
        XCTAssertNil(model.selectedHostID)
    }

    func testConnectionMonitorPresentationHandlesEmptyWorkspace() {
        XCTAssertEqual(model.workspacePresentation, .empty)

        model.showConnectionMonitor()

        #if os(macOS)
        XCTAssertEqual(model.sidebarPage, .hosts)
        #else
        XCTAssertEqual(model.sidebarPage, .connectionMonitor)
        #endif
        XCTAssertEqual(model.workspacePresentation, .empty)
        XCTAssertNil(model.selectedHostID)
        XCTAssertNil(model.selectedGroupID)
    }

    func testDeletePresentedHostCle空内容选择() {
        model.selectHost("h-webprod")

        model.deleteHost(id: "h-webprod")

        XCTAssertEqual(model.workspacePresentation, .empty)
    }
}

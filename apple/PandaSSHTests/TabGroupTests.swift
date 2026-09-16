import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// TabGroup 模型单元测试：覆盖正常流程（创建、命名、空分组判断）、
/// 意外操作（空名称处理）、边界条件（大量分组性能）三类用例。
@MainActor
final class TabGroupTests: XCTestCase {

    // MARK: - 正常流程

    func testCreateGroupWithValidName() {
        let group = TabGroup(id: UUID(), name: "开发环境", tabIDs: [])
        XCTAssertEqual(group.name, "开发环境")
        XCTAssertTrue(group.tabIDs.isEmpty)
    }

    func testCreateGroupWithTabIDs() {
        let tab1 = UUID()
        let tab2 = UUID()
        let group = TabGroup(id: UUID(), name: "测试", tabIDs: [tab1, tab2])
        XCTAssertEqual(group.tabIDs, [tab1, tab2])
        XCTAssertEqual(group.tabIDs.count, 2)
    }

    func testGroupEquality() {
        let id = UUID()
        let group1 = TabGroup(id: id, name: "A", tabIDs: [])
        let group2 = TabGroup(id: id, name: "A", tabIDs: [])
        XCTAssertEqual(group1, group2)
    }

    func testGroupIdentifiable() {
        let id = UUID()
        let group = TabGroup(id: id, name: "测试", tabIDs: [])
        XCTAssertEqual(group.id, id)
    }

    func testIsEmptyReturnsTrueForEmptyGroup() {
        let group = TabGroup(id: UUID(), name: "空分组", tabIDs: [])
        XCTAssertTrue(group.isEmpty)
    }

    func testIsEmptyReturnsFalseForNonEmptyGroup() {
        let group = TabGroup(id: UUID(), name: "有页签", tabIDs: [UUID()])
        XCTAssertFalse(group.isEmpty)
    }

    // MARK: - 意外操作

    func testCreateGroupWithEmptyName() {
        // 空名称应被允许，由 UI 层处理显示
        let group = TabGroup(id: UUID(), name: "", tabIDs: [])
        XCTAssertEqual(group.name, "")
    }

    func testCreateGroupWithDuplicateTabIDs() {
        // 允许重复 ID，由业务层去重
        let tabID = UUID()
        let group = TabGroup(id: UUID(), name: "重复", tabIDs: [tabID, tabID])
        XCTAssertEqual(group.tabIDs.count, 2)
    }

    // MARK: - 边界条件

    func testCreateGroupWithManyTabIDs() {
        let tabIDs = (0..<1000).map { _ in UUID() }
        let group = TabGroup(id: UUID(), name: "大量页签", tabIDs: tabIDs)
        XCTAssertEqual(group.tabIDs.count, 1000)
    }

    func testManyGroupsCreationPerformance() {
        measure {
            for i in 0..<10000 {
                _ = TabGroup(id: UUID(), name: "分组\(i)", tabIDs: [])
            }
        }
    }
}

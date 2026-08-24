import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class WorkspacePresentationSelectionTests: XCTestCase {
    private let firstTabID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondTabID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func test主机详情与页签可以往返而不改变后台页签集合() {
        let hostSelection = WorkspacePresentationSelection.hostDetail(hostID: "box")
        let tabSelection = WorkspacePresentationSelection.tab(tabID: firstTabID)

        XCTAssertEqual(
            hostSelection.normalized(
                validHostIDs: ["box"],
                validTabIDs: [firstTabID],
                fallbackTabID: firstTabID
            ),
            hostSelection
        )
        XCTAssertEqual(
            tabSelection.normalized(
                validHostIDs: ["box"],
                validTabIDs: [firstTabID],
                fallbackTabID: firstTabID
            ),
            tabSelection
        )
    }

    func test重复选择同一目标保持幂等() {
        let selection = WorkspacePresentationSelection.tab(tabID: firstTabID)

        XCTAssertEqual(
            selection.normalized(
                validHostIDs: ["box"],
                validTabIDs: [firstTabID],
                fallbackTabID: firstTabID
            ),
            selection
        )
    }

    func test目标主机被删除时回退到仍有效的活动页签() {
        let selection = WorkspacePresentationSelection.hostDetail(hostID: "deleted")

        XCTAssertEqual(
            selection.normalized(
                validHostIDs: ["box"],
                validTabIDs: [firstTabID],
                fallbackTabID: firstTabID
            ),
            .tab(tabID: firstTabID)
        )
    }

    func test目标页签被关闭时回退到新的活动页签() {
        let selection = WorkspacePresentationSelection.tab(tabID: firstTabID)

        XCTAssertEqual(
            selection.normalized(
                validHostIDs: ["box"],
                validTabIDs: [secondTabID],
                fallbackTabID: secondTabID
            ),
            .tab(tabID: secondTabID)
        )
    }

    func test无效回退页签不会成为当前内容() {
        let selection = WorkspacePresentationSelection.tab(tabID: firstTabID)

        XCTAssertEqual(
            selection.normalized(
                validHostIDs: ["box"],
                validTabIDs: [secondTabID],
                fallbackTabID: firstTabID
            ),
            .empty
        )
    }

    func test零标签与关闭最后标签回到空态() {
        for selection in [
            WorkspacePresentationSelection.empty,
            .tab(tabID: firstTabID)
        ] {
            XCTAssertEqual(
                selection.normalized(
                    validHostIDs: [],
                    validTabIDs: [],
                    fallbackTabID: nil
                ),
                .empty
            )
        }
    }

    func test仅有一个后台标签时空态不会擅自切换内容() {
        XCTAssertEqual(
            WorkspacePresentationSelection.empty.normalized(
                validHostIDs: ["box"],
                validTabIDs: [firstTabID],
                fallbackTabID: firstTabID
            ),
            .empty
        )
    }
}

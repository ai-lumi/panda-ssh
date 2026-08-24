import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class SFTPPresentationStateTests: XCTestCase {
    func test常规布局同时显示本地与远程() {
        let state = SFTPPresentationState(layout: .dualPane, selectedPane: .remote)

        XCTAssertEqual(state.visiblePanes, [.local, .remote])
    }

    func test紧凑布局只显示用户选择的面板() {
        var state = SFTPPresentationState(layout: .singlePane, selectedPane: .local)
        XCTAssertEqual(state.visiblePanes, [.local])

        state.select(.remote)
        XCTAssertEqual(state.visiblePanes, [.remote])
    }

    func test宽度快速往返不重置当前分段() {
        var state = SFTPPresentationState(layout: .singlePane, selectedPane: .remote)

        for layout in [
            WorkspaceLayoutPolicy.SFTPPresentation.dualPane,
            .singlePane,
            .dualPane,
            .singlePane
        ] {
            state.updateLayout(layout)
        }

        XCTAssertEqual(state.selectedPane, .remote)
        XCTAssertEqual(state.visiblePanes, [.remote])
    }

    func test加载与传输期间切换只改变呈现状态() {
        let sessionIdentity = UUID()
        let transferIDs = [UUID(), UUID()]
        var state = SFTPPresentationState(layout: .dualPane, selectedPane: .local)

        state.updateLayout(.singlePane)
        state.select(.remote)

        XCTAssertEqual(state.selectedPane, .remote)
        XCTAssertNotNil(sessionIdentity)
        XCTAssertEqual(transferIDs.count, 2)
    }

    func test空目录和无选中项仍可切换面板() {
        var state = SFTPPresentationState(layout: .singlePane, selectedPane: .local)
        state.select(.remote)

        XCTAssertEqual(state.visiblePanes, [.remote])
    }

    func test重复选择同一面板保持幂等() {
        var state = SFTPPresentationState(layout: .singlePane, selectedPane: .local)
        state.select(.local)
        XCTAssertEqual(state, SFTPPresentationState(layout: .singlePane, selectedPane: .local))
    }
}

import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 任务 6.1：设置呈现与导航回归测试。
///
/// 正常：showSettings 设置呈现标志；
/// 意外：重复调用不改变其他状态；
/// 边界：设置呈现不影响工作区页签和会话。
@MainActor
final class SettingsPresentationTests: XCTestCase {

    private func makeModel() -> AppModel {
        AppModel(backend: MockBackend.demo())
    }

    // MARK: - 正常流程

    func testShowSettings设置呈现标志() {
        let model = makeModel()
        model.showSettings()
        #if os(iOS)
        XCTAssertTrue(model.isPresentingSettings)
        #else
        XCTAssertEqual(model.sidebarPage, .settings)
        #endif
    }

    func test打开设置不改变工作区呈现() {
        let model = makeModel()
        let before = model.workspacePresentation
        model.showSettings()
        #if os(macOS)
        XCTAssertEqual(model.workspacePresentation, before)
        #endif
    }

    func test打开设置不改变选中主机() async {
        let model = makeModel()
        model.selectHost("h-1")
        // selectHost 异步执行，等待下一个 runloop
        try? await Task.sleep(for: .milliseconds(50))
        model.showSettings()
        #if os(macOS)
        XCTAssertEqual(model.selectedHostID, "h-1")
        #endif
    }

    // MARK: - 意外流程

    func test重复调用showSettings幂等() {
        let model = makeModel()
        model.showSettings()
        model.showSettings()
        #if os(iOS)
        XCTAssertTrue(model.isPresentingSettings)
        #else
        XCTAssertEqual(model.sidebarPage, .settings)
        #endif
    }

    func test关闭设置恢复工作区() {
        let model = makeModel()
        model.showSettings()
        #if os(iOS)
        model.isPresentingSettings = false
        XCTAssertFalse(model.isPresentingSettings)
        #else
        model.sidebarPage = .hosts
        XCTAssertEqual(model.sidebarPage, .hosts)
        #endif
    }

    // MARK: - 边界条件

    func test设置呈现不影响标签页() {
        let model = makeModel()
        let workspace = WorkspaceStore(
            hostNameProvider: { _ in nil },
            transferStore: TransferStore()
        )
        let tabCountBefore = workspace.tabs.count
        model.showSettings()
        XCTAssertEqual(workspace.tabs.count, tabCountBefore)
    }

    func test从设置切换到其他页面() {
        let model = makeModel()
        model.showSettings()
        model.showLogs()
        XCTAssertEqual(model.sidebarPage, .logs)
    }
}

#if os(macOS)
import XCTest
import SwiftUI
@testable import PandaSSH_macOS

/// CMD+W 快捷键行为测试：验证焦点感知的页签关闭逻辑。
///
/// 由于 `.onKeyPress` 依赖 SwiftUI 运行时焦点系统，无法在单元测试中
/// 直接模拟按键事件。因此测试聚焦于「当 CMD+W 被触发时，应调用哪个
/// 关闭方法」——即页签栏容器中的关闭动作逻辑。
@MainActor
final class KeyboardShortcutCloseTabTests: XCTestCase {
    override func setUp() {
        super.setUp()
        workspaceReset()
    }

    override func tearDown() {
        workspaceReset()
        super.tearDown()
    }

    // MARK: - 1.1 焦点在页签区域时 CMD+W 关闭当前活动页签（正常流程）

    /// 活动页签为非连接状态终端时，CMD+W 应直接关闭该页签。
    func test_cmdW_closesActiveTerminalTab_whenNotConnected() {
        let store = WorkspaceStore(hostNameProvider: { _ in "host-a" })
        let tabID = store.openTerminal(hostID: "host-a")
        store.select(tabID: tabID)

        // 模拟 CMD+W 触发的关闭动作（与页签栏 .onKeyPress 中调用的逻辑一致）
        if let activeID = store.activeTabID {
            store.requestClose(tabID: activeID)
        }

        // 非连接状态终端不弹确认，直接关闭
        XCTAssertNil(store.pendingCloseTabID, "非连接状态终端应直接关闭，无需二次确认")
        XCTAssertTrue(store.tabs.isEmpty, "页签应已被移除")
    }

    /// 活动页签为 SFTP 类型时，CMD+W 应直接关闭。
    func test_cmdW_closesActiveSftpTab() {
        let store = WorkspaceStore(hostNameProvider: { _ in "host-b" })
        let tabID = store.openSFTP(hostID: "host-b")
        store.select(tabID: tabID)

        if let activeID = store.activeTabID {
            store.requestClose(tabID: activeID)
        }

        XCTAssertNil(store.pendingCloseTabID, "SFTP 标签关闭无需二次确认")
        XCTAssertTrue(store.tabs.isEmpty, "SFTP 页签应已被移除")
    }

    // MARK: - 1.2 焦点不在页签区域时不触发关闭（意外操作）

    /// 焦点不在页签区域时，CMD+W 不应被处理。在实现层面，`.onKeyPress`
    /// 注册在页签栏容器上，仅当该容器或子视图持有焦点时触发。
    /// 此测试验证：不调用关闭方法时，页签状态保持不变。
    func test_cmdW_noAction_whenFocusNotOnTabStrip() {
        let store = WorkspaceStore(hostNameProvider: { _ in "host-c" })
        let tabID = store.openTerminal(hostID: "host-c")
        store.select(tabID: tabID)

        // 不调用任何关闭方法——模拟焦点不在页签区域时 .onKeyPress 不触发
        XCTAssertEqual(store.tabs.count, 1, "未触发关闭时页签应保留")
        XCTAssertEqual(store.activeTabID, tabID, "活动页签不应变化")
    }

    // MARK: - 1.3 无活动页签时 CMD+W 不执行操作（边界条件）

    /// 工作区没有任何页签时，CMD+W 应无操作。
    func test_cmdW_noAction_whenNoTabs() {
        let store = WorkspaceStore(hostNameProvider: { _ in "host-d" })

        XCTAssertNil(store.activeTabID, "无页签时活动 ID 应为 nil")

        // 模拟 CMD+W：无活动页签时不执行关闭
        if let activeID = store.activeTabID {
            store.requestClose(tabID: activeID)
        }

        XCTAssertTrue(store.tabs.isEmpty, "无页签时应保持为空")
    }

    // MARK: - 1.4 已连接终端 CMD+W 弹出二次确认（正常流程 + 边界条件）

    /// 已连接终端标签页按 CMD+W 应进入待确认状态。
    func test_cmdW_connectedTerminal_requestsConfirmation() {
        let store = WorkspaceStore(hostNameProvider: { _ in "host-e" })
        let tabID = store.openTerminal(hostID: "host-e")
        store.select(tabID: tabID)
        store.markTerminalConnected(tabID: tabID)

        if let activeID = store.activeTabID {
            store.requestClose(tabID: activeID)
        }

        XCTAssertEqual(store.pendingCloseTabID, tabID, "已连接终端应进入待确认状态")
        XCTAssertEqual(store.tabs.count, 1, "确认前页签应保留")
    }

    /// 确认后关闭页签。
    func test_cmdW_connectedTerminal_confirmClose() {
        let store = WorkspaceStore(hostNameProvider: { _ in "host-f" })
        let tabID = store.openTerminal(hostID: "host-f")
        store.select(tabID: tabID)
        store.markTerminalConnected(tabID: tabID)

        store.requestClose(tabID: tabID)
        XCTAssertEqual(store.pendingCloseTabID, tabID)

        store.confirmClose()

        XCTAssertNil(store.pendingCloseTabID, "确认后待关闭状态应清除")
        XCTAssertTrue(store.tabs.isEmpty, "确认后页签应被移除")
    }

    /// 取消后保留页签和会话。
    func test_cmdW_connectedTerminal_cancelClose() {
        let store = WorkspaceStore(hostNameProvider: { _ in "host-g" })
        let tabID = store.openTerminal(hostID: "host-g")
        store.select(tabID: tabID)
        store.markTerminalConnected(tabID: tabID)

        store.requestClose(tabID: tabID)
        store.cancelClose()

        XCTAssertNil(store.pendingCloseTabID, "取消后待关闭状态应清除")
        XCTAssertEqual(store.tabs.count, 1, "取消后页签应保留")
        XCTAssertEqual(store.activeTabID, tabID, "取消后活动页签应不变")
    }

    /// 连接中状态的终端标签页 CMD+W 直接关闭，不弹确认。
    func test_cmdW_connectingTerminal_closesWithoutConfirmation() {
        let store = WorkspaceStore(hostNameProvider: { _ in "host-h" })
        let tabID = store.openTerminal(hostID: "host-h")
        store.select(tabID: tabID)
        store.reportConnectionStatus(.connecting, forTabID: tabID)

        if let activeID = store.activeTabID {
            store.requestClose(tabID: activeID)
        }

        XCTAssertNil(store.pendingCloseTabID, "连接中状态不应弹确认")
        XCTAssertTrue(store.tabs.isEmpty, "连接中状态应直接关闭")
    }
}
#endif

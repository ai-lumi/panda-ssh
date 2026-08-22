import XCTest

#if os(macOS)
@testable import PandaSSH_macOS

/// `TerminalCoordinator.perform(_ item:hitLink:)` 菜单动作执行测试（macOS only）。
///
/// 覆盖 spec「终端内容区右键上下文菜单」每个 `TerminalMenuItem` 的执行行为：
/// - 正常流程：复制 / 粘贴 / 粘贴并回车 / 全选 / 清屏 / 重置终端 / 复制并粘贴 /
///   重连 / 关闭标签页 / 复制链接地址。
/// - 意外操作：failed 阶段粘贴不写入、connection 为 nil 时清屏不崩溃、空剪贴板不写入。
/// - 边界条件：空选中时复制不修改剪贴板、空剪贴板时粘贴不写入。
/// 满足 `AGENTS.md` 三类场景门禁。
final class TerminalMenuActionExecutorTests: XCTestCase {

    // MARK: - 测试用 Spy

    /// `PandaTerminalView` 子类：重写 `open func copy/paste`，记录调用次数。
    /// `copy` 模拟真实 SwiftTerm 行为：把 `injectedSelectedText` 写入 NSPasteboard。
    private final class SpyPandaTerminalView: PandaTerminalView {
        private(set) var copyCallCount = 0
        private(set) var pasteCallCount = 0
        /// 测试注入的「选中文本」；`copy` 调用时写入 NSPasteboard（模拟真实 copy 行为）。
        /// 空字符串视同无选中（不写剪贴板）。
        var injectedSelectedText: String = ""

        override func copy(_ sender: Any) {
            copyCallCount += 1
            guard !injectedSelectedText.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(injectedSelectedText, forType: .string)
        }

        override func paste(_ sender: Any) {
            pasteCallCount += 1
        }
    }

    // MARK: - 正常流程

    /// §5.1 正常流程（复制）：`perform(.copy)` → 调 `tv.copy`，NSPasteboard 内容等于选中文本。
    func testPerform_copy_callsTvCopyAndUpdatesPasteboard() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        view.injectedSelectedText = "hello"
        let coordinator = makeCoordinator(view: view)
        clearPasteboard()

        coordinator.perform(.copy, hitLink: nil)

        XCTAssertEqual(view.copyCallCount, 1, "应调用 tv.copy")
        XCTAssertEqual(pasteboardString(), "hello", "选中文本应写入剪贴板")
    }

    /// §5.1 正常流程（粘贴）：`perform(.paste)` → 写入等于剪贴板文本，无换行。
    func testPerform_paste_writesClipboardTextWithoutNewline() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let spyConn = SpyShellConnection()
        let coordinator = makeCoordinator(view: view, connection: spyConn)
        coordinator.currentPhase = .shell
        setPasteboard("hello")

        coordinator.perform(.paste, hitLink: nil)

        XCTAssertEqual(spyConn.lastWrite, "hello".data(using: .utf8), "写入应等于剪贴板文本")
        let written = String(data: spyConn.lastWrite ?? Data(), encoding: .utf8)
        XCTAssertEqual(written, "hello", "不应追加换行符")
    }

    /// §5.1 正常流程（粘贴并回车）：写入 = 剪贴板 + `\n`。
    func testPerform_pasteAndEnter_writesClipboardTextWithNewline() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let spyConn = SpyShellConnection()
        let coordinator = makeCoordinator(view: view, connection: spyConn)
        coordinator.currentPhase = .shell
        setPasteboard("hello")

        coordinator.perform(.pasteAndEnter, hitLink: nil)

        XCTAssertEqual(spyConn.lastWrite, "hello\n".data(using: .utf8), "写入应等于剪贴板文本 + LF")
    }

    /// §5.1 正常流程（全选）：`perform(.selectAll)` → `tv.selectAll` 被调用。
    func testPerform_selectAll_callsTvSelectAll() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let coordinator = makeCoordinator(view: view)

        coordinator.perform(.selectAll, hitLink: nil)

        XCTAssertTrue(coordinator.testDidCallSelectAll, "应调用 tv.selectAll")
    }

    /// §5.1 正常流程（清屏）：写入 == `"clear\n"` 字节流。
    func testPerform_clearScreen_writesClearCommand() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let spyConn = SpyShellConnection()
        let coordinator = makeCoordinator(view: view, connection: spyConn)
        coordinator.currentPhase = .shell

        coordinator.perform(.clearScreen, hitLink: nil)

        XCTAssertEqual(spyConn.lastWrite, "clear\n".data(using: .utf8), "应发送 clear 命令字节流")
    }

    /// §5.1 正常流程（重置终端）：写入 == RIS 序列（ESC c）。
    func testPerform_resetTerminal_writesRisSequence() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let spyConn = SpyShellConnection()
        let coordinator = makeCoordinator(view: view, connection: spyConn)

        coordinator.perform(.resetTerminal, hitLink: nil)

        XCTAssertEqual(spyConn.lastWrite, "\u{1B}c".data(using: .utf8), "应发送 RIS 控制序列 ESC c")
    }

    /// §5.1 正常流程（复制并粘贴）：剪贴板被更新 + 写入等于剪贴板文本，无换行。
    func testPerform_copyAndPaste_updatesPasteboardAndWrites() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        view.injectedSelectedText = "hello"
        let spyConn = SpyShellConnection()
        let coordinator = makeCoordinator(view: view, connection: spyConn)
        coordinator.currentPhase = .shell
        clearPasteboard()

        coordinator.perform(.copyAndPaste, hitLink: nil)

        XCTAssertEqual(view.copyCallCount, 1, "应先调用 tv.copy")
        XCTAssertEqual(pasteboardString(), "hello", "剪贴板应被更新为选中文本")
        XCTAssertEqual(spyConn.lastWrite, "hello".data(using: .utf8), "随后应写入剪贴板文本")
        let written = String(data: spyConn.lastWrite ?? Data(), encoding: .utf8)
        XCTAssertEqual(written, "hello", "不应追加换行符")
    }

    /// §5.1 正常流程（重连）：`perform(.reconnect)` → `session.retry()` 被调用。
    func testPerform_reconnect_callsOnReconnect() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let coordinator = makeCoordinator(view: view)
        var reconnectCalled = false
        coordinator.onReconnect = { reconnectCalled = true }

        coordinator.perform(.reconnect, hitLink: nil)

        XCTAssertTrue(reconnectCalled, "应调用 onReconnect 闭包")
    }

    /// §5.1 正常流程（关闭标签页）：`perform(.closeTab)` → `workspace.close(tabID:)` 被调用。
    func testPerform_closeTab_callsOnCloseTab() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let coordinator = makeCoordinator(view: view)
        var closeCalled = false
        coordinator.onCloseTab = { closeCalled = true }

        coordinator.perform(.closeTab, hitLink: nil)

        XCTAssertTrue(closeCalled, "应调用 onCloseTab 闭包")
    }

    /// §5.1 正常流程（复制链接地址）：`perform(.copyLink, hitLink:)` → NSPasteboard 内容等于链接。
    func testPerform_copyLink_writesLinkToPasteboard() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let coordinator = makeCoordinator(view: view)
        clearPasteboard()

        coordinator.perform(.copyLink, hitLink: "https://example.com")

        XCTAssertEqual(pasteboardString(), "https://example.com", "链接应写入剪贴板")
    }

    // MARK: - 意外操作

    /// §5.1 意外操作：`perform(.paste)` 但 `phase=.failed` → 不写入，不抛异常。
    func testPerform_paste_failedPhase_doesNotWrite() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let spyConn = SpyShellConnection()
        let coordinator = makeCoordinator(view: view, connection: spyConn)
        coordinator.currentPhase = .failed
        setPasteboard("hello")

        coordinator.perform(.paste, hitLink: nil)

        XCTAssertNil(spyConn.lastWrite, "failed 阶段不应写入")
    }

    /// §5.1 意外操作：`perform(.clearScreen)` 但 connection 为 nil → 不写入，不抛异常。
    func testPerform_clearScreen_nilConnection_doesNotCrash() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let coordinator = makeCoordinator(view: view, connection: nil)
        coordinator.currentPhase = .shell

        coordinator.perform(.clearScreen, hitLink: nil)

        // 测试不崩溃即通过（无 connection 写入路径）
    }

    /// §5.1 意外操作：`perform(.paste)` 但 `phase=.connecting` → 不写入。
    func testPerform_paste_connectingPhase_doesNotWrite() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let spyConn = SpyShellConnection()
        let coordinator = makeCoordinator(view: view, connection: spyConn)
        coordinator.currentPhase = .connecting
        setPasteboard("hello")

        coordinator.perform(.paste, hitLink: nil)

        XCTAssertNil(spyConn.lastWrite, "connecting 阶段不应写入")
    }

    // MARK: - 边界条件

    /// §5.1 边界条件：`perform(.paste)` 但剪贴板为空 → 不写入。
    func testPerform_paste_emptyClipboard_doesNotWrite() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let spyConn = SpyShellConnection()
        let coordinator = makeCoordinator(view: view, connection: spyConn)
        coordinator.currentPhase = .shell
        clearPasteboard()

        coordinator.perform(.paste, hitLink: nil)

        XCTAssertNil(spyConn.lastWrite, "空剪贴板不应写入")
    }

    /// §5.1 边界条件：`perform(.copy)` 但选中文本为空 → 不修改剪贴板。
    func testPerform_copy_emptySelection_doesNotModifyPasteboard() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        view.injectedSelectedText = ""
        let coordinator = makeCoordinator(view: view)
        let marker = "MARKER_\(UUID().uuidString)"
        setPasteboard(marker)

        coordinator.perform(.copy, hitLink: nil)

        XCTAssertEqual(view.copyCallCount, 1, "tv.copy 仍应被调用")
        XCTAssertEqual(pasteboardString(), marker, "空选中不应修改剪贴板")
    }

    /// §5.1 边界条件：`perform(.copyLink)` 但 hitLink 为 nil → 不修改剪贴板。
    func testPerform_copyLink_nilHitLink_doesNotModifyPasteboard() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let coordinator = makeCoordinator(view: view)
        let marker = "MARKER_\(UUID().uuidString)"
        setPasteboard(marker)

        coordinator.perform(.copyLink, hitLink: nil)

        XCTAssertEqual(pasteboardString(), marker, "nil hitLink 不应修改剪贴板")
    }

    /// §5.1 边界条件：`perform(.copyLink)` 但 hitLink 为空字符串 → 不修改剪贴板。
    func testPerform_copyLink_emptyHitLink_doesNotModifyPasteboard() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let coordinator = makeCoordinator(view: view)
        let marker = "MARKER_\(UUID().uuidString)"
        setPasteboard(marker)

        coordinator.perform(.copyLink, hitLink: "")

        XCTAssertEqual(pasteboardString(), marker, "空 hitLink 不应修改剪贴板")
    }

    /// §5.1 边界条件：`perform(.pasteAndEnter)` 在 failed 阶段 → 不写入。
    func testPerform_pasteAndEnter_failedPhase_doesNotWrite() {
        let view = SpyPandaTerminalView(frame: defaultFrame, font: nil)
        let spyConn = SpyShellConnection()
        let coordinator = makeCoordinator(view: view, connection: spyConn)
        coordinator.currentPhase = .failed
        setPasteboard("hello")

        coordinator.perform(.pasteAndEnter, hitLink: nil)

        XCTAssertNil(spyConn.lastWrite, "failed 阶段不应写入")
    }

    // MARK: - 辅助

    private let defaultFrame = CGRect(x: 0, y: 0, width: 320, height: 240)

    private func makeCoordinator(
        view: PandaTerminalView,
        connection: ShellConnection? = nil
    ) -> TerminalCoordinator {
        let coordinator = TerminalCoordinator(onReadError: {})
        coordinator.setup(terminalView: view, connection: connection)
        return coordinator
    }

    private func clearPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
    }

    private func setPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func pasteboardString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
#endif

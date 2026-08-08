import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 假 shell 会话测试:覆盖正常流程(连接/内置命令)、意外操作(未知命令、
/// 空命令、越界翻历史)、边界条件(clear/exit、离线主机)三类用例。
@MainActor
final class TerminalSessionTests: XCTestCase {

    private func makeHost(demo: DemoFlag? = nil) -> HostEntry {
        HostEntry(
            id: "h1", name: "web-prod", address: "203.0.113.10", port: 22,
            username: "luowenqiang", groupID: nil,
            fingerprint: "SHA256:test", demo: demo
        )
    }

    /// 进入 shell 阶段的会话。
    private func makeShell(demo: DemoFlag? = nil) -> TerminalSessionStore {
        let store = TerminalSessionStore(host: makeHost(demo: demo))
        store.finishConnecting()
        return store
    }

    // MARK: - 连接阶段

    func testInitialPhaseIsConnectingWithHint() {
        let store = TerminalSessionStore(host: makeHost())

        XCTAssertEqual(store.phase, .connecting)
        XCTAssertEqual(store.lines.count, 1)
        XCTAssertTrue(store.lines[0].text.contains("正在连接 203.0.113.10:22"))
    }

    func testFinishConnectingEntersShellWithWelcome() {
        let store = makeShell()

        XCTAssertEqual(store.phase, .shell)
        XCTAssertEqual(store.lines.count, 3)
        XCTAssertTrue(store.lines[2].text.contains("Welcome to web-prod"))
    }

    func testOfflineHostFailsAfterConnecting() {
        let store = TerminalSessionStore(host: makeHost(demo: .offline))

        store.finishConnecting()

        XCTAssertEqual(store.phase, .failed)
    }

    func testRetryAfterFailureReturnsToConnecting() {
        let store = TerminalSessionStore(host: makeHost(demo: .offline))
        store.finishConnecting()
        XCTAssertEqual(store.phase, .failed)

        store.retry()

        XCTAssertEqual(store.phase, .connecting)
        XCTAssertTrue(store.lines[0].text.contains("正在连接"))
    }

    // MARK: - Prompt

    func testPromptUsesTildeForHome() {
        let store = makeShell()
        XCTAssertEqual(store.prompt, "luowenqiang@web-prod:~$")
    }

    // MARK: - 内置命令(正常流程)

    func testHelpListsBuiltinCommands() {
        let store = makeShell()
        store.run("help")

        let output = store.lines.last?.text ?? ""
        for name in ["help", "ls", "pwd", "whoami", "uname", "date", "echo", "clear", "exit"] {
            XCTAssertTrue(output.contains(name), "help 输出应包含 \(name)")
        }
    }

    func testLsOutputsFakeListing() {
        let store = makeShell()
        store.run("ls")

        let output = store.lines.last?.text ?? ""
        XCTAssertTrue(output.contains("app"))
        XCTAssertTrue(output.contains("backup-2026-08-01.sql.gz"))
    }

    func testPwdPrintsCwd() {
        let store = makeShell()
        store.run("pwd")
        XCTAssertEqual(store.lines.last?.text, "/home/luowenqiang")
    }

    func testWhoamiPrintsUsername() {
        let store = makeShell()
        store.run("whoami")
        XCTAssertEqual(store.lines.last?.text, "luowenqiang")
    }

    func testUnamePrintsKernelLine() {
        let store = makeShell()
        store.run("uname -a")
        XCTAssertTrue(store.lines.last?.text.contains("Linux web-prod") == true)
    }

    func testDatePrintsSomething() {
        let store = makeShell()
        store.run("date")

        let output = store.lines.last?.text ?? ""
        XCTAssertFalse(output.isEmpty)
        XCTAssertFalse(output.contains("command not found"))
    }

    func testEchoPrintsArgumentStrippingQuotes() {
        let store = makeShell()
        store.run("echo hello world")
        XCTAssertEqual(store.lines.last?.text, "hello world")

        store.run("echo 'quoted'")
        XCTAssertEqual(store.lines.last?.text, "quoted")
    }

    // MARK: - 内置命令(边界与意外)

    func testUnknownCommandReportsNotFound() {
        let store = makeShell()
        store.run("bogus arg")

        XCTAssertTrue(store.lines.last?.text.contains("zsh: command not found: bogus") == true)
    }

    func testEmptyCommandOnlyEchoesPrompt() {
        let store = makeShell()
        let before = store.lines.count

        let result = store.run("   ")

        XCTAssertEqual(result, .none)
        XCTAssertEqual(store.lines.count, before + 1) // 只有一行 prompt,无输出
        XCTAssertTrue(store.history.isEmpty) // 空命令不进历史
    }

    func testClearEmptiesLines() {
        let store = makeShell()
        store.run("ls")

        let result = store.run("clear")

        XCTAssertEqual(result, .none)
        XCTAssertTrue(store.lines.isEmpty)
    }

    func testExitRequestsTabClose() {
        let store = makeShell()
        XCTAssertEqual(store.run("exit"), .closeTab)
    }

    func testRunAppendsPromptEchoLine() {
        let store = makeShell()
        store.run("whoami")

        // 倒数第二行是 prompt + 命令回显
        let echo = store.lines[store.lines.count - 2].text
        XCTAssertTrue(echo.contains("luowenqiang@web-prod:~$"))
        XCTAssertTrue(echo.contains("whoami"))
    }

    // MARK: - 命令历史

    func testHistoryUpDownCycles() {
        let store = makeShell()
        store.run("ls")
        store.run("pwd")

        XCTAssertEqual(store.historyUp(), "pwd")
        XCTAssertEqual(store.historyUp(), "ls")
        XCTAssertEqual(store.historyUp(), "ls") // 到顶后停留
        XCTAssertEqual(store.historyDown(), "pwd")
        XCTAssertEqual(store.historyDown(), "") // 回到底部清空输入
    }

    func testHistoryOnEmptyHistoryStaysEmpty() {
        let store = makeShell()
        XCTAssertEqual(store.historyUp(), "")
        XCTAssertEqual(store.historyDown(), "")
    }

    func testNewCommandResetsHistoryPosition() {
        let store = makeShell()
        store.run("ls")
        _ = store.historyUp()

        store.run("pwd")

        XCTAssertEqual(store.historyUp(), "pwd")
    }
}

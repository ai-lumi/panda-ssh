import XCTest

#if os(macOS)
@testable import PandaSSH_macOS

/// `TerminalCoordinator` PRIMARY selection 缓冲与中键粘贴测试（macOS only）。
///
/// 覆盖 spec「终端中键粘贴选中文本」与「终端选中即缓存 PRIMARY selection」两个 Requirement
/// 在 macOS 端的实现行为。满足 `AGENTS.md` 三类场景门禁。
final class TerminalCoordinatorPrimarySelectionTests: XCTestCase {

    // MARK: - 正常流程

    /// §2.1 正常流程 1：mouseUp 后 primarySelection 被更新；
    /// `pastePrimarySelection()` 写入该文本的 UTF-8 字节，不追加换行。
    func testPastePrimarySelection_writesSelectedTextWithoutNewline() {
        let coordinator = TerminalCoordinator(onReadError: {})
        let spyConn = SpyShellConnection()
        coordinator.update(connection: spyConn)
        coordinator.currentPhase = .shell

        // 模拟 mouseUp 后 primarySelection 被更新为 "hello"
        coordinator.updatePrimarySelection(from: "hello")

        coordinator.pastePrimarySelection()

        XCTAssertEqual(spyConn.lastWrite, "hello".data(using: .utf8))
        XCTAssertEqual(spyConn.writeCalls.count, 1, "应只写入一次")
        // 验证不追加换行符
        let written = String(data: spyConn.lastWrite ?? Data(), encoding: .utf8)
        XCTAssertEqual(written, "hello", "写入内容应为纯选中文本，无换行")
    }

    // MARK: - 意外操作

    /// §2.1 意外操作 1：`phase=.connecting` 下调用 `pastePrimarySelection()` → 不写入。
    func testPastePrimarySelection_connectingPhase_doesNotWrite() {
        let coordinator = TerminalCoordinator(onReadError: {})
        let spyConn = SpyShellConnection()
        coordinator.update(connection: spyConn)
        coordinator.currentPhase = .connecting
        coordinator.updatePrimarySelection(from: "hello")

        coordinator.pastePrimarySelection()

        XCTAssertNil(spyConn.lastWrite, ".connecting 阶段不应写入")
    }

    /// §2.1 意外操作 2：`phase=.failed` 下调用 `pastePrimarySelection()` → 不写入。
    func testPastePrimarySelection_failedPhase_doesNotWrite() {
        let coordinator = TerminalCoordinator(onReadError: {})
        let spyConn = SpyShellConnection()
        coordinator.update(connection: spyConn)
        coordinator.currentPhase = .failed
        coordinator.updatePrimarySelection(from: "hello")

        coordinator.pastePrimarySelection()

        XCTAssertNil(spyConn.lastWrite, ".failed 阶段不应写入")
    }

    // MARK: - 边界条件

    /// §2.1 边界 1：`primarySelection=""` 时调用 `pastePrimarySelection()` → 不写入。
    func testPastePrimarySelection_emptyBuffer_doesNotWrite() {
        let coordinator = TerminalCoordinator(onReadError: {})
        let spyConn = SpyShellConnection()
        coordinator.update(connection: spyConn)
        coordinator.currentPhase = .shell
        // primarySelection 初始为 ""

        coordinator.pastePrimarySelection()

        XCTAssertNil(spyConn.lastWrite, "空缓冲不应写入")
    }

    /// §2.1 边界 2：选中空字符串触发 `updatePrimarySelection()` → 不覆盖既有非空缓冲。
    func testUpdatePrimarySelection_emptyString_doesNotOverwriteExisting() {
        let coordinator = TerminalCoordinator(onReadError: {})
        coordinator.updatePrimarySelection(from: "existing")
        XCTAssertEqual(coordinator.primarySelectionForTesting, "existing")

        // 模拟空字符串选中（用户拖拽选中但 selectedText 为空）
        coordinator.updatePrimarySelection(from: "")

        XCTAssertEqual(coordinator.primarySelectionForTesting, "existing", "空字符串不应覆盖既有非空缓冲")
    }

    /// §2.1 边界 3：`updatePrimarySelection(from: nil)` 也不覆盖既有缓冲。
    func testUpdatePrimarySelection_nil_doesNotOverwriteExisting() {
        let coordinator = TerminalCoordinator(onReadError: {})
        coordinator.updatePrimarySelection(from: "existing")

        coordinator.updatePrimarySelection(from: nil as String?)

        XCTAssertEqual(coordinator.primarySelectionForTesting, "existing", "nil 不应覆盖既有缓冲")
    }

    // MARK: - 不污染剪贴板

    /// §2.1 不污染剪贴板：`updatePrimarySelection()` 调用前后
    /// `NSPasteboard.general.string(forType: .string)` 内容不变。
    func testUpdatePrimarySelection_doesNotModifyPasteboard() {
        let coordinator = TerminalCoordinator(onReadError: {})
        // 设置一个已知剪贴板内容作为标记
        let marker = "PASTEBOARD_MARKER_\(UUID().uuidString)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)

        coordinator.updatePrimarySelection(from: "hello")

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            marker,
            "PRIMARY 缓冲更新不应修改系统剪贴板"
        )
    }

    /// §2.1 不污染剪贴板（补充）：`pastePrimarySelection()` 调用前后剪贴板不变。
    func testPastePrimarySelection_doesNotModifyPasteboard() {
        let coordinator = TerminalCoordinator(onReadError: {})
        let spyConn = SpyShellConnection()
        coordinator.update(connection: spyConn)
        coordinator.currentPhase = .shell
        coordinator.updatePrimarySelection(from: "hello")
        let marker = "PASTEBOARD_MARKER_\(UUID().uuidString)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)

        coordinator.pastePrimarySelection()

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            marker,
            "中键粘贴不应修改系统剪贴板"
        )
    }
}
#endif

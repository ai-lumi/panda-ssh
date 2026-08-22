import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
import SwiftTerm

/// macOS `PandaTerminalView` 鼠标事件重写测试。
///
/// 覆盖 §3 的 `otherMouseDown`（中键粘贴）、`mouseUp`（PRIMARY 缓冲更新）、
/// `rightMouseDown`（不调 super，为 NSMenu 让路）三个重写。
/// 满足 `AGENTS.md` 三类场景门禁。
final class PandaTerminalViewMouseTests: XCTestCase {

    // MARK: - 测试用 Spy

    /// 测试用 spy：记录 `PandaTerminalViewDelegate` 回调次数，不调用真实 coordinator 行为。
    private final class SpyPandaDelegate: PandaTerminalViewDelegate {
        private(set) var pastePrimarySelectionCount = 0
        private(set) var updatePrimarySelectionCount = 0
        private(set) var lastUpdateTv: TerminalView?

        func pastePrimarySelection() { pastePrimarySelectionCount += 1 }
        func updatePrimarySelection(from tv: TerminalView) {
            updatePrimarySelectionCount += 1
            lastUpdateTv = tv
        }
    }

    // MARK: - 正常流程

    /// §3.1 正常流程 1：中键（buttonNumber=2）按下 → `pastePrimarySelection()` 被调用，
    /// 且不调 super（SwiftTerm 默认不处理 otherMouseDown）。
    func testOtherMouseDown_middleButton_callsPastePrimarySelection() {
        let view = makeView()
        let spy = SpyPandaDelegate()
        view.pandaDelegate = spy

        view.simulateOtherMouseDown(buttonNumber: 2)

        XCTAssertEqual(spy.pastePrimarySelectionCount, 1, "中键应触发 pastePrimarySelection")
        XCTAssertFalse(view.testDidCallSuperOtherMouseDown, "中键不应调 super")
    }

    /// §3.1 正常流程 1 补充：非中键（buttonNumber=1）按下 → 不触发 paste，调 super。
    func testOtherMouseDown_nonMiddleButton_callsSuper() {
        let view = makeView()
        let spy = SpyPandaDelegate()
        view.pandaDelegate = spy

        view.simulateOtherMouseDown(buttonNumber: 1)

        XCTAssertEqual(spy.pastePrimarySelectionCount, 0, "非中键不应触发 paste")
        XCTAssertTrue(view.testDidCallSuperOtherMouseDown, "非中键应调 super")
    }

    /// §3.1 正常流程 2：mouseUp → `updatePrimarySelection(from:)` 被调用，
    /// 且 super 也被调用（保留既有选择行为）。
    func testMouseUp_callsUpdatePrimarySelectionAndSuper() {
        let view = makeView()
        let spy = SpyPandaDelegate()
        view.pandaDelegate = spy

        view.simulateMouseUp()

        XCTAssertEqual(spy.updatePrimarySelectionCount, 1, "mouseUp 应触发 updatePrimarySelection")
        XCTAssertTrue(view.testDidCallSuperMouseUp, "mouseUp 应调 super 保留既有选择行为")
        XCTAssertTrue(spy.lastUpdateTv === view, "updatePrimarySelection 应携带自身 view 引用")
    }

    // MARK: - 意外操作

    /// §3.1 意外操作：`phase=.failed` 时中键按下 → `pastePrimarySelection` 被调但不写入。
    /// 用真实 `TerminalCoordinator` + `SpyShellConnection` 验证 phase 守卫。
    func testOtherMouseDown_failedPhase_doesNotWrite() {
        let view = makeView()
        let coordinator = TerminalCoordinator(onReadError: {})
        let spyConn = SpyShellConnection()
        coordinator.update(connection: spyConn)
        coordinator.currentPhase = .failed
        view.pandaDelegate = coordinator

        view.simulateOtherMouseDown(buttonNumber: 2)

        XCTAssertNil(spyConn.lastWrite, ".failed 阶段中键不应写入 shell 通道")
    }

    /// §3.1 意外操作补充：`.connecting` 阶段中键按下 → 不写入。
    func testOtherMouseDown_connectingPhase_doesNotWrite() {
        let view = makeView()
        let coordinator = TerminalCoordinator(onReadError: {})
        let spyConn = SpyShellConnection()
        coordinator.update(connection: spyConn)
        coordinator.currentPhase = .connecting
        view.pandaDelegate = coordinator

        view.simulateOtherMouseDown(buttonNumber: 2)

        XCTAssertNil(spyConn.lastWrite, ".connecting 阶段中键不应写入")
    }

    // MARK: - 边界条件

    /// §3.1 边界 4：rightMouseDown → 不调 super（避免系统默认菜单），不崩溃。
    func testRightMouseDown_doesNotCallSuper() {
        let view = makeView()

        view.simulateRightMouseDown()

        XCTAssertFalse(view.testDidCallSuperRightMouseDown, "rightMouseDown 不应调 super（为 NSMenu 让路）")
        // 测试不崩溃即通过
    }

    // MARK: - 辅助

    /// 构造 in-process `PandaTerminalView`，frame 320×240 保证可见区域。
    private func makeView() -> PandaTerminalView {
        PandaTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), font: nil)
    }
}
#endif

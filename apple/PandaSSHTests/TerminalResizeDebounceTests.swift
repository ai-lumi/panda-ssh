import XCTest

#if os(macOS)
@testable import PandaSSH_macOS

/// `TerminalCoordinator.sizeChanged` 的 window-change 去抖测试（macOS）。
///
/// 对应 spec「终端窗口调整」：首次尺寸立即上报；连续变化（侧栏显隐动画、
/// 窗口拖拽的逐帧回调）去抖 ~150ms，稳定后仅上报最终值，不逐帧发送。
/// 覆盖三类场景：正常流程 / 意外操作（detach 后不再上报）/ 边界（窗口内多次变化合并）。
@MainActor
final class TerminalResizeDebounceTests: XCTestCase {

    private func makeCoordinator() -> (TerminalCoordinator, SpyShellConnection, PandaTerminalView) {
        let coordinator = TerminalCoordinator(onReadError: {})
        let spy = SpyShellConnection()
        coordinator.update(connection: spy)
        let view = PandaTerminalView(frame: .zero, font: nil)
        return (coordinator, spy, view)
    }

    // MARK: - 正常流程

    /// 首次尺寸变化立即上报（连接建立后服务端需尽快拿到真实尺寸）。
    func testFirstSizeChangeReportsImmediately() {
        let (coordinator, spy, view) = makeCoordinator()
        defer { coordinator.detach() }

        coordinator.sizeChanged(source: view, newCols: 96, newRows: 35)

        XCTAssertEqual(spy.resizeCalls.count, 1, "首次尺寸应立即上报")
        XCTAssertEqual(spy.resizeCalls.first?.cols, 96)
        XCTAssertEqual(spy.resizeCalls.first?.rows, 35)
    }

    /// 连续变化（模拟侧栏动画逐帧回调）去抖合并：稳定后仅追加一次最终值上报。
    func testContinuousChangesAreDebouncedToFinalValue() async throws {
        let (coordinator, spy, view) = makeCoordinator()
        defer { coordinator.detach() }

        coordinator.sizeChanged(source: view, newCols: 96, newRows: 35)
        XCTAssertEqual(spy.resizeCalls.count, 1)

        // 模拟逐帧收窄 96 → 86（10 帧）
        for cols in stride(from: 95, through: 86, by: -1) {
            coordinator.sizeChanged(source: view, newCols: cols, newRows: 35)
        }
        // 去抖窗口内不得追加新上报
        XCTAssertEqual(spy.resizeCalls.count, 1, "去抖窗口内不应发送 window-change")

        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(spy.resizeCalls.count, 2, "稳定后应仅追加一次上报")
        XCTAssertEqual(spy.resizeCalls.last?.cols, 86, "上报的必须是最终尺寸")
        XCTAssertEqual(spy.resizeCalls.last?.rows, 35)
    }

    // MARK: - 意外操作

    /// detach 时取消待执行的去抖任务：视图销毁后不再向已释放的连接上报。
    func testPendingReportCancelledOnDetach() async throws {
        let (coordinator, spy, view) = makeCoordinator()

        coordinator.sizeChanged(source: view, newCols: 96, newRows: 35)
        coordinator.sizeChanged(source: view, newCols: 80, newRows: 30)
        coordinator.detach()

        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(spy.resizeCalls.count, 1, "detach 后去抖任务应被取消，不再上报")
    }

    // MARK: - 边界条件

    /// 去抖窗口结束后的新一轮变化视为新的序列：再次立即性不适用，仍走去抖。
    func testSeparateSequencesEachDebounce() async throws {
        let (coordinator, spy, view) = makeCoordinator()
        defer { coordinator.detach() }

        coordinator.sizeChanged(source: view, newCols: 96, newRows: 35)   // 首次立即
        coordinator.sizeChanged(source: view, newCols: 90, newRows: 35)   // 去抖序列 1
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(spy.resizeCalls.map(\.cols), [96, 90])

        coordinator.sizeChanged(source: view, newCols: 100, newRows: 40)  // 去抖序列 2
        coordinator.sizeChanged(source: view, newCols: 110, newRows: 44)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(spy.resizeCalls.map(\.cols), [96, 90, 110])
        XCTAssertEqual(spy.resizeCalls.map(\.rows), [35, 35, 44])
    }
}
#endif

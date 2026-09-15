import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
import AppKit

/// `TabRightClickMonitor` 右键捕获测试。
///
/// 覆盖：右键触发回调、左键不触发、bounds 外右键不触发。
final class TabRightClickMonitorTests: XCTestCase {

    /// 右键在视图 bounds 内 → 回调被调用。
    func testSimulateRightClick_insideBounds_callsCallback() {
        let view = TabRightClickMonitor.MonitorView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 30)
        )
        var called = false
        view.onRightClick = { _ in called = true }

        view.simulateRightClick(at: NSPoint(x: 50, y: 15))

        XCTAssertTrue(called, "bounds 内右键应触发回调")
    }

    /// 右键在视图 bounds 外 → 回调不被调用。
    func testSimulateRightClick_outsideBounds_doesNotCallCallback() {
        let view = TabRightClickMonitor.MonitorView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 30)
        )
        var called = false
        view.onRightClick = { _ in called = true }

        view.simulateRightClick(at: NSPoint(x: 200, y: 200))

        XCTAssertFalse(called, "bounds 外右键不应触发回调")
    }

    /// `hitTest` 始终返回 nil（左键穿透）。
    func testHitTest_alwaysReturnsNil() {
        let view = TabRightClickMonitor.MonitorView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 30)
        )

        let result = view.hitTest(NSPoint(x: 50, y: 15))

        XCTAssertNil(result, "hitTest 应返回 nil（左键穿透）")
    }

    /// 多次右键 → 回调多次触发。
    func testSimulateRightClick_multipleTimes_callsCallbackMultipleTimes() {
        let view = TabRightClickMonitor.MonitorView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 30)
        )
        var callCount = 0
        view.onRightClick = { _ in callCount += 1 }

        view.simulateRightClick(at: NSPoint(x: 10, y: 10))
        view.simulateRightClick(at: NSPoint(x: 20, y: 20))
        view.simulateRightClick(at: NSPoint(x: 30, y: 15))

        XCTAssertEqual(callCount, 3, "每次右键应各触发一次回调")
    }

    /// bounds 边缘点击 → 回调触发（边界包含）。
    func testSimulateRightClick_atEdge_callsCallback() {
        let view = TabRightClickMonitor.MonitorView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 30)
        )
        var called = false
        view.onRightClick = { _ in called = true }

        view.simulateRightClick(at: NSPoint(x: 0, y: 0))

        XCTAssertTrue(called, "bounds 边缘(0,0)应触发回调")
    }
}
#endif

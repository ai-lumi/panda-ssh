import XCTest
import SwiftUI

#if os(macOS)
@testable import PandaSSH_macOS

/// macOS 自绘顶部 chrome 事件桥接测试。
/// 正常流程：空白区单击拖窗、双击缩放。
/// 意外操作：页签/关闭/侧栏控件不继承窗口事件。
/// 边界条件：零宽空白区、无原生按钮窗口、全屏窗口。
@MainActor
final class WorkspaceChromeEventBridgeTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.isReleasedWhenClosed = false
        return w
    }

    // MARK: - 正常流程

    func testBlankDragViewOwnsMouseDownInsteadOfPassingItToWindow() {
        let view = WindowDragView.DragView()
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    func testDoubleClickOnBlankAreaZoomsWindow() {
        let window = makeWindow()
        defer { window.close() }
        let view = WindowDragView.DragView()
        window.contentView?.addSubview(view)
        var zoomed = false
        let orig = #selector(NSWindow.performZoom(_:))
        view.performZoomAction = { zoomed = true }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 0
        )!
        view.mouseDown(with: event)
        XCTAssertTrue(zoomed, "双击空白区应触发窗口缩放/还原")
        _ = orig
    }

    func testWindowHitTestingFindsOnlyBlankDragRegionForZoom() {
        let window = makeWindow()
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let dragView = WindowDragView.DragView(frame: NSRect(x: 0, y: 460, width: 100, height: 40))
        let tabView = NSView(frame: NSRect(x: 100, y: 460, width: 300, height: 40))
        content.addSubview(dragView)
        content.addSubview(tabView)
        window.contentView = content

        XCTAssertTrue(content.hitTest(NSPoint(x: 50, y: 480)) === dragView)
        XCTAssertTrue(content.hitTest(NSPoint(x: 150, y: 480)) === tabView)
        XCTAssertFalse((content.hitTest(NSPoint(x: 150, y: 480)) as? WindowDragView.DragView) != nil)
    }

    func testSingleClickDoesNotZoom() {
        let window = makeWindow()
        defer { window.close() }
        let view = WindowDragView.DragView()
        window.contentView?.addSubview(view)
        var zoomed = false
        view.performZoomAction = { zoomed = true }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
        view.mouseDown(with: event)
        XCTAssertFalse(zoomed, "单击不应触发缩放")
    }

    func testSingleClickOnBlankAreaStartsExplicitWindowDrag() {
        let window = makeWindow()
        defer { window.close() }
        let view = WindowDragView.DragView()
        window.contentView?.addSubview(view)
        var dragged = false
        view.performWindowDragAction = { _ in dragged = true }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
        view.mouseDown(with: event)
        XCTAssertTrue(dragged, "单击空白区应显式发起窗口拖动")
    }

    // MARK: - 意外操作

    func testTabViewsDoNotInheritWindowDrag() {
        let tabView = NSView()
        XCTAssertFalse(
            tabView is WindowDragView.DragView,
            "页签视图不应是 DragView 类型，不继承窗口拖动"
        )
    }

    func testCloseButtonDoesNotInheritWindowDrag() {
        let buttonView = NSButton()
        XCTAssertFalse(
            buttonView is WindowDragView.DragView,
            "关闭按钮不应是 DragView 类型，不继承窗口拖动"
        )
    }

    func testSidebarControlsDoNotInheritWindowDrag() {
        let sidebarView = NSView()
        XCTAssertFalse(
            sidebarView is WindowDragView.DragView,
            "侧栏控件不应是 DragView 类型，不继承窗口拖动"
        )
    }

    func testDoubleClickOnNonDragViewDoesNotZoom() {
        let nonDragView = NSView()
        XCTAssertFalse(
            nonDragView is WindowDragView.DragView,
            "非拖拽视图不应是 DragView 类型，不继承双击缩放"
        )
    }

    // MARK: - 边界条件

    func testZeroWidthDragRegionDoesNotPassMouseDownToWindow() {
        let view = WindowDragView.DragView()
        view.frame = NSRect(x: 0, y: 0, width: 0, height: 40)
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    func testDragViewOnBorderlessWindow() {
        let borderless = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered, defer: false
        )
        borderless.isReleasedWhenClosed = false
        defer { borderless.close() }
        let view = WindowDragView.DragView()
        borderless.contentView?.addSubview(view)
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        XCTAssertNil(borderless.standardWindowButton(.zoomButton))
        var zoomed = false
        view.performZoomAction = { zoomed = true }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: borderless.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 0
        )!
        view.mouseDown(with: event)
        XCTAssertFalse(zoomed, "无缩放按钮的窗口不应触发缩放")
    }

    func testDragViewOnFullScreenWindow() {
        let window = makeWindow()
        defer { window.close() }
        window.toggleFullScreen(nil)
        let view = WindowDragView.DragView()
        window.contentView?.addSubview(view)
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        XCTAssertTrue(window.styleMask.contains(.fullScreen))
    }
}
#endif

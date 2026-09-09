import XCTest
import SwiftUI

#if os(macOS)
@testable import PandaSSH_macOS

/// 使用独立 AppKit 窗口，不启动应用入口或真实后端。
@MainActor
final class MainWindowChromeLifecycleTests: XCTestCase {
    private final class ProbeWindow: NSWindow {
        var writes = 0
        override var titleVisibility: NSWindow.TitleVisibility { didSet { writes += 1 } }
        override var titlebarAppearsTransparent: Bool { didSet { writes += 1 } }
        override var styleMask: NSWindow.StyleMask { didSet { writes += 1 } }
        override var toolbar: NSToolbar? { didSet { writes += 1 } }
    }

    private func window() -> ProbeWindow {
        let window = ProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func test重复挂载与焦点尺寸通知不重写已正确的窗口属性() {
        let window = window()
        defer { window.close() }
        let coordinator = MainWindowChrome.Coordinator(metrics: MacOSWorkspaceChromeMetrics())
        coordinator.attach(to: window)
        pump()
        let writes = window.writes
        coordinator.attach(to: window)
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.post(name: name, object: window)
        }
        pump()
        XCTAssertEqual(window.writes, writes, "无状态变化时不能重建系统标题栏")
    }

    func test窗口属性偏离后在焦点通知中恢复() {
        let window = window()
        defer { window.close() }
        let coordinator = MainWindowChrome.Coordinator(metrics: MacOSWorkspaceChromeMetrics())
        coordinator.attach(to: window)
        pump()
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.toolbar = NSToolbar(identifier: "测试工具栏")
        let button = window.standardWindowButton(.closeButton)!
        button.isHidden = true
        button.alphaValue = 0
        button.isEnabled = false
        button.superview?.isHidden = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        pump()
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertNil(window.toolbar)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.alphaValue, 1)
        XCTAssertTrue(button.isEnabled)
        XCTAssertFalse(button.superview!.isHidden)
    }

    func test切换宿主后旧窗口的异步恢复不得继续执行() {
        let old = window()
        let current = window()
        defer { old.close(); current.close() }
        let coordinator = MainWindowChrome.Coordinator(metrics: MacOSWorkspaceChromeMetrics())
        coordinator.attach(to: nil)
        coordinator.attach(to: old)
        coordinator.attach(to: current)
        let button = old.standardWindowButton(.closeButton)!
        button.isHidden = true
        let writes = old.writes
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: old)
        pump()
        XCTAssertEqual(old.writes, writes)
        XCTAssertTrue(button.isHidden, "旧窗口排队回调不能干扰当前宿主")
    }

    func test解绑后通知不得重新配置窗口() {
        let window = window()
        defer { window.close() }
        let coordinator = MainWindowChrome.Coordinator(metrics: MacOSWorkspaceChromeMetrics())
        coordinator.attach(to: window)
        coordinator.attach(to: nil)
        window.titlebarAppearsTransparent = false
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        pump()
        XCTAssertFalse(window.titlebarAppearsTransparent)
    }

    func testSwiftUI宿主更新拆卸及无原生按钮窗口() {
        let window = window()
        defer { window.close() }
        let metrics = MacOSWorkspaceChromeMetrics()
        XCTAssertTrue(WindowDragView.DragView().mouseDownCanMoveWindow)
        func root(_ visible: Bool) -> AnyView {
            AnyView(
                MacOSUnifiedSplitHost(
                    sidebar: Text("主机"), detail: Text("测试内容"),
                    policy: .resolve(requestedSidebarWidth: 250, isSidebarVisible: visible)
                )
                .background(WindowDragView())
                .background(MainWindowChrome(metrics: metrics))
            )
        }
        let hosting = NSHostingView(rootView: root(true))
        window.contentView = hosting
        window.orderFrontRegardless()
        pump()
        hosting.rootView = root(false)
        pump()
        XCTAssertTrue(window.titlebarAppearsTransparent)
        hosting.rootView = AnyView(EmptyView())
        pump()
        window.titlebarAppearsTransparent = false
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        pump()
        XCTAssertFalse(window.titlebarAppearsTransparent)

        let borderless = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        borderless.isReleasedWhenClosed = false
        let coordinator = MainWindowChrome.Coordinator(metrics: metrics)
        coordinator.attach(to: borderless)
        pump()
        XCTAssertNil(borderless.standardWindowButton(.closeButton))
        coordinator.attach(to: nil)
        borderless.close()
    }
}
#endif

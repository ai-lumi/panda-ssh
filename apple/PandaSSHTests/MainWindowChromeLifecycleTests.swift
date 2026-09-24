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

    private final class AlternateContentView: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 123, height: 45) }
    }

    func test不同内容类型保持宿主类型且替换内容后仍禁用隐式拖窗() {
        let window = window()
        defer { window.close() }
        let coordinator = MainWindowChrome.Coordinator(metrics: MacOSWorkspaceChromeMetrics())
        let plain = NSView()
        window.contentView = plain
        let originalPlainClass = object_getClass(plain)!
        window.isMovableByWindowBackground = true
        coordinator.attach(to: window)
        XCTAssertTrue(object_getClass(plain) === originalPlainClass, "适配不能替换宿主运行时类型")
        XCTAssertFalse(window.isMovableByWindowBackground)

        let alternate = AlternateContentView()
        window.contentView = alternate
        let originalAlternateClass = object_getClass(alternate)!
        window.isMovableByWindowBackground = true
        coordinator.attach(to: window)
        XCTAssertTrue(object_getClass(alternate) === originalAlternateClass)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertEqual(alternate.intrinsicContentSize, NSSize(width: 123, height: 45))
        let adaptedClass = object_getClass(alternate)!
        coordinator.attach(to: window)
        XCTAssertTrue(object_getClass(alternate) === adaptedClass, "重复挂载不能修改宿主运行时类型")
        coordinator.attach(to: nil)
        window.contentView = nil
    }

    func test不同SwiftUI内容类型在同一窗口中可更新和布局() {
        let window = window()
        defer { window.close() }
        let coordinator = MainWindowChrome.Coordinator(metrics: MacOSWorkspaceChromeMetrics())
        let text = NSHostingView(rootView: Text("第一种内容"))
        let erased = NSHostingView(rootView: AnyView(Text("第二种内容")))
        for content in [text as NSView, erased as NSView] {
            window.contentView = content
            let originalClass = object_getClass(content)!
            window.isMovableByWindowBackground = true
            coordinator.attach(to: window)
            XCTAssertTrue(object_getClass(content) === originalClass)
            XCTAssertFalse(window.isMovableByWindowBackground)
            content.layoutSubtreeIfNeeded()
        }
        erased.rootView = AnyView(Text("更新内容"))
        erased.layoutSubtreeIfNeeded()
        coordinator.attach(to: nil)
        window.contentView = nil
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

    private func waitForTransparentTitlebar(_ window: NSWindow) async {
        // 等待实际挂载状态，避免固定 50ms 在全量运行时早于 SwiftUI 布局完成。
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "titlebarAppearsTransparent == YES"), object: window
        )
        await fulfillment(of: [ready], timeout: 2)
    }

    func testSwiftUI宿主更新拆卸及无原生按钮窗口() async {
        let window = window()
        defer { window.close() }
        let metrics = MacOSWorkspaceChromeMetrics()
        XCTAssertFalse(WindowDragView.DragView().mouseDownCanMoveWindow, "空白区域通过 performDrag 显式拖窗")
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
        await waitForTransparentTitlebar(window)
        hosting.rootView = root(false)
        pump()
        await waitForTransparentTitlebar(window)
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

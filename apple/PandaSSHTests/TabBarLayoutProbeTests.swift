import XCTest
import SwiftUI

#if os(macOS)
@testable import PandaSSH_macOS

/// 页签栏布局探针：在真实 AppKit/NSHostingView 布局中观测统一页签栏的实际高度，
/// 用于定位「页签按钮区高度异常」与「终端沉底」的根因。
/// 探针输出打印到测试日志（dump 行），断言只作宽松护栏。
@MainActor
final class TabBarLayoutProbeTests: XCTestCase {

    // MARK: - 工具

    /// 跑几个 runloop tick，让 SwiftUI 完成布局与 representable 更新。
    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 递归收集类名包含 match 的视图 frame；verbose 时打印整棵树。
    @discardableResult
    private func dumpHierarchy(_ view: NSView, depth: Int = 0, match: String, verbose: Bool = true) -> [NSRect] {
        let name = String(describing: type(of: view))
        if verbose {
            let indent = String(repeating: "  ", count: depth)
            print("PROBE \(indent)\(name) frame=\(view.frame)")
        }
        var hits: [NSRect] = []
        if (match == "MonitorView" ? name == match : name.contains(match)) {
            hits.append(view.frame)
        }
        for sub in view.subviews {
            hits.append(contentsOf: dumpHierarchy(sub, depth: depth + 1, match: match, verbose: verbose))
        }
        return hits
    }

    private func makeWindow(width: CGFloat = 1000, height: CGFloat = 600) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private final class ChromeConfigurationProbeWindow: NSWindow {
        private(set) var titlebarTransparencyWriteCount = 0

        override var titlebarAppearsTransparent: Bool {
            didSet { titlebarTransparencyWriteCount += 1 }
        }
    }

    func test首次打开页签不重复配置窗口Chrome() throws {
        let model = AppModel.previewModel()
        let host = try XCTUnwrap(model.hosts.first)
        let store = WorkspaceStore(hostNameProvider: { hostID in
            model.hosts.first(where: { $0.id == hostID })?.name
        })
        let root = HostListView()
            .environmentObject(model)
            .environmentObject(store)
            .transferStore(TransferStore())
        let hosting = NSHostingView(rootView: root)
        let window = ChromeConfigurationProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        pump(1.2)

        let writeCountBeforeOpening = window.titlebarTransparencyWriteCount
        XCTAssertGreaterThan(writeCountBeforeOpening, 0, "真实窗口应在初始挂载时配置 chrome")

        let tabID = store.openTerminal(hostID: host.id)
        model.presentTab(tabID)
        pump(0.5)

        XCTAssertEqual(
            window.titlebarTransparencyWriteCount,
            writeCountBeforeOpening,
            "首次打开页签不得重复写入未变化的标题栏透明度"
        )
    }

    func test窗口失去焦点后保持透明且不重复写入属性() throws {
        let model = AppModel.previewModel()
        let host = try XCTUnwrap(model.hosts.first)
        let store = WorkspaceStore(hostNameProvider: { hostID in
            model.hosts.first(where: { $0.id == hostID })?.name
        })
        let root = HostListView()
            .environmentObject(model)
            .environmentObject(store)
            .transferStore(TransferStore())
        let hosting = NSHostingView(rootView: root)
        let window = ChromeConfigurationProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        pump(1.2)

        _ = try XCTUnwrap(
            findView(hosting, matching: "MonitorView"),
            "激活时应存在统一顶部页签栏 MonitorView"
        )
        let writeCountBeforeResign = window.titlebarTransparencyWriteCount
        XCTAssertTrue(window.titlebarAppearsTransparent, "激活时标题栏应为透明")

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        pump(0.3)

        XCTAssertTrue(window.titlebarAppearsTransparent, "失去焦点后标题栏仍应保持透明")
        // 与当前幂等 chrome 契约一致：焦点通知复核属性，但不重复写入正确值。
        XCTAssertEqual(
            window.titlebarTransparencyWriteCount,
            writeCountBeforeResign,
            "失焦通知不得重复写入已正确的窗口属性"
        )
        let chrome = try XCTUnwrap(
            findView(hosting, matching: "MonitorView"),
            "失去焦点后统一顶部页签栏仍应保留在层级中"
        )
        let frame = chrome.convert(chrome.bounds, to: nil)
        XCTAssertGreaterThan(frame.width, 0, "失去焦点后页签栏宽度应大于 0")
        XCTAssertGreaterThan(frame.height, 0, "失去焦点后页签栏高度应大于 0")
    }

    /// 深度优先查找第一个类名包含 match 的视图。
    private func findView(_ view: NSView, matching match: String) -> NSView? {
        if (match == "MonitorView" ? String(describing: type(of: view)) == match : String(describing: type(of: view)).contains(match)) { return view }
        for sub in view.subviews {
            if let found = findView(sub, matching: match) { return found }
        }
        return nil
    }

    // MARK: - 探针 3：真实终端视图在场 + 动画过程中逐帧观测页签栏/终端 frame

    func testProbeWithTerminalDuringAnimatedSidebarToggle() {
        let model = AppModel.previewModel()
        let store = WorkspaceStore.previewStore()
        // 选中终端标签（previewStore 最后打开的是 SFTP 标签，终端视图不会创建）
        if let terminalTab = store.tabs.first(where: { $0.kind == .terminal }) {
            store.select(tabID: terminalTab.id)
        }
        // 从 detailOnly 开始（用户场景：侧栏隐藏 → 显示）
        model.columnVisibility = .detailOnly

        let root = WorkspaceView()
            .environmentObject(model)
            .environmentObject(store)
            .transferStore(TransferStore())
            .environmentObject(ToastCenter())
            .environmentObject(MacOSWorkspaceChromeMetrics())
        let hosting = NSHostingView(rootView: root)
        let window = makeWindow()
        window.contentView = hosting
        window.orderFrontRegardless()

        // 等 Mock 连接的 800ms 动画结束，SwiftTermWrapper 真正创建
        pump(1.5)
        hosting.layoutSubtreeIfNeeded()

        func probe(_ label: String) {
            let tabBar = dumpHierarchy(window.contentView!, depth: 0, match: "MonitorView", verbose: false)
            let terminal = dumpHierarchy(window.contentView!, depth: 0, match: "PandaTerminalView", verbose: false)
            print("PROBE [\(label)] tabBar=\(tabBar.map { "\($0.size)" }) terminal=\(terminal.map { "\($0)" })")
        }
        probe("stable detailOnly")

        // 用显式动画触发侧栏显示，逐 50ms 观测中间态
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            model.columnVisibility = .all
        }
        for i in 0..<10 {
            pump(0.05)
            hosting.layoutSubtreeIfNeeded()
            probe("animating \(i * 50)ms")
        }
        pump(1.0)
        hosting.layoutSubtreeIfNeeded()
        probe("stable all")
    }

    func test切换终端标签后两个终端视图都保持在层级中() {
        let model = AppModel.previewModel()
        let store = WorkspaceStore.previewStore()
        let terminals = store.tabs.filter { $0.kind == .terminal }
        XCTAssertEqual(terminals.count, 2)
        store.select(tabID: terminals[0].id)
        model.presentTab(terminals[0].id)

        let root = WorkspaceView()
            .environmentObject(model)
            .environmentObject(store)
            .transferStore(TransferStore())
            .environmentObject(ToastCenter())
            .environmentObject(MacOSWorkspaceChromeMetrics())
        let hosting = NSHostingView(rootView: root)
        let window = makeWindow()
        window.contentView = hosting
        window.orderFrontRegardless()
        pump(1.2)

        store.select(tabID: terminals[1].id)
        model.presentTab(terminals[1].id)
        pump(0.2)

        let terminalViews = dumpHierarchy(window.contentView!, depth: 0, match: "PandaTerminalView", verbose: false)
        XCTAssertEqual(terminalViews.count, 2, "切换标签不得销毁非活动终端视图")

        store.close(tabID: terminals[0].id)
        pump(0.2)
        let remainingTerminalViews = dumpHierarchy(window.contentView!, depth: 0, match: "PandaTerminalView", verbose: false)
        XCTAssertEqual(remainingTerminalViews.count, 1, "关闭标签后才应释放对应终端视图")
    }

    func testProbeUnifiedTabStripAfterOpeningFirstTab() throws {
        let model = AppModel.previewModel()
        let host = try XCTUnwrap(model.hosts.first)
        let store = WorkspaceStore(hostNameProvider: { hostID in
            model.hosts.first(where: { $0.id == hostID })?.name
        })
        let root = HostListView()
            .environmentObject(model)
            .environmentObject(store)
            .transferStore(TransferStore())
        let hosting = NSHostingView(rootView: root)
        let window = makeWindow()
        window.contentView = hosting
        window.orderFrontRegardless()
        pump(1.2)

        let tabID = store.openTerminal(hostID: host.id)
        model.presentTab(tabID)
        pump(0.5)

        _ = try XCTUnwrap(findView(hosting, matching: "MonitorView"))
        print("PROBE === UnifiedWorkspaceTabStrip 首次打开页签后 ===")
        dumpHierarchy(hosting, match: "")
    }

    func test首次打开页签期间统一顶部栏保持稳定几何() throws {
        let model = AppModel.previewModel()
        let host = try XCTUnwrap(model.hosts.first)
        let store = WorkspaceStore(hostNameProvider: { hostID in
            model.hosts.first(where: { $0.id == hostID })?.name
        })

        let root = HostListView()
            .environmentObject(model)
            .environmentObject(store)
            .transferStore(TransferStore())
        let hosting = NSHostingView(rootView: root)
        let window = makeWindow()
        window.contentView = hosting
        window.orderFrontRegardless()
        pump(1.2)

        let chrome = try XCTUnwrap(
            findView(hosting, matching: "MonitorView"),
            "未找到统一顶部页签栏的 MonitorView"
        )
        let initialFrame = chrome.convert(chrome.bounds, to: nil)
        XCTAssertGreaterThan(initialFrame.width, 0)
        XCTAssertGreaterThan(initialFrame.height, 0)

        let tabID = store.openTerminal(hostID: host.id)
        model.presentTab(tabID)

        var observedFrames: [NSRect] = []
        for _ in 0..<20 {
            pump(0.02)
            observedFrames.append(chrome.convert(chrome.bounds, to: nil))
        }

        XCTAssertFalse(observedFrames.isEmpty)
        XCTAssertTrue(
            observedFrames.allSatisfy {
                $0.width >= initialFrame.width / 2 && $0.height >= initialFrame.height / 2
            },
            "首次打开页签期间统一顶部栏不得短暂压缩；初始 frame=\(initialFrame)，采样 frame=\(observedFrames)"
        )
    }

    // MARK: - 探针 2：WorkspaceView 整体 + 侧栏显隐切换后的页签栏高度

    func testProbeUnifiedTabStripAcrossSidebarToggle() {
        let model = AppModel.previewModel()
        let store = WorkspaceStore.previewStore()

        let root = WorkspaceView()
            .environmentObject(model)
            .environmentObject(store)
            .transferStore(TransferStore())
            .environmentObject(ToastCenter())
            .environmentObject(MacOSWorkspaceChromeMetrics())
        let hosting = NSHostingView(rootView: root)
        let window = makeWindow()
        window.contentView = hosting
        window.orderFrontRegardless()
        pump()
        hosting.layoutSubtreeIfNeeded()
        pump(0.1)

        for visibility in [NavigationSplitViewVisibility.detailOnly, .all, .detailOnly, .all] {
            model.columnVisibility = visibility
            pump()
            hosting.layoutSubtreeIfNeeded()
            print("PROBE === WorkspaceView columnVisibility=\(visibility) ===")
            let hits = dumpHierarchy(window.contentView!, match: "MonitorView")
            XCTAssertFalse(hits.isEmpty, "统一页签栏输入桥接必须保持在视图树中")
            for frame in hits {
                XCTAssertLessThan(frame.height, 60, "侧栏显隐后页签栏高度异常: \(frame.height)")
            }
        }
    }
}
#endif

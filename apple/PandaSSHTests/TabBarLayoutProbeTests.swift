import XCTest
import SwiftUI

#if os(macOS)
@testable import PandaSSH_macOS

/// 页签栏布局探针：在真实 AppKit/NSHostingView 布局中观测 WorkspaceTabBar 的实际高度，
/// 用于定位「页签按钮区高度异常」与「终端沉底」的根因。
/// 探针输出打印到测试日志（dump 行），断言只作宽松护栏。
@MainActor
final class TabBarLayoutProbeTests: XCTestCase {

    // MARK: - 纯值滚动策略

    func test滚动指标覆盖溢出翻页与首尾状态() {
        let metrics = TabBarScrollMetrics.resolve(
            contentWidth: 1_200,
            viewportWidth: 400,
            offset: 350
        )

        XCTAssertTrue(metrics.needsScroll)
        XCTAssertTrue(metrics.canScrollBackward)
        XCTAssertTrue(metrics.canScrollForward)
        XCTAssertEqual(metrics.maximumOffset, 800)
        XCTAssertEqual(metrics.pageTarget(direction: .backward), 0)
        XCTAssertEqual(metrics.pageTarget(direction: .forward), 750)

        let trailing = TabBarScrollMetrics.resolve(
            contentWidth: 1_200,
            viewportWidth: 400,
            offset: 800
        )
        XCTAssertTrue(trailing.canScrollBackward)
        XCTAssertFalse(trailing.canScrollForward)
        XCTAssertEqual(trailing.pageTarget(direction: .forward), 800)
    }

    func test滚轮与显露页签目标始终夹取在合法范围() {
        let metrics = TabBarScrollMetrics.resolve(
            contentWidth: 1_000,
            viewportWidth: 300,
            offset: 200
        )

        XCTAssertEqual(metrics.wheelTarget(delta: -120), 320)
        XCTAssertEqual(metrics.wheelTarget(delta: 900), 0)
        XCTAssertEqual(metrics.revealedOffset(itemMinX: 640, itemMaxX: 740), 448)

        let scrolled = TabBarScrollMetrics.resolve(
            contentWidth: 1_000,
            viewportWidth: 300,
            offset: 500
        )
        XCTAssertEqual(scrolled.revealedOffset(itemMinX: 120, itemMaxX: 220), 112)
    }

    func test无效尺寸与临界宽度安全回退() {
        for values in [
            (Double.nan, 300.0, 20.0),
            (1_000.0, -Double.infinity, 20.0),
            (-1.0, 300.0, 20.0),
            (300.0, 300.0, 999.0),
        ] {
            let metrics = TabBarScrollMetrics.resolve(
                contentWidth: values.0,
                viewportWidth: values.1,
                offset: values.2
            )
            XCTAssertGreaterThanOrEqual(metrics.offset, 0)
            XCTAssertLessThanOrEqual(metrics.offset, metrics.maximumOffset)
            XCTAssertFalse(metrics.needsScroll)
            XCTAssertFalse(metrics.canScrollForward)
        }
    }

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
        if name.contains(match) {
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

    // MARK: - 探针 1：独立 WorkspaceTabBar（滚动模式）在 500pt 宽下的高度与左对齐

    func testProbeStandaloneScrollTabBar() {
        let model = AppModel.previewModel()
        let store = WorkspaceStore.previewStore()
        store.tabBarOverflowMode = .scroll

        let hosting = NSHostingView(rootView:
            WorkspaceTabBar()
                .environmentObject(model)
                .environmentObject(store)
        )
        let window = makeWindow()
        window.contentView?.addSubview(hosting)
        hosting.frame = NSRect(x: 0, y: 100, width: 500, height: 400)
        window.orderFrontRegardless()
        pump()
        hosting.layoutSubtreeIfNeeded()
        pump(0.1)

        print("PROBE === 独立 WorkspaceTabBar（滚动模式, 宽 500）===")
        let hits = dumpHierarchy(window.contentView!, match: "HeightConstrainedContainer")
        XCTAssertFalse(hits.isEmpty, "未找到 HeightConstrainedContainer")
        for frame in hits {
            XCTAssertLessThan(frame.height, 60, "页签栏滚动容器高度异常: \(frame.height)")
        }

        // 左对齐回归：scroll document（NSClipView 的 documentView）宽度 MUST 等于
        // 内容理想宽度而非撑满可见宽度——NSHostingView 根视图会把内容居中，
        // document 撑满时少量页签会显示在页签栏中部而非左侧。
        if let container = findView(window.contentView!, matching: "HeightConstrainedContainer"),
           let (document, clipWidth) = findScrollDocument(in: container) {
            print("PROBE document frame=\(document.frame) clipWidth=\(clipWidth)")
            XCTAssertLessThan(document.frame.width, clipWidth,
                              "document 不应撑满可见宽度（内容 \(document.frame.width)pt < 可见 \(clipWidth)pt）")
            XCTAssertEqual(document.frame.origin.x, 0, accuracy: 0.5, "document 应左对齐于 clip 视图")
        } else {
            XCTFail("未找到页签滚动区的 document view")
        }
    }

    func test二十个真实页签可按页向右再返回起点() throws {
        let model = AppModel.previewModel()
        let store = WorkspaceStore(hostNameProvider: { _ in "box" })
        store.tabBarOverflowMode = .scroll
        for _ in 0..<20 {
            store.openTerminal(hostID: "box")
        }
        let controller = TabBarScrollController()

        let hosting = NSHostingView(rootView:
            WorkspaceTabBar(scrollController: controller)
                .environmentObject(model)
                .environmentObject(store)
                .frame(width: 500)
        )
        let window = makeWindow()
        window.contentView = hosting
        window.orderFrontRegardless()
        pump(0.6)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.needsScroll)
        XCTAssertFalse(controller.canScrollLeft)
        XCTAssertTrue(controller.canScrollRight)

        let container = try XCTUnwrap(findView(hosting, matching: "HeightConstrainedContainer"))
        let scrollView = try XCTUnwrap(findScrollView(in: container))
        let initialOffset = scrollView.contentView.bounds.minX

        controller.scrollRight()
        pump(0.4)
        XCTAssertGreaterThan(scrollView.contentView.bounds.minX, initialOffset)
        XCTAssertTrue(controller.canScrollLeft)

        controller.scrollLeft()
        pump(0.4)
        XCTAssertEqual(scrollView.contentView.bounds.minX, 0, accuracy: 1)

        let lastTabID = try XCTUnwrap(store.tabs.last?.id)
        model.presentTab(lastTabID)
        pump(0.4)
        XCTAssertGreaterThan(scrollView.contentView.bounds.minX, 0)
        XCTAssertFalse(controller.canScrollRight)
    }

    /// 深度优先查找第一个类名包含 match 的视图。
    private func findView(_ view: NSView, matching match: String) -> NSView? {
        if String(describing: type(of: view)).contains(match) { return view }
        for sub in view.subviews {
            if let found = findView(sub, matching: match) { return found }
        }
        return nil
    }

    /// 在容器视图树中查找 NSScrollView 的 documentView 及其可见宽度。
    private func findScrollDocument(in container: NSView) -> (document: NSView, clipWidth: CGFloat)? {
        for sub in container.subviews {
            if let scrollView = sub as? NSScrollView, let document = scrollView.documentView {
                return (document, scrollView.contentView.bounds.width)
            }
            if let found = findScrollDocument(in: sub) { return found }
        }
        return nil
    }

    private func findScrollView(in container: NSView) -> NSScrollView? {
        if let scrollView = container as? NSScrollView { return scrollView }
        for subview in container.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - 探针 3：真实终端视图在场 + 动画过程中逐帧观测页签栏/终端 frame

    func testProbeWithTerminalDuringAnimatedSidebarToggle() {
        let model = AppModel.previewModel()
        let store = WorkspaceStore.previewStore()
        store.tabBarOverflowMode = .scroll
        // 选中终端标签（previewStore 最后打开的是 SFTP 标签，终端视图不会创建）
        if let terminalTab = store.tabs.first(where: { $0.kind == .terminal }) {
            store.select(tabID: terminalTab.id)
        }
        // 从 detailOnly 开始（用户场景：侧栏隐藏 → 显示）
        model.columnVisibility = .detailOnly

        let root = WorkspaceView()
            .environmentObject(model)
            .environmentObject(store)
            .environmentObject(TransferStore())
            .environmentObject(ToastCenter())
        let hosting = NSHostingView(rootView: root)
        let window = makeWindow()
        window.contentView = hosting
        window.orderFrontRegardless()

        // 等 Mock 连接的 800ms 动画结束，SwiftTermWrapper 真正创建
        pump(1.5)
        hosting.layoutSubtreeIfNeeded()

        func probe(_ label: String) {
            let tabBar = dumpHierarchy(window.contentView!, depth: 0, match: "HeightConstrainedContainer", verbose: false)
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

    // MARK: - 探针 2：WorkspaceView 整体 + 侧栏显隐切换后的页签栏高度

    func testProbeWorkspaceTabBarAcrossSidebarToggle() {
        let model = AppModel.previewModel()
        let store = WorkspaceStore.previewStore()
        store.tabBarOverflowMode = .scroll

        let root = WorkspaceView()
            .environmentObject(model)
            .environmentObject(store)
            .environmentObject(TransferStore())
            .environmentObject(ToastCenter())
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
            let hits = dumpHierarchy(window.contentView!, match: "HeightConstrainedContainer")
            for frame in hits {
                XCTAssertLessThan(frame.height, 60, "侧栏显隐后页签栏高度异常: \(frame.height)")
            }
        }
    }
}
#endif

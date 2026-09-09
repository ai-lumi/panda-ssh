import XCTest
import Combine

#if os(macOS)
import AppKit
@testable import PandaSSH_macOS

/// chrome 度量相等性去重：值不变 MUST NOT 重复发布 objectWillChange，
/// 消灭「发布 → 重渲染 → updateNSView → 再赋值发布」自激环。
final class MacosWorkspaceChromeMetricsTests: XCTestCase {
    private var metrics: MacOSWorkspaceChromeMetrics!
    private var cancellables: Set<AnyCancellable>!
    private var publishCount: Int!

    override func setUp() {
        super.setUp()
        metrics = MacOSWorkspaceChromeMetrics()
        cancellables = []
        publishCount = 0
        metrics.objectWillChange
            .sink { [weak self] _ in self?.publishCount += 1 }
            .store(in: &cancellables)
    }

    // MARK: 正常流程

    func test侧栏宽度首次赋值发布一次() {
        metrics.updateSidebarWidth(300)
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(metrics.sidebarWidth, 300)
    }

    func test侧栏宽度同值重复赋值不再发布() {
        metrics.updateSidebarWidth(300)
        metrics.updateSidebarWidth(300)
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(metrics.sidebarWidth, 300)
    }

    func test侧栏宽度变化后再次发布() {
        metrics.updateSidebarWidth(300)
        metrics.updateSidebarWidth(320)
        XCTAssertEqual(publishCount, 2)
        XCTAssertEqual(metrics.sidebarWidth, 320)
    }

    func test红绿灯安全宽度同值重复更新不再发布() {
        let window = makeWindow(width: 900)
        metrics.update(window: window)
        let first = metrics.trafficLightSafeWidth
        metrics.update(window: window)
        // 第二次以同几何更新：同值不发布，只有首次那一拍。
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(metrics.trafficLightSafeWidth, first)
    }

    func test红绿灯安全宽度窗口变化后再次发布() {
        let window = makeWindow(width: 900)
        metrics.update(window: window)
        // 红绿灯固定在左上角，x 不随窗口变宽改变；变窄到小于实测值触发夹逼变化。
        window.setFrame(NSRect(x: 0, y: 0, width: 40, height: 300), display: false)
        metrics.update(window: window)
        XCTAssertEqual(publishCount, 2)
        XCTAssertEqual(metrics.trafficLightSafeWidth, 40)
    }

    // MARK: 意外操作

    func test无效侧栏宽度输入不发布且值不变() {
        metrics.updateSidebarWidth(300)
        let before = publishCount
        metrics.updateSidebarWidth(.nan)
        metrics.updateSidebarWidth(0)
        metrics.updateSidebarWidth(-50)
        metrics.updateSidebarWidth(.infinity)
        XCTAssertEqual(publishCount, before)
        XCTAssertEqual(metrics.sidebarWidth, 300)
    }

    // MARK: 边界条件

    func test无红绿灯按钮的窗口走fallback且同值不重复发布() {
        // contentView 为 nil 的窗口无法提供 zoomButton，触发 fallback 路径。
        // 窗口宽 60：fallback = 60 ≠ 默认 76，首次更新发布；同值重复不再发布。
        let window = makeWindow(width: 60)
        window.contentView = nil
        metrics.update(window: window)
        XCTAssertEqual(metrics.trafficLightSafeWidth, 60)
        metrics.update(window: window)
        XCTAssertEqual(publishCount, 1)
    }

    func test极小窗口宽度fallback被夹逼到窗口宽度() {
        let window = makeWindow(width: 40)
        window.contentView = nil
        metrics.update(window: window)
        XCTAssertEqual(metrics.trafficLightSafeWidth, 40)
    }

    func testfallback值变化时正常发布() {
        // 宽 60 → fallback 60（首次发布）；变窄到 40 → fallback 40（再次发布）。
        let window = makeWindow(width: 60)
        window.contentView = nil
        metrics.update(window: window)
        window.setFrame(NSRect(x: 0, y: 0, width: 40, height: 300), display: false)
        metrics.update(window: window)
        XCTAssertEqual(publishCount, 2)
        XCTAssertEqual(metrics.trafficLightSafeWidth, 40)
    }

    // MARK: 工具

    private func makeWindow(width: Double) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }
}
#endif

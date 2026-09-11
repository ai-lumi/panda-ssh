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

    func test侧栏宽度变化后再次发布() {
        metrics.updateSidebarWidth(300)
        metrics.updateSidebarWidth(320)
        XCTAssertEqual(publishCount, 2)
        XCTAssertEqual(metrics.sidebarWidth, 320)
    }

    /// 幂等契约：无论走侧栏、正常窗口还是 fallback 路径，同值重复更新 MUST NOT 重复发布。
    func test幂等契约_同值重复更新不再发布() {
        // 侧栏路径
        metrics.updateSidebarWidth(300)
        metrics.updateSidebarWidth(300)
        XCTAssertEqual(publishCount, 1)

        // 正常窗口路径（有 zoomButton）
        let normalWindow = makeWindow(width: 900)
        metrics.update(window: normalWindow)
        let safeWidth = metrics.trafficLightSafeWidth
        metrics.update(window: normalWindow)
        XCTAssertEqual(publishCount, 2) // 只有首次窗口更新发布
        XCTAssertEqual(metrics.trafficLightSafeWidth, safeWidth)

        // fallback 路径（无 zoomButton）：窗口宽 60 ≠ 默认 76，首次发布
        let fallbackWindow = makeWindow(width: 60)
        fallbackWindow.contentView = nil
        metrics.update(window: fallbackWindow)
        XCTAssertEqual(metrics.trafficLightSafeWidth, 60)
        metrics.update(window: fallbackWindow)
        XCTAssertEqual(publishCount, 3) // 只有首次 fallback 发布
    }

    /// 值变化发布：正常窗口变窄和 fallback 值变化都 MUST 正常发布。
    func test值变化时正常发布() {
        // 正常窗口路径：变窄触发发布
        let window = makeWindow(width: 900)
        metrics.update(window: window)
        window.setFrame(NSRect(x: 0, y: 0, width: 40, height: 300), display: false)
        metrics.update(window: window)
        XCTAssertEqual(publishCount, 2)
        XCTAssertEqual(metrics.trafficLightSafeWidth, 40)

        // fallback 路径：宽 60 → 40，两次不同的 fallback 值各发布一次
        let fallbackWindow = makeWindow(width: 60)
        fallbackWindow.contentView = nil
        metrics.update(window: fallbackWindow)
        XCTAssertEqual(publishCount, 3)
        fallbackWindow.setFrame(NSRect(x: 0, y: 0, width: 40, height: 300), display: false)
        metrics.update(window: fallbackWindow)
        XCTAssertEqual(publishCount, 4)
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

    func test极小窗口宽度fallback被夹逼到窗口宽度() {
        let window = makeWindow(width: 40)
        window.contentView = nil
        metrics.update(window: window)
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

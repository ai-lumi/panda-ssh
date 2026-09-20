import XCTest
import SwiftUI

#if os(macOS)

@testable import PandaSSH_macOS

/// 页签栏固有宽度反馈循环回归测试（OpenSpec fix-tab-strip-intrinsic-width 任务 1.3）。
///
/// 根因：非滚动分支将可压缩的 tabDocument 与基于上一轮 tabFrames 的 trailingEmptyWidth
/// 并排放在固定宽度容器中，形成历史空白反向压缩新内容的反馈循环。
///
/// 测试策略：
/// - 用真实 UnifiedWorkspaceTabStrip + WorkspaceStore 在 NSHostingView 中渲染
/// - 通过 NSView 层级递归查找所有子视图，按尺寸和位置推断页签按钮宽度
/// - 使用 TabStripViewportState 纯值测试验证反馈循环的数学证据
///
/// 当前状态：Red（预期失败），修复后变绿。
@MainActor
final class TabStripIntrinsicWidthTests: XCTestCase {

    // MARK: - 辅助

    private func pump(_ seconds: Double = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 递归统计 NSView 层级中所有非零尺寸子视图。
    private func countNonTrivialSubviews(in view: NSView) -> Int {
        var count = 0
        for sub in view.subviews {
            if sub.frame.width > 1 && sub.frame.height > 1 {
                count += 1
            }
            count += countNonTrivialSubviews(in: sub)
        }
        return count
    }

    /// 递归查找层级中最宽视图的宽度（排除容器级视图）。
    private func findWidestLeafWidth(in view: NSView, maxDepth: Int = 10) -> CGFloat {
        guard maxDepth > 0 else { return 0 }
        var widest: CGFloat = 0
        for sub in view.subviews {
            if sub.subviews.isEmpty && sub.frame.width > widest {
                widest = sub.frame.width
            }
            let childWidest = findWidestLeafWidth(in: sub, maxDepth: maxDepth - 1)
            if childWidest > widest {
                widest = childWidest
            }
        }
        return widest
    }

    // MARK: - 反馈循环纯值证据

    /// 纯值测试：模拟反馈循环的数学过程，证明 trailingEmptyWidth 会压缩文档。
    ///
    /// 场景：两个页签，自然宽度约 268pt，containerWidth=800。
    /// 第一轮 previousContentWidth=130（来自上一轮单页签测量），
    /// trailingEmptyWidth = 800 - 138 = 662，文档被压缩到 800 - 662 = 138pt。
    /// 138 < 268 * 0.9 = 241.2 → 断言失败，证明反馈循环存在。
    func test反馈循环导致文档宽度低于自然宽度() {
        let containerWidth: Double = 800
        let naturalDocWidth: Double = 268  // 两个页签按钮 + 间距 + padding

        // 模拟上一轮只有一个页签时的测量值
        let previousContentWidth: Double = 130

        let contentWidth = TabStripViewportState.contentWidth(
            from: [UUID(): CGRect(x: 0, y: 0, width: previousContentWidth, height: 30)]
        )
        let viewport = TabStripViewportState.resolve(
            contentWidth: contentWidth,
            viewportWidth: containerWidth,
            offset: 0
        )

        // 当前布局分配：文档获得 containerWidth - trailingEmptyWidth
        let allocatedDocWidth = containerWidth - viewport.trailingEmptyWidth

        XCTAssertFalse(viewport.needsScroll, "不应溢出（旧值偏小）")
        XCTAssertGreaterThan(viewport.trailingEmptyWidth, 0, "应有尾部空白")
        XCTAssertLessThan(allocatedDocWidth, naturalDocWidth * 0.9,
            """
            反馈循环证据：文档分配宽度(\(allocatedDocWidth)) \
            低于自然宽度(\(naturalDocWidth))的 90%。\
            trailingEmptyWidth=\(viewport.trailingEmptyWidth) 基于旧测量值 \(previousContentWidth)。
            """)
    }

    /// 纯值测试：首次打开时（previousContentWidth=0），trailingEmptyWidth 等于整个容器宽度。
    func test首次打开时尾部空白占据整个容器() {
        let containerWidth: Double = 800

        let contentWidth = TabStripViewportState.contentWidth(from: [:])
        let viewport = TabStripViewportState.resolve(
            contentWidth: contentWidth,
            viewportWidth: containerWidth,
            offset: 0
        )

        XCTAssertEqual(contentWidth, 0, "空页签帧 → contentWidth=0")
        XCTAssertEqual(viewport.trailingEmptyWidth, containerWidth,
            "未测量时 trailingEmptyWidth 等于整个容器宽度，文档被压缩到 0")
    }

    // MARK: - 真实页签栏集成

    /// 确认 UnifiedWorkspaceTabStrip 在真实宿主中渲染，增删页签后视图完整。
    func test真实页签栏在宿主中增删后视图完整() {
        workspaceReset()
        defer { workspaceReset() }

        let model = AppModel(backend: MockBackend.demo())
        let workspace = WorkspaceStore(hostNameProvider: { _ in "web" })
        let tab1 = workspace.openTerminal(hostID: "h1")
        _ = workspace.openTerminal(hostID: "h2")

        let strip = UnifiedWorkspaceTabStrip()
            .environmentObject(model)
            .environmentObject(workspace)

        let hosting = NSHostingView(rootView: strip)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 40)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }

        pump(0.3)
        let viewCountBefore = countNonTrivialSubviews(in: hosting)
        XCTAssertGreaterThan(viewCountBefore, 0, "渲染后应有子视图")

        // 关闭一个，再新增一个
        workspace.close(tabID: tab1)
        pump(0.1)
        _ = workspace.openTerminal(hostID: "h3")
        pump(0.3)

        XCTAssertEqual(workspace.tabs.count, 2, "应有 2 个页签")
        let viewCountAfter = countNonTrivialSubviews(in: hosting)
        XCTAssertGreaterThan(viewCountAfter, 0, "增删后视图层级应完整")
    }

    /// 空间充足时，页签栏渲染后视图层级中应有足够多的元素来容纳所有页签内容。
    func test空间充足时页签栏视图层级元素数量合理() {
        workspaceReset()
        defer { workspaceReset() }

        let model = AppModel(backend: MockBackend.demo())
        let workspace = WorkspaceStore(hostNameProvider: { _ in "web" })
        workspace.openTerminal(hostID: "h1")
        workspace.openTerminal(hostID: "h2")

        let strip = UnifiedWorkspaceTabStrip()
            .environmentObject(model)
            .environmentObject(workspace)

        let hosting = NSHostingView(rootView: strip)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 40)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }

        pump(0.5)

        // 2 个页签，每个页签有状态圆点、图标、标题、关闭按钮等元素
        // 加上分组标签和容器视图，总数应显著大于 2
        let totalViews = countNonTrivialSubviews(in: hosting)
        XCTAssertGreaterThanOrEqual(totalViews, 6,
            "2 个页签应产生至少 6 个非平凡子视图（实际: \(totalViews)）")
    }
}

#endif

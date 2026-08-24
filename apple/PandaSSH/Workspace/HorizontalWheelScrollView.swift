import SwiftUI

#if os(macOS)
/// 页签滚动边界的纯值快照。所有输入先归一化，避免窗口动画或尚未布局时
/// 出现负宽度、非有限值与越界偏移。
struct TabBarScrollMetrics: Equatable {
    enum PageDirection {
        case backward
        case forward
    }

    static let revealPadding = 8.0

    let contentWidth: Double
    let viewportWidth: Double
    let offset: Double
    let maximumOffset: Double

    var needsScroll: Bool {
        viewportWidth > 0 && maximumOffset > 0.5
    }

    var canScrollBackward: Bool {
        needsScroll && offset > 0.5
    }

    var canScrollForward: Bool {
        needsScroll && offset < maximumOffset - 0.5
    }

    static func resolve(
        contentWidth: Double,
        viewportWidth: Double,
        offset: Double
    ) -> TabBarScrollMetrics {
        let safeContentWidth = finiteNonnegative(contentWidth)
        let safeViewportWidth = finiteNonnegative(viewportWidth)
        let maximumOffset = max(0, safeContentWidth - safeViewportWidth)
        let safeOffset = clamp(
            offset.isFinite ? offset : 0,
            lower: 0,
            upper: maximumOffset
        )
        return TabBarScrollMetrics(
            contentWidth: safeContentWidth,
            viewportWidth: safeViewportWidth,
            offset: safeOffset,
            maximumOffset: maximumOffset
        )
    }

    func pageTarget(direction: PageDirection) -> Double {
        let delta = direction == .backward ? -viewportWidth : viewportWidth
        return Self.clamp(offset + delta, lower: 0, upper: maximumOffset)
    }

    /// AppKit 的滚轮 delta 为正时内容应向起点移动，因此这里使用 `offset - delta`。
    func wheelTarget(delta: Double) -> Double {
        guard delta.isFinite else { return offset }
        return Self.clamp(offset - delta, lower: 0, upper: maximumOffset)
    }

    /// 返回让目标页签完整可识别的最小偏移；过宽页签优先显示其前缘。
    func revealedOffset(itemMinX: Double, itemMaxX: Double) -> Double {
        guard itemMinX.isFinite, itemMaxX.isFinite, viewportWidth > 0 else { return offset }
        let lower = min(itemMinX, itemMaxX)
        let upper = max(itemMinX, itemMaxX)
        let paddedLower = max(0, lower - Self.revealPadding)
        let paddedUpper = min(contentWidth, upper + Self.revealPadding)

        if paddedUpper - paddedLower >= viewportWidth {
            return Self.clamp(paddedLower, lower: 0, upper: maximumOffset)
        }
        if paddedLower < offset {
            return Self.clamp(paddedLower, lower: 0, upper: maximumOffset)
        }
        if paddedUpper > offset + viewportWidth {
            return Self.clamp(paddedUpper - viewportWidth, lower: 0, upper: maximumOffset)
        }
        return offset
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

/// 横向滚动状态控制器：暴露滚动边界状态与按页翻页动作。
final class TabBarScrollController: ObservableObject {
    /// 内容宽度是否超出可见宽度（决定是否显示翻页按钮）
    @Published var needsScroll = false
    /// 是否还能向左翻页
    @Published var canScrollLeft = false
    /// 是否还能向右翻页
    @Published var canScrollRight = false

    var scrollLeftAction: (() -> Void)?
    var scrollRightAction: (() -> Void)?
    var revealAction: ((CGRect) -> Void)?

    private var tabFrames: [UUID: CGRect] = [:]
    private var pendingRevealTabID: UUID?

    func scrollLeft() { scrollLeftAction?() }
    func scrollRight() { scrollRightAction?() }

    func updateTabFrame(_ frame: CGRect, for tabID: UUID) {
        guard frame.minX.isFinite, frame.maxX.isFinite else { return }
        tabFrames[tabID] = frame
        if pendingRevealTabID == tabID {
            pendingRevealTabID = nil
            revealAction?(frame)
        }
    }

    func retainTabIDs(_ tabIDs: Set<UUID>) {
        tabFrames = tabFrames.filter { tabIDs.contains($0.key) }
        if let pendingRevealTabID, !tabIDs.contains(pendingRevealTabID) {
            self.pendingRevealTabID = nil
        }
    }

    func reveal(tabID: UUID) {
        if let frame = tabFrames[tabID] {
            pendingRevealTabID = nil
            revealAction?(frame)
        } else {
            pendingRevealTabID = tabID
        }
    }
}

/// 支持鼠标滚轮横向滚动的页签容器。
/// 垂直滚轮事件转为横向偏移，滚动条隐藏，高度由内容决定。
struct HorizontalWheelScrollView<Content: View>: NSViewRepresentable {
    let content: Content
    let controller: TabBarScrollController

    init(controller: TabBarScrollController, @ViewBuilder content: () -> Content) {
        self.controller = controller
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> HeightConstrainedContainer {
        let container = HeightConstrainedContainer()

        let scrollView = WheelForwardingScrollView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none

        let hostingView = NSHostingView(rootView: content)
        scrollView.documentView = hostingView

        container.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.scrollView = scrollView
        context.coordinator.hostingView = hostingView
        context.coordinator.container = container
        context.coordinator.setupScrollActions()
        context.coordinator.startObserving()

        container.contentHeight = hostingView.fittingSize.height
        return container
    }

    func updateNSView(_ nsView: HeightConstrainedContainer, context: Context) {
        guard let hostingView = context.coordinator.hostingView else { return }
        hostingView.rootView = content

        let fittingSize = hostingView.fittingSize
        nsView.contentHeight = fittingSize.height

        // document 宽度取内容理想宽度（不撑满可见宽度）：
        // 1. 内容左对齐——NSHostingView 根视图默认把内容居中放置，
        //    若 document 撑满可见宽度，少量页签会显示在页签栏中部而非左侧；
        // 2. 可滚动范围严格等于内容宽度，翻页/滚轮边界计算不受可见宽度干扰。
        let newFrame = NSRect(x: 0, y: 0, width: fittingSize.width, height: fittingSize.height)
        // frame 未变化时不重复设置，避免 frameDidChange 通知与 @Published 更新形成反馈回路。
        if hostingView.frame != newFrame {
            hostingView.frame = newFrame
        }

        context.coordinator.updateScrollState()
    }

    /// 显式向 SwiftUI 报告理想尺寸：宽度跟随父视图提议，高度取内容高度。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HeightConstrainedContainer, context: Context) -> CGSize? {
        let height = nsView.contentHeight
        let width = proposal.width ?? 100
        return CGSize(width: width, height: height)
    }

    /// 带高度报告的容器：通过 intrinsicContentSize 告诉 SwiftUI 内容高度，避免被撑满。
    final class HeightConstrainedContainer: NSView {
        var contentHeight: CGFloat = 30 {
            didSet {
                if oldValue != contentHeight {
                    invalidateIntrinsicContentSize()
                }
            }
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
        }
    }

    final class Coordinator: NSObject {
        let controller: TabBarScrollController
        var scrollView: NSScrollView?
        var hostingView: NSHostingView<Content>?
        var container: HeightConstrainedContainer?

        init(controller: TabBarScrollController) {
            self.controller = controller
        }

        func setupScrollActions() {
            controller.scrollLeftAction = { [weak self] in
                self?.scroll(byPage: -1)
            }
            controller.scrollRightAction = { [weak self] in
                self?.scroll(byPage: 1)
            }
            controller.revealAction = { [weak self] frame in
                self?.reveal(frame: frame)
            }
        }

        func startObserving() {
            guard let scrollView else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(updateScrollState),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(updateScrollState),
                name: NSView.frameDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(updateScrollState),
                name: NSView.frameDidChangeNotification,
                object: scrollView.documentView
            )
            updateScrollState()
        }

        @objc func updateScrollState() {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let metrics = TabBarScrollMetrics.resolve(
                contentWidth: Double(documentView.frame.width),
                viewportWidth: Double(scrollView.contentView.bounds.width),
                offset: Double(scrollView.contentView.bounds.origin.x)
            )

            let normalizedX = CGFloat(metrics.offset)
            if abs(scrollView.contentView.bounds.origin.x - normalizedX) > 0.5 {
                scrollView.contentView.scroll(to: NSPoint(x: normalizedX, y: 0))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            Task { @MainActor in
                if self.controller.needsScroll != metrics.needsScroll {
                    self.controller.needsScroll = metrics.needsScroll
                }
                if self.controller.canScrollLeft != metrics.canScrollBackward {
                    self.controller.canScrollLeft = metrics.canScrollBackward
                }
                if self.controller.canScrollRight != metrics.canScrollForward {
                    self.controller.canScrollRight = metrics.canScrollForward
                }
            }
        }

        /// 按页翻页：direction -1 为向左，1 为向右，自动夹取不越界。
        private func scroll(byPage direction: CGFloat) {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let metrics = TabBarScrollMetrics.resolve(
                contentWidth: Double(documentView.frame.width),
                viewportWidth: Double(scrollView.contentView.bounds.width),
                offset: Double(scrollView.contentView.bounds.origin.x)
            )
            let pageDirection: TabBarScrollMetrics.PageDirection = direction < 0 ? .backward : .forward
            scroll(to: metrics.pageTarget(direction: pageDirection))
        }

        private func reveal(frame: CGRect) {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let metrics = TabBarScrollMetrics.resolve(
                contentWidth: Double(documentView.frame.width),
                viewportWidth: Double(scrollView.contentView.bounds.width),
                offset: Double(scrollView.contentView.bounds.origin.x)
            )
            let target = metrics.revealedOffset(
                itemMinX: Double(frame.minX),
                itemMaxX: Double(frame.maxX)
            )
            scroll(to: target)
        }

        private func scroll(to target: Double) {
            guard let scrollView else { return }
            let point = NSPoint(x: CGFloat(target), y: 0)
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// 自定义 NSScrollView：把垂直滚轮事件转为横向滚动。
final class WheelForwardingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView else {
            super.scrollWheel(with: event)
            return
        }

        let contentWidth = documentView.frame.width
        let visibleWidth = contentView.bounds.width
        // 内容未超出可见宽度时，交给系统处理
        guard contentWidth > visibleWidth else {
            super.scrollWheel(with: event)
            return
        }

        // 优先取水平 delta，否则把垂直 delta 转为水平
        let delta: CGFloat
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            delta = event.scrollingDeltaX
        } else {
            delta = event.scrollingDeltaY
        }

        let metrics = TabBarScrollMetrics.resolve(
            contentWidth: Double(contentWidth),
            viewportWidth: Double(visibleWidth),
            offset: Double(contentView.bounds.origin.x)
        )
        let newX = metrics.wheelTarget(delta: Double(delta))
        contentView.scroll(to: NSPoint(x: CGFloat(newX), y: 0))
        reflectScrolledClipView(contentView)
    }
}
#endif

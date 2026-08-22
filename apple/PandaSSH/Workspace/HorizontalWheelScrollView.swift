import SwiftUI

#if os(macOS)
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

    func scrollLeft() { scrollLeftAction?() }
    func scrollRight() { scrollRightAction?() }
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
        private var pendingNeedsScroll: Bool?
        private var needsScrollWorkItem: DispatchWorkItem?

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
        }

        func startObserving() {
            guard let scrollView else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
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
                object: scrollView.documentView
            )
            updateScrollState()
        }

        @objc func updateScrollState() {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let contentWidth = documentView.frame.width
            let visibleWidth = scrollView.contentView.bounds.width
            let currentX = scrollView.contentView.bounds.origin.x

            let newNeedsScroll = contentWidth > visibleWidth
            let newCanScrollLeft = currentX > 0
            let newCanScrollRight = currentX < contentWidth - visibleWidth - 1

            Task { @MainActor in
                if self.controller.canScrollLeft != newCanScrollLeft {
                    self.controller.canScrollLeft = newCanScrollLeft
                }
                if self.controller.canScrollRight != newCanScrollRight {
                    self.controller.canScrollRight = newCanScrollRight
                }
            }

            // needsScroll 加 400ms 防抖：侧栏显隐等窗口动画期间可见宽度逐帧变化，
            // 若实时更新会让翻页按钮随动画反复显隐（闪动）；
            // 400ms 覆盖系统 split view 动画时长，动画结束后才一次性应用稳定值。
            // canScrollLeft/Right 仍实时更新（只影响禁用态，不改变按钮有无）。
            pendingNeedsScroll = newNeedsScroll
            needsScrollWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let pending = self.pendingNeedsScroll else { return }
                if self.controller.needsScroll != pending {
                    self.controller.needsScroll = pending
                }
            }
            needsScrollWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
        }

        /// 按页翻页：direction -1 为向左，1 为向右，自动夹取不越界。
        private func scroll(byPage direction: CGFloat) {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let contentWidth = documentView.frame.width
            let pageWidth = scrollView.contentView.bounds.width
            let currentX = scrollView.contentView.bounds.origin.x
            var newX = currentX + direction * pageWidth
            newX = max(0, min(newX, contentWidth - pageWidth))
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: newX, y: 0))
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

        var newX = contentView.bounds.origin.x - delta
        newX = max(0, min(newX, contentWidth - visibleWidth))

        contentView.scroll(to: NSPoint(x: newX, y: 0))
        reflectScrolledClipView(contentView)
    }
}
#endif

#if os(macOS)
import SwiftUI
import AppKit

/// macOS 窗口宿主的纯值策略。它不持有 NSWindow，便于覆盖最小窗口、全屏与侧栏状态。
struct MacOSWorkspaceChromeHostPolicy: Equatable {
    let usesTransparentTitlebar: Bool
    let usesFullSizeContent: Bool
    let usesPrincipalToolbarItem: Bool
    let usesSystemToolbar: Bool
    let providesWindowDragRegion: Bool
    let keepsStandardWindowButtonsVisible: Bool
    let leadingReservedWidth: Double
    let trailingReservedWidth: Double
    let showsSidebarRecovery: Bool

    static func resolve(
        windowWidth: Double,
        isFullScreen _: Bool,
        isSidebarVisible: Bool,
        trafficLightSafeWidth: Double
    ) -> MacOSWorkspaceChromeHostPolicy {
        let safeWidth = windowWidth.isFinite ? max(0, windowWidth) : 0
        let safeTrafficLightWidth = trafficLightSafeWidth.isFinite
            ? min(max(0, trafficLightSafeWidth), safeWidth)
            : 0
        return MacOSWorkspaceChromeHostPolicy(
            usesTransparentTitlebar: true,
            usesFullSizeContent: true,
            usesPrincipalToolbarItem: false,
            usesSystemToolbar: false,
            providesWindowDragRegion: true,
            keepsStandardWindowButtonsVisible: true,
            leadingReservedWidth: safeTrafficLightWidth,
            trailingReservedWidth: 0,
            showsSidebarRecovery: !isSidebarVisible
        )
    }
}

/// unified 路径专用的 AppKit 分栏策略。纯值部分可在不创建窗口的情况下覆盖边界输入。
struct MacOSUnifiedSplitHostPolicy: Equatable {
    let usesAppKitSplitViewController: Bool
    let isSidebarCollapsed: Bool
    let sidebarWidth: Double

    static func resolve(requestedSidebarWidth: Double, isSidebarVisible: Bool) -> Self {
        let safeWidth = requestedSidebarWidth.isFinite ? requestedSidebarWidth : 250
        return Self(
            usesAppKitSplitViewController: true,
            isSidebarCollapsed: !isSidebarVisible,
            sidebarWidth: min(max(safeWidth, 220), 400)
        )
    }

    /// 分栏位置设置判定：仅当无上次应用值（首次）或候选值与上次
    /// 应用值差超过 0.5pt 时才需要调用 `splitView.setPosition`。
    /// 高频 SwiftUI 更新重复携带同值（或亚像素抖动）时不重设分栏位置，
    /// 避免强制 NSSplitView 反复布局。
    static func shouldApplyDividerPosition(candidate: Double, appliedWidth: Double?) -> Bool {
        guard candidate.isFinite else { return false }
        guard let appliedWidth else { return true }
        return abs(candidate - appliedWidth) > 0.5
    }
}

/// macOS unified 路径的原生分栏容器。
/// 它只接管 AppKit 的分栏几何；两列实际内容仍是共享 SwiftUI 视图。
struct MacOSUnifiedSplitHost<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    let sidebar: Sidebar
    let detail: Detail
    let policy: MacOSUnifiedSplitHostPolicy

    func makeNSViewController(context _: Context) -> Controller {
        Controller(sidebar: AnyView(sidebar), detail: AnyView(detail), policy: policy)
    }

    func updateNSViewController(_ controller: Controller, context _: Context) {
        controller.update(sidebar: AnyView(sidebar), detail: AnyView(detail), policy: policy)
    }

    final class Controller: NSSplitViewController {
        private let sidebarHost: NSHostingController<AnyView>
        private let detailHost: NSHostingController<AnyView>
        private let sidebarItem: NSSplitViewItem
        /// 上次真正下发到 `splitView.setPosition` 的侧栏宽度。
        /// 高频 SwiftUI 更新重复携带同值时据此跳过重设，避免强制布局。
        private var appliedSidebarWidth: Double?

        init(sidebar: AnyView, detail: AnyView, policy: MacOSUnifiedSplitHostPolicy) {
            sidebarHost = NSHostingController(rootView: sidebar)
            detailHost = NSHostingController(rootView: detail)
            // 顶部 chrome 已在父级结算标题栏；侧栏不能再次继承窗口安全区，
            // 否则会在搜索框前产生无控件的系统栏头空白。
            sidebarHost.safeAreaRegions = []
            // 不使用 sidebarWithViewController：该便利构造器会额外插入系统栏头，
            // 与统一顶部 chrome 叠加后正是侧栏搜索框上方的空白。
            sidebarItem = NSSplitViewItem(viewController: sidebarHost)
            super.init(nibName: nil, bundle: nil)
            splitView.isVertical = true
            addSplitViewItem(sidebarItem)
            addSplitViewItem(NSSplitViewItem(viewController: detailHost))
            apply(policy)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        func update(sidebar: AnyView, detail: AnyView, policy: MacOSUnifiedSplitHostPolicy) {
            sidebarHost.rootView = sidebar
            detailHost.rootView = detail
            apply(policy)
        }

        private func apply(_ policy: MacOSUnifiedSplitHostPolicy) {
            sidebarItem.minimumThickness = 220
            sidebarItem.maximumThickness = 400
            sidebarItem.isCollapsed = policy.isSidebarCollapsed
            guard !policy.isSidebarCollapsed, splitView.subviews.count > 1 else { return }
            guard MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: policy.sidebarWidth,
                appliedWidth: appliedSidebarWidth
            ) else { return }
            splitView.setPosition(CGFloat(policy.sidebarWidth), ofDividerAt: 0)
            appliedSidebarWidth = policy.sidebarWidth
        }
    }
}

/// macOS 专用窗口 chrome 状态。仅保存宿主实测的几何数据，不承载页签或会话。
final class MacOSWorkspaceChromeMetrics: ObservableObject {
    @Published private(set) var trafficLightSafeWidth: Double = 76
    @Published private(set) var sidebarWidth: Double = 250

    func update(window: NSWindow) {
        let fallback = min(76, max(0, window.frame.width))
        guard let contentView = window.contentView,
              let zoomButton = window.standardWindowButton(.zoomButton) else {
            // 值不变不赋值：@Published 无条件赋值会形成「发布 → 重渲染 → 再发布」自激环
            guard trafficLightSafeWidth != fallback else { return }
            trafficLightSafeWidth = fallback
            return
        }
        let frame = zoomButton.convert(zoomButton.bounds, to: contentView)
        let width = min(
            max(0, Double(frame.maxX) + 12),
            max(0, Double(window.frame.width))
        )
        guard trafficLightSafeWidth != width else { return }
        trafficLightSafeWidth = width
    }

    func updateSidebarWidth(_ width: Double) {
        guard width.isFinite, width > 0 else { return }
        guard sidebarWidth != width else { return }
        sidebarWidth = width
    }
}

/// 主窗口 chrome 由 AppKit 接管标题栏安全区和唯一顶行的窗口属性。
/// 不保留工作区系统 toolbar，避免与自绘页签栏形成第二行 chrome。
struct MainWindowChrome: NSViewRepresentable {
    @ObservedObject var metrics: MacOSWorkspaceChromeMetrics

    func makeCoordinator() -> Coordinator { Coordinator(metrics: metrics) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    final class Coordinator {
        private let metrics: MacOSWorkspaceChromeMetrics
        private weak var observedWindow: NSWindow?
        private var observations: [NSObjectProtocol] = []
        /// 已禁用内容视图的自动窗口拖动；空白区由 WindowDragView 手动 performDrag。
        private var didDisableHostingViewDrag = false

        init(metrics: MacOSWorkspaceChromeMetrics) {
            self.metrics = metrics
        }

        deinit {
            observations.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to window: NSWindow?) {
            if observedWindow !== window {
                observations.forEach(NotificationCenter.default.removeObserver)
                observations = []
                // 窗口切换时重置标记，确保新窗口也会禁用自动拖窗。
                didDisableHostingViewDrag = false
            }
            defer { observedWindow = window }
            guard let window else { return }
            if observedWindow !== window {
                observations = [
                    NSWindow.didResizeNotification,
                    NSWindow.didEnterFullScreenNotification,
                    NSWindow.didExitFullScreenNotification,
                    NSWindow.didBecomeKeyNotification,
                    NSWindow.didResignKeyNotification
                ].map { notification in
                    NotificationCenter.default.addObserver(
                        forName: notification,
                        object: window,
                        queue: .main
                    ) { [weak self, weak window] _ in
                        guard let self, let window, self.observedWindow === window else { return }
                        self.configure(window)
                    }
                }
                observedWindow = window
            }
            configure(window)
        }

        private func configure(_ window: NSWindow) {
            let policy = MacOSWorkspaceChromeHostPolicy.resolve(
                windowWidth: window.frame.width,
                isFullScreen: window.styleMask.contains(.fullScreen),
                isSidebarVisible: true,
                trafficLightSafeWidth: metrics.trafficLightSafeWidth
            )
            // SwiftUI 状态更新和焦点变化都会到达这里。重复调用窗口 setter
            // 仍可能触发 AppKit 重建标题栏，因此以实际属性逐项校正。
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if window.titlebarAppearsTransparent != policy.usesTransparentTitlebar {
                window.titlebarAppearsTransparent = policy.usesTransparentTitlebar
            }
            if policy.usesFullSizeContent && !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if !policy.usesSystemToolbar && window.toolbar != nil {
                window.toolbar = nil
            }
            if policy.keepsStandardWindowButtonsVisible {
                restoreStandardWindowButtons(in: window)
            }
            // 禁用 NSHostingView 的自动窗口拖动，防止页签拖放时窗口跟随移动。
            // 空白区拖窗由 WindowDragView 通过 window.performDrag(with:) 手动处理。
            if !didDisableHostingViewDrag {
                disableHostingViewWindowDrag(in: window)
                didDisableHostingViewDrag = true
            }
            metrics.update(window: window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.observedWindow === window else { return }
                self.restoreStandardWindowButtons(in: window)
                self.metrics.update(window: window)
            }
        }

        private func restoreStandardWindowButtons(in window: NSWindow) {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                if button.isHidden { button.isHidden = false }
                if button.alphaValue != 1 { button.alphaValue = 1 }
                if !button.isEnabled { button.isEnabled = true }
                if let container = button.superview, container.isHidden {
                    container.isHidden = false
                }
            }
        }

        /// 查找窗口内容视图层级中的 NSHostingView 并禁用自动窗口拖动。
        /// 页签按钮的 `.onDrag` 使用独立的拖拽会话，不受此属性影响。
        private func disableHostingViewWindowDrag(in window: NSWindow) {
            guard let contentView = window.contentView else { return }
            // mouseDownCanMoveWindow 是只读属性，需通过 ObjC 运行时创建子类覆盖。
            // 将内容视图的 isa 替换为返回 false 的子类，阻止 AppKit 自动窗口拖动。
            // mouseDown 仍转发给子视图，确保 SwiftUI 手势（含 .onDrag）正常工作。
            let subclass: AnyClass = NoWindowDragContentView.ensureSubclass(
                basedOn: type(of: contentView)
            )
            object_setClass(contentView, subclass)
        }

    }
}

/// 顶部自绘区域的空白拖窗区。
/// 它自行处理鼠标按下：单击显式拖动窗口，双击执行标准缩放/还原。
/// 不使用 mouseDownCanMoveWindow，避免事件被传给上层窗口后与页签拖放竞争。
struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        /// 测试注入点：非 nil 时替代窗口 performZoom 调用。
        var performZoomAction: (() -> Void)?
        /// 测试注入点：非 nil 时替代窗口的系统拖动调用。
        var performWindowDragAction: ((NSEvent) -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2, let window, window.standardWindowButton(.zoomButton) != nil {
                performZoomAction?()
                if performZoomAction == nil {
                    window.performZoom(nil)
                }
                return
            }
            guard let window else { return }
            if let performWindowDragAction {
                performWindowDragAction(event)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// 通过 ObjC 运行时动态创建的 NSView 子类，覆盖 `mouseDownCanMoveWindow` 返回 false。
/// 用于将窗口内容视图的 isa 替换为该类，阻止 AppKit 在非空白区自动拖动窗口。
/// 继承自内容视图的实际类（NSHostingView），保留所有既有方法。
private enum NoWindowDragContentView {
    private static var registeredSubclass: AnyClass?

    static func ensureSubclass(basedOn superclass: AnyClass) -> AnyClass {
        if let existing = registeredSubclass { return existing }
        let name = "PandaNoWindowDragContentView"
        guard let subclass = objc_allocateClassPair(superclass, name, 0) else {
            return superclass
        }
        let block: @convention(block) (Any) -> Bool = { _ in false }
        let imp = imp_implementationWithBlock(block)
        let selector = #selector(getter: NSView.mouseDownCanMoveWindow)
        class_addMethod(subclass, selector, imp, "B16@0:8")
        objc_registerClassPair(subclass)
        registeredSubclass = subclass
        return subclass
    }
}
#endif

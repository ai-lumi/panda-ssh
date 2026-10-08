// =============================================================================
// MainWindowChrome.swift — macOS 主窗口 Chrome（标题栏/分栏/拖拽）管理
//
// 本文件负责 macOS 平台下主窗口的「外壳」行为，包括：
//   1. 透明标题栏、全屏内容视图、隐藏系统工具栏等窗口外观策略
//   2. 基于 AppKit NSSplitViewController 的原生左右分栏容器（侧栏 + 详情）
//   3. 红绿灯（关闭/最小化/缩放）按钮区域的安全宽度测量
//   4. 窗口空白区域的手动拖拽与双击缩放
//   5. 通过公开窗口属性禁用背景隐式拖动
//
// 所有这些仅在 macOS 下生效（#if os(macOS)），iPadOS 不涉及窗口 chrome。
// =============================================================================

// 仅在 macOS 平台编译以下内容
#if os(macOS)
// 引入 SwiftUI 框架，用于构建用户界面
import SwiftUI
// 引入 AppKit 框架，用于操作原生 macOS 窗口和视图
import AppKit

/// macOS 窗口宿主的纯值策略。它不持有 NSWindow，便于覆盖最小窗口、全屏与侧栏状态。
/// 这是一个纯数据模型（struct），描述窗口应该呈现哪些外观特征，不包含任何 UI 引用。
struct MacOSWorkspaceChromeHostPolicy: Equatable {
    /// 是否使用透明标题栏（标题栏背景透明，内容视图可以延伸到标题栏区域）
    let usesTransparentTitlebar: Bool
    /// 是否让内容视图扩展到整个窗口（包括原本属于标题栏的区域）
    let usesFullSizeContent: Bool
    /// 是否使用系统主工具栏项（toolbar 中的 principal 位置）
    let usesPrincipalToolbarItem: Bool
    /// 是否显示系统工具栏（macOS 窗口顶部的标准工具栏条）
    let usesSystemToolbar: Bool
    /// 是否提供窗口拖拽区域（允许用户通过空白区域拖动窗口）
    let providesWindowDragRegion: Bool
    /// 是否保持红绿灯按钮（关闭/最小化/缩放）可见
    let keepsStandardWindowButtonsVisible: Bool
    /// 左侧预留宽度（像素），用于避让红绿灯按钮，防止内容被遮挡
    let leadingReservedWidth: Double
    /// 右侧预留宽度（像素），用于避让窗口右侧控件
    let trailingReservedWidth: Double
    /// 是否显示侧栏恢复按钮（当侧栏被隐藏时显示一个按钮让用户恢复侧栏）
    let showsSidebarRecovery: Bool

    /// 根据当前窗口状态计算出一套窗口外观策略（纯值，不涉及 UI 操作）
    /// - Parameters:
    ///   - windowWidth: 当前窗口宽度（像素）
    ///   - isFullScreen: 是否处于全屏模式（全屏时标题栏隐藏，策略不同）
    ///   - isSidebarVisible: 侧栏是否可见（决定是否显示恢复按钮）
    ///   - trafficLightSafeWidth: 红绿灯按钮区域的安全宽度（内容需要避让的宽度）
    static func resolve(
        windowWidth: Double,
        isFullScreen _: Bool,
        isSidebarVisible: Bool,
        trafficLightSafeWidth: Double
    ) -> MacOSWorkspaceChromeHostPolicy {
        // 将窗口宽度钳制到合法范围：如果是有限值则取 max(0, windowWidth)，否则为 0
        let safeWidth = windowWidth.isFinite ? max(0, windowWidth) : 0
        // 将红绿灯安全宽度钳制到 [0, safeWidth] 范围内，防止超出窗口宽度
        let safeTrafficLightWidth = trafficLightSafeWidth.isFinite
            ? min(max(0, trafficLightSafeWidth), safeWidth)
            : 0
        return MacOSWorkspaceChromeHostPolicy(
            // 启用透明标题栏，让窗口看起来更现代
            usesTransparentTitlebar: true,
            // 内容视图延伸到标题栏区域，实现统一顶部外观
            usesFullSizeContent: true,
            // 不使用系统 principal 工具栏项
            usesPrincipalToolbarItem: false,
            // 不显示系统工具栏（由自绘顶栏替代）
            usesSystemToolbar: false,
            // 启用手动窗口拖拽区域
            providesWindowDragRegion: true,
            // 保持红绿灯按钮可见
            keepsStandardWindowButtonsVisible: true,
            // 左侧预留红绿灯区域的宽度
            leadingReservedWidth: safeTrafficLightWidth,
            // 右侧不预留空间
            trailingReservedWidth: 0,
            // 侧栏不可见时显示恢复按钮
            showsSidebarRecovery: !isSidebarVisible
        )
    }
}

/// unified 路径专用的 AppKit 分栏策略。纯值部分可在不创建窗口的情况下覆盖边界输入。
/// 描述 NSSplitViewController（左右分栏）的配置：是否使用原生分栏、侧栏是否折叠、侧栏宽度。
struct MacOSUnifiedSplitHostPolicy: Equatable {
    /// 是否使用 AppKit 的 NSSplitViewController 来管理分栏（true = 使用原生分栏）
    let usesAppKitSplitViewController: Bool
    /// 侧栏是否处于折叠（隐藏）状态
    let isSidebarCollapsed: Bool
    /// 侧栏的宽度（像素），会被钳制到 [220, 400] 范围内
    let sidebarWidth: Double

    /// 根据请求的侧栏宽度和可见性，计算实际的分栏策略
    /// - Parameters:
    ///   - requestedSidebarWidth: 用户请求的侧栏宽度
    ///   - isSidebarVisible: 侧栏是否可见
    static func resolve(requestedSidebarWidth: Double, isSidebarVisible: Bool) -> Self {
        // 如果请求宽度不是有限值（如 NaN 或无穷大），则使用默认值 250
        let safeWidth = requestedSidebarWidth.isFinite ? requestedSidebarWidth : 250
        return Self(
            // 始终使用原生分栏控制器
            usesAppKitSplitViewController: true,
            // 不可见 = 折叠
            isSidebarCollapsed: !isSidebarVisible,
            // 将宽度钳制到 220~400 像素之间
            sidebarWidth: min(max(safeWidth, 220), 400)
        )
    }

    /// 分栏位置设置判定：仅当无上次应用值（首次）或候选值与上次
    /// 应用值差超过 0.5pt 时才需要调用 `splitView.setPosition`。
    /// 高频 SwiftUI 更新重复携带同值（或亚像素抖动）时不重设分栏位置，
    /// 避免强制 NSSplitView 反复布局。
    /// - Parameters:
    ///   - candidate: 本次想要设置的侧栏宽度
    ///   - appliedWidth: 上次实际已设置的侧栏宽度（nil 表示首次设置）
    /// - Returns: 是否需要调用 setPosition 来更新分栏位置
    static func shouldApplyDividerPosition(candidate: Double, appliedWidth: Double?) -> Bool {
        // 候选值无效（NaN/无穷大）则跳过
        guard candidate.isFinite else { return false }
        // 首次设置（没有上次值），必须应用
        guard let appliedWidth else { return true }
        // 差值超过 0.5 像素才应用，避免亚像素抖动
        return abs(candidate - appliedWidth) > 0.5
    }
}

/// macOS unified 路径的原生分栏容器。
/// 它只接管 AppKit 的分栏几何；两列实际内容仍是共享 SwiftUI 视图。
/// 这是一个 NSViewControllerRepresentable，将 AppKit 的 NSSplitViewController 桥接到 SwiftUI 中使用。
/// 泛型参数 Sidebar 和 Detail 分别是侧栏和详情区域的 SwiftUI 视图类型。
struct MacOSUnifiedSplitHost<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    /// 侧栏的 SwiftUI 视图内容
    let sidebar: Sidebar
    /// 详情区域的 SwiftUI 视图内容
    let detail: Detail
    /// 分栏策略（宽度、是否折叠等配置）
    let policy: MacOSUnifiedSplitHostPolicy

    // NSHostingController 会切断 SwiftUI 环境对象传递链，
    // 必须在 representable 层显式持有所有环境依赖，
    // 再手动注入到 NSHostingController 的 rootView 上。
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var toast: ToastCenter
    @EnvironmentObject private var chromeMetrics: MacOSWorkspaceChromeMetrics
    @Environment(\.transferStore) private var transfers

    /// 用所有环境依赖包装 rootView，供 NSHostingController 继承。
    private func wrapEnvironment<V: View>(_ view: V) -> AnyView {
        AnyView(
            view
                .environmentObject(model)
                .environmentObject(workspace)
                .environmentObject(toast)
                .environmentObject(chromeMetrics)
                .environment(\.transferStore, transfers)
        )
    }

    /// 首次创建 AppKit 控制器时调用，初始化分栏控制器
    func makeNSViewController(context _: Context) -> Controller {
        Controller(
            sidebar: wrapEnvironment(sidebar),
            detail: wrapEnvironment(detail),
            policy: policy
        )
    }

    /// SwiftUI 状态变化时调用，更新控制器中的视图内容和分栏策略
    func updateNSViewController(_ controller: Controller, context _: Context) {
        controller.update(
            sidebar: wrapEnvironment(sidebar),
            detail: wrapEnvironment(detail),
            policy: policy
        )
    }

    /// 内部控制器类，继承自 NSSplitViewController，管理实际的左右分栏布局
    final class Controller: NSSplitViewController {
        /// 侧栏的 NSHostingController，将 SwiftUI 视图嵌入到 AppKit 视图层级中
        private let sidebarHost: NSHostingController<AnyView>
        /// 详情区域的 NSHostingController
        private let detailHost: NSHostingController<AnyView>
        /// 侧栏对应的分栏项（NSSplitViewItem），用于控制侧栏的最小/最大宽度和折叠状态
        private let sidebarItem: NSSplitViewItem
        /// 上次真正下发到 `splitView.setPosition` 的侧栏宽度。
        /// 高频 SwiftUI 更新重复携带同值时据此跳过重设，避免强制布局。
        private var appliedSidebarWidth: Double?

        /// 初始化分栏控制器，设置左右两列内容
        init(sidebar: AnyView, detail: AnyView, policy: MacOSUnifiedSplitHostPolicy) {
            // 用 SwiftUI 视图创建 NSHostingController（AppKit 与 SwiftUI 的桥梁）
            sidebarHost = NSHostingController(rootView: sidebar)
            detailHost = NSHostingController(rootView: detail)
            // 顶部 chrome 已在父级结算标题栏；侧栏不能再次继承窗口安全区，
            // 否则会在搜索框前产生无控件的系统栏头空白。
            // safeAreaRegions = [] 表示侧栏不继承窗口的安全区域（顶部刘海/标题栏区域）
            sidebarHost.safeAreaRegions = []
            // 不使用 sidebarWithViewController：该便利构造器会额外插入系统栏头，
            // 与统一顶部 chrome 叠加后正是侧栏搜索框上方的空白。
            // 手动创建普通的 NSSplitViewItem 来避免系统栏头
            sidebarItem = NSSplitViewItem(viewController: sidebarHost)
            // 调用父类初始化，不使用 nib 文件
            super.init(nibName: nil, bundle: nil)
            // 设置为垂直分栏（左右布局，而非上下布局）
            splitView.isVertical = true
            // 添加侧栏分栏项（左侧）
            addSplitViewItem(sidebarItem)
            // 添加详情分栏项（右侧）
            addSplitViewItem(NSSplitViewItem(viewController: detailHost))
            // 应用初始分栏策略（宽度、折叠状态等）
            apply(policy)
        }

        // 标记为不可用，禁止从 storyboard/nib 初始化
        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// 当 SwiftUI 状态变化时，更新视图内容和分栏策略
        func update(sidebar: AnyView, detail: AnyView, policy: MacOSUnifiedSplitHostPolicy) {
            // 更新侧栏的 SwiftUI 视图
            sidebarHost.rootView = sidebar
            // 更新详情区域的 SwiftUI 视图
            detailHost.rootView = detail
            // 重新应用分栏策略
            apply(policy)
        }

        /// 将分栏策略应用到实际的分栏控制器上
        private func apply(_ policy: MacOSUnifiedSplitHostPolicy) {
            // 侧栏最小宽度 220 像素，防止侧栏被拖得太窄
            sidebarItem.minimumThickness = 220
            // 侧栏最大宽度 400 像素，防止侧栏占据太多空间
            sidebarItem.maximumThickness = 400
            // 设置侧栏是否折叠（隐藏）
            sidebarItem.isCollapsed = policy.isSidebarCollapsed
            // 如果侧栏已折叠或分栏子视图不足，则不需要设置分栏位置
            guard !policy.isSidebarCollapsed, splitView.subviews.count > 1 else { return }
            // 检查是否需要更新分栏位置（避免高频重复设置相同值导致性能问题）
            guard MacOSUnifiedSplitHostPolicy.shouldApplyDividerPosition(
                candidate: policy.sidebarWidth,
                appliedWidth: appliedSidebarWidth
            ) else { return }
            // 设置分栏分隔线的位置，即侧栏的实际宽度
            splitView.setPosition(CGFloat(policy.sidebarWidth), ofDividerAt: 0)
            // 记录本次设置的宽度，下次用于比较是否需要更新
            appliedSidebarWidth = policy.sidebarWidth
        }
    }
}

/// macOS 专用窗口 chrome 状态。仅保存宿主实测的几何数据，不承载页签或会话。
/// 这是一个 ObservableObject（可观察对象），当属性变化时会自动通知 SwiftUI 刷新相关视图。
final class MacOSWorkspaceChromeMetrics: ObservableObject {
    /// 红绿灯按钮区域的安全宽度（像素），内容视图需要在此宽度右侧开始，避免被红绿灯遮挡。
    /// @Published 表示当此值变化时，所有观察此对象的视图会自动刷新。
    /// private(set) 表示外部只能读取、不能修改此值（封装性）。
    // 默认值 76 像素（约覆盖三个红绿灯按钮）
    @Published private(set) var trafficLightSafeWidth: Double = 76
    /// 当前侧栏的实际宽度（像素），由 GeometryReader 测量后上报
    // 默认侧栏宽度 250 像素
    @Published private(set) var sidebarWidth: Double = 250

    /// 根据窗口的实际尺寸更新红绿灯安全宽度
    /// - Parameter window: 当前需要测量的 NSWindow 对象
    func update(window: NSWindow) {
        // 计算备用值：取 76 和窗口宽度的较小值，确保不超过窗口宽度
        let fallback = min(76, max(0, window.frame.width))
        // 尝试获取窗口的内容视图和缩放按钮（绿色全屏按钮）
        guard let contentView = window.contentView,
              let zoomButton = window.standardWindowButton(.zoomButton) else {
            // 值不变不赋值：@Published 无条件赋值会形成「发布 → 重渲染 → 再发布」自激环
            // 如果新值与旧值相同，则跳过赋值，避免触发不必要的视图刷新
            guard trafficLightSafeWidth != fallback else { return }
            // 使用备用值
            trafficLightSafeWidth = fallback
            return
        }
        // 将缩放按钮的坐标系从自身转换到内容视图坐标系，获取按钮右边缘的位置
        let frame = zoomButton.convert(zoomButton.bounds, to: contentView)
        // 计算安全宽度：按钮右边缘 + 12 像素间距，但不超过窗口宽度
        let width = min(
            // 按钮右边缘 + 12px 间距
            max(0, Double(frame.maxX) + 12),
            // 不超过窗口宽度
            max(0, Double(window.frame.width))
        )
        // 仅当值确实变化时才赋值，避免 @Published 的自激刷新循环
        guard trafficLightSafeWidth != width else { return }
        trafficLightSafeWidth = width
    }

    /// 更新侧栏宽度记录（由 GeometryReader 测量后调用）
    /// - Parameter width: 测量到的侧栏实际宽度
    func updateSidebarWidth(_ width: Double) {
        // 仅接受有效的正数宽度
        guard width.isFinite, width > 0 else { return }
        // 仅当值确实变化时才赋值，避免不必要的视图刷新
        guard sidebarWidth != width else { return }
        sidebarWidth = width
    }
}

/// 主窗口 chrome 由 AppKit 接管标题栏安全区和唯一顶行的窗口属性。
/// 不保留工作区系统 toolbar，避免与自绘页签栏形成第二行 chrome。
/// 这是一个 NSViewRepresentable，将一个空的 NSView 嵌入 SwiftUI 视图树中，
/// 通过其 Coordinator 来操控宿主窗口的标题栏外观和行为。
struct MainWindowChrome: NSViewRepresentable {
    /// 窗口度量数据（红绿灯宽度、侧栏宽度等），以观察模式订阅，变化时触发刷新
    @ObservedObject var metrics: MacOSWorkspaceChromeMetrics

    /// 创建协调器（Coordinator），负责实际操控 NSWindow 的生命周期
    func makeCoordinator() -> Coordinator { Coordinator(metrics: metrics) }

    /// 首次创建 NSView 时调用：创建一个空视图，并在主队列异步将协调器附加到宿主窗口
    func makeNSView(context: Context) -> NSView {
        // 创建一个空的 NSView（仅作为窗口操作的锚点）
        let view = NSView()
        // 异步执行：确保视图已经挂载到窗口上后再操作窗口属性
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    /// SwiftUI 状态变化导致视图更新时调用：重新确保协调器已附加到当前窗口
    func updateNSView(_ nsView: NSView, context: Context) {
        // 异步执行：确保视图层级已更新完毕后再操作窗口
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    /// 当 NSView 从视图树中移除时调用：断开协调器与窗口的连接，清理通知监听
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // 传入 nil 表示断开与窗口的连接
        coordinator.attach(to: nil)
    }

    /// 协调器类：负责实际操控 NSWindow 的标题栏配置、通知监听和窗口属性管理
    final class Coordinator {
        /// 窗口度量数据引用，用于更新红绿灯安全宽度等测量值
        private let metrics: MacOSWorkspaceChromeMetrics
        /// 当前正在监听的窗口（weak 引用，窗口关闭后自动变为 nil）
        private weak var observedWindow: NSWindow?
        /// 已注册的 NotificationCenter 观察者列表，用于在窗口切换时统一移除
        private var observations: [NSObjectProtocol] = []

        init(metrics: MacOSWorkspaceChromeMetrics) {
            self.metrics = metrics
        }

        /// 对象销毁时自动移除所有通知监听，防止内存泄漏
        deinit {
            observations.forEach(NotificationCenter.default.removeObserver)
        }

        /// 将协调器附加到指定窗口（或从窗口断开）
        /// - Parameter window: 目标窗口，nil 表示断开连接
        func attach(to window: NSWindow?) {
            // 如果目标窗口与当前监听窗口不同，需要清理旧的监听
            if observedWindow !== window {
                // 移除所有旧通知监听
                observations.forEach(NotificationCenter.default.removeObserver)
                // 清空监听列表
                observations = []
            }
            // 方法结束后更新记录的窗口引用
            defer { observedWindow = window }
            // 如果窗口为 nil，直接返回
            guard let window else { return }
            if observedWindow !== window {
                // 首次连接到新窗口：注册窗口事件通知监听
                observations = [
                    // 窗口大小改变时
                    NSWindow.didResizeNotification,
                    // 进入全屏时
                    NSWindow.didEnterFullScreenNotification,
                    // 退出全屏时
                    NSWindow.didExitFullScreenNotification,
                    // 窗口获得焦点时
                    NSWindow.didBecomeKeyNotification,
                    // 窗口失去焦点时
                    NSWindow.didResignKeyNotification
                ].map { notification in
                    // 为每种通知注册一个观察者，触发时重新配置窗口
                    NotificationCenter.default.addObserver(
                        forName: notification,
                        // 只监听目标窗口的通知
                        object: window,
                        // 在主线程处理通知
                        queue: .main
                    ) { [weak self, weak window] _ in
                        // 使用 weak 引用避免循环引用；检查窗口仍然是当前监听的窗口
                        guard let self, let window, self.observedWindow === window else { return }
                        // 重新配置窗口属性
                        self.configure(window)
                    }
                }
                // 记录当前监听的窗口
                observedWindow = window
            }
            // 立即执行一次配置
            configure(window)
        }

        /// 配置窗口的标题栏外观和行为（幂等操作，重复调用效果一致）
        private func configure(_ window: NSWindow) {
            // 根据当前窗口状态计算外观策略
            let policy = MacOSWorkspaceChromeHostPolicy.resolve(
                windowWidth: window.frame.width,
                isFullScreen: window.styleMask.contains(.fullScreen),
                isSidebarVisible: true,
                trafficLightSafeWidth: metrics.trafficLightSafeWidth
            )
            // SwiftUI 状态更新和焦点变化都会到达这里。重复调用窗口 setter
            // 仍可能触发 AppKit 重建标题栏，因此以实际属性逐项校正。
            // 仅当属性值与期望不同时才设置，避免不必要的 AppKit 重建
            if window.titleVisibility != .hidden {
                // 隐藏系统标题栏文字
                window.titleVisibility = .hidden
            }
            if window.titlebarAppearsTransparent != policy.usesTransparentTitlebar {
                // 设置标题栏透明
                window.titlebarAppearsTransparent = policy.usesTransparentTitlebar
            }
            if policy.usesFullSizeContent && !window.styleMask.contains(.fullSizeContentView) {
                // 让内容视图延伸到标题栏区域
                window.styleMask.insert(.fullSizeContentView)
            }
            if !policy.usesSystemToolbar && window.toolbar != nil {
                // 移除系统工具栏（由自绘顶栏替代）
                window.toolbar = nil
            }
            if policy.keepsStandardWindowButtonsVisible {
                // 确保红绿灯按钮可见
                restoreStandardWindowButtons(in: window)
            }
            // 保留 SwiftUI/AppKit 管理的宿主类型及 KVO；只关闭背景隐式拖窗。
            // 空白区域仍由 WindowDragView 显式调用 performDrag。
            if window.isMovableByWindowBackground {
                window.isMovableByWindowBackground = false
            }
            // swizzle AppKitWindowHostingView.mouseDownCanMoveWindow → false
            pandaSwizzleMouseDownCanMoveWindow(in: window.contentView)
            // 测量并更新红绿灯安全宽度
            metrics.update(window: window)
            // 异步再执行一次：某些窗口属性在首次配置后可能发生变化（如按钮位置）
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.observedWindow === window else { return }
                // 再次确保红绿灯按钮可见
                self.restoreStandardWindowButtons(in: window)
                // 再次测量更新
                self.metrics.update(window: window)
            }
        }

        /// 恢复窗口标准按钮（关闭、最小化、缩放）的可见性和可用性
        /// AppKit 在某些情况下可能隐藏或禁用这些按钮，此方法确保它们始终可见
        private func restoreStandardWindowButtons(in window: NSWindow) {
            // 遍历三种标准窗口按钮：关闭（红）、最小化（黄）、缩放（绿）
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                // 确保按钮可见
                if button.isHidden { button.isHidden = false }
                // 确保按钮完全不透明
                if button.alphaValue != 1 { button.alphaValue = 1 }
                // 确保按钮可点击
                if !button.isEnabled { button.isEnabled = true }
                // 某些 macOS 版本会将按钮放在一个容器视图中，也需要确保容器可见
                if let container = button.superview, container.isHidden {
                    container.isHidden = false
                }
            }
        }
    }
}

// MARK: - 阻断 AppKit 默认窗口拖拽的透明 NSView
// -----------------------------------------------------------------------------
// 用法：在需要阻断 AppKit 默认窗口拖拽的 SwiftUI 区域放
// .background(NonWindowDraggingView())
// 原理：NSView override mouseDownCanMoveWindow 返回 false，
// AppKit 在 hit-test 时碰到此视图就不会启动 performDrag。
//
// 另外，这个视图在首次挂到 window 时会自动 swizzle NSHostingView 类，
// 让所有 SwiftUI 宿主视图都阻断默认窗口拖拽。
// -----------------------------------------------------------------------------
struct NonWindowDraggingView: NSViewRepresentable {
    func makeNSView(context: Context) -> MouseDownCanMoveBlockerView {
        let view = MouseDownCanMoveBlockerView()
        print("🟢 NonWindowDraggingView.makeNSView called")
        return view
    }
    func updateNSView(_ nsView: MouseDownCanMoveBlockerView, context: Context) {}

    /// 关键：这个 NSView 需要：
    /// 1. mouseDownCanMoveWindow = false → AppKit 检查时窗口不跟动
    /// 2. isOpaque = true → hit-test 会先找到它（不跳过透明视图）
    /// 3. 但它不拦截任何鼠标事件——事件继续传递给 SwiftUI 手势系统
    final class MouseDownCanMoveBlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override var isOpaque: Bool { true }
        // 允许视图接收鼠标事件（默认就 true，但显式声明）
        override var acceptsFirstResponder: Bool { true }

        // ⚠️ 关键：override mouseDown 但不做任何处理！
        // 这样 AppKit 检查 mouseDownCanMoveWindow 时返回 false → 窗口不跟动
        // 然后 mouseDown 事件发给我们，我们不处理 → SwiftUI 的 NSEvent monitor 正常收到
        override func mouseDown(with event: NSEvent) {
            // 不做任何事，让事件自然传递
        }

        // 同样拦截 rightMouseDown 防止右键时窗口跟动
        override func rightMouseDown(with event: NSEvent) {
            // 不做任何事
        }
    }
}

/// 顶部自绘区域的空白拖窗区。
/// 它自行处理鼠标按下：单击显式拖动窗口，双击执行标准缩放/还原。
/// 不使用 mouseDownCanMoveWindow，避免事件被传给上层窗口后与页签拖放竞争。
/// 这是一个 NSViewRepresentable，将一个自定义 NSView 嵌入 SwiftUI 中处理鼠标事件。
struct WindowDragView: NSViewRepresentable {
    /// 创建自定义的 DragView 作为原生视图
    func makeNSView(context: Context) -> NSView { DragView() }
    /// 视图更新时无需额外操作（鼠标事件处理完全在 DragView 内部）
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 自定义 NSView 子类，处理鼠标按下事件来实现窗口拖拽和双击缩放
    final class DragView: NSView {
        /// 测试注入点：非 nil 时替代窗口 performZoom 调用。
        /// 用于单元测试中验证双击行为，而不需要真正的窗口
        var performZoomAction: (() -> Void)?
        /// 测试注入点：非 nil 时替代窗口的系统拖动调用。
        /// 用于单元测试中验证拖拽行为
        var performWindowDragAction: ((NSEvent) -> Void)?

        /// 返回 false 表示此视图不响应 AppKit 的自动窗口拖动
        /// （AppKit 默认允许用户通过拖动空白区域来移动窗口，这里禁用它）
        override var mouseDownCanMoveWindow: Bool { false }

        /// 处理鼠标按下事件
        override func mouseDown(with event: NSEvent) {
            // 双击（clickCount >= 2）且窗口存在缩放按钮时，执行缩放/还原操作
            if event.clickCount >= 2, let window, window.standardWindowButton(.zoomButton) != nil {
                // 如果有测试注入的缩放动作，执行它
                performZoomAction?()
                if performZoomAction == nil {
                    // 否则调用系统缩放（在全屏/窗口模式间切换）
                    window.performZoom(nil)
                }
                // 双击处理完毕，不再执行拖拽
                return
            }
            // 如果视图尚未挂载到窗口，直接返回
            guard let window else { return }
            if let performWindowDragAction {
                // 如果有测试注入的拖拽动作，执行它
                performWindowDragAction(event)
            } else {
                // 调用系统窗口拖拽（用户拖动此区域可移动整个窗口）
                window.performDrag(with: event)
            }
        }
    }
}

// MARK: - AppKit 默认窗口拖拽阻断
// -----------------------------------------------------------------------------
// 根因：AppKit 的 mouseDownCanMoveWindow 计算属性在视图 isOpaque=false 时
// 默认返回 true。SwiftUI 的 AppKitWindowHostingView 及其内部子视图因
// 透明标题栏窗口默认不透明，导致任何 mouseDown 事件都被 AppKit 立即
// 转换为窗口拖拽——抢在 SwiftUI 手势之前。
//
// 修复：用 ObjC runtime class_addMethod 给 AppKitWindowHostingView 类
// 添加 mouseDownCanMoveWindow 方法实现，让它永远返回 false。
//
// 为什么之前失败：
//   1. NSClassFromString("NSHostingView") 返回 nil —— 新版 SwiftUI 改名了
//   2. findNSHostingViewClass 只递归 subviews —— contentView 自己就是
//      AppKitWindowHostingView，不在 subviews 里
// 现在用 type(of: contentView) 直接拿运行时类，两个问题都没了。
// -----------------------------------------------------------------------------
import ObjectiveC

/// Swizzle contentView 的类（AppKitWindowHostingView），让 mouseDownCanMoveWindow 永远返回 false。
/// 调用时机：MainWindowChrome 配置窗口时（此时 window.contentView 已存在）。
/// 幂等——多调安全。
func pandaSwizzleMouseDownCanMoveWindow(in contentView: NSView?) {
    guard let contentView else { return }
    // 直接拿 contentView 的运行时类——它就是 AppKitWindowHostingView
    let cls = type(of: contentView)

    let sel = NSSelectorFromString("mouseDownCanMoveWindow")
    let typeEncoding = "c@:" // BOOL mouseDownCanMoveWindow

    // 返回 false 的 block IMP
    let block: @convention(block) (AnyObject) -> Bool = { _ in false }
    let newIMP = imp_implementationWithBlock(block as Any)

    let added = class_addMethod(cls, sel, newIMP, typeEncoding)
    print("🟡 swizzle: cls=\(cls), class_addMethod=\(added)")
    if !added {
        // 类已有此方法（罕见），直接替换实现
        if let method = class_getInstanceMethod(cls, sel) {
            method_setImplementation(method, newIMP)
            print("🟡 swizzle: fell back to method_setImplementation")
        }
    }
}

// 结束 #if os(macOS) 条件编译块
#endif

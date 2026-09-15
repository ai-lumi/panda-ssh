import SwiftUI

#if os(macOS)
import AppKit
#endif

/// 统一顶部 chrome 使用的独立页签容器。
/// 浏览按钮只改变容器的可见锚点；只有页签按钮会改变活动页签或会话呈现。
struct UnifiedWorkspaceTabStrip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var browseAnchorID: UUID?
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var viewportWidth = 0.0
    @State private var viewportOffset = 0.0

    private static let documentCoordinateSpace = "unified-workspace-tab-document"
    private static let documentHorizontalPadding = TabStripViewportState.revealPadding
    private static let browseButtonWidth = 28.0

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if workspace.tabs.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.on.rectangle")
                            .foregroundStyle(.secondary)
                        Text("暂无已打开页签")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .accessibilityLabel("暂无已打开页签")
                } else {
                    GeometryReader { containerProxy in
                        let containerWidth = containerProxy.size.width
                        let contentW = TabStripViewportState.contentWidth(from: tabFrames)
                        // 内容能完整放进容器时无需滚动；超出时预留两侧浏览按钮宽度
                        let needsScroll = containerWidth > 0 && (contentW - containerWidth) > 0.5
                        let reservedWidth = needsScroll ? Self.browseButtonWidth * 2 : 0
                        let scrollViewMaxWidth = max(0, containerWidth - reservedWidth)

                        HStack(spacing: 0) {
                            if needsScroll {
                                browseButton(systemName: "chevron.left", direction: -1, proxy: proxy)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(workspace.tabs) { tab in
                                        tabButton(tab)
                                            .id(tab.id)
                                            .background(tabFrameReporter(for: tab.id))
                                    }
                                }
                                .padding(.horizontal, Self.documentHorizontalPadding)
                                .padding(.vertical, 5)
                                .coordinateSpace(name: Self.documentCoordinateSpace)
                            }
                            .frame(maxWidth: scrollViewMaxWidth)
                            .background(viewportWidthReporter)
                            if needsScroll {
                                browseButton(systemName: "chevron.right", direction: 1, proxy: proxy)
                            }
                        }
                    }
                }
            }
            .macOSTabStripWheelBridge { input in
                scroll(to: currentViewport.targetOffset(after: input), using: proxy)
            }
            .onAppear { revealActiveTab(using: proxy) }
            .onChange(of: workspace.activeTabID) { _, _ in revealActiveTab(using: proxy) }
            .onChange(of: workspace.tabs.map(\.id)) { _, _ in
                normalizeBrowseAnchor()
                revealActiveTab(using: proxy)
            }
            .onPreferenceChange(UnifiedTabFramePreference.self) { frames in
                tabFrames = frames
                revealActiveTab(using: proxy, animated: false)
            }
        }
        .accessibilityIdentifier("unified-workspace-tab-strip")
    }

    private func browseButton(
        systemName: String,
        direction: Int,
        proxy: ScrollViewProxy
    ) -> some View {
        Button {
            moveBrowseAnchor(direction: direction, using: proxy)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: Self.browseButtonWidth, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canBrowse(direction: direction))
        .accessibilityLabel(direction < 0 ? "浏览前一页签" : "浏览后一页签")
    }

    @State private var hoveredTabID: UUID?
    #if os(macOS)
    @State private var tabMenuHandler: TabMenuActionHandler?
    #endif

    private func tabButton(_ tab: WorkspaceTab) -> some View {
        let isHovered = hoveredTabID == tab.id
        let active = isActive(tab)

        // 两个独立组件水平排列，各自管理自己的手势
        // 标签区域：onTapGesture（低优先级）
        // 关闭按钮：Button（高优先级），不受父视图 onTapGesture 影响
        return HStack(spacing: 0) {
            // ── 左侧：文本标签区域 ──
            labelArea(for: tab, active: active)

            // ── 右侧：关闭按钮 ─
            closeButton(for: tab, isHovered: isHovered)
        }
        .font(.callout)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? Color.primary.opacity(0.14) : Color.clear)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.15 : 0), lineWidth: 0.5)
        )
        .onHover { hovered in
            hoveredTabID = hovered ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
        }
        .accessibilityLabel(tab.title)
        #if os(macOS)
        .onTabRightClick { event in
            showTabContextMenu(for: tab, event: event)
        }
        #else
        .contextMenu {
            tabContextMenuContent(for: tab)
        }
        #endif
    }

    /// 左侧标签区域：状态圆点 + 图标 + 标题，点击选中
    private func labelArea(for tab: WorkspaceTab, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(for: tab.id))
                .frame(width: 6, height: 6)
            Image(systemName: tab.kind == .terminal ? "terminal" : "folder")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 30)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture {
            workspace.select(tabID: tab.id)
            model.presentTab(tab.id)
        }
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    /// 右侧关闭按钮：独立 Button，仅触发 requestClose
    private func closeButton(for tab: WorkspaceTab, isHovered: Bool) -> some View {
        Button {
            workspace.requestClose(tabID: tab.id)
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(
            Color.primary.opacity(isHovered ? 0.10 : 0.04),
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .padding(.trailing, 6)
        .accessibilityLabel("关闭 \(tab.title)")
    }

    private func isActive(_ tab: WorkspaceTab) -> Bool {
        model.workspacePresentation == .tab(tabID: tab.id)
    }

    private func statusColor(for tabID: UUID) -> Color {
        switch workspace.connectionStatus(forTabID: tabID) {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .inactive: Color.gray.opacity(0.6)
        }
    }

    // MARK: - 页签右键菜单

    #if os(macOS)
    /// macOS：构建 NSMenu 并弹出。
    private func showTabContextMenu(for tab: WorkspaceTab, event: NSEvent) {
        if tabMenuHandler == nil {
            tabMenuHandler = TabMenuActionHandler(workspace: workspace)
        }
        let menu = TabContextMenuBuilder.buildNSMenu(
            tabID: tab.id,
            tabKind: tab.kind,
            target: tabMenuHandler,
            action: #selector(TabMenuActionHandler.handleMenuItem(_:))
        )
        // 使用临时定位视图弹出菜单；事件已携带鼠标位置信息。
        let anchor = NSView(frame: .zero)
        NSMenu.popUpContextMenu(menu, with: event, for: anchor)
    }
    #else
    /// iPadOS：`.contextMenu` 内容构建。
    @ViewBuilder
    private func tabContextMenuContent(for tab: WorkspaceTab) -> some View {
        let items = TabContextMenuBuilder.items(for: tab.kind)
        if items.contains(.reconnect) {
            Button {
                workspace.reconnectTerminal(tabID: tab.id)
            } label: {
                Label(TabMenuItem.reconnect.title, systemImage: TabMenuItem.reconnect.symbolName)
            }
            Divider()
        }
        Button {
            workspace.requestClose(tabID: tab.id)
        } label: {
            Label(TabMenuItem.closeTab.title, systemImage: TabMenuItem.closeTab.symbolName)
        }
        Button {
            workspace.requestCloseOthers(keeping: tab.id)
        } label: {
            Label(TabMenuItem.closeOthers.title, systemImage: TabMenuItem.closeOthers.symbolName)
        }
        Button {
            workspace.requestCloseAll()
        } label: {
            Label(TabMenuItem.closeAll.title, systemImage: TabMenuItem.closeAll.symbolName)
        }
    }
    #endif

    private func moveBrowseAnchor(direction: Int, using proxy: ScrollViewProxy) {
        let viewport = currentViewport
        let input: TabStripScrollInput = .discrete(direction < 0 ? .backward : .forward)
        let targetOffset = viewport.targetOffset(after: input)
        scroll(to: targetOffset, using: proxy)
    }

    private func canBrowse(direction: Int) -> Bool {
        let viewport = currentViewport
        return abs(viewport.targetOffset(after: .discrete(direction < 0 ? .backward : .forward)) - viewport.offset) > 0.5
    }

    private func normalizeBrowseAnchor() {
        guard let browseAnchorID,
              workspace.tabs.contains(where: { $0.id == browseAnchorID }) else {
            self.browseAnchorID = workspace.activeTabID
            return
        }
    }

    private var currentViewport: TabStripViewportState {
        TabStripViewportState.resolve(
            contentWidth: TabStripViewportState.contentWidth(from: tabFrames),
            viewportWidth: viewportWidth,
            offset: viewportOffset
        )
    }

    private func revealActiveTab(using proxy: ScrollViewProxy, animated: Bool = true) {
        guard let activeTabID = workspace.activeTabID,
              let frame = tabFrames[activeTabID] else { return }
        browseAnchorID = activeTabID
        scroll(to: currentViewport.revealedOffset(
            itemMinX: Double(frame.minX),
            itemMaxX: Double(frame.maxX)
        ), using: proxy, animated: animated)
    }

    private func scroll(to targetOffset: Double, using proxy: ScrollViewProxy, animated: Bool = true) {
        // 几何更新可能重复到达；没有实际位移时不触发 scrollTo 或新的动画。
        guard abs(targetOffset - viewportOffset) > 0.5 else { return }
        guard let target = currentViewport.scrollTarget(
            for: targetOffset,
            among: tabFrames
        ) else { return }
        viewportOffset = targetOffset
        browseAnchorID = target.tabID
        let anchor = UnitPoint(x: target.anchorX, y: 0)
        if animated {
            withAnimation { proxy.scrollTo(target.tabID, anchor: anchor) }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(target.tabID, anchor: anchor) }
        }
    }

    private func tabFrameReporter(for tabID: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: UnifiedTabFramePreference.self,
                value: [tabID: proxy.frame(in: .named(Self.documentCoordinateSpace))]
            )
        }
    }

    private var viewportWidthReporter: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { viewportWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in viewportWidth = width }
        }
    }
}

#if os(macOS)
/// AppKit 输入适配只负责提取原始滚轮值；页签的边界和浏览规则仍由共享状态处理。
enum MacOSTabStripWheelInput {
    static func resolve(
        horizontalDelta: Double,
        verticalDelta: Double,
        isPrecise: Bool
    ) -> TabStripScrollInput? {
        TabStripScrollInput.normalize(
            horizontalDelta: horizontalDelta,
            verticalDelta: verticalDelta,
            isPrecise: isPrecise
        )
    }
}

/// 在页签栏边界内截获滚轮事件，避免 SwiftUI 横向 ScrollView 忽略普通鼠标的垂直滚轮。
private struct MacOSTabStripWheelBridge: NSViewRepresentable {
    let onInput: (TabStripScrollInput) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onInput = onInput
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onInput = onInput
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onInput: ((TabStripScrollInput) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            startMonitoring()
        }

        func startMonitoring() {
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point),
                      let input = MacOSTabStripWheelInput.resolve(
                          horizontalDelta: event.scrollingDeltaX,
                          verticalDelta: event.scrollingDeltaY,
                          isPrecise: event.hasPreciseScrollingDeltas
                      ) else { return event }
                self.onInput?(input)
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

private extension View {
    func macOSTabStripWheelBridge(
        onInput: @escaping (TabStripScrollInput) -> Void
    ) -> some View {
        background(MacOSTabStripWheelBridge(onInput: onInput))
    }
}
#else
private extension View {
    func macOSTabStripWheelBridge(
        onInput _: @escaping (TabStripScrollInput) -> Void
    ) -> some View { self }
}
#endif

private struct UnifiedTabFramePreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

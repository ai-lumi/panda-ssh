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

    private func tabButton(_ tab: WorkspaceTab) -> some View {
        Button {
            workspace.select(tabID: tab.id)
            model.presentTab(tab.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(for: tab.id))
                    .frame(width: 6, height: 6)
                Image(systemName: tab.kind == .terminal ? "terminal" : "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(tab.title)
                    .lineLimit(1)
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
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .accessibilityLabel("关闭 \(tab.title)")
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(
                isActive(tab) ? Color.primary.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive(tab) ? [.isButton, .isSelected] : .isButton)
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

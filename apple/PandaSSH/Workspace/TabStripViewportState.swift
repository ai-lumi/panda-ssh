import Foundation

/// 统一工作区顶部 chrome 的平台无关内容契约。
///
/// 它只保留渲染页签所需的顺序和活动标识，不拥有或修改会话生命周期。
struct WorkspaceShell: Equatable {
    let tabIDs: [UUID]
    let activeTabID: UUID?

    static func resolve(tabIDs: [UUID], activeTabID: UUID?) -> WorkspaceShell {
        WorkspaceShell(
            tabIDs: tabIDs,
            activeTabID: activeTabID.flatMap { tabIDs.contains($0) ? $0 : nil }
        )
    }
}

/// 独立页签容器的纯值视口状态。
/// 所有尺寸和偏移均在进入 UI 前归一化，供 macOS 与 iPadOS 共享。
struct TabStripViewportState: Equatable {
    static let revealPadding = 8.0

    let contentWidth: Double
    let viewportWidth: Double
    let offset: Double
    let maximumOffset: Double

    var needsScroll: Bool {
        viewportWidth > 0 && maximumOffset > 0.5
    }

    /// 内容未溢出时，页签文档末尾可交给窗口 chrome 的显式空白宽度。
    /// 溢出时由滚动容器占满视口，返回零，外层独立拖窗区仍可用。
    var trailingEmptyWidth: Double {
        needsScroll ? 0 : max(0, viewportWidth - contentWidth)
    }

    static func resolve(
        contentWidth: Double,
        viewportWidth: Double,
        offset: Double
    ) -> TabStripViewportState {
        let safeContentWidth = finiteNonnegative(contentWidth)
        let safeViewportWidth = finiteNonnegative(viewportWidth)
        let maximumOffset = max(0, safeContentWidth - safeViewportWidth)
        return TabStripViewportState(
            contentWidth: safeContentWidth,
            viewportWidth: safeViewportWidth,
            offset: clamp(offset.isFinite ? offset : 0, lower: 0, upper: maximumOffset),
            maximumOffset: maximumOffset
        )
    }

    /// 根据页签帧计算内容总宽度，包含尾部填充以便与 ScrollView 实际内容边界对齐。
    static func contentWidth(
        from tabFrames: [UUID: CGRect],
        trailingPadding: Double = revealPadding
    ) -> Double {
        let maxTabMaxX = tabFrames.values.map(\.maxX).max() ?? 0
        guard maxTabMaxX > 0 else { return 0 }
        return maxTabMaxX + trailingPadding
    }

    /// 根据目标偏移在页签中选出最适合 scrollTo 的目标页签与归一化 anchorX。
    /// 页签宽于视口时 anchorX 在 [0,1] 之间线性插值；窄于视口的页签回退到前缘（0）。
    /// 目标偏移抵达内容末端时直接以最后页签为目标：scrollTo 以单个页签为锚点的实际落点
    /// 不会超过该页签前缘，跨在最大偏移上的页签会卡住落点，导致最右页签永远无法完整显露；
    /// 窄页签经 ScrollView 末端夹取精确抵达，宽页签用 trailing anchor 贴住视口右缘。
    func scrollTarget(
        for targetOffset: Double,
        among tabFrames: [UUID: CGRect]
    ) -> (tabID: UUID, anchorX: Double)? {
        guard viewportWidth > 0 else { return nil }
        let sorted = tabFrames.sorted { $0.value.minX < $1.value.minX }
        guard let candidate = sorted.first(where: { $0.value.maxX > targetOffset })
              ?? sorted.last else { return nil }

        // 目标偏移已抵达内容末端：绕过骑跨页签，直达最后页签。
        if targetOffset >= maximumOffset - 0.5, let last = sorted.last {
            let lastWidth = Double(last.value.width)
            return (last.key, lastWidth > viewportWidth ? 1 : 0)
        }

        let frame = candidate.value
        let tabWidth = Double(frame.width)
        let tabMinX = Double(frame.minX)
        if tabWidth > viewportWidth {
            let denominator = tabWidth - viewportWidth
            let raw = (targetOffset - tabMinX) / denominator
            return (candidate.key, min(max(raw, 0), 1))
        }
        return (candidate.key, 0)
    }

    /// 返回让目标页签显露所需的最小偏移；目标宽于视口时保留其前缘。
    func revealedOffset(itemMinX: Double, itemMaxX: Double) -> Double {
        guard itemMinX.isFinite, itemMaxX.isFinite, viewportWidth > 0 else { return offset }
        let lower = min(itemMinX, itemMaxX)
        let upper = max(itemMinX, itemMaxX)
        let paddedLower = max(0, lower - Self.revealPadding)
        let paddedUpper = min(contentWidth, upper + Self.revealPadding)

        if paddedUpper - paddedLower >= viewportWidth || paddedLower < offset {
            return Self.clamp(paddedLower, lower: 0, upper: maximumOffset)
        }
        if paddedUpper > offset + viewportWidth {
            return Self.clamp(paddedUpper - viewportWidth, lower: 0, upper: maximumOffset)
        }
        return offset
    }

    /// 将已归一化的输入意图转换为容器内的新偏移，不触及页签选择或会话状态。
    func targetOffset(after input: TabStripScrollInput) -> Double {
        let delta: Double
        switch input {
        case .discrete(.backward):
            delta = viewportWidth
        case .discrete(.forward):
            delta = -viewportWidth
        case .continuous(let value):
            delta = value
        }
        return Self.clamp(offset - delta, lower: 0, upper: maximumOffset)
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

/// 统一页签容器接收的滚动意图。
/// 普通鼠标只有离散步进语义；精确指针设备保留连续 delta，供视口平滑移动。
enum TabStripScrollInput: Equatable {
    enum DiscreteDirection: Equatable {
        case backward
        case forward
    }

    case discrete(DiscreteDirection)
    case continuous(delta: Double)

    static func normalize(
        horizontalDelta: Double,
        verticalDelta: Double,
        isPrecise: Bool
    ) -> TabStripScrollInput? {
        guard horizontalDelta.isFinite, verticalDelta.isFinite else { return nil }
        let delta = abs(horizontalDelta) > abs(verticalDelta) ? horizontalDelta : verticalDelta
        guard abs(delta) > 0.000_1 else { return nil }

        if isPrecise {
            return .continuous(delta: delta)
        }
        return .discrete(delta > 0 ? .backward : .forward)
    }
}

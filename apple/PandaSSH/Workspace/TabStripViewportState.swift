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

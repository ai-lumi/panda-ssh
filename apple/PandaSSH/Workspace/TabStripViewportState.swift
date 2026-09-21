// =============================================================================
// 文件：TabStripViewportState.swift
// 功能：定义页签条（Tab Strip）的视口状态和滚动逻辑。
//       当打开的终端标签页太多、超出窗口宽度时，页签条需要支持水平滚动。
//       这个文件负责计算：
//       1. 内容总宽度（所有页签占多宽）
//       2. 视口宽度（窗口可见区域多宽）
//       3. 当前滚动偏移（已经滚了多远）
//       4. 最大可滚动范围（最多能滚多远）
//       5. 滚动目标计算（滚动后应该显示哪个页签）
//       6. 滚动输入归一化（把鼠标滚轮/触控板手势统一为滚动意图）
//       所有计算都是纯数学，不涉及 UI 渲染，方便测试。
// =============================================================================

// 导入 Foundation 框架，提供基础数据类型
import Foundation

/// 统一工作区顶部 chrome 的平台无关内容契约。
///
/// 它只保留渲染页签所需的顺序和活动标识，不拥有或修改会话生命周期。
/// 简单来说，这个结构体只是告诉页签条"有哪些标签页、当前激活哪个"。
/// 遵循 Equatable 协议，可以比较两个 WorkspaceShell 是否相同。
struct WorkspaceShell: Equatable {
    /// 所有标签页的 ID 数组，按显示顺序排列。
    /// UUID 是每个标签页的唯一标识符。
    let tabIDs: [UUID]
    /// 当前激活（选中）的标签页 ID。可选类型：nil 表示没有激活的标签页。
    let activeTabID: UUID?

    /// 工厂方法：根据原始数据创建一个经过校验的 WorkspaceShell。
    /// 校验逻辑：如果 activeTabID 不在 tabIDs 列表中，则将其设为 nil
    /// （防止出现"激活了一个不存在的标签页"的非法状态）。
    /// 参数：
    ///   - tabIDs: 所有标签页 ID 列表
    ///   - activeTabID: 当前激活的标签页 ID（可能无效）
    /// 返回值：校验后的 WorkspaceShell 实例
    static func resolve(tabIDs: [UUID], activeTabID: UUID?) -> WorkspaceShell {
        return WorkspaceShell(
            tabIDs: tabIDs,
            // flatMap 在这里的作用是：如果 activeTabID 为 nil 则返回 nil；
            // 如果不为 nil，则检查它是否在 tabIDs 中，在则保留，不在则返回 nil
            activeTabID: activeTabID.flatMap { tabIDs.contains($0) ? $0 : nil }
        )
    }
}

/// 独立页签容器的纯值视口状态。
/// 所有尺寸和偏移均在进入 UI 前归一化，供 macOS 与 iPadOS 共享。
/// 这个结构体是纯数据类型，不包含任何 UI 代码，只存储计算好的尺寸和偏移量，
/// 供 SwiftUI 视图直接使用。遵循 Equatable 协议，可以比较两次计算结果是否相同。
struct TabStripViewportState: Equatable {
    /// 页签显露时的额外内边距（单位：pt）。
    /// 当滚动到某个页签时，不会刚好停在页签边缘，而是多留 8pt 的呼吸空间，
    /// 视觉效果更舒适，不会显得太挤。
    static let revealPadding = 8.0

    /// 内容总宽度：所有页签加在一起占多宽（单位：pt）。
    let contentWidth: Double
    /// 视口宽度：窗口中页签条可见区域的宽度（单位：pt）。
    let viewportWidth: Double
    /// 当前滚动偏移：内容向左偏移了多少（单位：pt）。
    /// offset = 0 表示滚动到最左边（显示第一个页签）。
    /// offset 越大表示滚得越远（越靠右的页签可见）。
    let offset: Double
    /// 最大可滚动偏移：offset 的最大值。
    /// 当 contentWidth <= viewportWidth 时为 0（不需要滚动）。
    /// 当内容超出视口时为 contentWidth - viewportWidth。
    let maximumOffset: Double

    /// 是否需要滚动：当内容宽度超过视口宽度时需要滚动。
    /// 计算属性：视口宽度大于 0（有效值）且最大偏移大于 0.5pt 时返回 true。
    /// 0.5pt 的阈值是为了避免浮点精度误差导致的误判。
    var needsScroll: Bool {
        viewportWidth > 0 && maximumOffset > 0.5
    }

    /// 内容未溢出时，页签文档末尾可交给窗口 chrome 的显式空白宽度。
    /// 溢出时由滚动容器占满视口，返回零，外层独立拖窗区仍可用。
    /// 计算属性：
    /// - 如果需要滚动（内容超出视口），返回 0（没有多余的空白）
    /// - 如果不需要滚动（内容没超出视口），返回视口宽度减去内容宽度
    ///   （即右侧剩余的空白区域，可以用作窗口拖动区）
    var trailingEmptyWidth: Double {
        needsScroll ? 0 : max(0, viewportWidth - contentWidth)
    }

    /// 工厂方法：根据原始尺寸参数创建一个经过归一化的视口状态。
    /// 归一化处理包括：
    /// 1. 将所有输入值限制为有限非负数（过滤 NaN、Infinity 等异常值）
    /// 2. 计算最大可滚动偏移
    /// 3. 将当前偏移夹取到 [0, maximumOffset] 范围内
    /// 参数：
    ///   - contentWidth: 内容总宽度
    ///   - viewportWidth: 视口宽度
    ///   - offset: 当前滚动偏移
    /// 返回值：归一化后的 TabStripViewportState 实例
    static func resolve(
        contentWidth: Double,
        viewportWidth: Double,
        offset: Double
    ) -> TabStripViewportState {
        // 将内容宽度归一化为有限非负数（如果是 NaN/Infinity 则变为 0）
        let safeContentWidth = finiteNonnegative(contentWidth)
        // 将视口宽度归一化为有限非负数
        let safeViewportWidth = finiteNonnegative(viewportWidth)
        // 计算最大可滚动偏移：内容宽度减去视口宽度，最小为 0
        // 如果内容比视口窄，则不需要滚动，maximumOffset 为 0
        let maximumOffset = max(0, safeContentWidth - safeViewportWidth)
        return TabStripViewportState(
            // 归一化后的内容宽度
            contentWidth: safeContentWidth,
            // 归一化后的视口宽度
            viewportWidth: safeViewportWidth,
            // 将偏移夹取到有效范围内：
            // 先检查 offset 是否为有限值，不是则用 0
            // 然后用 clamp 限制在 [0, maximumOffset] 之间
            offset: clamp(offset.isFinite ? offset : 0, lower: 0, upper: maximumOffset),
            // 最大可滚动偏移
            maximumOffset: maximumOffset
        )
    }

    /// 根据页签帧计算内容总宽度，包含尾部填充以便与 ScrollView 实际内容边界对齐。
    /// 参数：
    ///   - tabFrames: 每个页签的矩形区域字典（key 是页签 ID，value 是该页签的 CGRect）
    ///     CGRect 包含页签的位置和尺寸信息，maxX 是页签右边缘的 x 坐标
    ///   - trailingPadding: 尾部填充宽度，默认为 revealPadding（8pt）
    /// 返回值：内容总宽度（最右页签的右边缘 + 尾部填充）
    static func contentWidth(
        from tabFrames: [UUID: CGRect],
        trailingPadding: Double = revealPadding
    ) -> Double {
        // 从所有页签帧中找出最大的 maxX（即最右页签的右边缘 x 坐标）
        // tabFrames.values 获取所有 CGRect 值
        // map(\.maxX) 提取每个 CGRect 的 maxX（右边缘）
        // .max() 找出最大值（最右边的位置）
        // ?? 0 如果没有页签则默认为 0
        let maxTabMaxX = tabFrames.values.map(\.maxX).max() ?? 0
        // 如果没有页签（maxTabMaxX <= 0），返回 0
        guard maxTabMaxX > 0 else { return 0 }
        // 返回最右页签的右边缘加上尾部填充
        return maxTabMaxX + trailingPadding
    }

    /// 根据目标偏移在页签中选出最适合 scrollTo 的目标页签与归一化 anchorX。
    /// 页签宽于视口时 anchorX 在 [0,1] 之间线性插值；窄于视口的页签回退到前缘（0）。
    /// 目标偏移抵达内容末端时直接以最后页签为目标：scrollTo 以单个页签为锚点的实际落点
    /// 不会超过该页签前缘，跨在最大偏移上的页签会卡住落点，导致最右页签永远无法完整显露；
    /// 窄页签经 ScrollView 末端夹取精确抵达，宽页签用 trailing anchor 贴住视口右缘。
    ///
    /// 这个方法解决的问题是：当用户滚动页签条时，需要告诉 ScrollView "滚动到哪个页签的
    /// 哪个位置"。anchorX 是一个 0 到 1 之间的值：
    /// - 0 表示对齐到页签的左边缘
    /// - 1 表示对齐到页签的右边缘
    /// - 0.5 表示对齐到页签的水平中心
    ///
    /// 参数：
    ///   - targetOffset: 期望滚动到的目标偏移量
    ///   - tabFrames: 所有页签的矩形区域字典
    /// 返回值：一个元组 (tabID, anchorX)，分别表示目标页签 ID 和锚点位置。
    ///   如果无法确定目标则返回 nil。
    func scrollTarget(
        for targetOffset: Double,
        among tabFrames: [UUID: CGRect]
    ) -> (tabID: UUID, anchorX: Double)? {
        // 前置条件：视口宽度必须大于 0（有效值），否则无法计算
        guard viewportWidth > 0 else { return nil }
        // 将所有页签按左边缘位置（minX）从小到大排序（从左到右）
        let sorted = tabFrames.sorted { $0.value.minX < $1.value.minX }
        // 找到第一个右边缘（maxX）超过目标偏移的页签（即目标位置可见的那个页签）
        // 如果没找到（所有页签都在目标位置左边），则取最后一个页签作为兜底
        guard let candidate = sorted.first(where: { $0.value.maxX > targetOffset })
              ?? sorted.last else { return nil }

        // 目标偏移已抵达内容末端：绕过骑跨页签，直达最后页签。
        // 当滚动到最右边时，直接以最后一个页签为目标，避免被"骑跨"页签卡住。
        // "骑跨"是指一个页签太宽，同时跨越了可见区域和不可见区域。
        if targetOffset >= maximumOffset - 0.5, let last = sorted.last {
            // 获取最后一个页签的宽度
            let lastWidth = Double(last.value.width)
            // 如果最后一个页签比视口还宽，anchorX 设为 1（对齐右边缘），
            // 否则设为 0（对齐左边缘）
            return (last.key, lastWidth > viewportWidth ? 1 : 0)
        }

        // 获取候选页签的矩形区域
        let frame = candidate.value
        // 将 CGRect 的宽度转为 Double 类型
        let tabWidth = Double(frame.width)
        // 将 CGRect 的左边缘 x 坐标转为 Double 类型
        let tabMinX = Double(frame.minX)
        // 如果候选页签比视口还宽（需要特殊处理锚点位置）
        if tabWidth > viewportWidth {
            // 计算页签中"可滚动范围"：页签宽度减去视口宽度
            let denominator = tabWidth - viewportWidth
            // 计算目标偏移在可滚动范围内的相对位置（0 到 1 之间）
            let raw = (targetOffset - tabMinX) / denominator
            // 将结果夹取到 [0, 1] 范围内，防止超出
            return (candidate.key, min(max(raw, 0), 1))
        }
        // 页签不比视口宽：锚点设为 0（对齐到页签左边缘）
        return (candidate.key, 0)
    }

    /// 返回让目标页签显露所需的最小偏移；目标宽于视口时保留其前缘。
    /// 这个方法解决的问题是：当新增一个页签或选中一个不在可见区域的页签时，
    /// 需要滚动多少才能让那个页签完整显示出来。
    /// 参数：
    ///   - itemMinX: 目标页签的左边缘 x 坐标
    ///   - itemMaxX: 目标页签的右边缘 x 坐标
    /// 返回值：需要滚动到的新偏移量。如果目标页签已经在可见区域内，返回当前偏移不变。
    func revealedOffset(itemMinX: Double, itemMaxX: Double) -> Double {
        // 前置条件：两个坐标都必须是有限值，且视口宽度大于 0
        guard itemMinX.isFinite, itemMaxX.isFinite, viewportWidth > 0 else { return offset }
        // 取两个坐标中较小的作为左边界（兼容参数传反的情况）
        let lower = min(itemMinX, itemMaxX)
        // 取两个坐标中较大的作为右边界
        let upper = max(itemMinX, itemMaxX)
        // 左边界减去内边距（向左多露出 8pt），但不能小于 0
        let paddedLower = max(0, lower - Self.revealPadding)
        // 右边界加上内边距（向右多露出 8pt），但不能超过内容总宽度
        let paddedUpper = min(contentWidth, upper + Self.revealPadding)

        // 情况 1：目标页签（含内边距）比整个视口还宽，或者目标在当前位置的左边
        // 此时滚动到目标的左边界
        if paddedUpper - paddedLower >= viewportWidth || paddedLower < offset {
            // 将结果夹取到有效偏移范围内
            return Self.clamp(paddedLower, lower: 0, upper: maximumOffset)
        }
        // 情况 2：目标的右边界超出了当前可见区域的右边缘
        // 需要向右滚动，让目标的右边缘刚好可见
        if paddedUpper > offset + viewportWidth {
            // 新的偏移 = 目标右边界 - 视口宽度，夹取到有效范围
            return Self.clamp(paddedUpper - viewportWidth, lower: 0, upper: maximumOffset)
        }
        // 情况 3：目标已经在可见区域内，不需要滚动，返回当前偏移
        return offset
    }

    /// 将已归一化的输入意图转换为容器内的新偏移，不触及页签选择或会话状态。
    /// 这个方法根据用户的滚动输入（离散方向或连续 delta）计算新的滚动偏移。
    /// 参数：
    ///   - input: 滚动输入，可以是离散的（向前/向后翻一页）或连续的（精确 delta 值）
    /// 返回值：计算出的新偏移量（已夹取到有效范围内）。
    func targetOffset(after input: TabStripScrollInput) -> Double {
        // delta 表示偏移变化量（正数表示向左滚/内容向右移动）
        let delta: Double
        switch input {
        case .discrete(.backward):
            // 离散向后（向左翻）：偏移增加一个视口宽度（翻一整页）
            delta = viewportWidth
        case .discrete(.forward):
            // 离散向前（向右翻）：偏移减少一个视口宽度
            delta = -viewportWidth
        case .continuous(let value):
            // 连续滚动：使用精确的 delta 值（来自触控板/精确鼠标滚轮）
            delta = value
        }
        // 新偏移 = 当前偏移 - delta，然后夹取到 [0, maximumOffset] 范围内
        // 注意这里用 offset - delta 是因为：delta 为正表示内容向右移动（向左滚动），
        // 对应 offset 增大
        return Self.clamp(offset - delta, lower: 0, upper: maximumOffset)
    }

    /// 将值归一化为有限非负数。
    /// 如果输入是 NaN 或 Infinity，返回 0；否则返回 max(0, value)（确保非负）。
    /// 参数：
    ///   - value: 要归一化的值
    /// 返回值：归一化后的非负有限值
    private static func finiteNonnegative(_ value: Double) -> Double {
        // isFinite 检查是否为有限值（排除 NaN 和 Infinity）
        // 如果是有限值，取 max(0, value) 确保非负；否则返回 0
        value.isFinite ? max(0, value) : 0
    }

    /// 将值夹取到指定范围内。
    /// 如果值小于 lower 则返回 lower，大于 upper 则返回 upper，否则返回原值。
    /// 参数：
    ///   - value: 要夹取的值
    ///   - lower: 下界
    ///   - upper: 上界
    /// 返回值：夹取后的值，保证在 [lower, upper] 范围内
    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        // 先取 max(value, lower) 确保不小于下界，再取 min(..., upper) 确保不大于上界
        min(max(value, lower), upper)
    }
}

/// 统一页签容器接收的滚动意图。
/// 普通鼠标只有离散步进语义（一次翻一页）；精确指针设备（触控板/精确鼠标滚轮）
/// 保留连续 delta，供视口平滑移动。
/// 这个枚举将不同输入设备的滚动行为统一为两种语义：
/// 1. discrete（离散）：普通鼠标滚轮，一次一个方向，翻一整页
/// 2. continuous（连续）：触控板双指滑动，精确的像素级滚动
/// 遵循 Equatable 协议，可以比较两次滚动输入是否相同。
enum TabStripScrollInput: Equatable {
    /// 离散滚动方向：只有两个方向——向后（backward）和向前（forward）。
    /// backward 表示向左翻（查看更左边的页签）
    /// forward 表示向右翻（查看更右边的页签）
    enum DiscreteDirection: Equatable {
        /// 向后滚动（向左翻一页）
        case backward
        /// 向前滚动（向右翻一页）
        case forward
    }

    /// 离散滚动：一次翻一页，用于普通鼠标滚轮
    case discrete(DiscreteDirection)
    /// 连续滚动：携带精确的像素偏移量，用于触控板等精确设备
    /// delta 参数表示滚动量（正数向左滚，负数向右滚）
    case continuous(delta: Double)

    /// 将原始的鼠标/触控板滚动数据归一化为统一的滚动输入。
    /// 这个方法解决的问题是：不同设备报告的滚动数据格式不同，
    /// 需要统一转换为 TabStripScrollInput 才能被视口状态使用。
    /// 参数：
    ///   - horizontalDelta: 水平滚动量（鼠标滚轮或触控板水平滑动）
    ///   - verticalDelta: 垂直滚动量（鼠标滚轮或触控板垂直滑动）
    ///   - isPrecise: 是否来自精确指针设备（触控板 = true，普通鼠标 = false）
    /// 返回值：归一化后的滚动输入，如果滚动量太小（接近 0）则返回 nil 表示忽略
    static func normalize(
        horizontalDelta: Double,
        verticalDelta: Double,
        isPrecise: Bool
    ) -> TabStripScrollInput? {
        // 前置条件：两个方向的滚动量都必须是有限值（排除 NaN/Infinity）
        guard horizontalDelta.isFinite, verticalDelta.isFinite else { return nil }
        // 选择绝对值更大的那个方向的滚动量作为主滚动方向
        // 因为用户可能斜着滑动触控板，取主方向更准确
        let delta = abs(horizontalDelta) > abs(verticalDelta) ? horizontalDelta : verticalDelta
        // 如果滚动量太小（小于 0.0001），视为无效输入，忽略
        // 这可以过滤掉触控板的微小抖动
        guard abs(delta) > 0.000_1 else { return nil }

        // 如果来自精确指针设备（触控板），返回连续滚动输入（保留精确的 delta 值）
        if isPrecise {
            return .continuous(delta: delta)
        }
        // 普通鼠标：返回离散滚动输入（只判断方向，不保留精确量）
        // delta > 0 表示向后（向左），否则向前（向右）
        return .discrete(delta > 0 ? .backward : .forward)
    }
}

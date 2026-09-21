// =============================================================================
// UnifiedWorkspaceChromeLayout.swift
// =============================================================================
// 文件功能说明：
// 计算统一的首部 Chrome（窗口外壳）布局尺寸。
//
// 无论是 macOS 还是 iPadOS，窗口顶部都有一排「工具栏区域」，里面从左到右
// 依次排列着：侧栏控件、页签条、右侧工具按钮等。这个结构体根据窗口总宽度、
// 侧栏宽度、各平台预留空间等参数，计算出每个组件应该占多少宽度。
//
// 设计原则：平台宿主只提供安全预留宽度（如交通灯按钮、安全区），
// 页签和侧栏的布局分配规则不因平台而分叉，由这个统一的布局结构体处理。
// =============================================================================

import Foundation
// 导入 Foundation 框架

/// 统一顶部 chrome 的共享空间分配。
/// 平台宿主只提供安全预留宽度；页签与侧栏的布局规则不因平台而分叉。
struct UnifiedWorkspaceChromeLayout: Equatable {
    // Equatable 让两个布局实例可以比较，
    // 当窗口尺寸变化时 SwiftUI 能检测到并重新布局

    /// 标题栏原生控件占用的左侧安全区，由 macOS 宿主实测提供。
    let leadingSafeWidth: Double
    // 左侧安全区宽度（点）。macOS 上通常是交通灯按钮（红黄绿）的宽度，
    // 页签条不能画到这个区域上面

    /// 仅用于窗口拖动的尾部空白区，不承载页签或按钮。
    let trailingSafeWidth: Double
    // 右侧安全区宽度（点）。macOS 上用于窗口拖动区域，
    // 这段空间不能被页签或按钮占用

    let availableWidth: Double
    // 去掉左右安全区后，中间真正可以用来放置控件的总宽度

    let sidebarToolsWidth: Double
    // 侧栏工具区域的宽度。当侧栏可见时，侧栏内的工具按钮
    // （如搜索框、操作按钮）占据的宽度

    /// detail 内的顶栏没有侧栏空间，不能创建溢出零宽 frame 的工具按钮。
    var showsSidebarTools: Bool { sidebarToolsWidth > 0 }
    // 计算属性：是否显示侧栏工具。
    // 如果 sidebarToolsWidth > 0，说明侧栏可见且有空间放工具按钮
    // 如果为 0，说明侧栏隐藏，不应该渲染工具按钮（避免零宽 frame 导致 UI 异常）

    let tabStripWidth: Double
    // 页签条的可用宽度。等于总可用宽度减去侧栏工具和侧栏恢复按钮的宽度

    let showsSidebarRecovery: Bool
    // 是否显示「侧栏恢复」按钮。当侧栏被隐藏时，显示一个小按钮
    // 让用户可以重新展开侧栏

    let sidebarRecoveryWidth: Double
    // 侧栏恢复按钮的宽度（最大 40 点）

    let drawsDetailTabBar: Bool
    // 是否在详情区域底部绘制独立的标签栏。当前固定为 false，
    // 预留扩展用

    static func resolve(
        windowWidth: Double,
        // 窗口总宽度（点）
        sidebarWidth: Double,
        // 侧栏的设计宽度（点）
        isSidebarVisible: Bool,
        // 侧栏当前是否可见
        leadingReservedWidth: Double,
        // 左侧预留宽度（如 macOS 交通灯按钮）
        trailingReservedWidth: Double,
        // 右侧预留宽度
        isFullScreen _: Bool,
        // 是否全屏模式。参数名用 _ 忽略，当前未使用，预留扩展
        showsCustomSidebarRecovery: Bool = true
        // 是否启用自定义侧栏恢复按钮。默认 true，
        // 调用方可以传 false 来禁用
    ) -> UnifiedWorkspaceChromeLayout {
        // 静态工厂方法：根据所有参数计算完整的布局尺寸

        let safeWindowWidth = finiteNonnegative(windowWidth)
        // 窗口宽度安全化：确保为非负有限值，防止 NaN 污染后续计算

        let safeLeadingWidth = min(finiteNonnegative(leadingReservedWidth), safeWindowWidth)
        // 左侧预留宽度安全化，且不超过窗口总宽度
        // min() 确保即使预留值异常大，也不会超过窗口宽度

        let safeTrailingWidth = min(
            finiteNonnegative(trailingReservedWidth),
            // 右侧预留宽度安全化
            max(0, safeWindowWidth - safeLeadingWidth)
            // 且不超过「窗口宽度 - 左侧预留」的剩余空间
            // max(0, ...) 确保上限不为负数
        )
        // 左右预留宽度之和不会超过窗口总宽度

        let availableWidth = max(0, safeWindowWidth - safeLeadingWidth - safeTrailingWidth)
        // 可用宽度 = 窗口总宽度 - 左侧预留 - 右侧预留
        // max(0, ...) 确保结果不为负数

        let sidebarToolsWidth = isSidebarVisible
            // 只有侧栏可见时才分配侧栏工具宽度
            ? min(max(0, finiteNonnegative(sidebarWidth) - safeLeadingWidth), availableWidth)
            // 侧栏可见时：侧栏工具宽度 = 侧栏宽度 - 左侧预留（交通灯占了一部分）
            // max(0, ...) 确保不为负；min(..., availableWidth) 确保不超过总可用宽度
            : 0
            // 侧栏不可见时：侧栏工具宽度为 0

        let showsSidebarRecovery = !isSidebarVisible && showsCustomSidebarRecovery
        // 侧栏恢复按钮显示条件：侧栏不可见 且 启用了自定义恢复功能

        let sidebarRecoveryWidth = showsSidebarRecovery ? min(40, availableWidth) : 0
        // 侧栏恢复按钮宽度：需要显示时最大 40 点（不超过可用宽度），
        // 不需要显示时为 0

        return UnifiedWorkspaceChromeLayout(
            leadingSafeWidth: safeLeadingWidth,
            // 左侧安全区宽度

            trailingSafeWidth: safeTrailingWidth,
            // 右侧安全区宽度

            availableWidth: availableWidth,
            // 中间可用总宽度

            sidebarToolsWidth: sidebarToolsWidth,
            // 侧栏工具区域宽度

            tabStripWidth: max(0, availableWidth - sidebarToolsWidth - sidebarRecoveryWidth),
            // 页签条宽度 = 可用总宽度 - 侧栏工具宽度 - 侧栏恢复按钮宽度
            // max(0, ...) 确保不为负数

            showsSidebarRecovery: showsSidebarRecovery,
            // 是否显示侧栏恢复按钮

            sidebarRecoveryWidth: sidebarRecoveryWidth,
            // 侧栏恢复按钮宽度

            drawsDetailTabBar: false
            // 详情区域标签栏：当前固定不绘制
        )
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        // 私有辅助方法：将任意 Double 值安全化为非负有限值
        value.isFinite ? max(0, value) : 0
        // 有限值 → 取 max(0, value) 确保非负
        // NaN 或 Infinity → 返回 0，避免异常值导致布局崩溃
    }
}

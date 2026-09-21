// =============================================================================
// IPadWorkspaceChromeHostPolicy.swift
// =============================================================================
// 文件功能说明：
// 定义 iPadOS 平台下「宿主 Chrome（外壳框架）」的适配策略。
// "Chrome" 指的是应用窗口的外壳框架（标题栏、导航栏等装饰性 UI）。
// iPadOS 与 macOS 的窗口管理方式不同：iPadOS 使用系统级导航（如返回手势），
// 因此这个策略文件只描述安全区边距和系统导航行为，不涉及页签或会话规则。
// =============================================================================

import Foundation
// 导入 Foundation 框架，提供基础数据类型

/// iPadOS 宿主的薄适配策略；只表达安全区与系统导航，不承载页签或会话规则。
struct IPadWorkspaceChromeHostPolicy: Equatable {
    // Equatable 让两个策略实例可以比较是否相同，
    // SwiftUI 借此判断布局是否需要更新

    let usesSystemNavigation: Bool
    // 是否使用系统级导航（如 iPadOS 的侧滑返回手势、导航栏返回按钮）。
    // iPadOS 上通常为 true，表示依赖系统提供的导航机制

    let topInset: Double
    // 顶部安全区内边距（单位：点/pt）。
    // iPadOS 有刘海、状态栏等区域不能放置交互内容，
    // 这个值告诉布局系统顶部需要留白多少

    let compactsTopChrome: Bool
    // 是否压缩顶部外壳（标题栏区域）的高度。
    // 在紧凑模式下（如分屏、Slide Over），顶部空间有限，需要缩小标题栏

    /// 两侧各预留 44 点导航控件与 4 点间距，页签只使用详情列内的剩余宽度。
    static func navigationTabStripWidth(availableWidth: Double) -> Double {
        // 静态方法：根据可用总宽度，计算页签条（tab strip）实际能使用的宽度。
        // 参数 availableWidth：详情列的总可用宽度（点）
        // 44 点是 iOS 人机界面指南推荐的最小可点击区域宽度，
        // 两侧各留 44 + 4 = 48 点，共 96 点给导航按钮

        availableWidth.isFinite ? max(0, availableWidth - 96) : 0
        // 先检查 availableWidth 是否为有限数值（排除 NaN、Infinity 等异常值）
        // 如果是有限值：用总宽度减去 96 点（两侧导航预留），并确保结果不为负数
        // 如果不是有限值：返回 0，表示没有可用空间
    }

    static func resolve(topSafeArea: Double, isCompact: Bool) -> IPadWorkspaceChromeHostPolicy {
        // 静态工厂方法：根据当前 iPadOS 环境参数，创建一个完整的策略实例
        // 参数 topSafeArea：系统报告的顶部安全区高度（状态栏、刘海等）
        // 参数 isCompact：当前是否处于紧凑尺寸模式（如分屏）

        IPadWorkspaceChromeHostPolicy(
            usesSystemNavigation: true,
            // iPadOS 始终使用系统导航，因为 iPad 没有 macOS 那样的自定义标题栏拖动

            topInset: topSafeArea.isFinite ? max(0, topSafeArea) : 0,
            // 顶部内边距：取系统安全区高度，确保不为负数也不为异常值
            // 这样内容区域会从安全区下方开始绘制，避免被刘海遮挡

            compactsTopChrome: isCompact
            // 紧凑模式下压缩顶部外壳高度，节省屏幕空间
        )
    }
}

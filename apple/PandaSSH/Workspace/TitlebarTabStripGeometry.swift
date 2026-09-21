// =============================================================================
// TitlebarTabStripGeometry.swift
// =============================================================================
// 文件功能说明：
// 计算 macOS 标题栏中页签条（Tab Strip）的可用几何区域。
// macOS 的窗口标题栏可以嵌入自定义内容（如页签），但需要避开交通灯按钮
// （红黄绿关闭/最小化/最大化按钮）和窗口标题文字等系统控件。
// 这个结构体根据窗口宽度、各区域预留宽度等参数，计算出页签条可以安全
// 放置的矩形区域（frame）。仅在 macOS 平台编译（#if os(macOS)）。
// =============================================================================

#if os(macOS)
// 条件编译：以下代码只在 macOS 平台上编译，iPadOS 不包含此文件
// 因为 iPadOS 没有传统意义上的窗口标题栏

import Foundation
// 导入 Foundation，提供 CGRect 等几何类型

/// 标题栏页签容器的安全几何。输入均以窗口坐标系的横向尺寸表示，
/// 计算结果只描述可用区域，不负责实际把视图装配到标题栏。
struct TitlebarTabStripGeometry: Equatable {
    // Equatable 让两个几何实例可以比较，SwiftUI 借此判断是否需要重新布局

    let frame: CGRect
    // 计算出的页签条可用矩形区域：
    // - x: 左边界距窗口左缘的偏移量
    // - y: 顶部偏移（通常为 0，因为标题栏从窗口顶部开始）
    // - width: 可用宽度
    // - height: 可用高度（通常等于标题栏高度）

    var isUsable: Bool {
        // 计算属性：判断计算出的区域是否有意义（宽高都大于 0）
        frame.width > 0 && frame.height > 0
        // 如果宽度或高度为 0，说明没有足够空间放置页签条，返回 false
    }

    static func resolve(
        windowWidth: Double,
        // 整个窗口的宽度（点）
        detailMinX: Double,
        // 详情列（detail column）的左边界 X 坐标
        leadingReservedWidth: Double,
        // 左侧预留宽度（如 macOS 交通灯按钮占用的空间）
        trailingReservedWidth: Double,
        // 右侧预留宽度（如窗口标题文字或其他控件占用的空间）
        titlebarHeight: Double
        // 标题栏的高度（点）
    ) -> TitlebarTabStripGeometry {
        // 根据以上参数，计算页签条的安全矩形区域

        let width = nonnegative(windowWidth)
        // 将窗口宽度安全化：确保不为负数或 NaN

        let detailStart = min(nonnegative(detailMinX), width)
        // 详情列起始位置：取 detailMinX 和窗口宽度的较小值，
        // 防止详情列起始位置超出窗口右边界

        let leading = nonnegative(leadingReservedWidth)
        // 左侧预留宽度安全化（≥ 0）

        let trailing = nonnegative(trailingReservedWidth)
        // 右侧预留宽度安全化（≥ 0）

        let minX = min(width, detailStart + leading)
        // 页签条左边界 = 详情列起始位置 + 左侧预留宽度，
        // 但不超过窗口总宽度（防止溢出）

        let maxX = max(minX, width - trailing)
        // 页签条右边界 = 窗口宽度 - 右侧预留宽度，
        // 但不小于 minX（防止右边界跑到左边界左边，产生负宽度）

        return TitlebarTabStripGeometry(
            frame: CGRect(x: minX, y: 0, width: maxX - minX, height: nonnegative(titlebarHeight))
            // 构造矩形：
            // x = minX（左边界）
            // y = 0（从标题栏顶部开始）
            // width = maxX - minX（可用宽度）
            // height = 标题栏高度（安全化为非负值）
        )
    }

    private static func nonnegative(_ value: Double) -> Double {
        // 私有辅助方法：将任意 Double 值安全化为非负有限值
        value.isFinite ? max(0, value) : 0
        // 如果是有限数：取 max(0, value)，确保不为负数
        // 如果是 NaN 或 Infinity：返回 0，避免异常值污染后续计算
    }
}
#endif
// 结束 macOS 条件编译块

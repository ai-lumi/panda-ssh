// =============================================================================
// QuitProtectionToast.swift — macOS 平台「再按一次退出」提示条
// =============================================================================
// 本文件仅在 macOS 平台编译（#if os(macOS)）。
// 实现一个底部中央的半透明圆角提示条，当用户第一次按下退出快捷键时显示，
// 提醒用户"再按一次退出"，防止误操作关闭应用。
// 提示条带有从底部滑入 + 淡入的组合动画效果。
// =============================================================================

// 条件编译：以下代码仅在 macOS 平台上编译，iPadOS 不包含此组件
#if os(macOS)
// 引入 SwiftUI 框架
import SwiftUI

/// 「再按一次退出」toast 提示视图。
/// 底部中央半透明圆角提示条，带进入/退出动画。
///
/// 视觉效果：一个带警告图标 + 文字的圆角矩形条，悬浮在窗口底部中央，
/// 背景为毛玻璃半透明材质，带有轻微阴影，从底部滑入/滑出。
struct QuitProtectionToast: View {
    /// 控制提示条是否可见；由外部父视图根据退出保护状态传入。
    /// 当 isVisible 为 true 时显示提示条，false 时隐藏。
    let isVisible: Bool

    /// 定义视图的内容结构。
    var body: some View {
        // 仅当 isVisible 为 true 时才渲染提示条内容
        if isVisible {
            // 水平堆叠布局：图标和文字横向排列，间距 8pt
            HStack(spacing: 8) {
                // 系统图标：实心警告三角形 ⚠️
                Image(systemName: "exclamationmark.triangle.fill")
                    // 图标颜色：黄色，传达警告含义
                    .foregroundStyle(.yellow)
                // 提示文字，告知用户需要再次操作才能退出
                Text("再按一次退出")
                    // 字体：callout 字号（比正文略小，适合辅助提示信息）
                    .font(.callout)
                    // 文字颜色：系统主色调（自动适配浅色/深色模式）
                    .foregroundStyle(.primary)
            }
            // 水平方向（左右）内边距 16pt，让内容不紧贴圆角边缘
            .padding(.horizontal, 16)
            // 垂直方向（上下）内边距 10pt，让内容上下留有呼吸空间
            .padding(.vertical, 10)
            // 背景：半透明毛玻璃材质，形状为圆角矩形（圆角半径 10pt）
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            // 投影效果：黑色 15% 透明度，模糊半径 8pt，向下偏移 2pt，营造悬浮感
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            // 出现/消失动画：从底部滑入 + 淡入淡出组合效果
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // 无障碍标识符：用于 UI 自动化测试定位此元素
            .accessibilityIdentifier("quit-protection-toast")
        }
        // 注意：当 isVisible 变为 false 时，视图从视图树中移除，
        // 配合父视图的 withAnimation 块，会触发 transition 定义的退出动画。
    }
}
// 结束 macOS 条件编译块
#endif

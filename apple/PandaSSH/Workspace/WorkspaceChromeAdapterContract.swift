// =============================================================================
// WorkspaceChromeAdapterContract.swift
// =============================================================================
// 文件功能说明：
// 定义平台 Chrome（窗口外壳框架）向共享工作区布局系统提供的「契约」。
//
// 所谓「契约」是一组纯数值属性（不含任何业务逻辑），描述当前平台的
// 窗口外壳能提供什么样的空间条件：是否使用标题栏安全矩形、是否有窗口拖动区域、
// 左右各预留多少宽度给系统控件等。
//
// macOS 和 iPadOS 的窗口行为差异很大：
// - macOS 有自定义标题栏，可以嵌入页签，有交通灯按钮预留空间
// - iPadOS 使用系统导航栏，有顶部安全区（刘海），没有窗口拖动概念
//
// 这个结构体把平台差异抽象成统一的数值接口，让上层布局代码不需要关心
// 具体是哪个平台。
// =============================================================================

import Foundation
// 导入 Foundation 框架

/// 平台 chrome 宿主向共享工作区提供的纯值边界。
/// 该契约不包含任何页签、会话或业务行为，因此可由 macOS 与 iPadOS 共用。
struct WorkspaceChromeAdapterContract: Equatable {
    // Equatable 让两个契约实例可以比较，
    // 当平台参数变化时 SwiftUI 能检测到并重新布局

    enum Platform: Equatable {
        // 内部枚举：标识当前运行的平台
        case macOS
        // macOS 桌面平台
        case iPadOS
        // iPadOS 平板平台
    }

    let usesTitlebarSafeRectangle: Bool
    // 是否使用标题栏安全矩形区域来放置页签条。
    // macOS 为 true：页签条放在标题栏的安全矩形内（避开交通灯和标题文字）
    // iPadOS 为 false：iPadOS 没有传统标题栏

    let providesWindowDragRegion: Bool
    // 是否提供窗口拖动区域。
    // macOS 为 true：标题栏空白区域可以拖动窗口
    // iPadOS 为 false：iPadOS 窗口移动由系统处理

    let usesSystemNavigation: Bool
    // 是否使用系统级导航（如返回手势、系统导航栏）。
    // macOS 为 false：macOS 不使用系统导航
    // iPadOS 为 true：iPadOS 依赖系统的导航机制

    let leadingReservedWidth: Double
    // 左侧预留宽度（点）。macOS 上用于交通灯按钮等系统控件，
    // iPadOS 上为 0（不需要左侧预留）

    let trailingReservedWidth: Double
    // 右侧预留宽度（点）。macOS 上用于窗口标题或其他控件，
    // iPadOS 上为 0

    let topInset: Double
    // 顶部内边距（点）。macOS 上为 0（标题栏从窗口顶部开始），
    // iPadOS 上等于顶部安全区高度（避开刘海和状态栏）

    static func resolve(
        platform: Platform,
        // 当前运行平台
        leadingReservedWidth: Double,
        // 调用方报告的左侧预留宽度
        trailingReservedWidth: Double,
        // 调用方报告的右侧预留宽度
        topSafeArea: Double
        // 系统报告的顶部安全区高度
    ) -> WorkspaceChromeAdapterContract {
        // 静态工厂方法：根据平台和参数，生成对应的契约实例

        switch platform {
        // 根据平台类型分支处理

        case .macOS:
            return WorkspaceChromeAdapterContract(
                usesTitlebarSafeRectangle: true,
                // macOS 使用标题栏安全矩形来放置页签条

                providesWindowDragRegion: true,
                // macOS 提供窗口拖动区域（标题栏空白处可拖动窗口）

                usesSystemNavigation: false,
                // macOS 不使用系统导航，而是自定义导航控件

                leadingReservedWidth: finiteNonnegative(leadingReservedWidth),
                // 左侧预留宽度安全化（确保为非负有限值）

                trailingReservedWidth: finiteNonnegative(trailingReservedWidth),
                // 右侧预留宽度安全化

                topInset: 0
                // macOS 顶部内边距为 0，标题栏紧贴窗口顶部
            )

        case .iPadOS:
            return WorkspaceChromeAdapterContract(
                usesTitlebarSafeRectangle: false,
                // iPadOS 不使用标题栏安全矩形（没有传统标题栏）

                providesWindowDragRegion: false,
                // iPadOS 不提供窗口拖动区域（由系统管理窗口移动）

                usesSystemNavigation: true,
                // iPadOS 使用系统导航

                leadingReservedWidth: 0,
                // iPadOS 左侧不需要预留空间给系统控件

                trailingReservedWidth: 0,
                // iPadOS 右侧也不需要预留

                topInset: finiteNonnegative(topSafeArea)
                // iPadOS 顶部内边距等于安全区高度（避开刘海/状态栏）
            )
        }
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        // 私有辅助方法：将任意 Double 值安全化为非负有限值
        value.isFinite ? max(0, value) : 0
        // 有限值 → 取 max(0, value) 确保非负
        // NaN 或 Infinity → 返回 0
    }
}

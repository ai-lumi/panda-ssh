// =============================================================================
// WorkspaceLayoutPolicy.swift
// =============================================================================
// 文件功能说明：
// 定义工作区的整体布局策略，决定 UI 以什么形式呈现给用户。
//
// 不同的平台和屏幕尺寸需要不同的布局方式：
// - macOS 桌面屏幕大 → 侧栏和主内容并排显示（sideBySide），SFTP 用双栏模式
// - iPadOS 宽屏 → 类似 macOS，并排显示
// - iPadOS 紧凑模式（分屏/Slide Over）→ 侧栏折叠为系统抽屉，SFTP 用单栏
//
// 这个结构体只描述「呈现方式」，不包含 SSH/SFTP 的业务状态。
// 它根据平台类型、尺寸类别和可用宽度来决定使用哪种布局。
// =============================================================================

import Foundation
// 导入 Foundation 框架

/// 仅描述工作区的呈现方式，不承载 SSH/SFTP 业务状态。
struct WorkspaceLayoutPolicy: Equatable {
    // Equatable 让两个策略实例可以比较，
    // 当窗口尺寸或平台变化时 SwiftUI 能检测到并重新布局

    enum Platform: Equatable {
        // 内部枚举：标识运行平台
        case macOS
        // macOS 桌面平台
        case iPadOS
        // iPadOS 平板平台
    }

    enum HorizontalSizeClass: Equatable {
        // 内部枚举：水平尺寸类别，描述屏幕在水平方向上的可用空间大小
        case compact
        // 紧凑模式：屏幕较窄（如 iPad 分屏、Slide Over），
        // 需要简化布局以节省空间
        case regular
        // 常规模式：屏幕足够宽，可以并排显示多个面板
        case unspecified
        // 未指定：无法确定尺寸类别时的默认值
    }

    enum SidebarPresentation: Equatable {
        // 内部枚举：侧栏的呈现方式
        case sideBySide
        // 并排显示：侧栏和主内容区同时可见，左右排列
        case systemCollapsed
        // 系统折叠：侧栏被系统隐藏为抽屉（overlay），
        // 需要用户手动滑出或点击按钮展开
    }

    enum SFTPPresentation: Equatable {
        // 内部枚举：SFTP 文件传输界面的呈现方式
        case dualPane
        // 双栏模式：左边显示远程目录，右边显示本地目录（或两个远程目录），
        // 方便拖拽传输文件
        case singlePane
        // 单栏模式：只显示一个目录视图，屏幕空间有限时的简化布局
    }

    static let regularWidthThreshold = 700.0
    // 静态常量：常规布局的最小宽度阈值（700 点）。
    // 当可用宽度 >= 700 点时认为空间足够，可以使用并排布局；
    // 小于 700 点则退回到紧凑布局

    let sidebarPresentation: SidebarPresentation
    // 侧栏呈现方式（并排 or 系统折叠）

    let sftpPresentation: SFTPPresentation
    // SFTP 界面呈现方式（双栏 or 单栏）

    let minimumInteractiveLength: Double
    // 最小可交互元素尺寸（点）。
    // macOS 为 24 点（鼠标操作可以更小）；
    // iPadOS 为 44 点（Apple 人机界面指南推荐的最小手指触摸尺寸）

    static func resolve(
        platform: Platform,
        // 当前运行平台
        horizontalSizeClass: HorizontalSizeClass,
        // 水平尺寸类别（compact/regular/unspecified）
        availableWidth: Double
        // 当前可用宽度（点）
    ) -> WorkspaceLayoutPolicy {
        // 静态工厂方法：根据平台和尺寸参数，决定使用哪种布局策略

        if platform == .macOS {
            // macOS 分支：桌面平台始终使用最完整的布局

            return WorkspaceLayoutPolicy(
                sidebarPresentation: .sideBySide,
                // macOS 屏幕够大，侧栏始终并排显示

                sftpPresentation: .dualPane,
                // macOS 使用 SFTP 双栏模式，方便文件管理

                minimumInteractiveLength: 24
                // macOS 最小交互尺寸 24 点（鼠标精确操作，不需要太大的点击区域）
            )
        }
        // 以下代码只针对 iPadOS 平台执行

        let hasUsableWidth = availableWidth.isFinite && availableWidth > 0
        // 判断可用宽度是否有效：必须是有限数值且大于 0
        // 排除 NaN、Infinity 和 0 等异常情况

        let usesCompactPresentation = horizontalSizeClass == .compact
            // 条件 1：系统报告为紧凑尺寸类别
            || !hasUsableWidth
            // 条件 2：可用宽度无效（无法确定宽度时保守地使用紧凑布局）
            || availableWidth < regularWidthThreshold
            // 条件 3：可用宽度小于 700 点阈值
        // 三个条件满足任意一个 → 使用紧凑布局

        if usesCompactPresentation {
            // 紧凑模式分支

            return WorkspaceLayoutPolicy(
                sidebarPresentation: .systemCollapsed,
                // 侧栏折叠为系统抽屉，节省有限的屏幕空间

                sftpPresentation: .singlePane,
                // SFTP 使用单栏模式，因为屏幕太窄放不下两个面板

                minimumInteractiveLength: 44
                // iPadOS 最小交互尺寸 44 点（手指触摸需要更大的点击区域）
            )
        }
        // 不满足紧凑条件 → 使用常规（宽松）布局

        return WorkspaceLayoutPolicy(
            sidebarPresentation: .sideBySide,
            // 侧栏并排显示，屏幕足够宽可以同时展示侧栏和主内容

            sftpPresentation: .dualPane,
            // SFTP 使用双栏模式，充分利用宽屏空间

            minimumInteractiveLength: 44
            // iPadOS 常规模式下最小交互尺寸仍为 44 点（触摸操作标准）
        )
    }
}

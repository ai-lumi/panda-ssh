import Foundation

/// iPadOS 宿主的薄适配策略；只表达安全区与系统导航，不承载页签或会话规则。
struct IPadWorkspaceChromeHostPolicy: Equatable {
    let usesSystemNavigation: Bool
    let topInset: Double
    let compactsTopChrome: Bool

    /// 两侧各预留 44 点导航控件与 4 点间距，页签只使用详情列内的剩余宽度。
    static func navigationTabStripWidth(availableWidth: Double) -> Double {
        availableWidth.isFinite ? max(0, availableWidth - 96) : 0
    }

    static func resolve(topSafeArea: Double, isCompact: Bool) -> IPadWorkspaceChromeHostPolicy {
        IPadWorkspaceChromeHostPolicy(
            usesSystemNavigation: true,
            topInset: topSafeArea.isFinite ? max(0, topSafeArea) : 0,
            compactsTopChrome: isCompact
        )
    }
}

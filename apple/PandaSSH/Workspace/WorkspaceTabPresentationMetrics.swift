import Foundation

struct WorkspaceTabPresentationMetrics: Equatable {
    enum Platform {
        case macOS
        case iPadOS
    }

    static let maximumTitleWidth = 180.0

    let showsCloseButton: Bool
    let minimumHitTarget: Double
    let closeButtonCornerRadius: Double
    let minimumTabHeight: Double
    let maximumTitleWidth: Double
    /// 父容器的选择手势不能接收关闭按钮等子控件的点击。
    let selectionGestureIncludesSubviews: Bool

    static func resolve(
        platform: Platform,
        isActive: Bool,
        isHovered: Bool,
        availableWidth: Double,
        titleCharacterCount _: Int
    ) -> WorkspaceTabPresentationMetrics {
        let safeAvailableWidth = availableWidth.isFinite && availableWidth > 0 ? availableWidth : 0
        let titleWidth = min(
            maximumTitleWidth,
            safeAvailableWidth
        )

        switch platform {
        case .macOS:
            return WorkspaceTabPresentationMetrics(
                showsCloseButton: isActive || isHovered,
                minimumHitTarget: 24,
                closeButtonCornerRadius: 4,
                minimumTabHeight: 28,
                maximumTitleWidth: titleWidth,
                selectionGestureIncludesSubviews: false
            )
        case .iPadOS:
            return WorkspaceTabPresentationMetrics(
                showsCloseButton: isActive || isHovered,
                minimumHitTarget: 44,
                closeButtonCornerRadius: 6,
                minimumTabHeight: 44,
                maximumTitleWidth: titleWidth,
                selectionGestureIncludesSubviews: false
            )
        }
    }
}

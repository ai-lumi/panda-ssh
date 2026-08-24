import Foundation

struct WorkspaceTabPresentationMetrics: Equatable {
    enum Platform {
        case macOS
        case iPadOS
    }

    static let maximumTitleWidth = 180.0
    private static let estimatedCharacterWidth = 8.0

    let showsCloseButton: Bool
    let minimumHitTarget: Double
    let minimumTabHeight: Double
    let maximumTitleWidth: Double

    static func resolve(
        platform: Platform,
        isActive: Bool,
        isHovered: Bool,
        availableWidth: Double,
        titleCharacterCount: Int
    ) -> WorkspaceTabPresentationMetrics {
        let safeAvailableWidth = availableWidth.isFinite && availableWidth > 0 ? availableWidth : 0
        let safeCharacterCount = max(0, titleCharacterCount)
        let titleWidth = min(
            maximumTitleWidth,
            safeAvailableWidth,
            Double(safeCharacterCount) * estimatedCharacterWidth
        )

        switch platform {
        case .macOS:
            return WorkspaceTabPresentationMetrics(
                showsCloseButton: isActive || isHovered,
                minimumHitTarget: 24,
                minimumTabHeight: 28,
                maximumTitleWidth: titleWidth
            )
        case .iPadOS:
            return WorkspaceTabPresentationMetrics(
                showsCloseButton: isActive || isHovered,
                minimumHitTarget: 44,
                minimumTabHeight: 44,
                maximumTitleWidth: titleWidth
            )
        }
    }
}

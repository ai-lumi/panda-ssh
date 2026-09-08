import Foundation

/// 平台 chrome 宿主向共享工作区提供的纯值边界。
/// 该契约不包含任何页签、会话或业务行为，因此可由 macOS 与 iPadOS 共用。
struct WorkspaceChromeAdapterContract: Equatable {
    enum Platform: Equatable {
        case macOS
        case iPadOS
    }

    let usesTitlebarSafeRectangle: Bool
    let providesWindowDragRegion: Bool
    let usesSystemNavigation: Bool
    let leadingReservedWidth: Double
    let trailingReservedWidth: Double
    let topInset: Double

    static func resolve(
        platform: Platform,
        leadingReservedWidth: Double,
        trailingReservedWidth: Double,
        topSafeArea: Double
    ) -> WorkspaceChromeAdapterContract {
        switch platform {
        case .macOS:
            return WorkspaceChromeAdapterContract(
                usesTitlebarSafeRectangle: true,
                providesWindowDragRegion: true,
                usesSystemNavigation: false,
                leadingReservedWidth: finiteNonnegative(leadingReservedWidth),
                trailingReservedWidth: finiteNonnegative(trailingReservedWidth),
                topInset: 0
            )
        case .iPadOS:
            return WorkspaceChromeAdapterContract(
                usesTitlebarSafeRectangle: false,
                providesWindowDragRegion: false,
                usesSystemNavigation: true,
                leadingReservedWidth: 0,
                trailingReservedWidth: 0,
                topInset: finiteNonnegative(topSafeArea)
            )
        }
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

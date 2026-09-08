#if os(macOS)
import Foundation

/// 标题栏页签容器的安全几何。输入均以窗口坐标系的横向尺寸表示，
/// 计算结果只描述可用区域，不负责实际把视图装配到标题栏。
struct TitlebarTabStripGeometry: Equatable {
    let frame: CGRect

    var isUsable: Bool {
        frame.width > 0 && frame.height > 0
    }

    static func resolve(
        windowWidth: Double,
        detailMinX: Double,
        leadingReservedWidth: Double,
        trailingReservedWidth: Double,
        titlebarHeight: Double
    ) -> TitlebarTabStripGeometry {
        let width = nonnegative(windowWidth)
        let detailStart = min(nonnegative(detailMinX), width)
        let leading = nonnegative(leadingReservedWidth)
        let trailing = nonnegative(trailingReservedWidth)
        let minX = min(width, detailStart + leading)
        let maxX = max(minX, width - trailing)
        return TitlebarTabStripGeometry(
            frame: CGRect(x: minX, y: 0, width: maxX - minX, height: nonnegative(titlebarHeight))
        )
    }

    private static func nonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
#endif

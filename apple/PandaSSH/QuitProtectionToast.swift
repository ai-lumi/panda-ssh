#if os(macOS)
import SwiftUI

/// 「再按一次退出」toast 提示视图。
/// 底部中央半透明圆角提示条，带进入/退出动画。
struct QuitProtectionToast: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("再按一次退出")
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("quit-protection-toast")
        }
    }
}
#endif

import SwiftUI

/// 自定义页签按钮：左侧彩色状态圆点、中间页签标题、右侧关闭按钮。
/// 当前活动页签高亮；点击切换活动页签；关闭按钮触发关闭动作。
struct WorkspaceTabButton: View {
    let tab: WorkspaceTab
    let dotColor: Color
    let statusLabel: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var metrics: WorkspaceTabPresentationMetrics {
        WorkspaceTabPresentationMetrics.resolve(
            platform: .macOS,
            isActive: isActive,
            isHovered: hovering,
            availableWidth: WorkspaceTabPresentationMetrics.maximumTitleWidth,
            titleCharacterCount: tab.title.count
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    Text(tab.title)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: metrics.maximumTitleWidth, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title)
            .accessibilityValue(statusLabel)
            .accessibilityHint("切换到此标签页")
            .accessibilityAddTraits(isActive ? .isSelected : [])

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: metrics.minimumHitTarget, height: metrics.minimumHitTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(
                hovering ? Color.primary.opacity(0.12) : Color.clear,
                in: Circle()
            )
            .opacity(metrics.showsCloseButton ? 1 : 0)
            .allowsHitTesting(metrics.showsCloseButton)
            .accessibilityLabel("关闭 \(tab.title)")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: metrics.minimumTabHeight)
        .background(
            isActive ? Color.primary.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}

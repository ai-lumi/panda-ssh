import SwiftUI

/// 自定义页签按钮：左侧彩色状态圆点、中间页签标题、右侧关闭按钮。
/// 当前活动页签高亮；点击切换活动页签；关闭按钮触发关闭动作。
struct WorkspaceTabButton: View {
    let tab: WorkspaceTab
    let dotColor: Color
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)

            Text(tab.title)
                .font(.callout)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(
                hovering ? Color.primary.opacity(0.12) : Color.clear,
                in: Circle()
            )
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("关闭标签页")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isActive ? Color.primary.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

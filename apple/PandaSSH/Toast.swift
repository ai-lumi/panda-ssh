import SwiftUI

/// 轻量 toast:顶部胶囊提示,1.8 秒自动消失(与原型 toast 一致)。
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var message: String?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        message = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

/// toast 展示修饰器:挂在根视图顶部。
private struct ToastOverlay: ViewModifier {
    @ObservedObject var center: ToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = center.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(white: 0.16).opacity(0.92), in: Capsule())
                    .shadow(radius: 8)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.message)
    }
}

extension View {
    func toastOverlay(_ center: ToastCenter) -> some View {
        modifier(ToastOverlay(center: center))
    }
}

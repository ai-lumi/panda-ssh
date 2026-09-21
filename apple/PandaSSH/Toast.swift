// =============================================================================
// Toast.swift — 轻量级 Toast 提示组件
// =============================================================================
// 本文件实现了一个顶部胶囊样式的临时消息提示（toast）系统。
// 包含三部分：
//   1. ToastCenter ——  observable 对象，管理当前要显示的消息及自动隐藏计时。
//   2. ToastOverlay ——  ViewModifier，将 toast 以 overlay 形式挂在根视图顶部。
//   3. View 扩展 —— 提供 .toastOverlay() 便捷方法，一行即可挂载 toast 功能。
// =============================================================================

// 引入 SwiftUI 框架，提供声明式 UI 能力
import SwiftUI

/// 轻量 toast:顶部胶囊提示,1.8 秒自动消失(与原型 toast 一致)。
///
/// 使用方式：在根视图上调用 `.toastOverlay(toastCenter)`，
/// 然后 anywhere 调用 `toastCenter.show("操作成功")` 即可弹出提示。
// 标记整个类必须在主线程（Main Actor）上运行，保证 UI 操作线程安全
@MainActor
final class ToastCenter: ObservableObject {
    /// 当前要显示的 toast 消息文本；为 nil 时不显示任何 toast。
    /// `private(set)` 表示外部只能读取、不能直接赋值，必须通过 show() 方法修改。
    /// `@Published` 使得任何持有 `@ObservedObject` 的视图在值变化时自动刷新。
    @Published private(set) var message: String?

    /// 用于控制自动隐藏的异步任务句柄。
    /// 每次调用 show() 时会取消旧任务、创建新任务，实现"连续调用时重新计时"的效果。
    private var hideTask: Task<Void, Never>?

    /// 显示一条 toast 消息。如果在 1.8 秒内再次调用，计时器会重置。
    /// - Parameter text: 要显示的提示文本
    func show(_ text: String) {
        // 设置消息内容，触发 @Published 通知视图刷新，toast 立即出现
        message = text
        // 取消之前可能还在等待的隐藏任务，防止提前消失
        hideTask?.cancel()
        // 创建一个新的异步任务：等待 1.8 秒后将 message 置为 nil（toast 消失）
        hideTask = Task { [weak self] in
            // [weak self] 弱引用 self，避免 Task 持有 ToastCenter 导致循环引用/内存泄漏
            // 暂停 1.8 秒；try? 忽略取消异常
            try? await Task.sleep(for: .seconds(1.8))
            // 如果任务被取消（新的 show 调用触发），直接退出
            guard !Task.isCancelled else { return }
            // 1.8 秒后清空消息，toast 从界面上消失
            self?.message = nil
        }
    }
}

/// toast 展示修饰器:挂在根视图顶部。
///
/// 这是一个 ViewModifier，作用是将 toast 消息以 overlay 的形式叠加在任意视图的顶部中央。
/// 当 `center.message` 有值时显示胶囊形提示条，无值时不显示任何内容。
private struct ToastOverlay: ViewModifier {
    /// 观察 ToastCenter 的消息变化；消息变化时视图自动重新渲染。
    @ObservedObject var center: ToastCenter

    /// 定义修饰器的视图结构：在原内容之上叠加 toast 层。
    func body(content: Content) -> some View {
        // overlay：在原视图上方叠加一层子视图；alignment: .top 表示对齐到顶部
        content.overlay(alignment: .top) {
            // 仅当有消息时才渲染 toast（可选绑定解包）
            if let message = center.message {
                // 显示消息文本
                Text(message)
                    // 字体：callout 字号（比正文略小，适合辅助信息）
                    .font(.callout)
                    // 文字颜色：使用系统主色调（自动适配浅色/深色模式）
                    .foregroundStyle(.primary)
                    // 水平方向（左右）内边距 16pt，让文字不紧贴胶囊边缘
                    .padding(.horizontal, 16)
                    // 垂直方向（上下）内边距 7pt，让文字上下留有呼吸空间
                    .padding(.vertical, 7)
                    // 背景：半透明毛玻璃材质（.regularMaterial），形状为胶囊形（两端半圆）
                    .background(.regularMaterial, in: Capsule())
                    // 距离视图顶部 12pt 的外边距，让 toast 不紧贴屏幕顶端
                    .padding(.top, 12)
                    // 出现/消失动画：从顶部滑入 + 淡入淡出组合效果
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 当 message 变化时，以 0.2 秒的缓入缓出动画过渡（配合 transition 生效）
        .animation(.easeInOut(duration: 0.2), value: center.message)
    }
}

extension View {
    /// 便捷方法：在任意视图上挂载 toast overlay。
    /// 用法示例：`ContentView().toastOverlay(toastCenter)`
    /// - Parameter center: ToastCenter 实例，管理 toast 的消息与生命周期
    /// - Returns: 添加了 toast 叠加层的视图
    func toastOverlay(_ center: ToastCenter) -> some View {
        // 应用上面定义的 ToastOverlay 修饰器
        modifier(ToastOverlay(center: center))
    }
}

#if os(macOS)
import SwiftUI
import AppKit

/// 主窗口 chrome 配置(持续生效,非一次性):
/// 隐藏标题文字、透明标题栏、内容延伸到窗口顶部、移除系统工具栏。
/// 系统工具栏会带来空白背景带与自带的侧栏切换按钮,且无法自定义容器布局;
/// 移除后顶部区域完全由 SwiftUI 自绘(侧栏顶部工具条 / 页签栏)。
/// macOS 26 上隐藏侧栏时系统会重新创建 NSToolbar(注入侧栏切换按钮),
/// 一次性配置会被覆盖,因此用 KVO + layout 钩子持续把 toolbar 重新置 nil。
/// 注:macOS 26 的分栏浮动面板强制把侧栏内容置于标题栏下方,
/// 无可见工具栏时系统不再支持侧栏融入标题栏(实测,见 openspec 相关迭代记录)。
struct MainWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ nsView: ChromeView, context: Context) { nsView.applyChrome() }

    final class ChromeView: NSView {
        private var toolbarObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            toolbarObservation?.invalidate()
            toolbarObservation = window?.observe(\.toolbar, options: [.new]) { [weak self] window, _ in
                // 系统重建工具栏(隐藏侧栏/分栏状态变化)时立即移除
                if window.toolbar != nil { self?.applyChrome() }
            }
            applyChrome()
        }

        override func layout() {
            super.layout()
            applyChrome()
        }

        func applyChrome() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            if window.toolbar != nil {
                window.toolbar = nil
            }
        }
    }
}

/// 窗口拖拽区:透明视图,mouseDownCanMoveWindow = true。
/// 系统工具栏移除后,顶部自绘区域的空白处用它保留拖拽窗口能力。
struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
#endif

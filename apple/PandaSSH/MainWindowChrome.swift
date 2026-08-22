#if os(macOS)
import SwiftUI
import AppKit

/// 主窗口 chrome 配置:隐藏标题文字、透明标题栏、内容延伸到窗口顶部。
/// macOS 26:保留系统工具栏——Tahoe 的分栏浮动面板只有在窗口持有可见
/// 工具栏时才会融入标题栏(面板顶部延伸到红绿灯行);移除工具栏时系统强制
/// 把侧栏面板压在标题栏下方。代价是 detail 区顶部有一条系统工具栏绘制带,
/// 且侧栏隐藏时系统会在标题栏放置自带的侧栏切换按钮(自绘的显隐按钮已移除)。
/// 注:此行为与现行 workspace spec「主窗口工具栏精简」不一致,待 spec 更新。
struct MainWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }
}

/// 窗口拖拽区:透明视图,mouseDownCanMoveWindow = true。
/// 顶部自绘区域的空白处用它保留拖拽窗口能力。
struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
#endif

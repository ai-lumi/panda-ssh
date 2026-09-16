#if os(macOS)
import SwiftUI
import AppKit

/// 拦截 CMD+W 系统快捷键，将其重定向为关闭活动页签而非关闭窗口。
///
/// macOS 系统 File 菜单的「关闭窗口」绑定了 CMD+W，优先级高于 SwiftUI
/// 的 `.onKeyPress`。此视图通过在 NSView 附加到窗口时安装本地事件监视器，
/// 在菜单系统处理按键前截获 CMD+W 并执行页签关闭。
struct CloseTabKeyInterceptor: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = InterceptorView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? InterceptorView)?.onClose = onClose
    }

    final class InterceptorView: NSView {
        var onClose: (() -> Void)?
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitor()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview == nil {
                removeMonitor()
            } else {
                installMonitor()
            }
        }

        deinit {
            removeMonitor()
        }

        private func installMonitor() {
            removeMonitor()
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.contains(.command),
                      event.charactersIgnoringModifiers == "w" else {
                    return event
                }
                self?.onClose?()
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }
}
#endif

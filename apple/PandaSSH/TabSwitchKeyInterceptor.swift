#if os(macOS)
import SwiftUI
import AppKit

/// 拦截 Ctrl+Tab / Ctrl+Shift+Tab 全局快捷键，在任何焦点状态下切换页签。
///
/// SwiftUI 的 `.onKeyPress` 依赖视图持有焦点，但终端视图（NSView-backed）
/// 会抢走 first responder，导致父视图的按键修饰符无法收到事件。
/// 本视图通过 `NSEvent.addLocalMonitorForEvents` 在 AppKit 事件管线的最前端
/// 截获 keyDown 事件，确保 Ctrl+Tab 始终生效。
struct TabSwitchKeyInterceptor: NSViewRepresentable {
    let onNext: () -> Void
    let onPrevious: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = InterceptorView()
        view.onNext = onNext
        view.onPrevious = onPrevious
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let interceptor = nsView as? InterceptorView
        interceptor?.onNext = onNext
        interceptor?.onPrevious = onPrevious
    }

    final class InterceptorView: NSView {
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
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
            // macOS 标准 keyCode：Tab=48, Escape=53, Return=36, 空格=49
            // @see Apple DTS: https://developer.apple.com/forums/thread/825509
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.contains(.control),
                      event.keyCode == 48 /* Tab key */ else {
                    return event
                }
                if event.modifierFlags.contains(.shift) {
                    self?.onPrevious?()
                } else {
                    self?.onNext?()
                }
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

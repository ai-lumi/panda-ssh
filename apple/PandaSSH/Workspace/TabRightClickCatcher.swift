#if os(macOS)
import AppKit
import SwiftUI

/// 透明右键监控层：检测右键点击并回调，不拦截左键/滚轮。
///
/// 设计要点：
/// - `hitTest` 返回 nil：不参与 hit-test，左键穿透到下层视图。
/// - `NSEvent.addLocalMonitorForEvents`：在 AppKit 事件管线中截获 `rightMouseDown`，
///   此监控在 hit-test 之前触发，不受 `hitTest` 返回值影响。
/// - 仅当右键位置在视图 bounds 内时触发回调，并传递 NSEvent 供 NSMenu 弹出使用。
struct TabRightClickMonitor: NSViewRepresentable {
    let onRightClick: (NSEvent) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    /// 透明监控 NSView：`hitTest` 返回 nil（左键穿透），
    /// 仅通过本地事件监控捕获右键。
    final class MonitorView: NSView {
        var onRightClick: ((NSEvent) -> Void)?
        private var monitor: Any?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// 不参与 hit-test：左键/滚轮穿透到下层视图。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            startMonitoring()
        }

        func startMonitoring() {
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(location) {
                    self.onRightClick?(event)
                    return nil
                }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }

        // MARK: - 测试钩子

        /// 模拟右键点击（测试用，生产代码不调用）。
        func simulateRightClick(at localPoint: NSPoint) {
            if bounds.contains(localPoint) {
                // 测试环境无真实 NSEvent，传 dummy event
                let dummyEvent = NSEvent.mouseEvent(
                    with: .rightMouseDown,
                    location: localPoint,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1.0
                )
                if let event = dummyEvent {
                    onRightClick?(event)
                }
            }
        }
    }
}

extension View {
    /// 在视图背景层叠加透明右键监控。左键/滚轮穿透，仅捕获右键。
    func onTabRightClick(perform action: @escaping (NSEvent) -> Void) -> some View {
        background(TabRightClickMonitor(onRightClick: action))
    }
}
#endif

// =============================================================================
// 文件：TabRightClickCatcher.swift
// 功能：在 macOS 上实现一个透明的右键监控层，覆盖在页签（Tab）上方。
//       它的设计非常巧妙：
//       - 对左键和滚轮完全"透明"（不拦截），让这些事件正常传递到下层视图
//       - 只捕获右键点击事件，并通过回调通知上层
//       - 通过 NSEvent.addLocalMonitorForEvents 在 AppKit 事件管线中截获右键，
//         这比 hitTest 更早触发，所以即使 hitTest 返回 nil 也能收到右键事件
//       这个文件仅在 macOS 平台编译（#if os(macOS) 条件编译）。
// =============================================================================

// 条件编译：以下代码仅在 macOS 平台上编译，iOS 不包含此文件内容
#if os(macOS)
// 导入 AppKit 框架（macOS 原生 UI 框架），提供 NSView、NSEvent 等类
import AppKit
// 导入 SwiftUI 框架，用于将此监控层嵌入 SwiftUI 视图层级
import SwiftUI

/// 透明右键监控层：检测右键点击并回调，不拦截左键/滚轮。
///
/// 设计要点：
/// - `hitTest` 返回 nil：不参与 hit-test，左键穿透到下层视图。
/// - `NSEvent.addLocalMonitorForEvents`：在 AppKit 事件管线中截获 `rightMouseDown`，
///   此监控在 hit-test 之前触发，不受 `hitTest` 返回值影响。
/// - 仅当右键位置在视图 bounds 内时触发回调，并传递 NSEvent 供 NSMenu 弹出使用。
///
/// 这个结构体遵循 NSViewRepresentable 协议，意思是把一个原生 AppKit 视图
/// （NSView）包装成可以在 SwiftUI 中使用的视图。
struct TabRightClickMonitor: NSViewRepresentable {
    /// 右键点击时的回调闭包。当检测到右键按下时调用，
    /// 参数 NSEvent 包含点击位置、时间戳等事件信息，
    /// 上层用它来确定在哪里弹出右键菜单。
    let onRightClick: (NSEvent) -> Void

    /// NSViewRepresentable 协议方法：创建原生 NSView 实例。
    /// SwiftUI 首次渲染此视图时调用一次。
    /// 参数：
    ///   - context: SwiftUI 提供的上下文对象（这里未使用）
    /// 返回值：创建好的 MonitorView 实例
    func makeNSView(context: Context) -> MonitorView {
        // 创建自定义的 MonitorView 实例
        let view = MonitorView()
        // 将外部传入的回调闭包赋值给 view 的 onRightClick 属性
        view.onRightClick = onRightClick
        // 返回创建好的视图
        return view
    }

    /// NSViewRepresentable 协议方法：当 SwiftUI 状态变化需要更新视图时调用。
    /// 这里只做一件事：把最新的回调闭包同步到原生视图上，
    /// 确保回调始终引用最新的闭包（避免捕获过期状态）。
    func updateNSView(_ nsView: MonitorView, context: Context) {
        // 更新原生视图上的回调闭包为最新值
        nsView.onRightClick = onRightClick
    }

    /// 透明监控 NSView：`hitTest` 返回 nil（左键穿透），
    /// 仅通过本地事件监控捕获右键。
    /// 这是一个原生 AppKit 视图类，被 SwiftUI 通过 NSViewRepresentable 包装使用。
    /// final 关键字表示不允许被继承。
    final class MonitorView: NSView {
        /// 右键点击时的回调闭包，由外层 TabRightClickMonitor 设置。
        /// 使用可选类型（?），因为初始化时可能尚未设置。
        var onRightClick: ((NSEvent) -> Void)?
        /// 事件监控器的引用。NSEvent.addLocalMonitorForEvents 返回一个不透明对象，
        /// 需要在视图销毁时移除，否则会导致内存泄漏。
        private var monitor: Any?

        /// 初始化方法：用给定的矩形区域创建视图。
        /// 参数：
        ///   - frameRect: 视图的初始位置和大小（CGRect 类型，macOS 上叫 NSRect）
        override init(frame frameRect: NSRect) {
            // 调用父类 NSView 的初始化方法
            super.init(frame: frameRect)
        }

        /// 标记此初始化方法不可用。
        /// 因为此视图只能通过代码创建，不应该从 Storyboard/XIB 文件加载。
        /// @available(*, unavailable) 告诉编译器任何调用都会报错。
        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// 不参与 hit-test：左键/滚轮穿透到下层视图。
        /// hitTest 是 AppKit 用来判断"鼠标事件应该由哪个视图处理"的方法。
        /// 返回 nil 表示"我不处理任何鼠标事件"，这样左键和滚轮就会穿透到下面的视图。
        /// 但右键不受影响，因为我们用的是 NSEvent.addLocalMonitorForEvents，
        /// 它在 hitTest 之前就会触发。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// 当视图被添加到窗口时调用（系统自动调用）。
        /// 这里启动右键事件监控。
        override func viewDidMoveToWindow() {
            // 先调用父类实现（标准做法，保持视图生命周期正确）
            super.viewDidMoveToWindow()
            // 启动事件监控
            startMonitoring()
        }

        /// 开始监控右键事件。
        /// 先停止已有的监控（避免重复注册），然后注册新的监控器。
        func startMonitoring() {
            // 先移除已有的监控器，防止重复注册
            stopMonitoring()
            // 确保视图已经添加到窗口（window 不为 nil），否则无法注册事件监控
            guard window != nil else { return }
            // 注册本地事件监控器，只监听右键按下事件（.rightMouseDown）
            // [weak self] 避免循环引用：闭包弱引用 self，当视图销毁时 self 自动变 nil
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                // 如果 self 已被释放（视图已销毁），直接返回原始事件（不拦截）
                guard let self else { return event }
                // 将事件的全局窗口坐标转换为相对于本视图的本地坐标
                let location = self.convert(event.locationInWindow, from: nil)
                // 判断右键点击位置是否在本视图的矩形区域内
                if self.bounds.contains(location) {
                    // 在视图内：调用回调通知上层有右键点击，传入事件对象
                    self.onRightClick?(event)
                    // 返回 nil 表示"消费"这个事件，不再传递给其他视图
                    return nil
                }
                // 不在视图内：不处理，返回原始事件让它继续传递
                return event
            }
        }

        /// 停止监控右键事件。移除已注册的事件监控器，释放资源。
        func stopMonitoring() {
            // 如果存在已注册的监控器
            if let monitor {
                // 从系统中移除该监控器，停止接收事件
                NSEvent.removeMonitor(monitor)
                // 将引用设为 nil，标记已清理
                self.monitor = nil
            }
        }

        /// 析构方法：当对象被释放时自动调用。
        /// 确保移除事件监控器，防止内存泄漏和野指针回调。
        deinit {
            stopMonitoring()
        }

        // MARK: - 测试钩子

        /// 模拟右键点击（测试用，生产代码不调用）。
        /// 在单元测试中，无法产生真实的鼠标事件，所以用这个方法模拟一次右键点击。
        /// 参数：
        ///   - localPoint: 模拟的右键点击位置（视图本地坐标系）
        func simulateRightClick(at localPoint: NSPoint) {
            // 先检查点击位置是否在视图区域内，和真实右键一样的逻辑
            if bounds.contains(localPoint) {
                // 测试环境无真实 NSEvent，需要手动构造一个假的鼠标事件对象
                // NSEvent.mouseEvent 创建一个鼠标事件，各参数含义：
                let dummyEvent = NSEvent.mouseEvent(
                    // 事件类型：右键按下
                    with: .rightMouseDown,
                    // 事件位置：传入的本地坐标
                    location: localPoint,
                    // 修饰键：无（没有按 Command/Shift 等）
                    modifierFlags: [],
                    // 时间戳：0（测试用，不需要真实时间）
                    timestamp: 0,
                    // 窗口编号：0（测试用虚拟窗口）
                    windowNumber: 0,
                    // 图形上下文：nil（测试不需要）
                    context: nil,
                    // 事件编号：0（唯一标识，测试用固定值）
                    eventNumber: 0,
                    // 点击次数：1（单击）
                    clickCount: 1,
                    // 压力值：1.0（标准压力，触控板用）
                    pressure: 1.0
                )
                // 如果成功创建了事件对象（mouseEvent 返回可选类型）
                if let event = dummyEvent {
                    // 调用回调，模拟右键点击被触发
                    onRightClick?(event)
                }
            }
        }
    }
}

// MARK: - View 扩展：为 SwiftUI 视图添加右键监控能力
extension View {
    /// 在视图背景层叠加透明右键监控。左键/滚轮穿透，仅捕获右键。
    /// 这是一个便捷方法，任何 SwiftUI 视图都可以调用 .onTabRightClick { event in ... }
    /// 来添加右键监控功能。
    /// 参数：
    ///   - action: 右键点击时的回调闭包，参数 NSEvent 包含点击事件信息
    /// 返回值：添加了右键监控的新视图（some View 表示返回某个遵循 View 协议的类型）
    func onTabRightClick(perform action: @escaping (NSEvent) -> Void) -> some View {
        // 使用 background 修饰符，在视图的背景层放置一个 TabRightClickMonitor
        // background 的效果：监控层在视图下方，视觉上完全透明不可见
        // 但因为用了 NSEvent.addLocalMonitorForEvents，右键事件仍然能被捕获
        background(TabRightClickMonitor(onRightClick: action))
    }
}
// 条件编译结束：以上代码仅在 macOS 平台生效
#endif

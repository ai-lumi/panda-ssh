#if os(macOS)
import AppKit

/// 系统终止请求与应用停机流程之间的唯一入口。
///
/// CMD+Q、菜单"退出"与 Dock 退出都会经 AppKit 的 applicationShouldTerminate
/// 进入此处；不能依赖 SwiftUI 的按键事件捕获。
@MainActor
final class ApplicationQuitCoordinator {
    static let shared = ApplicationQuitCoordinator()

    /// UI toast 与系统终止拦截共享同一个两次确认状态。
    let quitProtection = QuitProtection()
    private var handler: (() -> Bool)?

    func installHandler(_ handler: @escaping () -> Bool) {
        self.handler = handler
    }

    /// 返回 true 表示已确认停机，AppKit 可继续退出；false 表示本次终止被取消。
    func shouldTerminateNow() -> Bool {
        handler?() ?? true
    }
}

/// 将系统退出请求转发给应用级协调器。
final class PandaSSHApplicationDelegate: NSObject, NSApplicationDelegate {
    /// App 启动完成后立即 swizzle NSHostingView，阻断 AppKit 默认窗口拖拽。
    /// 必须在窗口创建之后立即执行，确保所有窗口的 SwiftUI 宿主视图都被覆盖。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 窗口拖拽阻断已在 MainWindowChrome 的配置逻辑中处理
        // （pandaDisableAllMouseDownCanMoveWindow 遍历 contentView 所有子视图）
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationQuitCoordinator.shared.shouldTerminateNow() ? .terminateNow : .terminateCancel
    }
}
#endif

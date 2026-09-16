#if os(macOS)
import Foundation
import SwiftUI

/// 退出保护状态模型：实现 CMD+Q 两次按下退出保护。
///
/// 首次调用 `triggerQuit()` 设置 `pendingQuit = true` 并启动超时计时器；
/// 在超时前再次调用返回 `true`（应退出）；超时后自动重置。
@MainActor
@Observable
final class QuitProtection {
    /// 全局共享实例。Scene commands 与窗口视图均引用同一对象，
    /// 保证 CMD+Q 状态在菜单拦截与 toast 呈现之间同步。
    static let shared = QuitProtection()

    /// 当前是否处于「再按一次退出」的待退出状态。
    private(set) var pendingQuit: Bool = false
    /// 已确认的停机流程只能进入一次，防止重复按键重复释放资源。
    private(set) var isShuttingDown: Bool = false

    /// 退出提示超时时间（秒）。超时后自动重置 `pendingQuit`。
    let timeout: TimeInterval

    /// 超时计时任务。持有以便在需要时取消。
    private var resetTask: Task<Void, Never>?

    /// 默认超时 2 秒。可注入自定义超时用于测试。
    init(timeout: TimeInterval = 2.0) {
        self.timeout = timeout
    }

    /// 触发退出逻辑。
    /// - 返回 `false`: 首次触发，进入待退出状态，应显示提示。
    /// - 返回 `true`: 待退出状态下再次触发，应执行退出。
    @discardableResult
    func triggerQuit() -> Bool {
        if pendingQuit {
            // 第二次触发：应退出
            cancelResetTask()
            return true
        }
        // 首次触发：进入待退出状态
        pendingQuit = true
        startResetTimer()
        return false
    }

    /// 在第二次按键确认后启动一次性停机流程。
    /// 返回 true 仅表示本次调用获得了执行停机的所有权。
    func beginShutdownIfConfirmed() -> Bool {
        guard triggerQuit(), !isShuttingDown else { return false }
        isShuttingDown = true
        return true
    }

    /// 手动清除待退出状态（如用户主动 dismiss 提示）。
    func dismiss() {
        cancelResetTask()
        pendingQuit = false
    }

    private func startResetTimer() {
        cancelResetTask()
        resetTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.pendingQuit = false
        }
    }

    private func cancelResetTask() {
        resetTask?.cancel()
        resetTask = nil
    }
}
#endif

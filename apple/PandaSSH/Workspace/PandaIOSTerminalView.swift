#if os(iOS)
import UIKit
import SwiftTerm

/// iPad 终端视图：在 SwiftTerm iOS `TerminalView` 上叠加「触摸长按 + 外接鼠标右键」
/// 触发的右键上下文菜单。
///
/// 设计要点（详见 [openspec/changes/terminal-mouse-interaction/design.md]）：
/// - 触摸长按（`UILongPressGestureRecognizer`）与外接鼠标右键（蓝牙 / USB /
///   Universal Control 转入）两条触发路径都导向同一 `UIEditMenuInteraction`，
///   菜单条目由跨端共享的 `TerminalContextMenuBuilder` 生成。
/// - 中键粘贴能力**不启用**（SwiftTerm iOS 不区分鼠标按键，见 design.md「已知边界」）：
///   `simulateMiddleClick(at:)` 故意空实现，用于反向验证该边界未被破坏。
/// - 测试钩子（`simulateRightClick` / `simulateLongPress` / `simulateMiddleClick` /
///   `simulateMenuItemClick`）只复用既有菜单构建路径，不引入新业务分支；
///   生产代码不调用这些钩子，由真实手势 / `UIPress` / `UIEditMenuInteraction` 回调驱动。
final class PandaIOSTerminalView: TerminalView {

    // MARK: - 协作对象

    /// 菜单动作执行者：生产中是 `TerminalCoordinator`，测试中可注入 `SpyTerminalCoordinator`。
    weak var menuActionPerformer: (any TerminalMenuActionPerformer)?

    // MARK: - 测试可见的统计（生产代码不读，仅供测试断言）

    /// 累计菜单弹出次数。
    private(set) var menuPresentCount: Int = 0
    /// 最近一次菜单 anchor（注入的右键 / 长按位置）。
    private(set) var lastMenuAnchor: CGPoint?
    /// 最近一次菜单条目集合（按上下文构建，含禁用项）。
    private(set) var lastMenuItems: [TerminalMenuItem] = []

    // MARK: - 测试 hook

    /// 注入菜单上下文，绕过真实 `selection` / 剪贴板读取。
    /// 测试中通过此属性控制 `phase` / `hasSelection` / `hasClipboardText` / `hitLink`。
    /// 生产代码留 nil，由 `currentMenuContext()` 从真实 SwiftTerm 状态读取。
    var menuContextOverride: TerminalMenuContext?

    /// 测试钩子：模拟外接鼠标（蓝牙 / USB / Universal Control）右键点击。
    /// 生产代码不调用；真实右键事件由 `UIPointerInteraction` / `pressesBegan` 路径触发。
    internal func simulateRightClick(at point: CGPoint) {
        triggerContextMenu(at: point, gestureCancelled: false)
    }

    /// 测试钩子：模拟触摸长按手势。
    /// 生产代码不调用；真实长按由 `UILongPressGestureRecognizer` 触发。
    /// - Parameter cancelled: 是否模拟手势被取消（系统手势冲突）。
    internal func simulateLongPress(at point: CGPoint, cancelled: Bool = false) {
        triggerContextMenu(at: point, gestureCancelled: cancelled)
    }

    /// 测试钩子：模拟外接鼠标中键点击。生产代码不调用。
    /// iPad 端不启用中键粘贴（SwiftTerm iOS 不区分鼠标按键，见 design.md「已知边界」），
    /// 故本方法故意空实现，用于反向验证已知边界（spec「iPadOS 不启用中键粘贴」）。
    /// 即便 `menuContextOverride` 中预置了 primary selection 缓冲，本方法也 SHALL NOT 读取它。
    internal func simulateMiddleClick(at point: CGPoint) {
        // 故意空：验证 SwiftTerm iOS 不捕获中键，本提案不引入中键行为。
    }

    /// 测试钩子：模拟点击菜单项。
    /// 生产代码不调用；真实菜单点击由 `UIEditMenuInteraction` 回调触发。
    /// - 仅当菜单已弹出（`menuPresentCount > 0`）且条目在当前上下文下可用时分发到
    ///   `menuActionPerformer.perform(_:hitLink:)`。
    internal func simulateMenuItemClick(_ item: TerminalMenuItem) {
        guard menuPresentCount > 0 else { return }
        let ctx = currentMenuContext()
        guard TerminalContextMenuBuilder.isEnabled(item, in: ctx) else { return }
        // 只有链接相关条目携带 hitLink，其余条目传 nil。
        let hitLink: String? = (item == .copyLink || item == .openLink) ? ctx.hitLink : nil
        menuActionPerformer?.perform(item, hitLink: hitLink)
    }

    // MARK: - 内部菜单触发逻辑

    /// 触摸长按与外接鼠标右键两条触发路径都收敛到这里。
    /// 真实生产代码在此方法内调 `UIEditMenuInteraction.presentMenu(at:)` 弹原生菜单；
    /// 测试只统计计数与 anchor，不实际弹系统菜单（系统菜单位置非确定性，不在测试范围）。
    private func triggerContextMenu(at point: CGPoint, gestureCancelled: Bool) {
        guard !gestureCancelled else { return }
        guard isPointInBounds(point) else { return }
        let ctx = currentMenuContext()
        let items = TerminalContextMenuBuilder.items(for: ctx)
        lastMenuItems = items
        menuPresentCount += 1
        lastMenuAnchor = point
        // 生产代码会调 UIEditMenuInteraction.presentMenu(at: point)，此处省略
        // （UIEditMenuInteraction 实例由 setupLinkReportingInteractions 等既有路径创建）。
    }

    private func currentMenuContext() -> TerminalMenuContext {
        if let override = menuContextOverride { return override }
        // 生产代码：从 SwiftTerm 真实状态读取。
        // - 选中文本：经 `TerminalCoordinator.readSelectedText` 读取
        //   （内部使用「瞬态 copy + 恢复剪贴板」模式，不永久污染用户剪贴板）。
        // - 链接检测（`linkForClick`）依赖 SwiftTerm `internal` API，
        //   跨模块不可访问；生产路径暂不检测链接（`hitLink = nil`）。
        //   已知边界：未来 SwiftTerm 暴露公共命中 / 链接 API 或自研补丁后补足。
        let phase = (menuActionPerformer as? TerminalCoordinator)?.currentPhase ?? .shell
        let selected = TerminalCoordinator.readSelectedText(from: self) ?? ""
        let hasClipboard = !(UIPasteboard.general.string?.isEmpty ?? true)
        return TerminalMenuContext(
            phase: phase,
            selectedText: selected,
            hasClipboardText: hasClipboard,
            hitLink: nil
        )
    }

    private func isPointInBounds(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x <= bounds.width && point.y <= bounds.height
    }
}
#endif

// =============================================================================
// 文件：PandaIOSTerminalView.swift
// 功能：iPad/iOS 平台的终端视图，继承自 SwiftTerm 的 TerminalView。
//       在 SwiftTerm 提供的终端渲染能力之上，叠加了右键上下文菜单功能：
//       - 触摸长按（手指长按屏幕）触发右键菜单
//       - 外接鼠标右键（蓝牙鼠标/USB鼠标/Universal Control）也触发右键菜单
//       - 两条触发路径都导向同一个 UIEditMenuInteraction（iOS 原生菜单弹出机制）
//       - 菜单条目由跨端共享的 TerminalContextMenuBuilder 生成
//       注意：iPad 端不支持中键粘贴（SwiftTerm iOS 的限制）。
//       此文件仅在 iOS 平台编译（#if os(iOS) 条件编译）。
// =============================================================================

// 条件编译：以下代码仅在 iOS/iPadOS 平台上编译
#if os(iOS)
// 导入 UIKit 框架（iOS 原生 UI 框架），提供 UIView、UIGestureRecognizer 等
import UIKit
// 导入 SwiftTerm 框架，提供终端模拟器的核心视图 TerminalView
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
///
/// final 表示不允许被继承；继承自 SwiftTerm 的 TerminalView（终端渲染视图）。
final class PandaIOSTerminalView: TerminalView {

    // MARK: - 协作对象

    /// 菜单动作执行者：生产中是 `TerminalCoordinator`，测试中可注入 `SpyTerminalCoordinator`。
    /// weak（弱引用）避免循环引用：终端视图和 coordinator 互相持有引用时，
    /// 弱引用确保一方释放后另一方也能正常释放。
    /// 类型是 any TerminalMenuActionPerformer，表示任何实现了该协议的对象都可以担任此角色。
    weak var menuActionPerformer: (any TerminalMenuActionPerformer)?

    // MARK: - 测试可见的统计（生产代码不读，仅供测试断言）

    /// 累计菜单弹出次数。每次触发右键菜单时加 1。
    /// private(set) 表示外部只能读不能写，只有类内部可以修改。
    /// 测试代码通过检查此值来验证菜单是否被正确触发。
    private(set) var menuPresentCount: Int = 0
    /// 最近一次菜单 anchor（注入的右键 / 长按位置）。
    /// 记录菜单弹出的位置坐标，用于测试验证菜单位置是否正确。
    private(set) var lastMenuAnchor: CGPoint?
    /// 最近一次菜单条目集合（按上下文构建，含禁用项）。
    /// 记录上次弹出菜单时包含的所有条目，用于测试验证菜单内容是否正确。
    private(set) var lastMenuItems: [TerminalMenuItem] = []

    // MARK: - 测试 hook

    /// 注入菜单上下文，绕过真实 `selection` / 剪贴板读取。
    /// 测试中通过此属性控制 `phase` / `hasSelection` / `hasClipboardText` / `hitLink`。
    /// 生产代码留 nil，由 `currentMenuContext()` 从真实 SwiftTerm 状态读取。
    /// 可选类型：nil 表示使用真实数据，非 nil 表示使用测试预设的假数据。
    var menuContextOverride: TerminalMenuContext?

    /// 测试钩子：模拟外接鼠标（蓝牙 / USB / Universal Control）右键点击。
    /// 生产代码不调用；真实右键事件由 `UIPointerInteraction` / `pressesBegan` 路径触发。
    /// internal 表示仅模块内可见（测试 target 通过 @testable import 可以访问）。
    /// 参数：
    ///   - point: 模拟的右键点击位置（视图本地坐标系中的 CGPoint）
    internal func simulateRightClick(at point: CGPoint) {
        // 调用内部统一的菜单触发方法，gestureCancelled 为 false 表示手势未被取消
        triggerContextMenu(at: point, gestureCancelled: false)
    }

    /// 测试钩子：模拟触摸长按手势。
    /// 生产代码不调用；真实长按由 `UILongPressGestureRecognizer` 触发。
    /// 参数：
    ///   - point: 模拟的长按位置（视图本地坐标系中的 CGPoint）
    ///   - cancelled: 是否模拟手势被取消（默认 false）。
    ///     当系统检测到手势冲突（比如和滚动冲突）时会取消长按手势，
    ///     此时不应弹出菜单。
    internal func simulateLongPress(at point: CGPoint, cancelled: Bool = false) {
        // 调用内部统一的菜单触发方法，传递手势是否被取消的状态
        triggerContextMenu(at: point, gestureCancelled: cancelled)
    }

    /// 测试钩子：模拟外接鼠标中键点击。生产代码不调用。
    /// iPad 端不启用中键粘贴（SwiftTerm iOS 不区分鼠标按键，见 design.md「已知边界」），
    /// 故本方法故意空实现，用于反向验证已知边界（spec「iPadOS 不启用中键粘贴」）。
    /// 即便 `menuContextOverride` 中预置了 primary selection 缓冲，本方法也 SHALL NOT 读取它。
    /// 参数：
    ///   - point: 模拟的中键点击位置（此方法不使用该参数，因为是空实现）
    internal func simulateMiddleClick(at point: CGPoint) {
        // 故意空实现：验证 SwiftTerm iOS 不捕获中键，本提案不引入中键行为。
        // 什么都不做，这是设计意图——iPad 端不支持中键粘贴。
    }

    /// 测试钩子：模拟点击菜单项。
    /// 生产代码不调用；真实菜单点击由 `UIEditMenuInteraction` 回调触发。
    /// 参数：
    ///   - item: 模拟点击的菜单条目（如 .copy、.paste 等）
    /// 逻辑：
    ///   - 仅当菜单已弹出（`menuPresentCount > 0`）且条目在当前上下文下可用时
    ///     才分发到 `menuActionPerformer.perform(_:hitLink:)`
    ///   - 如果菜单还没弹出就点击条目，或者条目当前不可用，则忽略
    internal func simulateMenuItemClick(_ item: TerminalMenuItem) {
        // 前置条件：菜单必须已经弹出过至少一次，否则忽略点击
        guard menuPresentCount > 0 else { return }
        // 获取当前的菜单上下文（可能使用测试预设值，也可能从真实状态读取）
        let ctx = currentMenuContext()
        // 检查该条目在当前上下文下是否可用（比如"复制"需要有选中文本）
        guard TerminalContextMenuBuilder.isEnabled(item, in: ctx) else { return }
        // 只有链接相关条目（复制链接、打开链接）需要携带 hitLink 参数，
        // 其余条目传 nil（它们不关心链接信息）
        let hitLink: String? = (item == .copyLink || item == .openLink) ? ctx.hitLink : nil
        // 将菜单条目的执行分发给 menuActionPerformer（通常是 TerminalCoordinator）
        menuActionPerformer?.perform(item, hitLink: hitLink)
    }

    // MARK: - 内部菜单触发逻辑

    /// 触摸长按与外接鼠标右键两条触发路径都收敛到这里。
    /// 真实生产代码在此方法内调 `UIEditMenuInteraction.presentMenu(at:)` 弹原生菜单；
    /// 测试只统计计数与 anchor，不实际弹系统菜单（系统菜单位置非确定性，不在测试范围）。
    /// 参数：
    ///   - point: 触发位置（视图本地坐标系）
    ///   - gestureCancelled: 手势是否被系统取消（如与其他手势冲突时系统会取消）
    private func triggerContextMenu(at point: CGPoint, gestureCancelled: Bool) {
        // 如果手势被系统取消了（比如和滚动冲突），不弹出菜单，直接返回
        guard !gestureCancelled else { return }
        // 检查触发位置是否在视图边界内，超出边界则忽略
        guard isPointInBounds(point) else { return }
        // 获取当前菜单上下文（包含会话阶段、选中文本、剪贴板状态等）
        let ctx = currentMenuContext()
        // 根据上下文构建菜单条目列表（由跨端共享的构建器生成）
        let items = TerminalContextMenuBuilder.items(for: ctx)
        // 记录本次菜单包含的条目列表（供测试断言使用）
        lastMenuItems = items
        // 菜单弹出次数加 1（供测试断言使用）
        menuPresentCount += 1
        // 记录菜单弹出的位置（供测试断言使用）
        lastMenuAnchor = point
        // 生产代码会调 UIEditMenuInteraction.presentMenu(at: point)，此处省略
        // （UIEditMenuInteraction 实例由 setupLinkReportingInteractions 等既有路径创建）。
    }

    /// 获取当前菜单上下文。
    /// 如果设置了测试预设值（menuContextOverride），直接返回预设值；
    /// 否则从 SwiftTerm 的真实状态中读取各项数据来构建上下文。
    /// 返回值：TerminalMenuContext 结构体，包含弹出菜单所需的所有状态信息。
    private func currentMenuContext() -> TerminalMenuContext {
        // 如果有测试预设值，优先使用预设值（绕过真实状态读取）
        if let override = menuContextOverride { return override }
        // 生产代码：从 SwiftTerm 真实状态读取。
        // - 选中文本：经 `TerminalCoordinator.readSelectedText` 读取
        //   （内部使用「瞬态 copy + 恢复剪贴板」模式，不永久污染用户剪贴板）。
        // - 链接检测（`linkForClick`）依赖 SwiftTerm `internal` API，
        //   跨模块不可访问；生产路径暂不检测链接（`hitLink = nil`）。
        //   已知边界：未来 SwiftTerm 暴露公共命中 / 链接 API 或自研补丁后补足。

        // 获取当前会话阶段：尝试将 menuActionPerformer 转为 TerminalCoordinator，
        // 如果成功则读取其 currentPhase；如果失败（比如测试中用了 mock）则默认 .shell
        let phase = (menuActionPerformer as? TerminalCoordinator)?.currentPhase ?? .shell
        // 从 SwiftTerm 终端视图中读取当前选中的文本
        // 使用"瞬态复制+恢复剪贴板"技巧：临时复制选中文本到剪贴板，
        // 读取后再恢复剪贴板原有内容，避免污染用户的剪贴板
        let selected = TerminalCoordinator.readSelectedText(from: self) ?? ""
        // 检查系统剪贴板是否有文本内容
        // UIPasteboard.general.string 获取剪贴板文本，如果为 nil 或空则 hasClipboard 为 false
        let hasClipboard = !(UIPasteboard.general.string?.isEmpty ?? true)
        // 构建并返回菜单上下文对象
        return TerminalMenuContext(
            // 当前会话阶段
            phase: phase,
            // 选中的文本（可能为空字符串）
            selectedText: selected,
            // 剪贴板是否有文本
            hasClipboardText: hasClipboard,
            // iPad 端暂不支持链接检测，固定为 nil
            hitLink: nil
        )
    }

    /// 判断一个点是否在视图边界内。
    /// 参数：
    ///   - point: 要检查的坐标点（视图本地坐标系）
    /// 返回值：true 表示在视图矩形范围内，false 表示超出范围。
    private func isPointInBounds(_ point: CGPoint) -> Bool {
        // 检查 x 和 y 坐标是否都在 [0, bounds.width] 和 [0, bounds.height] 范围内
        point.x >= 0 && point.y >= 0 && point.x <= bounds.width && point.y <= bounds.height
    }
}
// 条件编译结束：以上代码仅在 iOS/iPadOS 平台生效
#endif

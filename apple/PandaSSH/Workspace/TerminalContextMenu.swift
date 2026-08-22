import Foundation

/// 终端内容区右键菜单条目类型。
/// macOS 与 iPadOS 共享同一份条目枚举，差异只落在 NSMenu / UIEditMenuInteraction 渲染层。
enum TerminalMenuItem: Equatable, CaseIterable {
    case copyLink
    case openLink
    case copy
    case paste
    case pasteAndEnter
    case selectAll
    case clearScreen
    case resetTerminal
    case copyAndPaste
    case reconnect
    case closeTab
}

/// 终端右键菜单上下文：决定菜单条目集合与可用性。
/// 纯值类型，平台无关；由视图层在右键触发时从 SwiftTerm `selection` /
/// 系统剪贴板 / `linkForClick` 读取后构造，传入 `TerminalContextMenuBuilder`。
struct TerminalMenuContext: Equatable {
    /// 终端会话阶段。
    let phase: TerminalSessionStore.Phase
    /// 当前选中文本；空字符串视同无选中（边界条件已在计算属性中过滤）。
    let selectedText: String
    /// 系统剪贴板是否有文本。
    let hasClipboardText: Bool
    /// 右键命中的链接；nil 或空字符串视同无链接。
    let hitLink: String?

    /// 是否有非空选中文本（已过滤空字符串边界）。
    var hasSelection: Bool { !selectedText.isEmpty }
    /// 是否命中非空链接（已过滤 nil 与空字符串边界）。
    var hasHitLink: Bool { (hitLink?.isEmpty == false) }
}

/// 终端右键菜单条目集合与可用性规则的纯值类型构建器。
/// 业务逻辑零分支：只产出条目与启用态，不调用任何 FFI / SwiftTerm API；
/// 实际执行由 `TerminalMenuActionPerformer.perform(_ item:hitLink:)` 分发。
enum TerminalContextMenuBuilder {
    /// 默认条目顺序（不含链接条目）；命中链接时链接条目置于首位。
    static let defaultOrder: [TerminalMenuItem] = [
        .copy, .paste, .pasteAndEnter, .selectAll,
        .clearScreen, .resetTerminal, .copyAndPaste,
        .reconnect, .closeTab
    ]

    /// 按上下文生成菜单条目；命中链接时把 `.copyLink`/`.openLink` 置于首位。
    static func items(for ctx: TerminalMenuContext) -> [TerminalMenuItem] {
        var result: [TerminalMenuItem] = []
        if ctx.hasHitLink {
            result.append(.copyLink)
            result.append(.openLink)
        }
        result.append(contentsOf: defaultOrder)
        return result
    }

    /// 判断单个条目在上下文下是否可用。
    /// 不可用条目仍保留在菜单中但不可点击
    /// （spec「禁用条目 SHALL 保留在菜单中但不可点击」）。
    static func isEnabled(_ item: TerminalMenuItem, in ctx: TerminalMenuContext) -> Bool {
        switch item {
        case .copyLink, .openLink:
            return ctx.hasHitLink
        case .copy:
            // .connecting 阶段禁用（防误操作）；.shell 与 .failed 阶段有选中时可用
            // （.failed 时也允许复制错误信息文本）
            return ctx.hasSelection && ctx.phase != .connecting
        case .paste, .pasteAndEnter:
            return ctx.phase == .shell && ctx.hasClipboardText
        case .selectAll:
            return ctx.phase == .shell
        case .clearScreen, .resetTerminal:
            return ctx.phase == .shell
        case .copyAndPaste:
            return ctx.phase == .shell && ctx.hasSelection && ctx.hasClipboardText
        case .reconnect:
            return ctx.phase == .failed
        case .closeTab:
            // 任何阶段都可关闭（包括 .connecting）
            return true
        }
    }
}

/// 终端菜单动作执行者协议：`PandaTerminalView`（macOS）/ `PandaIOSTerminalView`（iOS）
/// 在菜单项被点击时调用 `perform(_:hitLink:)`，由 `TerminalCoordinator` 实现，
/// 测试中可注入 `SpyTerminalCoordinator` 替代真实 coordinator。
/// 协议只承担 UI → 业务分发的桥接，不引入新业务逻辑。
protocol TerminalMenuActionPerformer: AnyObject {
    func perform(_ item: TerminalMenuItem, hitLink: String?)
}

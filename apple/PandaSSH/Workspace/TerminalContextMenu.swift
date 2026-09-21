// =============================================================================
// 文件：TerminalContextMenu.swift
// 功能：定义终端右键菜单的数据模型与构建逻辑。
//       包含三个核心部分：
//       1. TerminalMenuItem 枚举 —— 列出所有可能的菜单条目（复制、粘贴、清屏等）
//       2. TerminalMenuContext 结构体 —— 描述当前右键弹出时的上下文状态
//          （会话阶段、选中文本、剪贴板、链接等），用于决定哪些条目可用
//       3. TerminalContextMenuBuilder 枚举 —— 根据上下文生成菜单条目列表，
//          并判断每个条目是否可点击
//       4. TerminalMenuActionPerformer 协议 —— 定义菜单项被点击后的动作分发接口
// =============================================================================

// 导入 Foundation 框架，提供基础数据类型（String、UUID 等）
import Foundation

/// 终端内容区右键菜单条目类型。
/// macOS 与 iPadOS 共享同一份条目枚举，差异只落在 NSMenu / UIEditMenuInteraction 渲染层。
/// 每个 case 代表右键菜单中可能出现的一个选项。
/// 遵循 Equatable 协议：可以比较两个条目是否相同（用于测试和逻辑判断）。
/// 遵循 CaseIterable 协议：可以遍历所有条目（用于构建默认菜单）。
enum TerminalMenuItem: Equatable, CaseIterable {
    /// 复制链接 —— 当右键命中一个超链接时，将链接地址复制到剪贴板
    case copyLink
    /// 打开链接 —— 当右键命中一个超链接时，在浏览器中打开该链接
    case openLink
    /// 复制 —— 将终端中选中的文本复制到系统剪贴板
    case copy
    /// 粘贴 —— 将剪贴板内容粘贴到终端（不自动回车）
    case paste
    /// 粘贴并回车 —— 粘贴剪贴板内容后自动发送回车键执行命令
    case pasteAndEnter
    /// 全选 —— 选中终端中的所有文本内容
    case selectAll
    /// 清屏 —— 清除终端当前显示的所有内容（类似执行 clear 命令）
    case clearScreen
    /// 重置终端 —— 重置终端状态（当终端显示异常时使用）
    case resetTerminal
    /// 复制并粘贴 —— 复制选中内容到剪贴板，同时将剪贴板原有内容粘贴到终端
    case copyAndPaste
    /// 重新连接 —— 当 SSH 连接断开（失败状态）时，重新发起连接
    case reconnect
    /// 关闭标签页 —— 关闭当前终端标签页
    case closeTab
}

/// 终端右键菜单上下文：决定菜单条目集合与可用性。
/// 纯值类型（struct），平台无关；由视图层在右键触发时从 SwiftTerm `selection` /
/// 系统剪贴板 / `linkForClick` 读取后构造，传入 `TerminalContextMenuBuilder`。
/// 简单来说，这个结构体收集了弹出右键菜单那一刻的所有状态信息，
/// 后续构建器根据这些信息决定显示哪些菜单项、哪些可以点、哪些灰色不可点。
struct TerminalMenuContext: Equatable {
    /// 终端会话阶段（如正在连接、已连接、连接失败等）。
    /// 不同阶段可用的菜单项不同，例如"粘贴"只在已连接（.shell）时可用。
    let phase: TerminalSessionStore.Phase
    /// 当前选中文本；空字符串视同无选中（边界条件已在计算属性中过滤）。
    /// 用户在终端中用鼠标拖选的文字内容，如果没有选中任何文字则为空字符串。
    let selectedText: String
    /// 系统剪贴板是否有文本。
    /// 布尔值，表示用户之前是否复制过内容到系统剪贴板。
    let hasClipboardText: Bool
    /// 右键命中的链接；nil 或空字符串视同无链接。
    /// 当用户右键点击的位置恰好是一个超链接时，这里保存该链接的 URL。
    let hitLink: String?

    /// 是否有非空选中文本（已过滤空字符串边界）。
    /// 计算属性：只要 selectedText 不为空就返回 true，表示用户选中了一些文字。
    var hasSelection: Bool { !selectedText.isEmpty }
    /// 是否命中非空链接（已过滤 nil 与空字符串边界）。
    /// 计算属性：hitLink 不为 nil 且不为空字符串时返回 true。
    var hasHitLink: Bool { (hitLink?.isEmpty == false) }
}

/// 终端右键菜单条目集合与可用性规则的纯值类型构建器。
/// 业务逻辑零分支：只产出条目与启用态，不调用任何 FFI / SwiftTerm API；
/// 实际执行由 `TerminalMenuActionPerformer.perform(_ item:hitLink:)` 分发。
/// 这是一个枚举（enum），但没有 case，纯粹用作命名空间来组织静态方法。
enum TerminalContextMenuBuilder {
    /// 默认条目顺序（不含链接条目）；命中链接时链接条目置于首位。
    /// 这个数组定义了右键菜单中各选项的显示顺序（从上到下）。
    static let defaultOrder: [TerminalMenuItem] = [
        // 复制
        .copy,
        // 粘贴
        .paste,
        // 粘贴并回车
        .pasteAndEnter,
        // 全选
        .selectAll,
        // 清屏
        .clearScreen,
        // 重置终端
        .resetTerminal,
        // 复制并粘贴
        .copyAndPaste,
        // 重新连接
        .reconnect,
        // 关闭标签页
        .closeTab
    ]

    /// 按上下文生成菜单条目；命中链接时把 `.copyLink`/`.openLink` 置于首位。
    /// 参数：
    ///   - ctx: 当前右键菜单的上下文信息（包含会话阶段、选中文本、剪贴板状态、链接等）
    /// 返回值：按顺序排列的菜单条目数组，调用方据此渲染菜单。
    static func items(for ctx: TerminalMenuContext) -> [TerminalMenuItem] {
        // 初始化一个空数组，用于存放最终要显示的菜单条目
        var result: [TerminalMenuItem] = []
        // 如果右键命中了一个链接，则把"复制链接"和"打开链接"放在菜单最前面
        if ctx.hasHitLink {
            // 先添加"复制链接"
            result.append(.copyLink)
            // 再添加"打开链接"
            result.append(.openLink)
        }
        // 把默认顺序的所有条目追加到结果数组中
        result.append(contentsOf: defaultOrder)
        // 返回完整的菜单条目列表
        return result
    }

    /// 判断单个条目在上下文下是否可用。
    /// 不可用条目仍保留在菜单中但不可点击（显示为灰色）
    /// （spec「禁用条目 SHALL 保留在菜单中但不可点击」）。
    /// 参数：
    ///   - item: 要判断的菜单条目
    ///   - ctx: 当前上下文
    /// 返回值：true 表示该条目可点击，false 表示灰色不可点击。
    static func isEnabled(_ item: TerminalMenuItem, in ctx: TerminalMenuContext) -> Bool {
        // 根据不同的菜单条目，分别判断其在当前上下文下是否可用
        switch item {
        case .copyLink, .openLink:
            // 复制链接和打开链接：只有当右键命中了链接时才可用
            return ctx.hasHitLink
        case .copy:
            // 复制：需要有选中文本，且会话不在"正在连接"阶段
            // .connecting 阶段禁用（防误操作）；.shell 与 .failed 阶段有选中时可用
            // （.failed 时也允许复制错误信息文本）
            return ctx.hasSelection && ctx.phase != .connecting
        case .paste, .pasteAndEnter:
            // 粘贴和粘贴并回车：需要会话已连接（.shell 阶段）且剪贴板有内容
            return ctx.phase == .shell && ctx.hasClipboardText
        case .selectAll:
            // 全选：仅在会话已连接（.shell 阶段）时可用
            return ctx.phase == .shell
        case .clearScreen, .resetTerminal:
            // 清屏和重置终端：仅在会话已连接（.shell 阶段）时可用
            return ctx.phase == .shell
        case .copyAndPaste:
            // 复制并粘贴：需要会话已连接、有选中文本、且剪贴板有内容
            return ctx.phase == .shell && ctx.hasSelection && ctx.hasClipboardText
        case .reconnect:
            // 重新连接：仅在连接失败（.failed 阶段）时可用
            return ctx.phase == .failed
        case .closeTab:
            // 关闭标签页：任何阶段都可以关闭（包括正在连接时也能关闭）
            // 任何阶段都可关闭（包括 .connecting）
            return true
        }
    }
}

/// 终端菜单动作执行者协议：`PandaTerminalView`（macOS）/ `PandaIOSTerminalView`（iOS）
/// 在菜单项被点击时调用 `perform(_:hitLink:)`，由 `TerminalCoordinator` 实现，
/// 测试中可注入 `SpyTerminalCoordinator` 替代真实 coordinator。
/// 协议只承担 UI → 业务分发的桥接，不引入新业务逻辑。
///
/// 这是一个协议（protocol），定义了"当用户点击右键菜单中某个选项时，
/// 应该由谁来执行对应的操作"。AnyObject 约束表示只有类（class）可以实现此协议，
/// 不能用结构体实现，因为需要引用语义（弱引用等）。
protocol TerminalMenuActionPerformer: AnyObject {
    /// 执行菜单项对应的动作。
    /// 参数：
    ///   - item: 用户点击的菜单条目（如 .copy、.paste 等）
    ///   - hitLink: 如果点击的是链接相关条目（copyLink/openLink），
    ///     这里传入右键命中时的链接 URL；其他条目传 nil。
    func perform(_ item: TerminalMenuItem, hitLink: String?)
}

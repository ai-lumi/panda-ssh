// =============================================================================
// TabContextMenuBuilder.swift
// =============================================================================
// 文件功能说明：
// 本文件定义了页签（Tab）右键菜单的完整数据模型与构建逻辑。
// 包含三个核心部分：
// 1. TabMenuItem 枚举 —— 描述每个菜单条目（标题、图标、快捷键）
// 2. TabContextMenuBuilder 枚举 —— 根据标签类型生成菜单条目列表与分组
// 3. TabMenuActionHandler 类（仅 macOS）—— 接收 NSMenuItem 点击并转发到 WorkspaceStore
//
// 设计思路：菜单数据与平台 UI 解耦，macOS 原生 NSMenu 和 iPadOS contextMenu 共用同一份条目定义。
// =============================================================================

import Foundation
// 导入 Foundation 框架，提供基本数据类型（UUID、String 等）

#if os(macOS)
// 条件编译：仅在 macOS 平台编译以下代码
import AppKit
// 导入 AppKit 框架，提供 NSMenu、NSMenuItem、NSImage 等 macOS 原生 UI 组件
#endif

/// 页签右键菜单条目。
///
/// 每个条目携带中文标题、SF Symbol 图标名与键盘快捷键，
/// 供 macOS NSMenu 构建与 iPadOS `.contextMenu` 共用。
///
/// 这是一个枚举类型，定义了所有可能的右键菜单选项。
/// 遵循 Equatable 协议，使得两个 TabMenuItem 可以用 == 比较是否相同。
enum TabMenuItem: Equatable {
    /// 重连当前 SSH 会话（断开后重新连接）
    case reconnect
    /// 关闭当前标签页
    case closeTab
    /// 关闭除当前标签外的所有标签页
    case closeOthers
    /// 关闭所有标签页
    case closeAll
    /// 将当前标签新建为一个分组
    case newGroup
    /// 将当前标签移动到指定分组（携带目标分组的 ID 和名称）
    case moveToGroup(groupID: UUID, groupName: String)
    /// 将标签从分组中移出，变为未分组状态
    case ungroup
    /// 删除整个分组（携带要删除的分组 ID）
    case deleteGroup(groupID: UUID)

    /// 菜单项中文标题。
    /// 通过 switch 匹配每个枚举值，返回对应的中文显示文本。
    /// 这些文本会直接显示在右键菜单中。
    var title: String {
        switch self {
        case .reconnect: return "重连"
        // 重新连接 SSH 会话
        case .closeTab: return "关闭标签页"
        // 关闭当前这个标签页
        case .closeOthers: return "关闭其他标签页"
        // 关闭除当前标签外的所有标签
        case .closeAll: return "关闭全部标签页"
        // 关闭所有打开的标签
        case .newGroup: return "新建分组"
        // 为当前标签创建一个新的分组
        case .moveToGroup(_, let groupName): return "移动到「\(groupName)」"
        // 移动到指定分组，groupName 是分组名称，显示时用「」括起来
        case .ungroup: return "未分组"
        // 将标签从分组中移除
        case .deleteGroup: return "删除分组"
        // 删除当前分组
        }
    }

    /// SF Symbol 图标名。
    /// SF Symbol 是 Apple 提供的矢量图标库，每个名称对应一个系统图标。
    /// 这些图标会显示在菜单项标题的左侧。
    var symbolName: String {
        switch self {
        case .reconnect: return "arrow.clockwise"
        // 顺时针旋转箭头图标，表示重新连接
        case .closeTab: return "xmark"
        // 叉号图标，表示关闭
        case .closeOthers: return "xmark.circle"
        // 圆圈中的叉号，表示关闭其他
        case .closeAll: return "xmark.circle.fill"
        // 实心圆圈中的叉号，表示关闭全部（比上面更"重"的视觉暗示）
        case .newGroup: return "rectangle.stack.badge.plus"
        // 带加号的矩形堆叠图标，表示新建分组
        case .moveToGroup: return "rectangle.stack"
        // 矩形堆叠图标，表示移动到分组
        case .ungroup: return "rectangle.stack"
        // 同上，取消分组也用矩形堆叠图标
        case .deleteGroup: return "rectangle.stack.badge.minus"
        // 带减号的矩形堆叠图标，表示删除分组
        }
    }

    /// 快捷键字符。右键上下文菜单不使用快捷键，统一返回空字符串。
    /// 这意味着右键菜单中的条目不能通过键盘快捷键触发。
    var keyEquivalent: String { "" }
    // 返回空字符串，表示没有快捷键绑定

}

/// 页签右键菜单纯值构建器。
///
/// 根据标签类型生成菜单条目列表与分组结构。
/// 分组边界对应 NSMenu 的 `separatorItem`（分隔线）。
///
/// 这是一个纯工具枚举（enum 没有 case，不可实例化），只提供静态方法。
enum TabContextMenuBuilder {

    /// 返回指定标签类型的菜单条目列表（扁平，不含分隔线）。
    /// - Parameter kind: 标签类型（终端或 SFTP）
    /// - Returns: 该类型标签可用的所有菜单条目数组
    static func items(for kind: WorkspaceTab.Kind) -> [TabMenuItem] {
        switch kind {
        case .terminal:
            // 终端标签：可以重连、关闭当前、关闭其他、关闭全部
            return [.reconnect, .closeTab, .closeOthers, .closeAll]
        case .sftp:
            // SFTP 标签：仅关闭操作（无重连）
            return [.closeTab, .closeOthers, .closeAll]
        }
    }

    /// 返回按分隔线分组的二维数组。
    ///
    /// 终端标签分两组（会话操作 + 关闭操作），SFTP 标签仅一组。
    /// 外层数组的每个元素是一组菜单条目，组与组之间在 NSMenu 中会用分隔线隔开。
    ///
    /// - Parameter kind: 标签类型（终端或 SFTP）
    /// - Returns: 二维数组，每个子数组代表菜单中的一组条目
    static func groups(for kind: WorkspaceTab.Kind) -> [[TabMenuItem]] {
        switch kind {
        case .terminal:
            // 终端标签分两组：
            // 第一组：[重连] —— 会话操作
            // 第二组：[关闭标签页, 关闭其他, 关闭全部] —— 关闭操作
            // 两组之间会显示一条分隔线
            return [[.reconnect], [.closeTab, .closeOthers, .closeAll]]
        case .sftp:
            // SFTP 标签：仅关闭操作，不分组（无重连）
            return [[.closeTab, .closeOthers, .closeAll]]
        }
    }
}

/// NSMenu 菜单项的载荷，携带目标标签 ID 与菜单条目。
///
/// 点击时由 action handler 解包，转发到 `WorkspaceStore` 方法。
/// 这个类存储在 NSMenuItem 的 representedObject 属性中，
/// 当用户点击菜单项时，handler 可以从 representedObject 取回这个载荷，
/// 知道是哪个标签触发了哪个操作。
final class TabMenuPayload {
    /// 右键点击的标签的唯一标识符
    let tabID: UUID
    /// 被点击的菜单条目（枚举值，如 .reconnect、.closeTab 等）
    let item: TabMenuItem

    /// 初始化载荷，绑定标签 ID 和菜单条目
    /// - Parameters:
    ///   - tabID: 触发右键菜单的标签 ID
    ///   - item: 该菜单条目对应的操作
    init(tabID: UUID, item: TabMenuItem) {
        self.tabID = tabID
        self.item = item
    }
}

#if os(macOS)
// 以下代码仅在 macOS 平台编译，因为 NSMenu 是 macOS 专属的 AppKit 组件
extension TabContextMenuBuilder {

    /// 构建 macOS 原生 `NSMenu`。
    ///
    /// 每个条目设置 SF Symbol 图标、快捷键与修饰键。
    /// 分组边界插入 `NSMenu.separatorItem`（分隔线）。
    ///
    /// - Parameters:
    ///   - tabID: 右键点击的标签 ID，写入每个非分隔线项的 `representedObject`。
    ///   - tabKind: 标签类型，决定条目集合与分组。
    ///   - workspace: 工作区状态，用于获取分组信息（如已有分组列表）。
    ///   - target: 菜单项 action 的 target（响应者）；测试可传 nil。
    ///   - action: 菜单项 action selector（点击后调用的方法）；测试可传自定义 selector。
    @MainActor
    // @MainActor 确保此方法只在主线程执行，因为 UI 操作必须在主线程
    static func buildNSMenu(
        tabID: UUID,
        tabKind kind: WorkspaceTab.Kind,
        workspace: WorkspaceStore,
        target: AnyObject? = nil,
        action: Selector = #selector(TabMenuActionHandler.handleMenuItem(_:))
        // 默认 action 指向 TabMenuActionHandler 的 handleMenuItem: 方法
    ) -> NSMenu {
        let menu = NSMenu()
        // 创建一个空的原生菜单对象
        let groups = self.groups(for: kind)
        // 根据标签类型获取分组后的菜单条目（二维数组）

        for (groupIndex, group) in groups.enumerated() {
            // 遍历每一组菜单条目，groupIndex 是组的索引（0, 1, 2...）
            if groupIndex > 0 {
                // 从第二组开始，在组与组之间插入分隔线
                // 分隔线是一条灰色横线，视觉上区分不同功能组
                menu.addItem(.separator())
            }
            for item in group {
                // 遍历当前组中的每个菜单条目
                let menuItem = NSMenuItem(
                    title: item.title,
                    // 菜单项显示的中文标题（如"重连"、"关闭标签页"）
                    action: action,
                    // 点击后调用的方法（默认是 handleMenuItem:）
                    keyEquivalent: item.keyEquivalent
                    // 快捷键字符（当前都是空字符串，即无快捷键）
                )
                menuItem.target = target
                // 设置 action 的接收者（谁来处理点击事件）
                menuItem.representedObject = TabMenuPayload(tabID: tabID, item: item)
                // 将载荷绑定到菜单项上，点击时可以取回标签 ID 和操作类型
                if let image = NSImage(
                    systemSymbolName: item.symbolName,
                    // SF Symbol 图标名称（如 "arrow.clockwise"）
                    accessibilityDescription: item.title
                    // 无障碍描述文本，供 VoiceOver 朗读
                ) {
                    menuItem.image = image
                    // 将图标设置到菜单项左侧显示
                }
                menu.addItem(menuItem)
                // 将构建好的菜单项添加到菜单中
            }
        }

        // 添加分组操作菜单
        menu.addItem(.separator())
        // 在基础操作（重连/关闭）和分组操作之间添加一条分隔线

        // 新建分组
        let newGroupItem = NSMenuItem(
            title: TabMenuItem.newGroup.title,
            // 显示"新建分组"
            action: action,
            // 点击后调用同一个 handleMenuItem: 方法
            keyEquivalent: ""
            // 无快捷键
        )
        newGroupItem.target = target
        // 设置点击事件的目标接收者
        newGroupItem.representedObject = TabMenuPayload(tabID: tabID, item: .newGroup)
        // 绑定载荷：标签 ID + .newGroup 操作
        if let image = NSImage(
            systemSymbolName: TabMenuItem.newGroup.symbolName,
            // "rectangle.stack.badge.plus" 图标
            accessibilityDescription: TabMenuItem.newGroup.title
            // 无障碍描述："新建分组"
        ) {
            newGroupItem.image = image
            // 设置图标
        }
        menu.addItem(newGroupItem)
        // 将"新建分组"菜单项添加到菜单

        // 移动到已有分组
        for group in workspace.groups {
            // 遍历工作区中所有已有的分组
            let menuItem = NSMenuItem(
                title: "移动到「\(group.name)」",
                // 显示"移动到「分组名」"，例如"移动到「开发服务器」"
                action: action,
                keyEquivalent: ""
            )
            menuItem.target = target
            menuItem.representedObject = TabMenuPayload(tabID: tabID, item: .moveToGroup(groupID: group.id, groupName: group.name))
            // 载荷中携带目标分组的 ID 和名称，点击时用于移动标签
            if let image = NSImage(
                systemSymbolName: TabMenuItem.moveToGroup(groupID: group.id, groupName: group.name).symbolName,
                // "rectangle.stack" 图标
                accessibilityDescription: "移动到分组"
            ) {
                menuItem.image = image
            }
            menu.addItem(menuItem)
            // 每个已有分组对应一个菜单项，用户可以点击将标签移入该分组
        }

        // 取消分组
        let ungroupItem = NSMenuItem(
            title: TabMenuItem.ungroup.title,
            // 显示"未分组"
            action: action,
            keyEquivalent: ""
        )
        ungroupItem.target = target
        ungroupItem.representedObject = TabMenuPayload(tabID: tabID, item: .ungroup)
        // 载荷标记为 .ungroup 操作
        if let image = NSImage(
            systemSymbolName: TabMenuItem.ungroup.symbolName,
            accessibilityDescription: TabMenuItem.ungroup.title
        ) {
            ungroupItem.image = image
        }
        menu.addItem(ungroupItem)
        // 将"未分组"菜单项添加到菜单末尾

        return menu
        // 返回构建完成的 NSMenu 对象，调用方会将其弹出显示
    }
}

/// 页签右键菜单 action handler。
///
/// 持有 `WorkspaceStore` 弱引用，接收 NSMenuItem 点击后
/// 解包 `TabMenuPayload` 并转发到对应的 `WorkspaceStore` 方法。
///
/// 使用弱引用（weak）持有 WorkspaceStore 是为了避免循环引用：
/// NSMenu -> menuItem -> target(handler) -> workspace
/// 如果 handler 强引用 workspace，而 workspace 又间接引用 handler，就会内存泄漏。
@MainActor
final class TabMenuActionHandler: NSObject {
    /// 工作区状态对象的弱引用
    /// weak 关键字表示不增加引用计数，当 WorkspaceStore 被释放时自动变为 nil
    private weak var workspace: WorkspaceStore?

    /// 初始化 handler，传入工作区状态对象
    /// - Parameter workspace: 工作区状态，用于执行菜单操作
    init(workspace: WorkspaceStore) {
        self.workspace = workspace
    }

    /// NSMenuItem 点击回调：解包 payload 并执行对应操作。
    /// 当用户点击右键菜单中的某个条目时，系统会调用这个方法。
    /// @objc 标记使这个方法可以被 Objective-C runtime 发现（NSMenu 的 action 机制需要）。
    @objc func handleMenuItem(_ sender: NSMenuItem) {
        // sender 是被点击的 NSMenuItem 对象
        guard let payload = sender.representedObject as? TabMenuPayload else { return }
        // 从菜单项的 representedObject 中取出载荷
        // 如果取不到（类型不匹配或为 nil），直接返回不做任何事
        switch payload.item {
        // 根据载荷中的菜单条目类型执行对应操作
        case .reconnect:
            // 用户点击了"重连"：重新建立 SSH 连接
            workspace?.reconnectSession(tabID: payload.tabID)
        case .closeTab:
            // 用户点击了"关闭标签页"：关闭指定标签
            workspace?.requestClose(tabID: payload.tabID)
        case .closeOthers:
            // 用户点击了"关闭其他标签页"：保留当前标签，关闭其余所有
            workspace?.requestCloseOthers(keeping: payload.tabID)
        case .closeAll:
            // 用户点击了"关闭全部标签页"：关闭所有标签
            workspace?.requestCloseAll()
        case .newGroup:
            // 用户点击了"新建分组"：为当前标签创建一个新分组
            _ = workspace?.createGroup(forTabID: payload.tabID)
            // _ = 表示忽略返回值（创建的分组 ID）
        case .moveToGroup(let groupID, _):
            // 用户点击了"移动到分组"：将标签移到指定分组
            // groupID 是目标分组 ID，_ 忽略分组名称（此处不需要）
            workspace?.moveTab(payload.tabID, toGroup: groupID)
        case .ungroup:
            // 用户点击了"未分组"：将标签从当前分组中移出
            workspace?.removeTabFromGroup(payload.tabID)
        case .deleteGroup(let groupID):
            // 用户点击了"删除分组"：删除指定分组
            workspace?.deleteGroup(id: groupID)
        }
    }
}
#endif
// #endif 结束 macOS 条件编译块

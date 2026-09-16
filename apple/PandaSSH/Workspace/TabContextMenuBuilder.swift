import Foundation

#if os(macOS)
import AppKit
#endif

/// 页签右键菜单条目。
///
/// 每个条目携带中文标题、SF Symbol 图标名与键盘快捷键，
/// 供 macOS NSMenu 构建与 iPadOS `.contextMenu` 共用。
enum TabMenuItem: Equatable {
    case reconnect
    case closeTab
    case closeOthers
    case closeAll
    case newGroup
    case moveToGroup(groupID: UUID, groupName: String)
    case ungroup
    case deleteGroup(groupID: UUID)

    /// 菜单项中文标题。
    var title: String {
        switch self {
        case .reconnect: return "重连"
        case .closeTab: return "关闭标签页"
        case .closeOthers: return "关闭其他标签页"
        case .closeAll: return "关闭全部标签页"
        case .newGroup: return "新建分组"
        case .moveToGroup(_, let groupName): return "移动到「\(groupName)」"
        case .ungroup: return "未分组"
        case .deleteGroup: return "删除分组"
        }
    }

    /// SF Symbol 图标名。
    var symbolName: String {
        switch self {
        case .reconnect: return "arrow.clockwise"
        case .closeTab: return "xmark"
        case .closeOthers: return "xmark.circle"
        case .closeAll: return "xmark.circle.fill"
        case .newGroup: return "rectangle.stack.badge.plus"
        case .moveToGroup: return "rectangle.stack"
        case .ungroup: return "rectangle.stack"
        case .deleteGroup: return "rectangle.stack.badge.minus"
        }
    }

    /// 快捷键字符。
    var keyEquivalent: String {
        switch self {
        case .reconnect: return "r"
        case .closeTab: return "w"
        case .closeOthers: return "w"
        case .closeAll: return "w"
        case .newGroup, .moveToGroup, .ungroup, .deleteGroup: return ""
        }
    }

}

#if os(macOS)
extension TabMenuItem {
    /// macOS NSMenu 的快捷键修饰键。iPadOS 长按菜单不展示快捷键，
    /// 因此不得让 AppKit 类型泄漏到共享业务菜单模型。
    var keyModifiers: NSEvent.ModifierFlags {
        switch self {
        case .reconnect: return .command
        case .closeTab: return .command
        case .closeOthers: return [.command, .option]
        case .closeAll: return [.command, .option, .shift]
        case .newGroup, .moveToGroup, .ungroup, .deleteGroup: return []
        }
    }
}
#endif

/// 页签右键菜单纯值构建器。
///
/// 根据标签类型生成菜单条目列表与分组结构。
/// 分组边界对应 NSMenu 的 `separatorItem`。
enum TabContextMenuBuilder {

    /// 返回指定标签类型的菜单条目列表（扁平，不含分隔线）。
    static func items(for kind: WorkspaceTab.Kind) -> [TabMenuItem] {
        switch kind {
        case .terminal:
            return [.reconnect, .closeTab, .closeOthers, .closeAll]
        case .sftp:
            return [.closeTab, .closeOthers, .closeAll]
        }
    }

    /// 返回按分隔线分组的二维数组。
    ///
    /// 终端标签分两组（会话操作 + 关闭操作），SFTP 标签仅一组。
    static func groups(for kind: WorkspaceTab.Kind) -> [[TabMenuItem]] {
        switch kind {
        case .terminal:
            return [[.reconnect], [.closeTab, .closeOthers, .closeAll]]
        case .sftp:
            return [[.closeTab, .closeOthers, .closeAll]]
        }
    }
}

/// NSMenu 菜单项的载荷，携带目标标签 ID 与菜单条目。
///
/// 点击时由 action handler 解包，转发到 `WorkspaceStore` 方法。
final class TabMenuPayload {
    let tabID: UUID
    let item: TabMenuItem

    init(tabID: UUID, item: TabMenuItem) {
        self.tabID = tabID
        self.item = item
    }
}

#if os(macOS)
extension TabContextMenuBuilder {

    /// 构建 macOS 原生 `NSMenu`。
    ///
    /// 每个条目设置 SF Symbol 图标、快捷键与修饰键。
    /// 分组边界插入 `NSMenu.separatorItem`。
    ///
    /// - Parameters:
    ///   - tabID: 右键点击的标签 ID，写入每个非分隔线项的 `representedObject`。
    ///   - tabKind: 标签类型，决定条目集合与分组。
    ///   - workspace: 工作区状态，用于获取分组信息。
    ///   - target: 菜单项 action 的 target；测试可传 nil。
    ///   - action: 菜单项 action selector；测试可传 `#selector(NSObject.noop)`。
    @MainActor
    static func buildNSMenu(
        tabID: UUID,
        tabKind kind: WorkspaceTab.Kind,
        workspace: WorkspaceStore,
        target: AnyObject? = nil,
        action: Selector = #selector(TabMenuActionHandler.handleMenuItem(_:))
    ) -> NSMenu {
        let menu = NSMenu()
        let groups = self.groups(for: kind)

        for (groupIndex, group) in groups.enumerated() {
            if groupIndex > 0 {
                menu.addItem(.separator())
            }
            for item in group {
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: action,
                    keyEquivalent: item.keyEquivalent
                )
                menuItem.keyEquivalentModifierMask = item.keyModifiers
                menuItem.target = target
                menuItem.representedObject = TabMenuPayload(tabID: tabID, item: item)
                if let image = NSImage(
                    systemSymbolName: item.symbolName,
                    accessibilityDescription: item.title
                ) {
                    menuItem.image = image
                }
                menu.addItem(menuItem)
            }
        }

        // 添加分组操作菜单
        menu.addItem(.separator())

        // 新建分组
        let newGroupItem = NSMenuItem(
            title: TabMenuItem.newGroup.title,
            action: action,
            keyEquivalent: ""
        )
        newGroupItem.target = target
        newGroupItem.representedObject = TabMenuPayload(tabID: tabID, item: .newGroup)
        if let image = NSImage(
            systemSymbolName: TabMenuItem.newGroup.symbolName,
            accessibilityDescription: TabMenuItem.newGroup.title
        ) {
            newGroupItem.image = image
        }
        menu.addItem(newGroupItem)

        // 移动到已有分组
        for group in workspace.groups {
            let menuItem = NSMenuItem(
                title: "移动到「\(group.name)」",
                action: action,
                keyEquivalent: ""
            )
            menuItem.target = target
            menuItem.representedObject = TabMenuPayload(tabID: tabID, item: .moveToGroup(groupID: group.id, groupName: group.name))
            if let image = NSImage(
                systemSymbolName: TabMenuItem.moveToGroup(groupID: group.id, groupName: group.name).symbolName,
                accessibilityDescription: "移动到分组"
            ) {
                menuItem.image = image
            }
            menu.addItem(menuItem)
        }

        // 取消分组
        let ungroupItem = NSMenuItem(
            title: TabMenuItem.ungroup.title,
            action: action,
            keyEquivalent: ""
        )
        ungroupItem.target = target
        ungroupItem.representedObject = TabMenuPayload(tabID: tabID, item: .ungroup)
        if let image = NSImage(
            systemSymbolName: TabMenuItem.ungroup.symbolName,
            accessibilityDescription: TabMenuItem.ungroup.title
        ) {
            ungroupItem.image = image
        }
        menu.addItem(ungroupItem)

        return menu
    }
}

/// 页签右键菜单 action handler。
///
/// 持有 `WorkspaceStore` 弱引用，接收 NSMenuItem 点击后
/// 解包 `TabMenuPayload` 并转发到对应的 `WorkspaceStore` 方法。
@MainActor
final class TabMenuActionHandler: NSObject {
    private weak var workspace: WorkspaceStore?

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
    }

    /// NSMenuItem 点击回调：解包 payload 并执行对应操作。
    @objc func handleMenuItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? TabMenuPayload else { return }
        switch payload.item {
        case .reconnect:
            workspace?.reconnectTerminal(tabID: payload.tabID)
        case .closeTab:
            workspace?.requestClose(tabID: payload.tabID)
        case .closeOthers:
            workspace?.requestCloseOthers(keeping: payload.tabID)
        case .closeAll:
            workspace?.requestCloseAll()
        case .newGroup:
            workspace?.createGroup(forTabID: payload.tabID)
        case .moveToGroup(let groupID, _):
            workspace?.moveTab(payload.tabID, toGroup: groupID)
        case .ungroup:
            workspace?.removeTabFromGroup(payload.tabID)
        case .deleteGroup(let groupID):
            workspace?.deleteGroup(id: groupID)
        }
    }
}
#endif

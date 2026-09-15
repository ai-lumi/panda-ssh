import Foundation

#if os(macOS)
import AppKit
#endif

/// 页签右键菜单条目。
///
/// 每个条目携带中文标题、SF Symbol 图标名与键盘快捷键，
/// 供 macOS NSMenu 构建与 iPadOS `.contextMenu` 共用。
enum TabMenuItem: Equatable, CaseIterable {
    case reconnect
    case closeTab
    case closeOthers
    case closeAll

    /// 菜单项中文标题。
    var title: String {
        switch self {
        case .reconnect: return "重连"
        case .closeTab: return "关闭标签页"
        case .closeOthers: return "关闭其他标签页"
        case .closeAll: return "关闭全部标签页"
        }
    }

    /// SF Symbol 图标名。
    var symbolName: String {
        switch self {
        case .reconnect: return "arrow.clockwise"
        case .closeTab: return "xmark"
        case .closeOthers: return "xmark.circle"
        case .closeAll: return "xmark.circle.fill"
        }
    }

    /// 快捷键字符。
    var keyEquivalent: String {
        switch self {
        case .reconnect: return "r"
        case .closeTab: return "w"
        case .closeOthers: return "w"
        case .closeAll: return "w"
        }
    }

    /// 快捷键修饰键。
    var keyModifiers: NSEvent.ModifierFlags {
        switch self {
        case .reconnect: return .command
        case .closeTab: return .command
        case .closeOthers: return [.command, .option]
        case .closeAll: return [.command, .option, .shift]
        }
    }
}

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
    ///   - target: 菜单项 action 的 target；测试可传 nil。
    ///   - action: 菜单项 action selector；测试可传 `#selector(NSObject.noop)`。
    static func buildNSMenu(
        tabID: UUID,
        tabKind kind: WorkspaceTab.Kind,
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
        }
    }
}
#endif

import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// `TabContextMenuBuilder` 纯值逻辑测试。
///
/// 覆盖菜单条目集合 (`items(for:)`)、分组结构 (`groups(for:)`)、
/// 条目属性（标题/图标/快捷键），以及 macOS NSMenu 构建。
/// 满足 `AGENTS.md` 三类场景门禁（正常流程 / 意外操作 / 边界条件）。
final class TabContextMenuBuilderTests: XCTestCase {

    // MARK: - 正常流程

    /// 终端标签 `items(for:)` 返回完整四项（重连 + 关闭三项）。
    func testItems_terminal_returnsAllFourItems() {
        let items = TabContextMenuBuilder.items(for: .terminal)
        XCTAssertEqual(items, [.reconnect, .closeTab, .closeOthers, .closeAll])
    }

    /// SFTP 标签 `items(for:)` 返回三项（无重连）。
    func testItems_sftp_returnsThreeItemsWithoutReconnect() {
        let items = TabContextMenuBuilder.items(for: .sftp)
        XCTAssertEqual(items, [.closeTab, .closeOthers, .closeAll])
    }

    /// 终端标签 `groups(for:)` 返回两组：会话操作 + 关闭操作。
    func testGroups_terminal_returnsTwoGroups() {
        let groups = TabContextMenuBuilder.groups(for: .terminal)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0], [.reconnect])
        XCTAssertEqual(groups[1], [.closeTab, .closeOthers, .closeAll])
    }

    /// SFTP 标签 `groups(for:)` 返回一组（无分隔线需求）。
    func testGroups_sftp_returnsOneGroup() {
        let groups = TabContextMenuBuilder.groups(for: .sftp)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0], [.closeTab, .closeOthers, .closeAll])
    }

    // MARK: - 条目属性

    /// 每个条目携带正确的中文标题。
    func testTitle_allItems_haveCorrectTitles() {
        XCTAssertEqual(TabMenuItem.reconnect.title, "重连")
        XCTAssertEqual(TabMenuItem.closeTab.title, "关闭标签页")
        XCTAssertEqual(TabMenuItem.closeOthers.title, "关闭其他标签页")
        XCTAssertEqual(TabMenuItem.closeAll.title, "关闭全部标签页")
    }

    /// 每个条目携带正确的 SF Symbol 图标名。
    func testSymbolName_allItems_haveCorrectSymbols() {
        XCTAssertEqual(TabMenuItem.reconnect.symbolName, "arrow.clockwise")
        XCTAssertEqual(TabMenuItem.closeTab.symbolName, "xmark")
        XCTAssertEqual(TabMenuItem.closeOthers.symbolName, "xmark.circle")
        XCTAssertEqual(TabMenuItem.closeAll.symbolName, "xmark.circle.fill")
    }

    /// 每个条目携带正确的快捷键。
    func testKeyEquivalent_allItems_haveCorrectShortcuts() {
        XCTAssertEqual(TabMenuItem.reconnect.keyEquivalent, "r")
        XCTAssertEqual(TabMenuItem.closeTab.keyEquivalent, "w")
        XCTAssertEqual(TabMenuItem.closeOthers.keyEquivalent, "w")
        XCTAssertEqual(TabMenuItem.closeAll.keyEquivalent, "w")
    }

    /// 每个条目的修饰键正确。
    func testKeyModifiers_allItems_haveCorrectModifiers() {
        XCTAssertEqual(TabMenuItem.reconnect.keyModifiers, .command)
        XCTAssertEqual(TabMenuItem.closeTab.keyModifiers, .command)
        XCTAssertEqual(TabMenuItem.closeOthers.keyModifiers, [.command, .option])
        XCTAssertEqual(TabMenuItem.closeAll.keyModifiers, [.command, .option, .shift])
    }

    // MARK: - 边界条件

    /// `TabMenuItem` 为 `Equatable`，可比较。
    func testEquatable_sameItems_areEqual() {
        XCTAssertEqual(TabMenuItem.reconnect, TabMenuItem.reconnect)
        XCTAssertNotEqual(TabMenuItem.reconnect, TabMenuItem.closeTab)
    }

    /// `TabMenuItem` 为 `CaseIterable`，覆盖所有 case。
    func testAllCases_containsAllFourItems() {
        XCTAssertEqual(TabMenuItem.allCases.count, 4)
        XCTAssertTrue(TabMenuItem.allCases.contains(.reconnect))
        XCTAssertTrue(TabMenuItem.allCases.contains(.closeTab))
        XCTAssertTrue(TabMenuItem.allCases.contains(.closeOthers))
        XCTAssertTrue(TabMenuItem.allCases.contains(.closeAll))
    }
}

// MARK: - macOS NSMenu 构建测试

#if os(macOS)
import AppKit

extension TabContextMenuBuilderTests {

    /// 终端标签 NSMenu 包含 4 条目 + 1 分隔线 = 5 项。
    func testBuildNSMenu_terminal_hasFiveItemsWithSeparator() {
        let tabID = UUID()
        let menu = TabContextMenuBuilder.buildNSMenu(tabID: tabID, tabKind: .terminal)

        XCTAssertEqual(menu.items.count, 5, "终端标签应有 4 条目 + 1 分隔线")

        // 第一项：重连
        let reconnect = menu.items[0]
        XCTAssertFalse(reconnect.isSeparatorItem)
        XCTAssertEqual(reconnect.title, "重连")
        XCTAssertNotNil(reconnect.image, "重连项应有图标")
        XCTAssertEqual(reconnect.keyEquivalent, "r")

        // 第二项：分隔线
        XCTAssertTrue(menu.items[1].isSeparatorItem)

        // 第三项：关闭标签页
        let closeTab = menu.items[2]
        XCTAssertEqual(closeTab.title, "关闭标签页")
        XCTAssertNotNil(closeTab.image)
        XCTAssertEqual(closeTab.keyEquivalent, "w")

        // 第四项：关闭其他
        let closeOthers = menu.items[3]
        XCTAssertEqual(closeOthers.title, "关闭其他标签页")
        XCTAssertNotNil(closeOthers.image)

        // 第五项：关闭全部
        let closeAll = menu.items[4]
        XCTAssertEqual(closeAll.title, "关闭全部标签页")
        XCTAssertNotNil(closeAll.image)
    }

    /// SFTP 标签 NSMenu 包含 3 条目，无分隔线。
    func testBuildNSMenu_sftp_hasThreeItemsNoSeparator() {
        let tabID = UUID()
        let menu = TabContextMenuBuilder.buildNSMenu(tabID: tabID, tabKind: .sftp)

        XCTAssertEqual(menu.items.count, 3, "SFTP 标签应有 3 条目，无分隔线")
        for item in menu.items {
            XCTAssertFalse(item.isSeparatorItem)
        }
    }

    /// 每个非分隔线项的 `representedObject` 为 `TabMenuPayload`，携带正确 tabID。
    func testBuildNSMenu_nonSeparatorItems_carryPayload() {
        let tabID = UUID()
        let menu = TabContextMenuBuilder.buildNSMenu(tabID: tabID, tabKind: .terminal)

        for item in menu.items where !item.isSeparatorItem {
            let payload = item.representedObject as? TabMenuPayload
            XCTAssertNotNil(payload, "非分隔线项应携带 TabMenuPayload")
            XCTAssertEqual(payload?.tabID, tabID)
        }
    }

    /// NSMenu 中快捷键修饰键正确设置。
    func testBuildNSMenu_keyEquivalentModifierMasks() {
        let tabID = UUID()
        let menu = TabContextMenuBuilder.buildNSMenu(tabID: tabID, tabKind: .terminal)

        // 重连：⌘
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, .command)
        // 关闭标签页：⌘
        XCTAssertEqual(menu.items[2].keyEquivalentModifierMask, .command)
        // 关闭其他：⌥⌘
        XCTAssertEqual(menu.items[3].keyEquivalentModifierMask, [.command, .option])
        // 关闭全部：⇧⌘⌥
        XCTAssertEqual(menu.items[4].keyEquivalentModifierMask, [.command, .option, .shift])
    }
}
#endif

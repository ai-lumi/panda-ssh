import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// `TabContextMenuBuilder` 纯值逻辑测试。
///
/// 覆盖菜单条目集合 (`items(for:)`)、分组结构 (`groups(for:)`)、
/// 条目属性（标题/图标/快捷键），以及 macOS NSMenu 构建（含分组操作区）。
/// 满足 `AGENTS.md` 三类场景门禁（正常流程 / 意外操作 / 边界条件）。
@MainActor
final class TabContextMenuBuilderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        workspaceReset()
    }

    override func tearDown() {
        workspaceReset()
        super.tearDown()
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(hostNameProvider: { _ in nil })
    }

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

    /// 所有条目不绑定快捷键字符（右键菜单不使用快捷键）。
    func testKeyEquivalent_allItems_areEmpty() {
        XCTAssertEqual(TabMenuItem.reconnect.keyEquivalent, "")
        XCTAssertEqual(TabMenuItem.closeTab.keyEquivalent, "")
        XCTAssertEqual(TabMenuItem.closeOthers.keyEquivalent, "")
        XCTAssertEqual(TabMenuItem.closeAll.keyEquivalent, "")
    }

    // MARK: - 边界条件

    /// `TabMenuItem` 为 `Equatable`，可比较。
    func testEquatable_sameItems_areEqual() {
        XCTAssertEqual(TabMenuItem.reconnect, TabMenuItem.reconnect)
        XCTAssertNotEqual(TabMenuItem.reconnect, TabMenuItem.closeTab)
    }

    /// 分组操作条目携带正确的标题与图标。
    func testGroupItems_haveCorrectTitlesAndSymbols() {
        let groupID = UUID()
        XCTAssertEqual(TabMenuItem.newGroup.title, "新建分组")
        XCTAssertEqual(TabMenuItem.moveToGroup(groupID: groupID, groupName: "开发").title, "移动到「开发」")
        XCTAssertEqual(TabMenuItem.ungroup.title, "未分组")
        XCTAssertEqual(TabMenuItem.deleteGroup(groupID: groupID).title, "删除分组")

        XCTAssertEqual(TabMenuItem.newGroup.symbolName, "rectangle.stack.badge.plus")
        XCTAssertEqual(TabMenuItem.moveToGroup(groupID: groupID, groupName: "开发").symbolName, "rectangle.stack")
        XCTAssertEqual(TabMenuItem.ungroup.symbolName, "rectangle.stack")
        XCTAssertEqual(TabMenuItem.deleteGroup(groupID: groupID).symbolName, "rectangle.stack.badge.minus")
    }

    /// 分组操作条目不绑定快捷键字符。
    func testGroupItems_haveEmptyKeyEquivalents() {
        let groupID = UUID()
        XCTAssertEqual(TabMenuItem.newGroup.keyEquivalent, "")
        XCTAssertEqual(TabMenuItem.moveToGroup(groupID: groupID, groupName: "开发").keyEquivalent, "")
        XCTAssertEqual(TabMenuItem.ungroup.keyEquivalent, "")
        XCTAssertEqual(TabMenuItem.deleteGroup(groupID: groupID).keyEquivalent, "")
    }
}

// MARK: - macOS NSMenu 构建测试

#if os(macOS)
import AppKit

extension TabContextMenuBuilderTests {

    /// 终端标签 NSMenu：4 关闭/重连条目 + 2 分隔线 + 分组操作区（新建分组 + 未分组）。
    func testBuildNSMenu_terminal_hasGroupSectionWithSeparators() {
        let tabID = UUID()
        let menu = TabContextMenuBuilder.buildNSMenu(
            tabID: tabID, tabKind: .terminal, workspace: makeStore()
        )

        // 重连 + sep + 关闭三项 + sep + 新建分组 + 未分组
        XCTAssertEqual(menu.items.count, 8, "终端标签应有 6 条目 + 2 分隔线")
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertTrue(menu.items[5].isSeparatorItem)

        // 第一项：重连
        let reconnect = menu.items[0]
        XCTAssertFalse(reconnect.isSeparatorItem)
        XCTAssertEqual(reconnect.title, "重连")
        XCTAssertNotNil(reconnect.image, "重连项应有图标")
        XCTAssertEqual(reconnect.keyEquivalent, "")

        // 关闭标签页 / 关闭其他 / 关闭全部
        XCTAssertEqual(menu.items[2].title, "关闭标签页")
        XCTAssertNotNil(menu.items[2].image)
        XCTAssertEqual(menu.items[2].keyEquivalent, "")
        XCTAssertEqual(menu.items[3].title, "关闭其他标签页")
        XCTAssertNotNil(menu.items[3].image)
        XCTAssertEqual(menu.items[4].title, "关闭全部标签页")
        XCTAssertNotNil(menu.items[4].image)

        // 分组操作区
        XCTAssertEqual(menu.items[6].title, "新建分组")
        XCTAssertEqual(menu.items[7].title, "未分组")
    }

    /// SFTP 标签 NSMenu：3 关闭条目 + 1 分隔线 + 分组操作区。
    func testBuildNSMenu_sftp_hasCloseItemsAndGroupSection() {
        let tabID = UUID()
        let menu = TabContextMenuBuilder.buildNSMenu(
            tabID: tabID, tabKind: .sftp, workspace: makeStore()
        )

        // 关闭三项（无重连，无组内分隔线）+ sep + 新建分组 + 未分组
        XCTAssertEqual(menu.items.count, 6, "SFTP 标签应有 5 条目 + 1 分隔线")
        XCTAssertFalse(menu.items[0].isSeparatorItem)
        XCTAssertFalse(menu.items[1].isSeparatorItem)
        XCTAssertFalse(menu.items[2].isSeparatorItem)
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertEqual(menu.items[4].title, "新建分组")
        XCTAssertEqual(menu.items[5].title, "未分组")
    }

    /// 工作区已有分组时，菜单在「新建分组」与「未分组」之间插入移动到分组条目。
    func testBuildNSMenu_withExistingGroup_includesMoveToGroupItems() {
        let store = makeStore()
        let tabID = store.openTerminal(hostID: "h1")
        store.createGroup(forTabID: tabID, name: "开发")

        let menu = TabContextMenuBuilder.buildNSMenu(
            tabID: tabID, tabKind: .terminal, workspace: store
        )

        XCTAssertEqual(menu.items.count, 9)
        XCTAssertEqual(menu.items[7].title, "移动到「开发」")

        let payload = menu.items[7].representedObject as? TabMenuPayload
        XCTAssertEqual(payload?.item, .moveToGroup(groupID: store.groups[0].id, groupName: "开发"))
        store.closeAll()
    }

    /// 每个非分隔线项的 `representedObject` 为 `TabMenuPayload`，携带正确 tabID。
    func testBuildNSMenu_nonSeparatorItems_carryPayload() {
        let tabID = UUID()
        let menu = TabContextMenuBuilder.buildNSMenu(
            tabID: tabID, tabKind: .terminal, workspace: makeStore()
        )

        for item in menu.items where !item.isSeparatorItem {
            let payload = item.representedObject as? TabMenuPayload
            XCTAssertNotNil(payload, "非分隔线项应携带 TabMenuPayload")
            XCTAssertEqual(payload?.tabID, tabID)
        }
    }

}
#endif

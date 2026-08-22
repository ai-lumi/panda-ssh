import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// `TerminalContextMenuBuilder` 纯值类型逻辑测试。
///
/// 覆盖菜单条目集合 (`items(for:)`) 与可用性规则 (`isEnabled(_:in:)`)，
/// 不依赖任何 UI 框架（NSMenu / UIEditMenuInteraction）。
/// 满足 `AGENTS.md` 三类场景门禁（正常流程 / 意外操作 / 边界条件）。
final class TerminalContextMenuBuilderTests: XCTestCase {

    // MARK: - 正常流程

    /// §1.1 正常流程 1：`phase=.shell && hasSelection && hasClipboardText && hitLink=nil`
    /// → `items(for:)` 返回默认顺序；`isEnabled` 全部为 true。
    func testItems_shellPhaseWithSelectionClipboardNoLink_returnsDefaultOrder() {
        let ctx = TerminalMenuContext(
            phase: .shell,
            selectedText: "hello",
            hasClipboardText: true,
            hitLink: nil
        )

        let items = TerminalContextMenuBuilder.items(for: ctx)

        XCTAssertEqual(items, [
            .copy, .paste, .pasteAndEnter, .selectAll,
            .clearScreen, .resetTerminal, .copyAndPaste,
            .reconnect, .closeTab
        ], "无链接时条目集合应为默认顺序")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.copy, in: ctx), ".copy 在 .shell + hasSelection 应启用")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.paste, in: ctx), ".paste 在 .shell + hasClipboardText 应启用")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.pasteAndEnter, in: ctx))
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.selectAll, in: ctx))
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.clearScreen, in: ctx))
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.resetTerminal, in: ctx))
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.copyAndPaste, in: ctx), ".copyAndPaste 在 .shell + hasSelection + hasClipboardText 应启用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.reconnect, in: ctx), ".reconnect 仅在 .failed 启用")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.closeTab, in: ctx), ".closeTab 任何阶段都启用")
    }

    /// §1.1 正常流程 2：`phase=.failed` → 除「重连」「关闭标签页」外全部禁用，
    /// 「复制」在有选中时仍可用（用于失败信息拷贝）。
    func testItems_failedPhase_disablesAllExceptReconnectCloseTab_copyAvailableWithSelection() {
        let ctx = TerminalMenuContext(
            phase: .failed,
            selectedText: "err msg",
            hasClipboardText: true,
            hitLink: nil
        )

        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.reconnect, in: ctx), ".reconnect 在 .failed 应启用")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.closeTab, in: ctx))
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.copy, in: ctx), ".copy 在 .failed + hasSelection 应仍可用（拷贝错误信息）")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.paste, in: ctx), ".paste 在 .failed 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.pasteAndEnter, in: ctx))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.selectAll, in: ctx))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.clearScreen, in: ctx))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.resetTerminal, in: ctx))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copyAndPaste, in: ctx))
    }

    /// §1.1 正常流程 3：`phase=.connecting` → 除「关闭标签页」外其它全部禁用。
    func testItems_connectingPhase_disablesAllExceptCloseTab() {
        let ctx = TerminalMenuContext(
            phase: .connecting,
            selectedText: "hello",
            hasClipboardText: true,
            hitLink: nil
        )

        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.closeTab, in: ctx), ".closeTab 在 .connecting 应启用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copy, in: ctx), ".copy 在 .connecting 应禁用（防误操作）")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.paste, in: ctx))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.pasteAndEnter, in: ctx))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.selectAll, in: ctx))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.clearScreen, in: ctx))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.resetTerminal, in: ctx))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copyAndPaste, in: ctx))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.reconnect, in: ctx), ".reconnect 仅在 .failed 启用，.connecting 应禁用")
    }

    // MARK: - 意外操作

    /// §1.1 意外操作：`hitLink="https://x"` 但 `hasSelection=false`
    /// → `items(for:)` 首位 `.copyLink`、次位 `.openLink`，且两者启用。
    func testItems_hitLinkWithoutSelection_linkItemsAtHead() {
        let ctx = TerminalMenuContext(
            phase: .shell,
            selectedText: "",
            hasClipboardText: true,
            hitLink: "https://x"
        )

        let items = TerminalContextMenuBuilder.items(for: ctx)

        XCTAssertEqual(items.prefix(2), [.copyLink, .openLink], "命中链接时链接条目应置于首位")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.copyLink, in: ctx))
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.openLink, in: ctx))
    }

    // MARK: - 边界条件

    /// §1.1 边界 1：`hasSelection=true` 但 `selectedText==""`（空字符串）
    /// → 视同 `hasSelection=false`，「复制」「复制并粘贴」禁用。
    func testItems_emptySelectedText_treatedAsNoSelection() {
        let ctx = TerminalMenuContext(
            phase: .shell,
            selectedText: "",
            hasClipboardText: true,
            hitLink: nil
        )

        XCTAssertFalse(ctx.hasSelection, "空字符串视同无选中")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copy, in: ctx), "空选中时 .copy 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copyAndPaste, in: ctx), "空选中时 .copyAndPaste 应禁用")
    }

    /// §1.1 边界 2：`hitLink=""`（空串而非 nil）→ 视同无链接，不输出链接条目。
    func testItems_emptyHitLink_treatedAsNoLink() {
        let ctx = TerminalMenuContext(
            phase: .shell,
            selectedText: "hello",
            hasClipboardText: true,
            hitLink: ""
        )

        XCTAssertFalse(ctx.hasHitLink, "空串 hitLink 视同无链接")
        let items = TerminalContextMenuBuilder.items(for: ctx)
        XCTAssertFalse(items.contains(.copyLink), "空 hitLink 不应输出 .copyLink")
        XCTAssertFalse(items.contains(.openLink), "空 hitLink 不应输出 .openLink")
        XCTAssertEqual(items, TerminalContextMenuBuilder.defaultOrder, "无链接时条目集合应为默认顺序")
    }
}

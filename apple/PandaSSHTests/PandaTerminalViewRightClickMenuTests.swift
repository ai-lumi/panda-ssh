import XCTest

#if os(macOS)
@testable import PandaSSH_macOS

/// macOS `PandaTerminalView` 右键 NSMenu 构建与点击分发测试。
///
/// 覆盖 spec「终端内容区右键上下文菜单」在 macOS 端的实现行为：
/// - 正常流程：shell 阶段条目顺序与启用态、failed 阶段仅重连/关闭/复制启用。
/// - 意外操作：右键位置越界不弹菜单、不抛异常。
/// - 边界条件：每个 enabled item 点击都调用 `perform(_:hitLink:)` 一次。
/// 满足 `AGENTS.md` 三类场景门禁。
final class PandaTerminalViewRightClickMenuTests: XCTestCase {

    // MARK: - 正常流程

    /// §4.1 正常流程 1：`phase=.shell && hasSelection && hasClipboardText && hitLink="https://x"`
    /// → 菜单条目按 `[copyLink, openLink, copy, paste, pasteAndEnter, selectAll,
    /// clearScreen, resetTerminal, copyAndPaste, reconnect, closeTab]` 顺序出现，
    /// 启用态符合 `TerminalContextMenuBuilder.isEnabled`。
    func testRightClick_shellPhaseWithSelectionClipboardAndLink_showsFullItemOrder() {
        let (view, coordinator) = MacTerminalViewTestHarness.make(
            phase: .shell,
            selectedText: "hello",
            hasClipboardText: true,
            hitLink: "https://x"
        )

        view.simulateRightClick(at: NSPoint(x: 100, y: 100))

        XCTAssertEqual(view.menuPresentCount, 1, "右键应弹菜单一次")
        XCTAssertEqual(view.lastMenuAnchor, NSPoint(x: 100, y: 100), "anchor 应为右键位置")
        XCTAssertEqual(view.lastMenuItems, [
            .copyLink, .openLink,
            .copy, .paste, .pasteAndEnter, .selectAll,
            .clearScreen, .resetTerminal, .copyAndPaste,
            .reconnect, .closeTab
        ], "命中链接时链接条目置于首位，后接默认顺序")
        // 逐项验证启用态符合 Builder 规则
        for item in view.lastMenuItems {
            let expected = TerminalContextMenuBuilder.isEnabled(item, in: view.lastMenuContext!)
            let actual = view.lastNSMenu?.items.first(where: {
                ($0.representedObject as? PandaTerminalView.MenuPayload)?.item == item
            })?.isEnabled
            XCTAssertEqual(actual, expected, "条目 \(item) 的 NSMenuItem.isEnabled 应与 Builder 规则一致")
        }
        XCTAssertTrue(coordinator.performCalls.isEmpty, "未点击菜单项时 perform 不应被调用")
    }

    /// §4.1 正常流程 2：`phase=.failed` → 仅「重连」「关闭标签页」「复制」（当有选中时）启用。
    func testRightClick_failedPhase_enablesOnlyReconnectCloseTabAndCopy() {
        let (view, coordinator) = MacTerminalViewTestHarness.make(
            phase: .failed,
            selectedText: "err msg",
            hasClipboardText: true,
            hitLink: nil
        )

        view.simulateRightClick(at: NSPoint(x: 50, y: 50))

        XCTAssertEqual(view.menuPresentCount, 1, "failed 阶段右键仍应弹菜单")
        XCTAssertEqual(view.lastMenuItems, MacTerminalViewTestHarness.defaultItemOrder, "无链接时条目集合为默认顺序")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.reconnect, in: view.lastMenuContext!), "reconnect 在 failed 应启用")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.closeTab, in: view.lastMenuContext!), "closeTab 任何阶段都应启用")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.copy, in: view.lastMenuContext!), "copy 在 failed + hasSelection 应启用（拷贝错误信息）")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.paste, in: view.lastMenuContext!), "paste 在 failed 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.pasteAndEnter, in: view.lastMenuContext!))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.selectAll, in: view.lastMenuContext!))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.clearScreen, in: view.lastMenuContext!))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.resetTerminal, in: view.lastMenuContext!))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copyAndPaste, in: view.lastMenuContext!))
        XCTAssertTrue(coordinator.performCalls.isEmpty)
    }

    /// §4.1 正常流程补充：`phase=.connecting` → 除「关闭标签页」外其它全部禁用。
    func testRightClick_connectingPhase_disablesAllExceptCloseTab() {
        let (view, _) = MacTerminalViewTestHarness.make(
            phase: .connecting,
            selectedText: "hello",
            hasClipboardText: true,
            hitLink: nil
        )

        view.simulateRightClick(at: NSPoint(x: 100, y: 100))

        XCTAssertEqual(view.menuPresentCount, 1)
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.closeTab, in: view.lastMenuContext!), "closeTab 在 connecting 应启用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copy, in: view.lastMenuContext!), "copy 在 connecting 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.paste, in: view.lastMenuContext!))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.reconnect, in: view.lastMenuContext!), "reconnect 仅在 failed 启用")
    }

    // MARK: - 意外操作

    /// §4.1 意外操作：右键位置在终端视图外（负坐标）→ 不弹菜单，不抛异常。
    func testRightClick_outOfBounds_doesNotShowMenu() {
        let (view, coordinator) = MacTerminalViewTestHarness.make()

        view.simulateRightClick(at: NSPoint(x: -10, y: -10))

        XCTAssertEqual(view.menuPresentCount, 0, "边界外不应弹菜单")
        XCTAssertNil(view.lastMenuAnchor, "边界外不应更新 anchor")
        XCTAssertTrue(view.lastMenuItems.isEmpty, "边界外不应构建条目集合")
        XCTAssertNil(view.lastNSMenu, "边界外不应构建 NSMenu")
        XCTAssertTrue(coordinator.performCalls.isEmpty)
        // 测试不崩溃即通过
    }

    /// §4.1 意外操作补充：右键位置在视图右上角外（x 超出宽度）→ 不弹菜单。
    func testRightClick_xOutOfBounds_doesNotShowMenu() {
        let (view, _) = MacTerminalViewTestHarness.make()

        view.simulateRightClick(at: NSPoint(x: 400, y: 100))

        XCTAssertEqual(view.menuPresentCount, 0, "x 越界不应弹菜单")
    }

    // MARK: - 边界条件

    /// §4.1 边界 1：右键位置在视图右下角边缘（含等于边界）→ 应弹菜单。
    func testRightClick_atLowerRightEdge_showsMenu() {
        let (view, _) = MacTerminalViewTestHarness.make()

        view.simulateRightClick(at: NSPoint(x: 320, y: 240))

        XCTAssertEqual(view.menuPresentCount, 1, "边缘点（含等于）应弹菜单")
        XCTAssertEqual(view.lastMenuAnchor, NSPoint(x: 320, y: 240))
    }

    /// §4.1 边界 2：菜单点击每个 enabled item → coordinator 对应 `perform(_:)` 被调用一次。
    func testMenuItemClick_eachEnabledItem_callsPerformOnce() {
        let (view, coordinator) = MacTerminalViewTestHarness.make(
            phase: .shell,
            selectedText: "hello",
            hasClipboardText: true,
            hitLink: "https://x"
        )
        view.simulateRightClick(at: NSPoint(x: 100, y: 100))

        let enabledItems = view.lastMenuItems.filter {
            TerminalContextMenuBuilder.isEnabled($0, in: view.lastMenuContext!)
        }
        XCTAssertFalse(enabledItems.isEmpty, "当前上下文应至少有一个启用项")

        for item in enabledItems {
            view.simulateMenuItemClick(item)
        }

        XCTAssertEqual(coordinator.performCalls.count, enabledItems.count, "每个 enabled item 应触发一次 perform")
        // 验证每个调用与对应 item 类型一致
        for (i, item) in enabledItems.enumerated() {
            XCTAssertEqual(coordinator.performCalls[i].item, item, "第 \(i) 次调用的 item 应匹配")
        }
    }

    /// §4.1 边界 3：链接命中时点击「复制链接地址」携带 hitLink。
    func testMenuItemClick_copyLinkCarriesHitLink() {
        let (view, coordinator) = MacTerminalViewTestHarness.make(
            phase: .shell,
            hitLink: "https://example.com"
        )
        view.simulateRightClick(at: NSPoint(x: 100, y: 100))

        view.simulateMenuItemClick(.copyLink)

        XCTAssertEqual(coordinator.performCalls.count, 1)
        XCTAssertEqual(coordinator.performCalls[0].item, .copyLink)
        XCTAssertEqual(coordinator.performCalls[0].hitLink, "https://example.com", "hitLink 应携带命中链接")
    }

    /// §4.1 边界 4：点击「打开链接」携带 hitLink。
    func testMenuItemClick_openLinkCarriesHitLink() {
        let (view, coordinator) = MacTerminalViewTestHarness.make(
            phase: .shell,
            hitLink: "https://example.com"
        )
        view.simulateRightClick(at: NSPoint(x: 100, y: 100))

        view.simulateMenuItemClick(.openLink)

        XCTAssertEqual(coordinator.performCalls.count, 1)
        XCTAssertEqual(coordinator.performCalls[0].item, .openLink)
        XCTAssertEqual(coordinator.performCalls[0].hitLink, "https://example.com")
    }

    // MARK: - 意外操作（菜单项点击）

    /// §4.1 意外操作：点击被禁用的菜单项不调用 perform。
    /// failed 阶段 .paste 被禁用，仍注入点击事件验证防御。
    func testMenuItemClick_disabledItem_doesNotCallPerform() {
        let (view, coordinator) = MacTerminalViewTestHarness.make(phase: .failed)
        view.simulateRightClick(at: NSPoint(x: 100, y: 100))

        // .paste 在 failed 阶段被禁用
        view.simulateMenuItemClick(.paste)

        XCTAssertTrue(coordinator.performCalls.isEmpty, "禁用项点击不应触发 perform")
    }

    /// §4.1 意外操作：菜单未弹出时点击事件不触发 perform。
    func testMenuItemClick_withoutMenu_doesNotCallPerform() {
        let (view, coordinator) = MacTerminalViewTestHarness.make()
        // 不调用 simulateRightClick，菜单未弹出

        view.simulateMenuItemClick(.copy)

        XCTAssertTrue(coordinator.performCalls.isEmpty, "菜单未弹出时点击不应分发")
    }

    /// §4.1 边界 5：连续点击多个菜单项依次调用 perform。
    func testMenuItemClick_consecutiveClicksCallPerformInOrder() {
        let (view, coordinator) = MacTerminalViewTestHarness.make(
            phase: .shell,
            selectedText: "hello",
            hasClipboardText: true,
            hitLink: "https://x"
        )
        view.simulateRightClick(at: NSPoint(x: 100, y: 100))

        view.simulateMenuItemClick(.copyLink)
        view.simulateMenuItemClick(.copy)
        view.simulateMenuItemClick(.pasteAndEnter)
        view.simulateMenuItemClick(.closeTab)

        XCTAssertEqual(coordinator.performCalls.count, 4)
        XCTAssertEqual(coordinator.performCalls[0].item, .copyLink)
        XCTAssertEqual(coordinator.performCalls[0].hitLink, "https://x")
        XCTAssertEqual(coordinator.performCalls[1].item, .copy)
        XCTAssertNil(coordinator.performCalls[1].hitLink)
        XCTAssertEqual(coordinator.performCalls[2].item, .pasteAndEnter)
        XCTAssertNil(coordinator.performCalls[2].hitLink)
        XCTAssertEqual(coordinator.performCalls[3].item, .closeTab)
        XCTAssertNil(coordinator.performCalls[3].hitLink)
    }
}

// MARK: - 测试辅助：暴露 lastMenuContext 供断言

extension PandaTerminalView {
    /// 测试辅助：暴露最近一次菜单构建使用的上下文，便于断言 isEnabled 矩阵。
    /// 通过 `menuContextOverride` 直接返回（测试中始终走 override 路径）。
    var lastMenuContext: TerminalMenuContext? {
        menuContextOverride
    }
}
#endif

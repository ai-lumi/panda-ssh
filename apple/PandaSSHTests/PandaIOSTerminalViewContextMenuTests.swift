import XCTest

#if os(iOS)
@testable import PandaSSH_iOS

/// iPad 终端视图右键菜单自动化测试。
///
/// 完整用例清单见
/// [openspec/changes/terminal-mouse-interaction/test-cases-ipad-context-menu.md]。
/// 覆盖 §A 触摸长按、§B 外接鼠标右键、§C 两条路径一致性、§D 菜单项点击分发、
/// §E 已知边界（中键无响应）五组共 29 个用例，
/// 满足 `AGENTS.md` 三类场景门禁（正常流程 / 意外操作 / 边界条件）。
@MainActor
final class PandaIOSTerminalViewContextMenuTests: XCTestCase {

    // MARK: - A 组：触摸长按触发菜单

    /// A.1（正常流程）长按手势识别成功后弹出菜单。
    func testA1_longPressTriggersMenu() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make()

        view.simulateLongPress(at: CGPoint(x: 100, y: 100))

        XCTAssertEqual(view.menuPresentCount, 1, "长按应弹出菜单一次")
        XCTAssertEqual(view.lastMenuAnchor, CGPoint(x: 100, y: 100), "anchor 应为长按位置")
        XCTAssertEqual(view.lastMenuItems, IOSTerminalViewTestHarness.defaultItemOrder, "无链接时条目集合为默认顺序")
        XCTAssertTrue(coordinator.performCalls.isEmpty, "未点击菜单项时 perform 不应被调用")
    }

    /// A.2（正常流程）连接失败阶段长按仍可弹菜单（仅「重连」「关闭标签页」可用）。
    func testA2_longPressInFailedPhaseShowsReconnectCloseEnabled() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(phase: .failed)

        view.simulateLongPress(at: CGPoint(x: 50, y: 50))

        XCTAssertEqual(view.menuPresentCount, 1, "failed 阶段长按仍应弹出菜单")
        XCTAssertEqual(view.lastMenuItems, IOSTerminalViewTestHarness.defaultItemOrder, "条目集合不变")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.reconnect, in: view.lastMenuContext!), "reconnect 在 failed 应启用")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.closeTab, in: view.lastMenuContext!), "closeTab 任何阶段都应启用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.paste, in: view.lastMenuContext!), "paste 在 failed 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.clearScreen, in: view.lastMenuContext!), "clearScreen 在 failed 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.resetTerminal, in: view.lastMenuContext!), "resetTerminal 在 failed 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.selectAll, in: view.lastMenuContext!), "selectAll 在 failed 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copyAndPaste, in: view.lastMenuContext!), "copyAndPaste 在 failed 应禁用")
        XCTAssertTrue(coordinator.performCalls.isEmpty)
    }

    /// A.3（意外操作）长按过程中手势被取消（系统手势冲突）。
    func testA3_longPressCancelledDoesNotShowMenu() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make()

        view.simulateLongPress(at: CGPoint(x: 100, y: 100), cancelled: true)

        XCTAssertEqual(view.menuPresentCount, 0, "手势取消不应弹菜单")
        XCTAssertNil(view.lastMenuAnchor)
        XCTAssertTrue(view.lastMenuItems.isEmpty)
        XCTAssertTrue(coordinator.performCalls.isEmpty)
    }

    /// A.4（意外操作）连接中阶段长按 → 仅「关闭标签页」启用。
    func testA4_longPressInConnectingPhaseDisablesAllExceptCloseTab() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(phase: .connecting)

        view.simulateLongPress(at: CGPoint(x: 100, y: 100))

        XCTAssertEqual(view.menuPresentCount, 1)
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.closeTab, in: view.lastMenuContext!), "closeTab 在 connecting 应启用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.reconnect, in: view.lastMenuContext!), "reconnect 仅在 failed 启用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.paste, in: view.lastMenuContext!))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copy, in: view.lastMenuContext!), "copy 在 connecting 应禁用")
        XCTAssertTrue(coordinator.performCalls.isEmpty)
    }

    /// A.5（边界条件）长按位置在视图边界外 → 不弹菜单，不抛异常。
    func testA5_longPressOutOfBoundsDoesNotShowMenu() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make()

        view.simulateLongPress(at: CGPoint(x: -10, y: -10))

        XCTAssertEqual(view.menuPresentCount, 0, "边界外不应弹菜单")
        XCTAssertTrue(coordinator.performCalls.isEmpty)
        // 测试不崩溃即通过（无异常抛出）
    }

    /// A.6（边界条件）长按位置在视图右下角边缘（含等号边界）。
    func testA6_longPressAtLowerRightEdgeShowsMenu() {
        let (view, _) = IOSTerminalViewTestHarness.make()

        view.simulateLongPress(at: CGPoint(x: 320, y: 240))

        XCTAssertEqual(view.menuPresentCount, 1, "边缘点（含等于）应弹菜单")
        XCTAssertEqual(view.lastMenuAnchor, CGPoint(x: 320, y: 240))
    }

    // MARK: - B 组：外接鼠标右键触发菜单

    /// B.1（正常流程）外接鼠标右键点击弹出菜单。
    func testB1_rightClickTriggersMenu() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make()

        view.simulateRightClick(at: CGPoint(x: 100, y: 100))

        XCTAssertEqual(view.menuPresentCount, 1)
        XCTAssertEqual(view.lastMenuAnchor, CGPoint(x: 100, y: 100))
        XCTAssertEqual(view.lastMenuItems, IOSTerminalViewTestHarness.defaultItemOrder, "右键与长按条目集合一致")
        XCTAssertTrue(coordinator.performCalls.isEmpty)
    }

    /// B.2（正常流程）连接失败阶段外接鼠标右键弹菜单。
    func testB2_rightClickInFailedPhaseMatchesLongPress() {
        let (view, _) = IOSTerminalViewTestHarness.make(phase: .failed)

        view.simulateRightClick(at: CGPoint(x: 50, y: 50))

        XCTAssertEqual(view.menuPresentCount, 1)
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.reconnect, in: view.lastMenuContext!))
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.closeTab, in: view.lastMenuContext!))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.paste, in: view.lastMenuContext!))
    }

    /// B.3（正常流程）Universal Control 从 Mac 转入鼠标右键 → 与 B.1 行为一致。
    /// iPad 端无法在单元测试中区分鼠标来源（蓝牙/USB/Universal Control），
    /// 三者都走同一 `simulateRightClick` 路径，本用例验证该路径不区分来源。
    func testB3_universalControlMouseRightClickMatchesBluetooth() {
        let (view, _) = IOSTerminalViewTestHarness.make()

        // 模拟 Universal Control 转入鼠标的右键事件（注入路径与 B.1 相同）
        view.simulateRightClick(at: CGPoint(x: 100, y: 100))

        XCTAssertEqual(view.menuPresentCount, 1, "Universal Control 鼠标右键应弹菜单")
        XCTAssertEqual(view.lastMenuItems, IOSTerminalViewTestHarness.defaultItemOrder, "条目集合应与蓝牙鼠标右键一致")
    }

    /// B.4（意外操作）右键位置在视图外 → 不弹菜单，不抛异常。
    func testB4_rightClickOutOfBoundsDoesNotShowMenu() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make()

        view.simulateRightClick(at: CGPoint(x: -10, y: -10))

        XCTAssertEqual(view.menuPresentCount, 0)
        XCTAssertTrue(coordinator.performCalls.isEmpty)
    }

    /// B.5（边界条件）右键位置在视图右下角边缘。
    func testB5_rightClickAtLowerRightEdgeShowsMenu() {
        let (view, _) = IOSTerminalViewTestHarness.make()

        view.simulateRightClick(at: CGPoint(x: 320, y: 240))

        XCTAssertEqual(view.menuPresentCount, 1)
        XCTAssertEqual(view.lastMenuAnchor, CGPoint(x: 320, y: 240))
    }

    /// B.6（边界条件）右键位置恰好在字符单元边界（col/row 整数倍）。
    /// 验证不崩溃、菜单正常弹出。本测试不依赖真实 `calculateMouseHit`（PandaIOSTerminalView
    /// 测试钩子直接用注入点作为 anchor，不计算 grid 坐标）。
    func testB6_rightClickAtCharCellBoundaryShowsMenu() {
        let (view, _) = IOSTerminalViewTestHarness.make()

        // 假设 cell 宽度 8pt：80 = 10 列、16 = 2 行（边界点）
        view.simulateRightClick(at: CGPoint(x: 80, y: 16))

        XCTAssertEqual(view.menuPresentCount, 1)
        XCTAssertEqual(view.lastMenuAnchor, CGPoint(x: 80, y: 16))
    }

    // MARK: - C 组：两条触发路径菜单一致性

    /// C.1（正常流程）长按与右键产生相同菜单条目集合。
    func testC1_longPressAndRightClickProduceSameItems() {
        // 用同一上下文分别构造两个 view（同一 phase/selection/clipboard/hitLink）
        let (longPressView, _) = IOSTerminalViewTestHarness.make()
        let (rightClickView, _) = IOSTerminalViewTestHarness.make()

        longPressView.simulateLongPress(at: CGPoint(x: 100, y: 100))
        rightClickView.simulateRightClick(at: CGPoint(x: 100, y: 100))

        XCTAssertEqual(longPressView.lastMenuItems, rightClickView.lastMenuItems, "两条路径条目集合应一致")
        // 进一步验证 isEnabled 矩阵一致：逐项比较
        for item in longPressView.lastMenuItems {
            let lpEnabled = TerminalContextMenuBuilder.isEnabled(item, in: longPressView.lastMenuContext!)
            let rcEnabled = TerminalContextMenuBuilder.isEnabled(item, in: rightClickView.lastMenuContext!)
            XCTAssertEqual(lpEnabled, rcEnabled, "item \(item) 在两条路径下启用态应一致")
        }
    }

    /// C.2（正常流程）链接命中时两条路径都出现链接条目。
    func testC2_linkHitShowsLinkItemsInBothPaths() {
        let (longPressView, _) = IOSTerminalViewTestHarness.make(hitLink: "https://example.com")
        let (rightClickView, _) = IOSTerminalViewTestHarness.make(hitLink: "https://example.com")

        longPressView.simulateLongPress(at: CGPoint(x: 100, y: 100))
        rightClickView.simulateRightClick(at: CGPoint(x: 100, y: 100))

        XCTAssertEqual(longPressView.lastMenuItems.prefix(2), [.copyLink, .openLink], "长按：链接条目应置于首位")
        XCTAssertEqual(rightClickView.lastMenuItems.prefix(2), [.copyLink, .openLink], "右键：链接条目应置于首位")
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.copyLink, in: longPressView.lastMenuContext!))
        XCTAssertTrue(TerminalContextMenuBuilder.isEnabled(.copyLink, in: rightClickView.lastMenuContext!))
    }

    /// C.3（意外操作）剪贴板无文本时两条路径都禁用粘贴类条目。
    func testC3_noClipboardTextDisablesPasteInBothPaths() {
        let (longPressView, _) = IOSTerminalViewTestHarness.make(hasClipboardText: false)
        let (rightClickView, _) = IOSTerminalViewTestHarness.make(hasClipboardText: false)

        longPressView.simulateLongPress(at: CGPoint(x: 100, y: 100))
        rightClickView.simulateRightClick(at: CGPoint(x: 100, y: 100))

        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.paste, in: longPressView.lastMenuContext!), "长按：无剪贴板时 paste 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.paste, in: rightClickView.lastMenuContext!), "右键：无剪贴板时 paste 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.pasteAndEnter, in: longPressView.lastMenuContext!))
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.pasteAndEnter, in: rightClickView.lastMenuContext!))
        // 其它条目启用态应一致
        XCTAssertEqual(
            longPressView.lastMenuItems.map { TerminalContextMenuBuilder.isEnabled($0, in: longPressView.lastMenuContext!) },
            rightClickView.lastMenuItems.map { TerminalContextMenuBuilder.isEnabled($0, in: rightClickView.lastMenuContext!) },
            "其它条目启用态应一致"
        )
    }

    /// C.4（边界条件）有选中但选中为空字符串（视同无选中）→ 两条路径都禁用 .copy/.copyAndPaste。
    func testC4_emptySelectedTextTreatedAsNoSelection() {
        let (longPressView, _) = IOSTerminalViewTestHarness.make(selectedText: "")
        let (rightClickView, _) = IOSTerminalViewTestHarness.make(selectedText: "")

        longPressView.simulateLongPress(at: CGPoint(x: 100, y: 100))
        rightClickView.simulateRightClick(at: CGPoint(x: 100, y: 100))

        XCTAssertFalse(longPressView.lastMenuContext!.hasSelection, "空字符串视同无选中")
        XCTAssertFalse(rightClickView.lastMenuContext!.hasSelection)
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copy, in: longPressView.lastMenuContext!), "长按：空选中时 copy 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copy, in: rightClickView.lastMenuContext!), "右键：空选中时 copy 应禁用")
        XCTAssertFalse(TerminalContextMenuBuilder.isEnabled(.copyAndPaste, in: longPressView.lastMenuContext!))
        XCTAssertEqual(longPressView.lastMenuItems, rightClickView.lastMenuItems, "两条路径条目集合应一致")
    }

    /// C.5（边界条件）连续触发：先长按取消、再右键触发 → 状态不互相干扰。
    func testC5_cancelledLongPressThenRightClickDoesNotInterfere() {
        let (view, _) = IOSTerminalViewTestHarness.make()

        // 第一次：长按被取消（不弹菜单）
        view.simulateLongPress(at: CGPoint(x: 50, y: 50), cancelled: true)
        XCTAssertEqual(view.menuPresentCount, 0, "取消的长按不应弹菜单")

        // 第二次：右键触发（应正常弹菜单）
        view.simulateRightClick(at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(view.menuPresentCount, 1, "右键应弹菜单")
        XCTAssertEqual(view.lastMenuAnchor, CGPoint(x: 100, y: 100), "anchor 应为右键位置，不被前一次长按影响")
    }

    // MARK: - D 组：菜单项点击执行动作（perform 调用分发）

    /// D.1（正常流程）点击「复制」调用 perform(.copy)。
    func testD1_clickCopyCallsPerformCopy() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(selectedText: "hello")
        view.simulateLongPress(at: CGPoint(x: 100, y: 100))

        view.simulateMenuItemClick(.copy)

        XCTAssertEqual(coordinator.performCalls.count, 1)
        XCTAssertEqual(coordinator.performCalls[0].item, .copy)
        XCTAssertNil(coordinator.performCalls[0].hitLink, "无链接时 hitLink 应为 nil")
    }

    /// D.2（正常流程）点击「粘贴并回车」调用 perform(.pasteAndEnter)。
    func testD2_clickPasteAndEnterCallsPerform() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(hasClipboardText: true)
        view.simulateRightClick(at: CGPoint(x: 100, y: 100))

        view.simulateMenuItemClick(.pasteAndEnter)

        XCTAssertEqual(coordinator.performCalls.count, 1)
        XCTAssertEqual(coordinator.performCalls[0].item, .pasteAndEnter)
        XCTAssertNil(coordinator.performCalls[0].hitLink)
    }

    /// D.3（正常流程）点击「重连」调用 perform(.reconnect) — failed 阶段。
    func testD3_clickReconnectCallsPerformInFailedPhase() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(phase: .failed)
        view.simulateLongPress(at: CGPoint(x: 100, y: 100))

        view.simulateMenuItemClick(.reconnect)

        XCTAssertEqual(coordinator.performCalls.count, 1)
        XCTAssertEqual(coordinator.performCalls[0].item, .reconnect)
        XCTAssertNil(coordinator.performCalls[0].hitLink)
    }

    /// D.4（正常流程）点击「关闭标签页」调用 perform(.closeTab)。
    func testD4_clickCloseTabCallsPerform() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(phase: .shell)
        view.simulateRightClick(at: CGPoint(x: 100, y: 100))

        view.simulateMenuItemClick(.closeTab)

        XCTAssertEqual(coordinator.performCalls.count, 1)
        XCTAssertEqual(coordinator.performCalls[0].item, .closeTab)
    }

    /// D.5（正常流程）点击「复制链接地址」携带 hitLink。
    func testD5_clickCopyLinkCarriesHitLink() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(hitLink: "https://example.com")
        view.simulateLongPress(at: CGPoint(x: 100, y: 100))

        view.simulateMenuItemClick(.copyLink)

        XCTAssertEqual(coordinator.performCalls.count, 1)
        XCTAssertEqual(coordinator.performCalls[0].item, .copyLink)
        XCTAssertEqual(coordinator.performCalls[0].hitLink, "https://example.com", "hitLink 应携带命中链接")
    }

    /// D.6（正常流程）点击「打开链接」调用 perform(.openLink, hitLink)。
    func testD6_clickOpenLinkCallsPerformWithHitLink() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(hitLink: "https://example.com")
        view.simulateLongPress(at: CGPoint(x: 100, y: 100))

        view.simulateMenuItemClick(.openLink)

        XCTAssertEqual(coordinator.performCalls.count, 1)
        XCTAssertEqual(coordinator.performCalls[0].item, .openLink)
        XCTAssertEqual(coordinator.performCalls[0].hitLink, "https://example.com")
    }

    /// D.7（意外操作）点击被禁用的菜单项不调用 perform。
    /// failed 阶段 .paste 被禁用，仍注入点击事件验证防御。
    func testD7_clickingDisabledItemDoesNotCallPerform() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(phase: .failed)
        view.simulateLongPress(at: CGPoint(x: 100, y: 100))

        // .paste 在 failed 阶段被禁用
        view.simulateMenuItemClick(.paste)

        XCTAssertTrue(coordinator.performCalls.isEmpty, "禁用项点击不应触发 perform")
    }

    /// D.8（意外操作）菜单未弹出时点击事件不触发 perform。
    func testD8_clickWithoutMenuDoesNotCallPerform() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make()
        // 不调用 simulateLongPress/simulateRightClick，菜单未弹出

        view.simulateMenuItemClick(.copy)

        XCTAssertTrue(coordinator.performCalls.isEmpty, "菜单未弹出时点击不应分发")
    }

    /// D.9（边界条件）连续点击多个菜单项依次调用 perform。
    func testD9_consecutiveClicksCallPerformInOrder() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(
            selectedText: "hello",
            hasClipboardText: true,
            hitLink: "https://x"
        )
        view.simulateLongPress(at: CGPoint(x: 100, y: 100))

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

    // MARK: - E 组：已知边界验证（外接鼠标中键不触发任何行为）

    /// E.1（正常流程）外接鼠标中键点击不调用 perform、不弹菜单。
    /// 验证 SwiftTerm iOS 不捕获中键（design.md「已知边界」），本提案未引入中键行为。
    func testE1_middleClickDoesNotTriggerAnything() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make()

        view.simulateMiddleClick(at: CGPoint(x: 100, y: 100))

        XCTAssertEqual(view.menuPresentCount, 0, "中键不应弹菜单")
        XCTAssertTrue(coordinator.performCalls.isEmpty, "中键不应调用 perform")
        XCTAssertNil(view.lastMenuAnchor, "中键不应更新 anchor")
        XCTAssertTrue(view.lastMenuItems.isEmpty, "中键不应更新条目集合")
    }

    /// E.2（意外操作）即使 menuContextOverride 预置了 selectedText（模拟有可粘贴内容），
    /// 中键点击也不消费。验证 iPad 端中键路径完全不读取任何上下文状态。
    func testE2_middleClickDoesNotConsumeEvenWithContextPreset() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make(selectedText: "hello")

        view.simulateMiddleClick(at: CGPoint(x: 50, y: 50))

        XCTAssertEqual(view.menuPresentCount, 0)
        XCTAssertTrue(coordinator.performCalls.isEmpty, "中键不应调用 perform 即使有可粘贴内容")
        // menuContextOverride 不应被中键修改
        XCTAssertEqual(view.menuContextOverride?.selectedText, "hello", "预置的 selectedText 不应被中键消费")
    }

    /// E.3（边界条件）外接鼠标中键在视图边界外不抛异常。
    func testE3_middleClickOutOfBoundsDoesNotCrash() {
        let (view, coordinator) = IOSTerminalViewTestHarness.make()

        view.simulateMiddleClick(at: CGPoint(x: -10, y: -10))

        // 测试不崩溃即通过
        XCTAssertEqual(view.menuPresentCount, 0)
        XCTAssertTrue(coordinator.performCalls.isEmpty)
    }
}

// MARK: - 测试辅助：暴露 lastMenuContext 供断言

extension PandaIOSTerminalView {
    /// 测试辅助：暴露最近一次菜单构建使用的上下文，便于断言 isEnabled 矩阵。
    /// 通过 `menuContextOverride` 直接返回（测试中始终走 override 路径）。
    var lastMenuContext: TerminalMenuContext? {
        menuContextOverride
    }
}
#endif

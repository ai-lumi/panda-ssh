#if os(macOS)
import AppKit
import SwiftTerm

/// macOS 终端视图回调协议：暴露 PRIMARY selection 相关回调给 `PandaTerminalView`。
/// `TerminalCoordinator` 实现；测试可注入 spy。
protocol PandaTerminalViewDelegate: AnyObject {
    /// 中键粘贴：把 PRIMARY 缓冲写入 shell 通道。
    func pastePrimarySelection()
    /// mouseUp 后更新 PRIMARY 缓冲（从 tv 读取选中文本）。
    func updatePrimarySelection(from tv: TerminalView)
}

/// macOS 终端视图：在 SwiftTerm `TerminalView` 上叠加中键粘贴、右键菜单、
/// mouseUp PRIMARY 缓冲联动（spec「终端中键粘贴选中文本」「终端选中即缓存 PRIMARY selection」）。
///
/// 设计要点（详见 [openspec/changes/terminal-mouse-interaction/design.md]）：
/// - `otherMouseDown`（buttonNumber=2）→ `pandaDelegate.pastePrimarySelection()`，
///   不调 super（SwiftTerm macOS 默认不处理 otherMouseDown）。
/// - `mouseUp` → 先调 super（保留既有选择行为），再调 `pandaDelegate.updatePrimarySelection(from:)`。
/// - `rightMouseDown` → 不调 super（避免系统默认菜单），调 `triggerContextMenu(at:)`
///   构建 `NSMenu` 并在视图内弹出。菜单条目由 `TerminalContextMenuBuilder` 生成，
///   点击通过 `@objc handleMenuItem(_:)` 转发到 `menuActionPerformer.perform(_:hitLink:)`。
/// - 测试钩子（`simulate*`）只复用既有事件处理路径，生产代码不调用。
class PandaTerminalView: TerminalView {
    /// SwiftUI opacity 不会移除 AppKit 光标区域，后台终端必须同步隐藏原生视图。
    func updatePresentationVisibility(_ visible: Bool) {
        guard isHidden == visible else { return }
        isHidden = !visible
        if !visible {
            discardCursorRects()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        window?.invalidateCursorRects(for: self)
    }

    /// PRIMARY selection 回调对象；生产中是 `TerminalCoordinator`，测试中可注入 spy。
    weak var pandaDelegate: (any PandaTerminalViewDelegate)?

    /// 菜单动作执行者：生产中是 `TerminalCoordinator`，测试中可注入 `SpyTerminalCoordinator`。
    /// `rightMouseDown` 构建的每个 `NSMenuItem` 的点击最终转发到此对象的 `perform(_:hitLink:)`。
    weak var menuActionPerformer: (any TerminalMenuActionPerformer)?

    // MARK: - 测试可见的统计（生产代码不读）

    private(set) var testDidCallSuperRightMouseDown = false
    private(set) var testDidCallSuperMouseUp = false
    private(set) var testDidCallSuperOtherMouseDown = false

    /// 累计菜单弹出次数（含 NSMenu 构建）。
    private(set) var menuPresentCount: Int = 0
    /// 最近一次菜单 anchor（右键命中位置，视图本地坐标）。
    private(set) var lastMenuAnchor: NSPoint?
    /// 最近一次菜单条目集合（按上下文构建，含禁用项）。
    private(set) var lastMenuItems: [TerminalMenuItem] = []
    /// 最近一次构建的 `NSMenu`（生产代码用于 popUp；测试通过此属性断言 NSMenuItem 结构）。
    private(set) var lastNSMenu: NSMenu?

    // MARK: - 测试 hook

    /// 注入菜单上下文，绕过真实 `selection` / 剪贴板 / `linkForClick` 读取。
    /// 测试中通过此属性控制 `phase` / `hasSelection` / `hasClipboardText` / `hitLink`。
    /// 生产代码留 nil，由 `currentMenuContext(at:)` 从真实 SwiftTerm 状态读取。
    var menuContextOverride: TerminalMenuContext?

    // MARK: - 重写鼠标事件

    override func otherMouseDown(with event: NSEvent) {
        handleOtherMouseDown(buttonNumber: event.buttonNumber, event: event)
    }

    /// 中键 / 其它按键分发逻辑（生产由 `otherMouseDown(with:)` 转调，测试由 `simulateOtherMouseDown` 转调）。
    /// - 中键（buttonNumber==2）：触发 PRIMARY 粘贴，不调 super。
    ///   SwiftTerm macOS 默认不重写 otherMouseDown（super 是 NSView 默认 no-op）；
    ///   鼠标模式转发不在本提案范围（SwiftTerm 默认也不处理）。
    /// - 其它按键：调 super（保留 SwiftTerm/NSView 默认行为）；event 为 nil 时仅记录标志
    ///   （测试钩子无法用公开 API 构造带指定 buttonNumber 的 NSEvent ——
    ///   `NSEvent` 无 `otherMouseEvent` 工厂，`mouseEvent` 不接受 buttonNumber，
    ///   故测试传入的 buttonNumber 与构造事件的 buttonNumber 解耦，分发以传入值为准）。
    internal func handleOtherMouseDown(buttonNumber: Int, event: NSEvent?) {
        if buttonNumber == 2 {
            pandaDelegate?.pastePrimarySelection()
            testDidCallSuperOtherMouseDown = false
        } else {
            if let event { super.otherMouseDown(with: event) }
            testDidCallSuperOtherMouseDown = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        // 先调 super：保留 SwiftTerm 既有选择行为（selection.active / drag / link 检测）。
        super.mouseUp(with: event)
        testDidCallSuperMouseUp = true
        // 再通知 coordinator 更新 PRIMARY 缓冲（spec「mouseUp 后若存在非空选中文本，
        // 自动写入终端 PRIMARY selection 缓冲」）。
        pandaDelegate?.updatePrimarySelection(from: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        // 不调 super：避免 NSResponder 默认菜单（无自定义菜单时右键无反应）。
        testDidCallSuperRightMouseDown = false
        // 把事件位置转到视图本地坐标，组装菜单上下文并构建 NSMenu。
        let point = convert(event.locationInWindow, from: nil)
        triggerContextMenu(at: point)
    }

    // MARK: - 右键菜单构建与分发

    /// 触发右键上下文菜单：边界检查 → 组装 `TerminalMenuContext` → 构建 `NSMenu` → 弹出。
    /// 测试通过 `simulateRightClick(at:)` 直接调用此方法，跳过 NSEvent 构造。
    private func triggerContextMenu(at point: NSPoint) {
        guard isPointInBounds(point) else { return }
        let ctx = currentMenuContext(at: point)
        let items = TerminalContextMenuBuilder.items(for: ctx)
        lastMenuItems = items
        menuPresentCount += 1
        lastMenuAnchor = point
        let menu = buildNSMenu(from: items, context: ctx)
        lastNSMenu = menu
        // 生产环境：在有 window 与 currentEvent 时弹出原生 NSMenu。
        // 测试环境（无 window）跳过弹出，仅保留 in-memory NSMenu 供断言。
        guard window != nil, let event = NSApp?.currentEvent else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// 根据 `TerminalMenuItem` 列表与上下文构建 `NSMenu`。
    /// 每个 `NSMenuItem` 的 `representedObject` 携带 `MenuPayload`（item + hitLink），
    /// 点击时由 `handleMenuItem(_:)` 解包转发到 `menuActionPerformer.perform`。
    private func buildNSMenu(from items: [TerminalMenuItem], context: TerminalMenuContext) -> NSMenu {
        let menu = NSMenu()
        for item in items {
            let menuItem = NSMenuItem(
                title: title(for: item),
                action: #selector(handleMenuItem(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.isEnabled = TerminalContextMenuBuilder.isEnabled(item, in: context)
            // 只有链接相关条目携带 hitLink，其余条目传 nil，避免非链接动作误带链接上下文。
            let payloadHitLink: String? = (item == .copyLink || item == .openLink) ? context.hitLink : nil
            menuItem.representedObject = MenuPayload(item: item, hitLink: payloadHitLink)
            menu.addItem(menuItem)
        }
        return menu
    }

    /// `NSMenuItem` 点击回调：解包 `representedObject` 的 `MenuPayload`，
    /// 转发到 `menuActionPerformer.perform(_:hitLink:)`。
    @objc internal func handleMenuItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload else { return }
        menuActionPerformer?.perform(payload.item, hitLink: payload.hitLink)
    }

    /// 覆盖 `NSUserInterfaceValidations.validateUserInterfaceItem(_:)`：
    /// 绕过 SwiftTerm 超类对自定义菜单项的验证。
    ///
    /// `NSMenu.popUpContextMenu` 弹出时，系统会对每个 `NSMenuItem` 调
    /// `validateUserInterfaceItem(_:)`。SwiftTerm 的 `TerminalView` 遵循
    /// `NSUserInterfaceValidations`，其默认实现可能对非 SwiftTerm 标准 selector
    /// （如我们自定义的 `handleMenuItem(_:)`）返回 `false`，
    /// 导致即使 `isEnabled=true` 的条目也被系统级禁用（表现为全灰）。
    ///
    /// 此处对携带 `MenuPayload` 的菜单项返回 `menuItem.isEnabled`（即我们在
    /// `buildNSMenu` 中基于 `TerminalContextMenuBuilder.isEnabled` 设置的值），
    /// 其余菜单项走 `super` 默认路径。
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let menuItem = item as? NSMenuItem, menuItem.representedObject is MenuPayload {
            return menuItem.isEnabled
        }
        return super.validateUserInterfaceItem(item)
    }

    /// `NSMenuItem.representedObject` 携带的载荷：封装条目类型与命中链接。
    /// 测试通过 `NSMenuItem.representedObject as? MenuPayload` 断言 NSMenu 结构。
    struct MenuPayload {
        let item: TerminalMenuItem
        let hitLink: String?
    }

    /// 菜单条目对应的中文标题。
    private func title(for item: TerminalMenuItem) -> String {
        switch item {
        case .copyLink: return "复制链接地址"
        case .openLink: return "打开链接"
        case .copy: return "复制"
        case .paste: return "粘贴"
        case .pasteAndEnter: return "粘贴并回车"
        case .selectAll: return "全选"
        case .clearScreen: return "清屏"
        case .resetTerminal: return "重置终端"
        case .copyAndPaste: return "复制并粘贴"
        case .reconnect: return "重连"
        case .closeTab: return "关闭标签页"
        }
    }

    /// 组装当前菜单上下文。测试中通过 `menuContextOverride` 注入；
    /// 生产中从真实 SwiftTerm `selection` / 剪贴板 / coordinator 读取。
    private func currentMenuContext(at point: NSPoint) -> TerminalMenuContext {
        if let override = menuContextOverride { return override }
        // 生产代码路径：从 SwiftTerm 真实状态读取。
        // - 选中文本：经 `TerminalCoordinator.readSelectedText` 读取
        //   （内部使用「瞬态 copy + 恢复剪贴板」模式，不永久污染用户剪贴板）。
        // - 链接检测（`calculateMouseHit` / `linkForClick`）依赖 SwiftTerm `internal` API，
        //   跨模块不可访问；生产路径暂不检测链接（`hitLink = nil`）。
        //   测试通过 `menuContextOverride` 注入 `hitLink` 覆盖菜单构建逻辑。
        //   已知边界：未来 SwiftTerm 暴露公共命中 / 链接 API 或自研补丁后补足。
        let phase = (menuActionPerformer as? TerminalCoordinator)?.currentPhase ?? .shell
        let selected = TerminalCoordinator.readSelectedText(from: self) ?? ""
        let hasClipboard = !(NSPasteboard.general.string(forType: .string)?.isEmpty ?? true)
        return TerminalMenuContext(
            phase: phase,
            selectedText: selected,
            hasClipboardText: hasClipboard,
            hitLink: nil
        )
    }

    /// 判断点是否在视图可见区域内（含等于边界）。
    private func isPointInBounds(_ point: NSPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x <= bounds.width && point.y <= bounds.height
    }

    // MARK: - 测试钩子（生产代码不调用）

    /// 测试钩子：模拟中键 / 其它按键按下事件，触发 `otherMouseDown` 逻辑。
    /// - Parameter buttonNumber: 鼠标按键编号（2=中键，0=左键，1=右键等）。
    internal func simulateOtherMouseDown(buttonNumber: Int) {
        // 用 `mouseEvent` 构造一个 .otherMouseDown 事件（供 else 分支 super 转发）；
        // 其 buttonNumber 与测试传入的解耦：分发以 `handleOtherMouseDown(buttonNumber:)` 传入值为准。
        // 若该类型在当前 SDK 下 mouseEvent 返回 nil，else 分支会跳过 super（无事件可转发），
        // 但仍置 `testDidCallSuperOtherMouseDown`，测试断言不受影响。
        let event = NSEvent.mouseEvent(
            with: .otherMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )
        handleOtherMouseDown(buttonNumber: buttonNumber, event: event)
    }

    /// 测试钩子：模拟左键 mouseUp 事件，触发 `mouseUp` 逻辑。
    internal func simulateMouseUp() {
        let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        mouseUp(with: event)
    }

    /// 测试钩子：模拟右键按下事件，触发 `rightMouseDown` 逻辑（固定位置 10,10）。
    /// 保留给 §3 既有测试使用；§4 菜单测试用 `simulateRightClick(at:)` 注入精确位置。
    internal func simulateRightMouseDown() {
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        rightMouseDown(with: event)
    }

    /// 测试钩子：模拟右键点击指定位置，触发 `triggerContextMenu` 完整路径
    /// （边界检查 → 构建上下文 → 构建 NSMenu → 跳过 popUp）。
    /// 生产代码不调用；真实右键事件由 `rightMouseDown(with:)` 驱动。
    internal func simulateRightClick(at point: NSPoint) {
        triggerContextMenu(at: point)
    }

    /// 测试钩子：模拟点击菜单项。
    /// 生产代码不调用；真实菜单点击由 `NSMenuItem` action 机制驱动 `handleMenuItem(_:)`。
    /// - 仅当菜单已弹出（`menuPresentCount > 0`）且条目在当前上下文下可用时，
    ///   通过 `handleMenuItem(_:)` 转发到 `menuActionPerformer.perform(_:hitLink:)`。
    /// - 通过 NSMenuItem action 机制调用 `handleMenuItem`，与生产路径一致，覆盖 NSMenu 构建链路。
    internal func simulateMenuItemClick(_ item: TerminalMenuItem) {
        guard menuPresentCount > 0 else { return }
        guard let menu = lastNSMenu else { return }
        guard let menuItem = menu.items.first(where: {
            ($0.representedObject as? MenuPayload)?.item == item
        }) else { return }
        let ctx = menuContextOverride ?? currentMenuContext(at: lastMenuAnchor ?? .zero)
        guard TerminalContextMenuBuilder.isEnabled(item, in: ctx) else { return }
        handleMenuItem(menuItem)
    }
}
#endif

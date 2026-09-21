// =============================================================================
// PandaTerminalView.swift
// =============================================================================
// 文件功能说明：
// 本文件实现了 macOS 平台的自定义终端视图 PandaTerminalView，继承自 SwiftTerm 的 TerminalView。
// 核心功能包括：
// 1. 中键粘贴 —— 按下鼠标中键将 PRIMARY selection 缓冲写入 shell 通道
// 2. 右键菜单 —— 构建并弹出 NSMenu，提供复制/粘贴/重连/关闭等操作
// 3. mouseUp PRIMARY 联动 —— 选中文本后自动缓存到 PRIMARY selection 缓冲
// 4. 测试钩子 —— 提供 simulate* 方法供单元测试模拟鼠标事件和菜单操作
//
// 整个文件用 #if os(macOS) 包裹，仅在 macOS 平台编译。
// =============================================================================

#if os(macOS)
// 条件编译：仅在 macOS 平台编译
import AppKit
// 导入 AppKit：提供 NSView、NSEvent、NSMenu、NSPasteboard 等 macOS 原生组件
import SwiftTerm
// 导入 SwiftTerm：第三方终端模拟器库，提供 TerminalView 基类

/// macOS 终端视图回调协议：暴露 PRIMARY selection 相关回调给 `PandaTerminalView`。
/// `TerminalCoordinator` 实现；测试可注入 spy。
///
/// PRIMARY selection 是 X11 风格的选择机制：选中文本自动复制到缓冲区，
/// 中键点击自动粘贴。这个协议让 TerminalView 可以通知 coordinator 执行这些操作。
protocol PandaTerminalViewDelegate: AnyObject {
    /// 中键粘贴：把 PRIMARY 缓冲写入 shell 通道。
    /// 当用户按下鼠标中键时调用，将之前选中的文本发送到远程 shell。
    func pastePrimarySelection()
    /// mouseUp 后更新 PRIMARY 缓冲（从 tv 读取选中文本）。
    /// 当用户松开鼠标左键（完成文本选择）时调用，将选中文本缓存到 PRIMARY 缓冲。
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
    // 继承自 SwiftTerm 的 TerminalView，获得完整的终端渲染和输入处理能力

    /// SwiftUI opacity 不会移除 AppKit 光标区域，后台终端必须同步隐藏原生视图。
    /// 当标签页不在前台时，需要隐藏这个 AppKit 视图，否则它会继续占据光标区域。
    /// - Parameter visible: 是否可见（true=前台显示，false=后台隐藏）
    func updatePresentationVisibility(_ visible: Bool) {
        guard isHidden == visible else { return }
        // 如果当前隐藏状态已经和目标一致，不需要操作，直接返回
        isHidden = !visible
        // 设置 AppKit 视图的隐藏/显示状态（visible=true 时 isHidden=false）
        if !visible {
            // 如果要隐藏视图
            discardCursorRects()
            // 丢弃所有光标矩形（终端中不同区域可能显示不同光标形状，如 I 型或箭头）
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            // 如果当前视图是第一响应者（正在接收键盘输入），取消第一响应者状态
            // 这样键盘输入就不会发送到隐藏的终端
        }
        window?.invalidateCursorRects(for: self)
        // 通知窗口重新计算光标区域，确保光标显示正确
    }

    /// PRIMARY selection 回调对象；生产中是 `TerminalCoordinator`，测试中可注入 spy。
    /// weak 弱引用，避免循环引用
    weak var pandaDelegate: (any PandaTerminalViewDelegate)?

    /// 菜单动作执行者：生产中是 `TerminalCoordinator`，测试中可注入 `SpyTerminalCoordinator`。
    /// `rightMouseDown` 构建的每个 `NSMenuItem` 的点击最终转发到此对象的 `perform(_:hitLink:)`。
    /// weak 弱引用，避免循环引用
    weak var menuActionPerformer: (any TerminalMenuActionPerformer)?

    // MARK: - 测试可见的统计（生产代码不读）
    // 以下属性仅供单元测试断言使用，生产代码不会读取它们

    /// 测试标记：rightMouseDown 是否调用了 super
    private(set) var testDidCallSuperRightMouseDown = false
    /// 测试标记：mouseUp 是否调用了 super
    private(set) var testDidCallSuperMouseUp = false
    /// 测试标记：otherMouseDown 是否调用了 super
    private(set) var testDidCallSuperOtherMouseDown = false

    /// 累计菜单弹出次数（含 NSMenu 构建）。
    /// 每次右键菜单弹出时加 1，测试可以断言这个值来验证菜单是否被正确触发。
    private(set) var menuPresentCount: Int = 0
    /// 最近一次菜单 anchor（右键命中位置，视图本地坐标）。
    /// 记录右键点击在视图中的坐标位置。
    private(set) var lastMenuAnchor: NSPoint?
    /// 最近一次菜单条目集合（按上下文构建，含禁用项）。
    /// 记录最近一次构建的菜单包含哪些条目（如复制、粘贴、重连等）。
    private(set) var lastMenuItems: [TerminalMenuItem] = []
    /// 最近一次构建的 `NSMenu`（生产代码用于 popUp；测试通过此属性断言 NSMenuItem 结构）。
    private(set) var lastNSMenu: NSMenu?

    // MARK: - 测试 hook

    /// 注入菜单上下文，绕过真实 `selection` / 剪贴板 / `linkForClick` 读取。
    /// 测试中通过此属性控制 `phase` / `hasSelection` / `hasClipboardText` / `hitLink`。
    /// 生产代码留 nil，由 `currentMenuContext(at:)` 从真实 SwiftTerm 状态读取。
    /// 设置这个属性后，构建菜单时会使用注入的上下文而非真实状态。
    var menuContextOverride: TerminalMenuContext?

    // MARK: - 重写鼠标事件

    /// 重写 otherMouseDown 方法：处理鼠标中键和其他非标准按键。
    /// 当用户按下鼠标中键（滚轮按下）或其他按键时，系统会调用此方法。
    override func otherMouseDown(with event: NSEvent) {
        handleOtherMouseDown(buttonNumber: event.buttonNumber, event: event)
        // 转发到内部处理方法，传入按键编号和事件对象
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
            // buttonNumber == 2 表示鼠标中键（滚轮按键）
            pandaDelegate?.pastePrimarySelection()
            // 调用 delegate 的粘贴方法：将 PRIMARY selection 缓冲中的文本发送到远程 shell
            testDidCallSuperOtherMouseDown = false
            // 记录：没有调用 super（因为中键粘贴是我们自定义的行为）
        } else {
            // 非中键的其他按键
            if let event { super.otherMouseDown(with: event) }
            // 如果有事件对象，调用 super 让 SwiftTerm/NSView 处理默认行为
            testDidCallSuperOtherMouseDown = true
            // 记录：调用了 super
        }
    }

    /// 重写 mouseUp 方法：鼠标左键松开时调用。
    /// 先调 super 保留 SwiftTerm 的文本选择行为，再通知 coordinator 更新 PRIMARY 缓冲。
    override func mouseUp(with event: NSEvent) {
        // 先调 super：保留 SwiftTerm 既有选择行为（selection.active / drag / link 检测）。
        super.mouseUp(with: event)
        // super.mouseUp 会完成文本选择的最终确认（如确定选择范围、高亮显示等）
        testDidCallSuperMouseUp = true
        // 记录：调用了 super（测试可断言此标记）
        // 再通知 coordinator 更新 PRIMARY 缓冲（spec「mouseUp 后若存在非空选中文本，
        // 自动写入终端 PRIMARY selection 缓冲」）。
        pandaDelegate?.updatePrimarySelection(from: self)
        // 将当前选中的文本读取并缓存到 PRIMARY selection 缓冲区
        // 这样用户之后可以用中键粘贴这段文本
    }

    /// 重写 rightMouseDown 方法：鼠标右键按下时调用。
    /// 不调 super 以避免系统默认菜单，改为构建自定义右键菜单。
    override func rightMouseDown(with event: NSEvent) {
        // 不调 super：避免 NSResponder 默认菜单（无自定义菜单时右键无反应）。
        testDidCallSuperRightMouseDown = false
        // 记录：没有调用 super
        // 把事件位置转到视图本地坐标，组装菜单上下文并构建 NSMenu。
        let point = convert(event.locationInWindow, from: nil)
        // event.locationInWindow 是鼠标在窗口中的坐标
        // convert(from: nil) 将窗口坐标转换为视图本地坐标（以视图左下角为原点）
        triggerContextMenu(at: point)
        // 用转换后的坐标触发右键菜单构建和弹出
    }

    // MARK: - 右键菜单构建与分发

    /// 触发右键上下文菜单：边界检查 → 组装 `TerminalMenuContext` → 构建 `NSMenu` → 弹出。
    /// 测试通过 `simulateRightClick(at:)` 直接调用此方法，跳过 NSEvent 构造。
    /// - Parameter point: 右键点击位置（视图本地坐标系）
    private func triggerContextMenu(at point: NSPoint) {
        guard isPointInBounds(point) else { return }
        // 边界检查：如果点击位置不在视图范围内，不弹出菜单
        let ctx = currentMenuContext(at: point)
        // 组装菜单上下文：包含当前终端阶段、选中文本、剪贴板状态、命中链接等信息
        let items = TerminalContextMenuBuilder.items(for: ctx)
        // 根据上下文生成菜单条目列表（如复制、粘贴、重连等，部分条目可能根据上下文被禁用）
        lastMenuItems = items
        // 记录菜单条目（供测试断言）
        menuPresentCount += 1
        // 菜单弹出计数加 1
        lastMenuAnchor = point
        // 记录菜单弹出位置
        let menu = buildNSMenu(from: items, context: ctx)
        // 将菜单条目列表转换为 macOS 原生 NSMenu 对象
        lastNSMenu = menu
        // 记录构建的 NSMenu（供测试断言）
        // 生产环境：在有 window 与 currentEvent 时弹出原生 NSMenu。
        // 测试环境（无 window）跳过弹出，仅保留 in-memory NSMenu 供断言。
        guard window != nil, let event = NSApp?.currentEvent else { return }
        // 如果没有窗口（测试环境）或没有当前事件，跳过弹出
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        // 在视图内弹出原生右键菜单
        // menu: 要弹出的菜单对象
        // event: 触发弹出的事件
        // self: 菜单关联的视图
    }

    /// 根据 `TerminalMenuItem` 列表与上下文构建 `NSMenu`。
    /// 每个 `NSMenuItem` 的 `representedObject` 携带 `MenuPayload`（item + hitLink），
    /// 点击时由 `handleMenuItem(_:)` 解包转发到 `menuActionPerformer.perform`。
    /// - Parameters:
    ///   - items: 菜单条目列表（如 .copy, .paste, .reconnect 等）
    ///   - context: 当前菜单上下文（包含选中文本、剪贴板状态等）
    /// - Returns: 构建好的 NSMenu 对象
    private func buildNSMenu(from items: [TerminalMenuItem], context: TerminalMenuContext) -> NSMenu {
        let menu = NSMenu()
        // 创建空的 NSMenu
        for item in items {
            // 遍历每个菜单条目
            let menuItem = NSMenuItem(
                title: title(for: item),
                // 设置菜单项的中文标题（如"复制"、"粘贴"等）
                action: #selector(handleMenuItem(_:)),
                // 点击后调用 handleMenuItem: 方法
                keyEquivalent: ""
                // 无快捷键
            )
            menuItem.target = self
            // 设置 action 的目标为 self（即本视图对象）
            menuItem.isEnabled = TerminalContextMenuBuilder.isEnabled(item, in: context)
            // 根据上下文决定菜单项是否可用（灰色/可点击）
            // 例如：没有选中文本时"复制"会被禁用
            // 只有链接相关条目携带 hitLink，其余条目传 nil，避免非链接动作误带链接上下文。
            let payloadHitLink: String? = (item == .copyLink || item == .openLink) ? context.hitLink : nil
            // 如果是"复制链接"或"打开链接"条目，携带命中的链接 URL
            // 其他条目不需要链接信息，传 nil
            menuItem.representedObject = MenuPayload(item: item, hitLink: payloadHitLink)
            // 将载荷绑定到菜单项，点击时可以取回条目类型和链接信息
            menu.addItem(menuItem)
            // 将菜单项添加到菜单中
        }
        return menu
        // 返回构建完成的菜单
    }

    /// `NSMenuItem` 点击回调：解包 `representedObject` 的 `MenuPayload`，
    /// 转发到 `menuActionPerformer.perform(_:hitLink:)`。
    /// 当用户点击右键菜单中的某个条目时，系统调用此方法。
    /// @objc 使方法可以被 Objective-C runtime 发现（NSMenu action 机制需要）。
    @objc internal func handleMenuItem(_ sender: NSMenuItem) {
        // sender 是被点击的 NSMenuItem
        guard let payload = sender.representedObject as? MenuPayload else { return }
        // 从菜单项中取出载荷（包含条目类型和链接信息）
        menuActionPerformer?.perform(payload.item, hitLink: payload.hitLink)
        // 将操作转发给 menuActionPerformer 执行
        // 例如：.copy -> 复制选中文本，.reconnect -> 重新连接 SSH
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
    ///
    /// 简单来说：SwiftTerm 父类可能会错误地禁用我们的自定义菜单项，
    /// 这里通过重写验证方法来修复这个问题。
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let menuItem = item as? NSMenuItem, menuItem.representedObject is MenuPayload {
            // 如果是我们的自定义菜单项（携带了 MenuPayload）
            return menuItem.isEnabled
            // 直接返回我们在 buildNSMenu 中设置的 enabled 状态
        }
        return super.validateUserInterfaceItem(item)
        // 其他菜单项走父类的默认验证逻辑
    }

    /// `NSMenuItem.representedObject` 携带的载荷：封装条目类型与命中链接。
    /// 测试通过 `NSMenuItem.representedObject as? MenuPayload` 断言 NSMenu 结构。
    struct MenuPayload {
        /// 菜单条目类型（如 .copy, .paste, .reconnect 等）
        let item: TerminalMenuItem
        /// 命中的链接 URL（仅链接相关条目有值，其他为 nil）
        let hitLink: String?
    }

    /// 菜单条目对应的中文标题。
    /// 将枚举值映射为用户可见的中文文本。
    /// - Parameter item: 菜单条目枚举值
    /// - Returns: 对应的中文字符串
    private func title(for item: TerminalMenuItem) -> String {
        switch item {
        case .copyLink: return "复制链接地址"
        // 复制终端中检测到的超链接地址
        case .openLink: return "打开链接"
        // 在浏览器中打开终端中的超链接
        case .copy: return "复制"
        // 复制选中的文本
        case .paste: return "粘贴"
        // 粘贴剪贴板内容到终端
        case .pasteAndEnter: return "粘贴并回车"
        // 粘贴剪贴板内容并自动按回车执行
        case .selectAll: return "全选"
        // 选中终端中的所有文本
        case .clearScreen: return "清屏"
        // 清除终端屏幕内容
        case .resetTerminal: return "重置终端"
        // 重置终端状态（恢复默认设置）
        case .copyAndPaste: return "复制并粘贴"
        // 复制选中文本并粘贴（用于快速复制一行并执行）
        case .reconnect: return "重连"
        // 重新建立 SSH 连接
        case .closeTab: return "关闭标签页"
        // 关闭当前终端标签
        }
    }

    /// 组装当前菜单上下文。测试中通过 `menuContextOverride` 注入；
    /// 生产中从真实 SwiftTerm `selection` / 剪贴板 / coordinator 读取。
    /// - Parameter point: 右键点击位置（用于链接命中检测，当前未实现）
    /// - Returns: 菜单上下文，包含终端阶段、选中文本、剪贴板状态、链接信息
    private func currentMenuContext(at point: NSPoint) -> TerminalMenuContext {
        if let override = menuContextOverride { return override }
        // 如果测试注入了上下文覆盖值，直接使用它
        // 生产代码路径：从 SwiftTerm 真实状态读取。
        // - 选中文本：经 `TerminalCoordinator.readSelectedText` 读取
        //   （内部使用「瞬态 copy + 恢复剪贴板」模式，不永久污染用户剪贴板）。
        // - 链接检测（`calculateMouseHit` / `linkForClick`）依赖 SwiftTerm `internal` API，
        //   跨模块不可访问；生产路径暂不检测链接（`hitLink = nil`）。
        //   测试通过 `menuContextOverride` 注入 `hitLink` 覆盖菜单构建逻辑。
        //   已知边界：未来 SwiftTerm 暴露公共命中 / 链接 API 或自研补丁后补足。
        let phase = (menuActionPerformer as? TerminalCoordinator)?.currentPhase ?? .shell
        // 获取当前终端阶段（shell 或 sftp 等），如果无法获取则默认为 .shell
        let selected = TerminalCoordinator.readSelectedText(from: self) ?? ""
        // 读取当前终端中选中的文本（如果没有选中则为空字符串）
        let hasClipboard = !(NSPasteboard.general.string(forType: .string)?.isEmpty ?? true)
        // 检查系统剪贴板是否有文本内容
        // NSPasteboard.general 是系统全局剪贴板
        // .string 类型表示纯文本
        return TerminalMenuContext(
            phase: phase,
            // 终端当前阶段
            selectedText: selected,
            // 选中的文本
            hasClipboardText: hasClipboard,
            // 剪贴板是否有内容
            hitLink: nil
            // 命中的链接（当前生产代码暂不检测，固定为 nil）
        )
    }

    /// 判断点是否在视图可见区域内（含等于边界）。
    /// 用于右键菜单的边界检查，确保只在视图范围内弹出菜单。
    /// - Parameter point: 要检查的坐标点（视图本地坐标系）
    /// - Returns: true 表示点在视图范围内
    private func isPointInBounds(_ point: NSPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x <= bounds.width && point.y <= bounds.height
        // 检查 x 和 y 是否都在 [0, 宽度] 和 [0, 高度] 范围内
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
            // 使用 NSEvent 的工厂方法构造一个鼠标事件
            with: .otherMouseDown,
            // 事件类型：其他鼠标按键按下
            location: NSPoint(x: 10, y: 10),
            // 鼠标位置固定在 (10, 10)
            modifierFlags: [],
            // 无修饰键（没有按 Cmd/Ctrl/Shift/Option）
            timestamp: 0,
            // 时间戳为 0（测试用，不影响逻辑）
            windowNumber: 0,
            // 窗口编号为 0
            context: nil,
            // 无图形上下文
            eventNumber: 0,
            // 事件编号为 0
            clickCount: 1,
            // 点击次数为 1（单击）
            pressure: 1.0
            // 压力为 1.0（标准按压力度）
        )
        handleOtherMouseDown(buttonNumber: buttonNumber, event: event)
        // 将构造的事件转发到内部处理方法
    }

    /// 测试钩子：模拟右键点击指定位置，触发 `triggerContextMenu` 完整路径
    /// （边界检查 → 构建上下文 → 构建 NSMenu → 跳过 popUp）。
    /// 生产代码不调用；真实右键事件由 `rightMouseDown(with:)` 驱动。
    /// - Parameter point: 模拟的右键点击位置
    internal func simulateRightClick(at point: NSPoint) {
        triggerContextMenu(at: point)
        // 直接调用内部方法，跳过 NSEvent 构造
    }

    /// 测试钩子：模拟点击菜单项。
    /// 生产代码不调用；真实菜单点击由 `NSMenuItem` action 机制驱动 `handleMenuItem(_:)`。
    /// - 仅当菜单已弹出（`menuPresentCount > 0`）且条目在当前上下文下可用时，
    ///   通过 `handleMenuItem(_:)` 转发到 `menuActionPerformer.perform(_:hitLink:)`。
    /// - 通过 NSMenuItem action 机制调用 `handleMenuItem`，与生产路径一致，覆盖 NSMenu 构建链路。
    /// - Parameter item: 要模拟点击的菜单条目
    internal func simulateMenuItemClick(_ item: TerminalMenuItem) {
        guard menuPresentCount > 0 else { return }
        // 菜单必须已经弹出过，否则不处理
        guard let menu = lastNSMenu else { return }
        // 必须有已构建的 NSMenu 对象
        guard let menuItem = menu.items.first(where: {
            ($0.representedObject as? MenuPayload)?.item == item
        }) else { return }
        // 在菜单的所有条目中找到匹配的那个
        let ctx = menuContextOverride ?? currentMenuContext(at: lastMenuAnchor ?? .zero)
        // 获取菜单上下文（优先使用测试注入的，否则从真实状态读取）
        guard TerminalContextMenuBuilder.isEnabled(item, in: ctx) else { return }
        // 检查该条目在当前上下文下是否可用（未禁用）
        handleMenuItem(menuItem)
        // 调用真实的菜单项处理方法，与生产路径一致
    }
}
#endif
// 结束 macOS 条件编译块

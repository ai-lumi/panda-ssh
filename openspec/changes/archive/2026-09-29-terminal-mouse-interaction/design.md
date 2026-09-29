## Context

当前 `apple/PandaSSH/Workspace/TerminalTabView.swift` 中 `MacTerminalRepresentable` / `IOSTerminalRepresentable` 直接实例化 SwiftTerm 的 `TerminalView`，并把 `terminalDelegate` 指向 `TerminalCoordinator`。SwiftTerm 的 `MacTerminalView`（即 macOS 上的 `TerminalView`）已经实现了 `mouseDown` / `mouseUp` / `mouseDragged` 处理左键选择，但**未重写** `rightMouseDown` 与 `otherMouseDown`，因此右键无任何自定义菜单、中键无任何操作。SwiftTerm 已暴露的公共能力包括 `paste(_:)` / `copy(_:)` / `selectAll(_:)` / `insertText(_:replacementRange:isPaste:)` / `selection.getSelectedText()` / `clearTerminal()` / `softReset()` / `hardReset()` 等，本设计完全复用这些 API，不引入 SwiftTerm 私有 hack。

约束（来自 `AGENTS.md`）：
- 业务逻辑（写入 SSH 通道、清屏 / 重置序列生成）只能落在 `crates/panda-core`，Swift 侧经 FFI 调用。但本提案涉及的「写入 shell 通道」「发送 `clear` 命令」「发送 ESC c 序列」都走**既有** `ShellConnection.write` / `TerminalViewDelegate.send`，不新增业务规则，不新增 FFI 导出，符合分层边界。
- 平台差异只能用 `#if os()` 收敛在视图层，且仅限 UI / 平台服务差异。
- 强制 TDD：Swift 可测逻辑用 XCTest；纯 UI 布局不强制测试，但菜单条目可用性规则属可测逻辑，必须覆盖。

## Goals / Non-Goals

**Goals:**

- 在不修改 SwiftTerm 源码、不 fork 的前提下，通过子类化 + delegate 扩展实现中键粘贴与右键菜单。
- 菜单条目可用性规则 100% 可单测（不依赖真实 NSWindow / 真实 SSH）。
- macOS 与 iPadOS 共享菜单条目定义与可用性规则，差异只落在「触发方式」与「平台特定 NSMenu / UIEditMenu 实现」。
- PRIMARY selection 缓冲与系统剪贴板完全隔离，不污染 `NSPasteboard.general`。

**Non-Goals:**

- 不实现跨应用 PRIMARY selection（X11 bridge）、不与系统其它应用共享 PRIMARY。
- 不改造 SwiftTerm `allowMouseReporting` / 鼠标模式协议转发（远端应用鼠标事件转发行为不变）。
- 不引入用户可配置菜单项 / 自定义按键绑定（后续提案）。
- 不实现标签页右键菜单（已在 `ui-workspace-optimization` 规范化，本提案不重叠）。
- 不修改任何 FFI 导出函数与 `crates/panda-core` 业务逻辑。

## Decisions

### Decision 1：子类化 `TerminalView` 而非在 Representable 外包事件监听

**选择**：macOS 端新增 `PandaTerminalView: TerminalView`（即 `MacTerminalView` 子类），重写 `rightMouseDown(with:)` / `otherMouseDown(with:)` / `mouseUp(with:)`；iOS 端新增 `PandaIOSTerminalView: TerminalView`（即 `iOS TerminalView` 子类），挂载长按手势与 `UIEditMenuInteraction`。

**理由**：

- SwiftTerm 的事件链由 `MacTerminalView` 自己消费 `mouseDown` / `mouseUp`，外包 `NSEvent` 监听无法可靠拿到选中文本与命中位置（要复用 `selection.getSelectedText()` / `calculateMouseHit(with:)` / `linkForClick(at:hasCommandModifier:)`，这些是 `MacTerminalView` 的方法）。
- 子类化后可以通过 `super.mouseUp(with:)` 复用既有左键选择逻辑，再叠加 PRIMARY 缓存更新，避免重复实现选择算法。
- 子类化不破坏 SwiftTerm 公共 API 契约，未来 SwiftTerm 升级只需回归测试即可。

**备选方案**：在 `MacTerminalRepresentable` 外层套一个透明 `NSView` 接收鼠标事件 → 无法拿到 SwiftTerm 内部 `selection` / `calculateMouseHit`，需要重写选择算法，违反「不重复实现业务逻辑」原则，否决。

### Decision 2：PRIMARY selection 缓冲放在 `TerminalCoordinator`

**选择**：`TerminalCoordinator` 新增 `private var primarySelection: String = ""` 与 `func updatePrimarySelection()` / `func pastePrimarySelection()` 方法。`PandaTerminalView.mouseUp` 在调用 `super.mouseUp` 后调用 `coordinator.updatePrimarySelection()`，`otherMouseDown` 调用 `coordinator.pastePrimarySelection()`。

**理由**：

- `TerminalCoordinator` 已是 `TerminalViewDelegate` 实现，承担「用户输入 → SSH 通道」的桥接职责，PRIMARY 缓冲与 paste 流自然归属此处。
- 不引入新的全局单例 / 共享状态，会话关闭（`detach()`）时缓冲随 coordinator 释放，无生命周期泄漏。
- `pastePrimarySelection()` 内部走 `connection?.write(Data(primarySelection.utf8))`，与既有 `send(source:data:)` 同一条路径，不新增写入通道。

**备选方案**：用 `NSPasteboard(name: .findPboard)` 当 PRIMARY 缓冲 → `.findPboard` 语义不符（它是 Find 数据），且会被系统 Find 功能污染。用独立自定义 `NSPasteboard(name: "PandaPrimarySelection")` → 可行但增加跨进程序列化开销，且 iPad 上 `UIPasteboard` 不支持自定义 named pasteboard。统一用 `TerminalCoordinator` 内存属性最简。

### Decision 3：菜单条目可用性规则集中在 `TerminalContextMenuBuilder`

**选择**：新增 `apple/PandaSSH/Workspace/TerminalContextMenu.swift`，定义纯值类型 `TerminalMenuContext`（包含 `phase: TerminalSessionStore.Phase` / `hasSelection: Bool` / `hasClipboardText: Bool` / `hitLink: String?`）与 `TerminalContextMenuBuilder`：

```swift
enum TerminalMenuItem: Equatable {
    case copyLink, openLink              // 仅当 hitLink != nil
    case copy, paste, pasteAndEnter      // 复制 / 粘贴 / 粘贴并回车
    case selectAll, clearScreen, resetTerminal
    case copyAndPaste
    case reconnect, closeTab
}

struct TerminalContextMenuBuilder {
    static func items(for ctx: TerminalMenuContext) -> [TerminalMenuItem]
    static func isEnabled(_ item: TerminalMenuItem, in ctx: TerminalMenuContext) -> Bool
}
```

**理由**：

- 可用性规则（无选中时禁用「复制」、failed 阶段禁用「粘贴」等）是纯函数，无 UI 依赖，XCTest 可全覆盖（正常 / 边界 / 异常三类场景）。
- macOS `NSMenu` 与 iPadOS `UIEditMenu` 都从同一个 `[TerminalMenuItem]` 列表构建，差异只落在条目渲染（`NSMenuItem` vs `UIEditMenuAction`）。
- 业务逻辑分支为零，符合分层边界：`Builder` 只产出条目与启用态，不调用任何 FFI / 业务方法；实际执行由 `TerminalCoordinator` 接收 `TerminalMenuItem` 后分发到 `tv.copy` / `tv.paste` / `connection.write` 等。

**备选方案**：在 `PandaTerminalView.rightMouseDown` 内联构建 `NSMenu` → 可用性规则不可单测，且 macOS / iOS 重复，否决。

### Decision 4：清屏 / 重置终端的「字节流生成」位置

**选择**：

- 「清屏」菜单项执行时：`TerminalCoordinator` 调用 `connection?.write(Data("clear\n".utf8))`，让远端 shell 自己执行 `clear` 命令清屏。这复用既有写入路径，不在客户端改 buffer。
- 「重置终端」菜单项执行时：先调用 `tv.softReset()` 或 `tv.hardReset()`（SwiftTerm 公共 API）清空本地滚动缓冲，再调用 `connection?.write(Data("\u{1B}c".utf8))` 发送 RIS 控制序列到远端。

**理由**：

- 「清屏」是 shell 层语义（用户期望类似 `clear` 命令），由远端 shell 解释最稳妥；客户端只负责发字节。
- 「重置终端」是终端模拟器语义（清空滚动历史 + 重置终端状态 + 发 RIS 通知远端），SwiftTerm 已有 `softReset`/`hardReset` 公共方法，直接复用。
- 不在 `crates/panda-core` 新增「终端清屏」「终端重置」业务函数：这些不是业务规则，只是 UI 触发的字节流写入，走既有 `ShellConnection.write` 即可。Rust 侧无新增导出。

**备选方案**：在 `panda-core` 加 `ShellSession::clear_screen()` / `reset_terminal()` 方法 → 引入只对终端模拟器有意义的「业务」函数，违反「`panda-core` 只承载跨平台业务规则」原则，且 Linux GTK4 端将来自己有终端模拟器，不需要 Rust 侧帮忙，否决。

### Decision 5：右键菜单「关闭标签页」复用既有门控

**选择**：「关闭标签页」菜单项执行时调用 `workspace.close(tabID: tab.id)`，复用 `ui-workspace-optimization` 已规范化的「SSH 终端标签页关闭二次确认」流程。

**理由**：避免重复实现关闭确认逻辑，确保右键关闭与标签栏 × 按钮关闭行为一致；如果将来二次确认逻辑变更，只需改一处。

**备选方案**：在右键菜单内嵌独立的二次确认对话框 → 行为分裂、维护成本高，否决。

### Decision 6：右键菜单「重连」复用 `TerminalSessionStore.retry()`

**选择**：「重连」菜单项调用 `session.retry()`，复用既有重连参数与状态机；`WorkspaceStore` 暴露 `reconnectTerminal(tabID:)` 转发到对应 `TerminalSessionStore`。

**理由**：`TerminalSessionStore.retry()` 已实现「保留上次连接参数 → 回到 connecting → 触发视图 `task(id:)` 重连」，无需新增逻辑。

### Decision 7：iPadOS 触摸长按与外接鼠标右键都触发 `UIEditMenuInteraction`

**选择**：iPadOS 端 `PandaIOSTerminalView` 同时挂载两条触发路径：
1. `UILongPressGestureRecognizer` —— 触摸用户长按 0.5s 弹菜单。
2. 重写 `UIPointerInteraction` 的 `pointerInteraction(_:interaction:styleFor:)`（iPadOS 13.4+）或在 `singleTap`/`pressesBegan` 中识别 `UIPress.type == .button` 的辅助按键（右键）事件——把鼠标右键也导向 `UIEditMenuInteraction.presentMenu(at:)`。

菜单条目通过 `TerminalContextMenuBuilder` 生成，回调走同一 `TerminalCoordinator.perform(_:)` 接口，与 macOS 完全共享。

**理由**：
- iPadOS 13.4+ 完整支持外接蓝牙/USB 鼠标与 Universal Control，外接鼠标右键事件按系统约定应该弹 contextual menu，与触摸长按语义等价；只用长按会让外接鼠标用户在终端里右键无反应，体验割裂。
- `UIEditMenuInteraction`（iOS 16+）是系统原生编辑菜单 API，两条触发路径都走它，保证菜单外观与系统一致，避免维护两套菜单 UI。
- 共享 `TerminalContextMenuBuilder` + `perform(_:)` 后，iPad 端只有「触发手势识别」是平台特定代码，业务逻辑零分支，符合 `#if os()` 允许清单。

**备选方案**：
- 只用 `UIMenuController`（已 deprecated，iOS 16+ 不推荐），否决。
- 只支持触摸长按，外接鼠标右键不弹菜单（让系统接管，弹 SwiftTerm iOS 自带的 `UIMenuController`），否决：体验割裂、与 macOS 行为不一致。
- 在 SwiftTerm iOS 路径之外自研补丁识别鼠标中键 —— 已在 Non-goals 明确不做（保留为已知边界，未来 SwiftTerm 升级或独立提案处理）。

## Risks / Trade-offs

- **[风险] SwiftTerm 升级后 `copy(_:)` / `softReset` / `selectionActive` 等 API 变更** → 缓解：把这些调用集中在 `PandaTerminalView` / `PandaIOSTerminalView` / `TerminalCoordinator` 少数几个方法里，并加 XCTest 回归测试；升级 SwiftTerm 时跑测试即可发现破坏点。SwiftTerm 是相对稳定的项目，`copy(_:)` 是 `@objc open` 公共 API，破坏概率低。
- **[风险] macOS 上 `otherMouseDown` 与 `allowMouseReporting` 冲突**：当远端应用启用鼠标模式（如 vim、tmux、htop）时，中键事件可能被远端消费。→ 缓解：`otherMouseDown` 中先判断 `allowMouseReporting && terminal.mouseMode.sendButtonPress()`，若为真则调 `super.otherMouseDown(with:)`（走 SwiftTerm 既有鼠标转发逻辑），不执行 PRIMARY 粘贴；这与 Linux 终端行为一致（在 vim 里中键也是给 vim）。
- **[风险] PRIMARY 缓冲与 Cmd+C 复制不同步** → 故意保留：Linux 终端的 PRIMARY 与 CLIPBOARD 本就是两个独立缓冲，用户期望中键粘贴「最近选中」而非「最近 Cmd+C」。文档与 spec 已明确「PRIMARY SHALL NOT 写入系统剪贴板」，这是设计而非 bug。
- **[风险] 「清屏」菜单项发 `clear\n` 命令在某些远端 shell（如 fish、csh）行为不一致** → 缓解：spec 描述为「发送 `clear` 命令字节流到远端，远端 shell 负责清屏」，把最终行为解释权交给远端 shell；绝大多数 Linux/macOS 默认 bash/zsh 都支持 `clear` 内建或外部命令。如果用户在裸 sh 之外的环境遇到问题，可在后续提案加「在客户端清空可视区」的备选项。
- **[风险] iPadOS 上 `UIEditMenuInteraction` 在某些 iOS 17 早期版本弹窗位置不理想** → 缓解：用 SwiftTerm 的 `calculateMouseHit(at:)`（iOS 上对应方法）拿到命中位置作为 menu anchor，不依赖系统默认位置；测试用例覆盖「菜单能弹出」即可，不强制像素级位置。
- **[trade-off] 子类化 `TerminalView` 增加少量平台特定代码** → 可接受：`PandaTerminalView`（macOS）与 `PandaIOSTerminalView`（iOS）是视图层平台差异，符合 `#if os()` 允许清单；`TerminalContextMenuBuilder` 与可用性规则是平台无关纯值类型，跨端共享。
- **[已知边界] iPad 外接鼠标与 Universal Control 转入鼠标的中键事件无法触发中键粘贴** → 接受：SwiftTerm iOS 端用 `UIPointerInteraction`（仅位置 / 修饰键，无按键区分）+ `pressesBegan`（只处理 `UIKey` 键盘按键，[iOSTerminalView.swift:2553](file:///Users/luowenqiang/files/my-codes/panda-ssh/apple/DerivedData/SourcePackages/checkouts/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift#L2553)），并把触摸 tap hard-code 为左键（[iOSTerminalView.swift:696-710](file:///Users/luowenqiang/files/my-codes/panda-ssh/apple/DerivedData/SourcePackages/checkouts/SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift#L696-L710)）。所以即使外接鼠标或 Universal Control 把 Mac 鼠标移到 iPad 上，中键事件**不会进入** SwiftTerm iOS 的应用代码路径。本提案在 iPad 端不启用中键粘贴与 PRIMARY 缓冲，并在 spec 中明确为已知边界。未来如 SwiftTerm 升级支持 `UIPress.type == .button` 的中键识别，或自研补丁，再开独立提案解锁。**右键菜单**不受此限制：外接鼠标右键事件能被 `UIPointerInteraction` + `pressesBegan` 路径捕获，本提案 Decision 7 已让 iPad 端触摸长按与鼠标右键都触发同一 `UIEditMenuInteraction`。
- **[已知边界] 读取选中文本时瞬态写入系统剪贴板** → 接受：SwiftTerm 的 `selection` 属性与 `SelectionService` 类型均为 `internal`，跨模块不可访问；`getSelectedText()` 虽为 `public`，但需先取得 `selection` 实例才能调用。为读取选中文本以填充 PRIMARY 缓冲（macOS `mouseUp`）与构建右键菜单上下文（双端），`TerminalCoordinator.readSelectedText(from:)` 采用「瞬态 copy + 恢复剪贴板」模式：保存原值 → 调 `tv.copy(self)`（macOS 写 `NSPasteboard.general`、iOS 写 `UIPasteboard.general`）→ 读取 → 恢复原值。净效果用户剪贴板内容不变，但存在**瞬态写入窗口**（微秒级），期间其他进程轮询剪贴板可读到选中内容（终端选中可能含敏感信息）。这是 SwiftTerm 不暴露公共选中文本读取入口的硬限制。spec 中「PRIMARY 缓冲 SHALL NOT 写入系统剪贴板」针对的是缓冲本身（纯内存 `String`，确实不写剪贴板），**不**否定读取选中时的瞬态写入；本边界在此明确标注。未来 SwiftTerm 暴露公共 `getSelectedText()` 入口或自研补丁后可消除此瞬态写入。

## Migration Plan

- 不需要数据迁移：本提案只新增 UI 交互，不改动主机配置、密钥引用、传输任务等持久化数据。
- 不需要 FFI 契约迁移：`crates/panda-ffi` 导出函数与签名不变。
- 部署步骤：`apple/Scripts/build-rust.sh` → `xcodegen` → `xcodebuild`（macOS / iOS 双端构建）。
- 回滚策略：删除新增的 `PandaTerminalView` / `PandaIOSTerminalView` / `TerminalContextMenu.swift`，把 `MacTerminalRepresentable` / `IOSTerminalRepresentable` 中的实例化从 `PandaTerminalView` 改回 `TerminalView` 即可完全回滚，无残留状态。

## Open Questions

无。所有关键决策已收敛，可执行性已验证（SwiftTerm 公共 API 已确认存在），无需要用户拍板的延迟决策。

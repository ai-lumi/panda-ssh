## 1. 菜单条目模型与可用性规则（纯值类型，TDD 起点）

- [x] 1.1 在 `apple/PandaSSHTests/` 新增 `TerminalContextMenuBuilderTests.swift`，覆盖以下用例（先红后绿）：
  - **正常流程**：`phase=.shell && hasSelection=true && hasClipboardText=true && hitLink=nil` → `items(for:)` 返回 `[copy, paste, pasteAndEnter, selectAll, clearScreen, resetTerminal, copyAndPaste, reconnect, closeTab]`；`isEnabled(.copy, ...)` 全部为 true。
  - **正常流程**：`phase=.failed` → 「粘贴」「粘贴并回车」「清屏」「重置终端」「复制并粘贴」「全选」「重连」中除「重连」「关闭标签页」外全部禁用，「复制」在有选中时仍可用（用于失败信息拷贝）。
  - **正常流程**：`phase=.connecting` → 除「关闭标签页」外其它全部禁用。
  - **意外操作**：`hitLink="https://x"` 但 `hasSelection=false` → `items(for:)` 返回值首位为 `.copyLink`、次位为 `.openLink`，且 `isEnabled(.copyLink)` / `isEnabled(.openLink)` 为 true。
  - **边界条件**：`hasSelection=true` 但 `selectedText==""`（空字符串）→ 视同 `hasSelection=false`，「复制」「复制并粘贴」禁用。
  - **边界条件**：`hitLink=""`（空串而非 nil）→ 视同无链接，不输出链接条目。
- [x] 1.2 在 `apple/PandaSSH/Workspace/` 新增 `TerminalContextMenu.swift`，定义 `TerminalMenuItem` 枚举、`TerminalMenuContext` 值类型、`TerminalContextMenuBuilder` 静态方法 `items(for:)` / `isEnabled(_:in:)`，让 1.1 的测试转绿。
- [ ] 1.3 跑 `xcodebuild test -scheme PandaSSH-macOS -only-testing:PandaSSHTests/TerminalContextMenuBuilderTests` 验证全绿；记录覆盖率，确保该文件 lines/regions >= 95%。

## 2. PRIMARY selection 缓冲与中键粘贴（macOS）

- [x] 2.1 在 `apple/PandaSSHTests/` 新增 `TerminalCoordinatorPrimarySelectionTests.swift`，用 in-process `TerminalView` + `MockShellConnection` 覆盖：
  - **正常流程**：模拟 `mouseUp` 后 coordinator.primarySelection 被更新为选中文本；调用 `pastePrimarySelection()` 后 `MockShellConnection.lastWriteData` 等于该文本的 UTF-8 字节，且不追加换行。
  - **意外操作**：在 `phase=.connecting` 或 `.failed` 下调用 `pastePrimarySelection()` → `MockShellConnection.lastWriteData` 为 nil（未写入）。
  - **边界条件**：`primarySelection=""`（从未选中或选中为空）时调用 `pastePrimarySelection()` → 不写入任何字节。
  - **边界条件**：选中空字符串触发 `updatePrimarySelection()` → 不覆盖既有非空缓冲。
  - **不污染剪贴板**：`updatePrimarySelection()` 调用前后 `NSPasteboard.general.string(forType: .string)` 内容不变（用临时设置一个已知字符串对比）。
- [x] 2.2 在 `apple/PandaSSH/Workspace/TerminalTabView.swift` 的 `TerminalCoordinator` 新增 `private var primarySelection: String = ""`、`func updatePrimarySelection(from: TerminalView)`、`func pastePrimarySelection()`，实现 2.1 测试。
- [ ] 2.3 让 2.1 测试转绿，跑 `xcodebuild test -scheme PandaSSH-macOS -only-testing:PandaSSHTests/TerminalCoordinatorPrimarySelectionTests` 验证。

## 3. macOS `PandaTerminalView` 子类（右键 + 中键 + mouseUp 钩子）

- [x] 3.1 在 `apple/PandaSSHTests/` 新增 `PandaTerminalViewMouseTests.swift`，覆盖：
  - **正常流程**：构造 `PandaTerminalView`，注入 mock coordinator，模拟 `otherMouseDown` 事件（buttonNumber=2）→ 断言 `coordinator.pastePrimarySelection()` 被调用且 `super.otherMouseDown` 在 `allowMouseReporting && terminal.mouseMode.sendButtonPress()` 为 true 时被调用而非 paste。
  - **正常流程**：模拟 `mouseUp` → 断言 `coordinator.updatePrimarySelection(from:)` 被调用，且 `super.mouseUp` 也被调用（保留既有选择行为）。
  - **意外操作**：`otherMouseDown` 在 `phase=.failed` 时（coordinator.connection 为 nil）→ 不调用 `pastePrimarySelection` 或调用后无写入。
  - **边界条件**：`rightMouseDown` 命中位置触发后，`super.rightMouseDown` 不被调用（避免系统默认菜单），改为构建 NSMenu（后续任务覆盖菜单内容，本任务只验证不 fallthrough）。
- [x] 3.2 在 `apple/PandaSSH/Workspace/TerminalTabView.swift`（或新增 `PandaTerminalView.swift`）定义 `final class PandaTerminalView: TerminalView`（macOS only），重写 `mouseUp` / `otherMouseDown` / `rightMouseDown`，让 3.1 转绿。
- [ ] 3.3 跑 `xcodebuild test -scheme PandaSSH-macOS -only-testing:PandaSSHTests/PandaTerminalViewMouseTests` 验证。

## 4. macOS 右键 NSMenu 构建

- [x] 4.1 在 `apple/PandaSSHTests/` 新增 `PandaTerminalViewRightClickMenuTests.swift`，覆盖：
  - **正常流程**：`phase=.shell && hasSelection=true && hasClipboardText=true && hitLink="https://x"` → 菜单条目按 `[copyLink, openLink, copy, paste, pasteAndEnter, selectAll, clearScreen, resetTerminal, copyAndPaste, reconnect, closeTab]` 顺序出现，启用态符合 `TerminalContextMenuBuilder.isEnabled`。
  - **正常流程**：`phase=.failed` → 仅「重连」「关闭标签页」「复制」（当有选中时）启用。
  - **意外操作**：右键位置在终端视图外（calculateMouseHit 返回越界）→ 不弹菜单，不抛异常。
  - **边界条件**：菜单点击每个 enabled item → coordinator 对应 `perform(_:)` 被调用一次（用 spy coordinator 验证调用次数与 item 类型）。
- [x] 4.2 在 `PandaTerminalView.rightMouseDown(with:)` 中：调 `calculateMouseHit` + `linkForClick` 组装 `TerminalMenuContext`，用 `TerminalContextMenuBuilder.items(for:)` 构建 `NSMenu`，每个 `NSMenuItem` 的 action 转发到 `coordinator.perform(_:)`。让 4.1 转绿。
- [ ] 4.3 跑 `xcodebuild test -scheme PandaSSH-macOS -only-testing:PandaSSHTests/PandaTerminalViewRightClickMenuTests` 验证。

## 5. 菜单执行动作（TerminalCoordinator.perform）

- [x] 5.1 在 `apple/PandaSSHTests/` 新增 `TerminalMenuActionExecutorTests.swift`，覆盖每个 `TerminalMenuItem` 的执行：
  - **正常流程（复制）**：`perform(.copy)` → 调 `tv.copy`，`NSPasteboard.general` 内容等于选中文本。
  - **正常流程（粘贴）**：`perform(.paste)` → `MockShellConnection.lastWriteData` 等于剪贴板文本，无换行。
  - **正常流程（粘贴并回车）**：`perform(.pasteAndEnter)` → 写入 = 剪贴板 + `\n`。
  - **正常流程（全选）**：`perform(.selectAll)` → `tv.selectAll` 被调用。
  - **正常流程（清屏）**：`perform(.clearScreen)` → `MockShellConnection.lastWriteData` == `"clear\n".utf8`。
  - **正常流程（重置终端）**：`perform(.resetTerminal)` → `tv.softReset`/`hardReset` 被调用 + `MockShellConnection.lastWriteData` == `"\u{1B}c".utf8`。
  - **正常流程（复制并粘贴）**：`perform(.copyAndPaste)` → 剪贴板被更新 + 写入等于剪贴板文本，无换行。
  - **正常流程（重连）**：`perform(.reconnect)` → `session.retry()` 被调用（通过 spy 验证）。
  - **正常流程（关闭标签页）**：`perform(.closeTab)` → `workspace.close(tabID:)` 被调用。
  - **意外操作**：`perform(.paste)` 但 `phase=.failed` → 不写入，不抛异常。
  - **意外操作**：`perform(.clearScreen)` 但 connection 为 nil → 不写入，不抛异常。
  - **边界条件**：`perform(.paste)` 但剪贴板为 nil/空 → 不写入。
  - **边界条件**：`perform(.copy)` 但选中文本为空 → 不修改剪贴板。
- [x] 5.2 在 `TerminalCoordinator` 新增 `func perform(_ item: TerminalMenuItem, hitLink: String?)`，分发到 `tv.copy/paste/selectAll/softReset`、`connection?.write`、`session.retry()`、`workspace.close(tabID:)`。让 5.1 转绿。
- [ ] 5.3 跑 `xcodebuild test -scheme PandaSSH-macOS -only-testing:PandaSSHTests/TerminalMenuActionExecutorTests` 验证。

## 6. WorkspaceStore 重连转发

- [x] 6.1 在 `apple/PandaSSHTests/` 新增 `WorkspaceStoreReconnectTests.swift`：
  - **正常流程**：注册一个 mock terminal session，调 `reconnectTerminal(tabID:)` → session.retry() 被调用（通过观察 `attempt` +1、`phase → .connecting` 副作用验证；用真实 `TerminalSessionStore` 而非 spy，因 `TerminalSessionStore` 为 `final` 不可子类化，未连接态 `retry()` 仅更新状态不触发异步 connect Task）。
  - **意外操作**：传不存在的 tabID → 不抛异常，不调用任何 session。
  - **边界条件**：tabID 存在但 session 已释放（weak 引用 nil）/ 从未注册 → 不抛异常。
- [x] 6.2 在 `apple/PandaSSH/Workspace/WorkspaceStore.swift` 新增 `func reconnectTerminal(tabID:)`，从 `terminalSessions[tabID]` 取出 session 调 `.retry()``。让 6.1 转绿。（**已在 §6.1 之前实现**：`reconnectTerminal(tabID:)` 与默认 `reconnectHandler` 读 `terminalSessions[id]?.value?.retry()` 已存在于 WorkspaceStore.swift，§6.1 测试覆盖其默认注册表转发路径。）
- [ ] 6.3 跑 `xcodebuild test -scheme PandaSSH-macOS -only-testing:PandaSSHTests/WorkspaceStoreReconnectTests` 验证。

## 7. iPadOS 长按与外接鼠标右键菜单（UIEditMenuInteraction）

> **完整测试用例清单见 [test-cases-ipad-context-menu.md](./test-cases-ipad-context-menu.md)**：29 个用例分 A/B/C/D/E 五组（触摸长按、外接鼠标右键、两条路径一致性、菜单项点击分发、已知边界反向验证），覆盖正常流程 / 意外操作 / 边界条件三类场景。本节给出实现任务骨架，细节以测试文档为准。

- [x] 7.0 测试基础设施先行（见测试文档 §0）：
  - `SpyShellConnection`（暴露 `lastWrite` / `writeCalls` / `resizeCalls` / `closeCount`）
  - `SpyTerminalCoordinator`（记录 `perform(_ item:hitLink:)` 调用序列，不调用真实 `tv.copy`/`connection.write`）
  - `IOSTerminalViewTestHarness.make(phase:hasSelection:hasClipboardText:hitLink:coordinator:)` 工厂
  - `PandaIOSTerminalView` 暴露 `internal simulateRightClick(at:)` / `simulateMiddleClick(at:)` 测试钩子（生产代码不调用）
- [x] 7.1 在 `apple/PandaSSHTests/` 新增 `PandaIOSTerminalViewContextMenuTests.swift`，按测试文档 §2-§6 实现 29 个用例（A.1-A.6、B.1-B.6、C.1-C.5、D.1-D.9、E.1-E.3），先红后绿。
- [x] 7.2 在 `apple/PandaSSH/Workspace/TerminalTabView.swift` 新增 `final class PandaIOSTerminalView: TerminalView`（iOS only），挂 `UILongPressGestureRecognizer` + `UIEditMenuInteraction`，并识别外接鼠标右键（`UIPointerInteraction` / `UIPress.type == .button`）导向同一 `UIEditMenuInteraction.presentMenu(at:)`。菜单构建复用 `TerminalContextMenuBuilder`，回调走 `TerminalCoordinator.perform`。让 7.1 转绿。
- [ ] 7.3 跑覆盖率验证（测试文档 §8 命令）：`xcodebuild test -scheme PandaSSH-iOS -destination 'platform=iOS Simulator,name=iPad (10th generation)' -enableCodeCoverage YES -only-testing:PandaSSH-iOSTests/PandaIOSTerminalViewContextMenuTests`，确认 `PandaIOSTerminalView` 的 lines >= 95% 且 regions >= 95%。
- [ ] 7.4 真机手动验收（用户在 iPad 执行，见测试文档 §9 备注 2）：触摸长按 + 外接蓝牙鼠标右键 + Universal Control 从 Mac 转入鼠标右键，三种触发方式都弹同一菜单且条目行为正确；外接鼠标中键点击无任何响应（确认 SwiftTerm iOS 限制生效）。

## 8. 集成接入既有 TerminalTabView

- [x] 8.1 修改 `MacTerminalRepresentable.makeNSView` / `IOSTerminalRepresentable.makeUIView`，把 `TerminalView(frame:font:)` 改为 `PandaTerminalView(frame:font:)` / `PandaIOSTerminalView(frame:font:)`，确保 coordinator 持有子类引用以调用 `perform`。
- [x] 8.2 在 `TerminalCoordinator.setup` 增加对 `PandaTerminalView` / `PandaIOSTerminalView` 的强类型识别（仅用于 `softReset` / `hardReset` 等子类暴露的便捷方法，不引入业务分支）。（实现：`as?` 识别子类后接线 `pandaDelegate` / `menuActionPerformer = self`，使生产路径下右键菜单点击与中键粘贴生效；裸 `TerminalView` 旧测试 `as?` 失败即跳过，保持兼容。）
- [ ] 8.3 跑既有 `apple/PandaSSHTests/TerminalSessionTests.swift` 等回归测试，确保接入子类不破坏既有终端会话流（数据读写、resize、关闭）。

## 9. 双端构建与覆盖率门禁

- [x] 9.1 跑 `cargo test`（无 Rust 改动，确保不退化）。（**已验证**：`cargo test --workspace` 全绿，无 Rust 改动，未退化。）
- [ ] 9.2 跑 `apple/Scripts/build-rust.sh` → `cd apple && xcodegen` → `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS build` → `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-iOS build -destination 'generic/platform=iOS Simulator'`，双端构建通过。
- [ ] 9.3 跑全部 macOS + iOS 单元测试，全绿。
- [ ] 9.4 跑覆盖率统计（`xcodebuild test ... -enableCodeCoverage YES` + `xcrun xccov`），确认 `TerminalContextMenu.swift` / `TerminalCoordinator` 新增方法 / `PandaTerminalView` / `PandaIOSTerminalView` / `WorkspaceStore.reconnectTerminal` 的 lines >= 95% 且 regions >= 95%；不达标补测试。
- [ ] 9.5 手动验收清单（用户在 macOS 真机执行，参考 spec 三类场景）：
  - 终端连接后选中文本 → 中键粘贴到 shell，剪贴板不变。
  - 终端右键 → 菜单条目按 spec 启用 / 禁用；执行每个 enabled item 行为正确。
  - 连接失败阶段右键 → 仅「重连」「关闭标签页」可用。
  - iPadOS 长按 → 菜单弹窗与 macOS 一致。

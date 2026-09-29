# iPad 外接鼠标右键与触摸长按菜单 — 自动化测试用例

> 本文档是 [tasks.md 第 7 节](./tasks.md) 的细化展开，只覆盖 iPadOS 端 `PandaIOSTerminalView` 的「右键菜单触发」与「菜单执行动作」两类行为。macOS 端、`TerminalContextMenuBuilder` 可用性规则、`TerminalCoordinator.perform(_:)` 执行动作的测试已在 tasks.md 第 1、5 节覆盖，本文不重复。
>
> 测试 target：`PandaSSH-iOSTests`（共享 `apple/PandaSSHTests/` 源码目录，依赖 `PandaSSH-iOS`），运行命令：
> ```sh
> xcodebuild test \
>   -project apple/PandaSSH.xcodeproj \
>   -scheme PandaSSH-iOS \
>   -destination 'platform=iOS Simulator,name=iPad (10th generation)' \
>   -only-testing:PandaSSH-iOSTests/PandaIOSTerminalViewContextMenuTests
> ```
>
> 覆盖率门禁：本测试文件覆盖 `PandaIOSTerminalView` 的 `rightMouseDown` 等价路径（长按 + 鼠标右键）与菜单分发逻辑，要求 `lines >= 95%` 且 `regions >= 95%`。

## 0. 测试基础设施需求（前置任务，先建后用）

现有 `MockShellConnection`（[ShellConnection.swift:56-73](file:///Users/luowenqiang/files/my-codes/panda-ssh/apple/PandaSSH/Workspace/ShellConnection.swift#L56-L73)）写入即回显，**不暴露单次写入断言**，无法直接验证菜单点击后的字节流。本测试需要以下基础设施（在测试用例之前先实现，TDD 起点）：

### 0.1 SpyShellConnection

```swift
final class SpyShellConnection: ShellConnection {
    private(set) var writeCalls: [Data] = []   // 每次写入的字节流快照
    private(set) var resizeCalls: [(cols: UInt64, rows: UInt64)] = []
    private(set) var closeCount = 0
    private var buffer = Data()                 // 兼容既有读路径

    func write(_ data: Data) throws { writeCalls.append(data); buffer.append(data) }
    func read(max: UInt64) throws -> Data {
        let n = min(Int(max), buffer.count); let chunk = buffer.prefix(n)
        buffer.removeFirst(n); return Data(chunk)
    }
    func resize(cols: UInt64, rows: UInt64) throws { resizeCalls.append((cols, rows)) }
    func close() throws { closeCount += 1 }

    /// 仅断言最近一次写入（方便菜单动作的「写入内容」校验）
    var lastWrite: Data? { writeCalls.last }
}
```

### 0.2 SpyTerminalCoordinator

记录 `perform(_ item: TerminalMenuItem, hitLink: String?)` 的调用次数与 item 序列，不调用真实 `tv.copy`/`tv.paste`/`connection.write`，避免依赖真实 SwiftTerm 内部状态：

```swift
final class SpyTerminalCoordinator: TerminalCoordinatorProtocolForTest {
    private(set) var performCalls: [(item: TerminalMenuItem, hitLink: String?)] = []
    func perform(_ item: TerminalMenuItem, hitLink: String?) {
        performCalls.append((item, hitLink))
    }
}
```

> 协议 `TerminalCoordinatorProtocolForTest` 是测试专用抽象（只暴露 `perform`），让 `PandaIOSTerminalView` 在生产代码注入 `TerminalCoordinator`，在测试注入 `SpyTerminalCoordinator`。这一抽象只落在视图层，不进入业务逻辑，符合分层边界。

### 0.3 IOSTerminalViewTestHarness

构造 in-process `PandaIOSTerminalView` 的辅助工厂：

```swift
@MainActor
enum IOSTerminalViewTestHarness {
    static func make(
        phase: TerminalSessionStore.Phase = .shell,
        hasSelection: Bool = false,
        hasClipboardText: Bool = true,
        hitLink: String? = nil,
        coordinator: SpyTerminalCoordinator = SpyTerminalCoordinator()
    ) -> (view: PandaIOSTerminalView, coordinator: SpyTerminalCoordinator)
}
```

内部策略：
- 用 `UIWindow` + `rootViewController` 把视图加入视图层级（某些手势识别需要 view 在窗口中才生效）。
- `phase`/`hasSelection`/`hasClipboardText`/`hitLink` 通过测试 hook 注入到 `TerminalMenuContext` 构造（不依赖真实 SwiftTerm `selection` 状态）。
- 视图 frame 设为 `CGRect(x: 0, y: 0, width: 320, height: 240)`，保证 `calculateMouseHit` 在可见区域。

### 0.4 事件注入辅助

| 触发路径 | 注入方式 | 关键 API |
|---|---|---|
| 触摸长按 | 构造 `UITouch` + `UIEvent` 模拟 `.began`/`.changed`/`.ended` 三阶段，duration >= `minimumPressDuration` | iOS 13.4+ 私有 API `UITouch` init 受限，改用直接调 `gestureRecognizer.state = .began/.ended` 触发回调 |
| 外接鼠标右键 | 构造 `UIPress`（`type == .button`，`key.keyCode` 为鼠标右键占位）+ `UIPressesEvent` 注入 `pressesBegan(_:with:)` | iOS 13.4+ `UIPress` 公共初始化受限；备选方案：直接调 `view.simulateRightClick(at:)` 测试 helper 方法（在 `PandaIOSTerminalView` 上暴露 `internal func simulateRightClick(at point: CGPoint)` 给测试用，生产代码不调用） |
| 外接鼠标中键（验证无响应） | 同上，构造中键 `UIPress` 注入 | 断言 `performCalls` 仍为空、`SpyShellConnection.lastWrite` 仍为 nil |
| 边界外点击 | 传入 `point = CGPoint(x: -10, y: -10)` 或 `(x: 9999, y: 9999)` | 走同一 helper |

> **注**：iOS 上 `UIPress` / `UIPressesEvent` 没有公共构造器。测试策略采用「在 `PandaIOSTerminalView` 上暴露 `internal` 测试钩子方法」——这些钩子**只用于测试**，生产代码不调用，且只暴露已经存在的菜单构建路径，不引入新的业务分支。这是测试可注入性的合理边界，不违反分层原则（业务逻辑仍在 `TerminalContextMenuBuilder` / `TerminalCoordinator.perform`）。

## 1. 测试用例分组概览

| 组 | 用例数 | 触发方式 | 关注点 |
|---|---|---|---|
| A | 6 | 触摸长按 | 长按手势识别 → 菜单弹出 |
| B | 6 | 外接鼠标右键（含 Universal Control） | 右键事件 → 菜单弹出 |
| C | 5 | 触摸长按 + 外接鼠标右键 | 两条触发路径菜单一致性 |
| D | 9 | 菜单项点击 | `perform(_:)` 调用正确分发 |
| E | 3 | 外接鼠标中键 | 已知边界验证（无响应） |
| 合计 | 29 | | 覆盖正常/意外/边界三类场景 |

每组都按「正常流程 / 意外操作 / 边界条件」三类分组标注。

## 2. A 组：触摸长按触发菜单

### A.1（正常流程）长按手势识别成功后弹出菜单

- **GIVEN** `PandaIOSTerminalView` 处于 `phase=.shell`，无选中，剪贴板有文本，无链接命中
- **WHEN** 在视图 `(100, 100)` 处注入长按手势（`.began` → 等 `minimumPressDuration` → `.ended`）
- **THEN** `coordinator.performCalls` 为空（未点击菜单项），但 `UIEditMenuInteraction` 的 `presentMenu(at:)` 被调用一次，菜单 anchor 为 `(100, 100)`
- **断言**：`XCTAssertEqual(menuPresentCount, 1)`、`XCTAssertEqual(menuAnchor, CGPoint(x: 100, y: 100))`

### A.2（正常流程）连接失败阶段长按仍可弹菜单（仅「重连」「关闭标签页」可用）

- **GIVEN** `phase=.failed`
- **WHEN** 在视图任意位置长按
- **THEN** 菜单弹出，可见条目集合为 `[reconnect, closeTab, copy(disabled), paste(disabled), pasteAndEnter(disabled), selectAll(disabled), clearScreen(disabled), resetTerminal(disabled), copyAndPaste(disabled)]`（链接条目不出现）
- **断言**：`menuItems.map(\.identifier)` 包含 `reconnect`/`closeTab`；`isEnabled(.paste) == false`、`isEnabled(.reconnect) == true`

### A.3（意外操作）长按过程中手势被取消（系统手势冲突）

- **GIVEN** 同 A.1
- **WHEN** 长按手势状态 `.began` → `.cancelled`（模拟系统手势打断）
- **THEN** `menuPresentCount == 0`（菜单不应弹出），`coordinator.performCalls` 为空
- **断言**：`XCTAssertEqual(menuPresentCount, 0)`

### A.4（意外操作）连接中阶段长按

- **GIVEN** `phase=.connecting`
- **WHEN** 长按视图任意位置
- **THEN** 菜单弹出，但除「关闭标签页」外其它条目禁用；条目集合与 A.2 相同，但 `isEnabled(.reconnect) == false`、`isEnabled(.closeTab) == true`
- **断言**：`isEnabled(.closeTab) == true`、`isEnabled(.paste) == false`、`isEnabled(.reconnect) == false`

### A.5（边界条件）长按位置在视图边界外

- **GIVEN** 同 A.1
- **WHEN** 注入长按手势，位置 `CGPoint(x: -10, y: -10)`（视图左上角外）
- **THEN** `menuPresentCount == 0`，不抛异常
- **断言**：`XCTAssertEqual(menuPresentCount, 0)`；测试不崩溃

### A.6（边界条件）长按位置在视图右下角边缘

- **GIVEN** 同 A.1，视图 frame `CGRect(0,0,320,240)`
- **WHEN** 长按位置 `CGPoint(x: 320, y: 240)`（边缘点，含 `\leq` 等于）
- **THEN** 菜单弹出，anchor 为 `(320, 240)`；条目集合与 A.1 相同
- **断言**：`XCTAssertEqual(menuPresentCount, 1)`、`XCTAssertEqual(menuAnchor, CGPoint(x: 320, y: 240))`

## 3. B 组：外接鼠标右键触发菜单

### B.1（正常流程）外接鼠标右键点击弹出菜单

- **GIVEN** `PandaIOSTerminalView` 处于 `phase=.shell`，无选中，剪贴板有文本
- **WHEN** 调 `view.simulateRightClick(at: CGPoint(x: 100, y: 100))`（注入外接鼠标右键事件）
- **THEN** `menuPresentCount == 1`，菜单 anchor 为 `(100, 100)`；条目集合与 A.1 完全一致
- **断言**：`XCTAssertEqual(menuPresentCount, 1)`、菜单条目 `map(\.identifier)` 等于 A.1 的条目集合

### B.2（正常流程）连接失败阶段外接鼠标右键弹菜单

- **GIVEN** `phase=.failed`
- **WHEN** 调 `view.simulateRightClick(at: CGPoint(x: 50, y: 50))`
- **THEN** 菜单弹出，条目可用性与 A.2 一致
- **断言**：`isEnabled(.reconnect) == true`、`isEnabled(.paste) == false`

### B.3（正常流程）Universal Control 从 Mac 转入鼠标右键

- **GIVEN** 同 B.1
- **WHEN** 模拟 Universal Control 转入鼠标的右键事件（注入路径与 B.1 相同，因为 `UIPointerInteraction` 不区分鼠标来源，只看按键）
- **THEN** 行为与 B.1 一致（菜单弹出，条目相同）
- **断言**：与 B.1 相同；本用例保证 Universal Control 转入的鼠标右键**不会**因鼠标来源不同走不同分支
- **备注**：iPad 端无法在测试中区分「蓝牙鼠标」与「Universal Control 转入鼠标」，因此本用例与 B.1 在单元测试层面等价；真机验收阶段（tasks.md 7.4）由用户手动确认三种来源（蓝牙/USB/Universal Control）行为一致

### B.4（意外操作）右键位置在视图外

- **GIVEN** 同 B.1
- **WHEN** 调 `view.simulateRightClick(at: CGPoint(x: -10, y: -10))`
- **THEN** `menuPresentCount == 0`，不抛异常
- **断言**：`XCTAssertEqual(menuPresentCount, 0)`；测试不崩溃

### B.5（边界条件）右键位置在视图右下角边缘

- **GIVEN** 同 B.1，视图 frame `CGRect(0,0,320,240)`
- **WHEN** 调 `view.simulateRightClick(at: CGPoint(x: 320, y: 240))`
- **THEN** 菜单弹出，anchor 为 `(320, 240)`；条目集合与 B.1 一致
- **断言**：`XCTAssertEqual(menuPresentCount, 1)`、`XCTAssertEqual(menuAnchor, CGPoint(x: 320, y: 240))`

### B.6（边界条件）右键位置恰好在字符单元边界（col/row 整数倍）

- **GIVEN** 同 B.1，cell 宽度假设 8pt
- **WHEN** 调 `view.simulateRightClick(at: CGPoint(x: 80, y: 16))`（恰好第 10 列、第 2 行）
- **THEN** 菜单弹出，`calculateMouseHit` 返回的 grid 命中为 `(col: 10, row: 1)`（0-based）；菜单 anchor 为 `(80, 16)`
- **断言**：`XCTAssertEqual(hitGridCol, 10)`、`XCTAssertEqual(hitGridRow, 1)`

## 4. C 组：两条触发路径菜单一致性

### C.1（正常流程）长按与右键产生相同菜单条目集合

- **GIVEN** 同一 `PandaIOSTerminalView` 实例（同 phase/selection/clipboard/hitLink）
- **WHEN** 分别用 A.1 的长按路径与 B.1 的右键路径触发
- **THEN** 两次 `menuItems.map(\.identifier)` 与 `isEnabled` 矩阵完全相等
- **断言**：`XCTAssertEqual(longPressItems, rightClickItems)`

### C.2（正常流程）链接命中时两条路径都出现链接条目

- **GIVEN** `hitLink = "https://example.com"`，其它状态同 A.1
- **WHEN** 分别长按与右键触发
- **THEN** 两次菜单首两个条目都是 `[.copyLink, .openLink]`，且都启用
- **断言**：`XCTAssertEqual(longPressItems.prefix(2), [.copyLink, .openLink])`、`XCTAssertEqual(rightClickItems.prefix(2), [.copyLink, .openLink])`

### C.3（意外操作）剪贴板无文本时两条路径都禁用粘贴类条目

- **GIVEN** `hasClipboardText = false`，`phase = .shell`，无选中
- **WHEN** 分别长按与右键触发
- **THEN** 两次菜单都禁用 `.paste`/`.pasteAndEnter`/`.copyAndPaste`，启用集合一致
- **断言**：`XCTAssertEqual(isEnabled(.paste, in: longPressCtx), false)`、`XCTAssertEqual(isEnabled(.paste, in: rightClickCtx), false)`；其它条目启用态相等

### C.4（边界条件）有选中但选中为空字符串

- **GIVEN** `hasSelection = true`，但底层 `selection.getSelectedText()` 返回 `""`
- **WHEN** 分别长按与右键触发
- **THEN** 两条路径都把 `.copy`/`.copyAndPaste` 当作禁用（视同无选中），条目集合与「无选中」一致
- **断言**：`XCTAssertEqual(longPressItems.map(\.identifier), rightClickItems.map(\.identifier))`；`isEnabled(.copy, in: longPressCtx) == false`

### C.5（边界条件）连续触发：先长按取消、再右键触发

- **GIVEN** 同 A.1
- **WHEN** 长按触发 `.began` 后立刻 `.cancelled`（如 A.3），随后调 `simulateRightClick(at:)`
- **THEN** 第一次 `menuPresentCount == 0`，第二次 `menuPresentCount == 1`；两次状态不互相干扰
- **断言**：`XCTAssertEqual(menuPresentCount, 1)`、最后一次 anchor 等于右键位置

## 5. D 组：菜单项点击执行动作（perform 调用）

> D 组聚焦「菜单项被点击后 `coordinator.perform(_ item:hitLink:)` 是否被正确调用」，不验证 `TerminalCoordinator.perform` 的内部行为（复制/粘贴/写入字节流断言在 tasks.md 5.1 的 `TerminalMenuActionExecutorTests` 覆盖，本组只验证分发链路）。

### D.1（正常流程）点击「复制」调用 perform(.copy)

- **GIVEN** 菜单已通过 A.1 长按弹出，`hasSelection = true`
- **WHEN** 模拟点击菜单项 `.copy`
- **THEN** `coordinator.performCalls.count == 1`，`performCalls[0].item == .copy`，`performCalls[0].hitLink == nil`
- **断言**：`XCTAssertEqual(coordinator.performCalls, [(.copy, nil)])`

### D.2（正常流程）点击「粘贴并回车」调用 perform(.pasteAndEnter)

- **GIVEN** 菜单已弹出，`hasClipboardText = true`
- **WHEN** 模拟点击 `.pasteAndEnter`
- **THEN** `coordinator.performCalls == [(.pasteAndEnter, nil)]`

### D.3（正常流程）点击「重连」调用 perform(.reconnect) — failed 阶段

- **GIVEN** `phase = .failed`，菜单通过 A.2 长按弹出
- **WHEN** 模拟点击 `.reconnect`
- **THEN** `coordinator.performCalls == [(.reconnect, nil)]`

### D.4（正常流程）点击「关闭标签页」调用 perform(.closeTab)

- **GIVEN** `phase = .shell`，菜单已弹出
- **WHEN** 模拟点击 `.closeTab`
- **THEN** `coordinator.performCalls == [(.closeTab, nil)]`

### D.5（正常流程）点击「复制链接地址」携带 hitLink

- **GIVEN** `hitLink = "https://example.com"`，菜单已弹出（含链接条目）
- **WHEN** 模拟点击 `.copyLink`
- **THEN** `coordinator.performCalls == [(.copyLink, "https://example.com")]`

### D.6（正常流程）点击「打开链接」调用 perform(.openLink, hitLink)

- **GIVEN** 同 D.5
- **WHEN** 模拟点击 `.openLink`
- **THEN** `coordinator.performCalls == [(.openLink, "https://example.com")]`

### D.7（意外操作）点击被禁用的菜单项不调用 perform

- **GIVEN** `phase = .failed`，菜单中 `.paste` 被禁用
- **WHEN** 模拟点击 `.paste`（即使 UI 上禁用，仍注入点击事件验证防御）
- **THEN** `coordinator.performCalls.count == 0`（禁用项点击不触发 perform）
- **断言**：`XCTAssertEqual(coordinator.performCalls.count, 0)`

### D.8（意外操作）菜单未弹出时点击事件不触发 perform

- **GIVEN** 菜单未弹出（`menuPresentCount == 0`，例如 A.3 取消后）
- **WHEN** 直接调 `coordinator.perform(.copy, hitLink: nil)` 之外的任何路径注入点击（如直接构造 `UIControl.Event` 注入）
- **THEN** `coordinator.performCalls.count == 0`（菜单未弹出时不分发点击）
- **断言**：`XCTAssertEqual(coordinator.performCalls.count, 0)`

### D.9（边界条件）连续点击多个菜单项依次调用 perform

- **GIVEN** 菜单已弹出，`hasSelection = true`，`hasClipboardText = true`，`hitLink = "https://x"`
- **WHEN** 依次模拟点击 `.copyLink` → `.copy` → `.pasteAndEnter` → `.closeTab`
- **THEN** `coordinator.performCalls` 严格按顺序等于 `[(.copyLink, "https://x"), (.copy, nil), (.pasteAndEnter, nil), (.closeTab, nil)]`
- **断言**：`XCTAssertEqual(coordinator.performCalls.count, 4)`；逐项 `XCTAssertEqual`

## 6. E 组：已知边界验证（外接鼠标中键不触发任何行为）

> E 组验证 [design.md Risks](./design.md) 中「已知边界」：SwiftTerm iOS 不区分鼠标按键，外接鼠标中键事件**不会**进入 `PandaIOSTerminalView` 的中键粘贴路径。E 组用反向断言确认本提案**没有**意外引入中键行为。

### E.1（正常流程）外接鼠标中键点击不调用 perform、不写入字节

- **GIVEN** `PandaIOSTerminalView` 处于 `phase=.shell`，`primarySelection` 内部缓冲为空（因为 iPad 端不维护该缓冲）
- **WHEN** 调 `view.simulateMiddleClick(at: CGPoint(x: 100, y: 100))`（注入外接鼠标中键事件）
- **THEN** `coordinator.performCalls.count == 0`；`SpyShellConnection.lastWrite == nil`；`menuPresentCount == 0`（中键不弹菜单）
- **断言**：`XCTAssertEqual(coordinator.performCalls.count, 0)`、`XCTAssertNil(spyConn.lastWrite)`

### E.2（意外操作）外接鼠标中键点击不应触发其他菜单条目

- **GIVEN** 同 E.1，但 `primarySelection` 内部缓冲被人为预置为 `"hello"`（验证即使有缓冲，中键路径也不消费）
- **WHEN** 调 `view.simulateMiddleClick(at: CGPoint(x: 50, y: 50))`
- **THEN** `spyConn.lastWrite == nil`（中键不读取 PRIMARY 缓冲写入通道）；缓冲值仍为 `"hello"`（未被消费）
- **断言**：`XCTAssertNil(spyConn.lastWrite)`

### E.3（边界条件）外接鼠标中键在视图边界外不抛异常

- **GIVEN** 同 E.1
- **WHEN** 调 `view.simulateMiddleClick(at: CGPoint(x: -10, y: -10))`
- **THEN** 测试不崩溃；`coordinator.performCalls.count == 0`；`spyConn.lastWrite == nil`
- **断言**：`XCTAssertEqual(coordinator.performCalls.count, 0)`、`XCTAssertNil(spyConn.lastWrite)`

## 7. 用例与三类场景映射

| 类别 | 用例编号 | 用例数 |
|---|---|---|
| 正常流程 | A.1, A.2, B.1, B.2, B.3, C.1, C.2, C.3, D.1, D.2, D.3, D.4, D.5, D.6, E.1 | 15 |
| 意外操作 | A.3, A.4, B.4, C.3（注：意外 = 错误输入/失败路径），D.7, D.8, E.2 | 7 |
| 边界条件 | A.5, A.6, B.5, B.6, C.4, C.5, D.9, E.3 | 7 |
| 合计 | | 29 |

> C.3 既属「意外操作」（剪贴板为空时禁用粘贴类条目，模拟用户在无内容时点击）也属「边界」，归到意外操作类别。三类场景全覆盖，满足 `AGENTS.md` 用例门禁。

## 8. 覆盖率门禁

- 测试文件：`apple/PandaSSHTests/PandaIOSTerminalViewContextMenuTests.swift`
- 覆盖目标：`PandaIOSTerminalView`（iOS target）的 `rightMouseDown 等价路径` / `longPress 手势识别` / `menuItems 构建` / `分发 perform` 四个方法族
- 门禁：`lines >= 95%` 且 `regions >= 95%`
- 验证命令：
  ```sh
  xcodebuild test \
    -project apple/PandaSSH.xcodeproj \
    -scheme PandaSSH-iOS \
    -destination 'platform=iOS Simulator,name=iPad (10th generation)' \
    -enableCodeCoverage YES \
    -only-testing:PandaSSH-iOSTests/PandaIOSTerminalViewContextMenuTests
  xcrun xccov view --report --target PandaSSH-iOS \
    ~/Library/Developer/Xcode/DerivedData/PandaSSH-*/Logs/Test/*.xcresult
  ```
- 不达标补救：补充针对未覆盖分支的用例（如 `PandaIOSTerminalView` 内部 `if phase == .connecting` 的某个未命分支），不放宽门禁。

## 9. 已知限制与备注

1. **`UIPress` / `UIPressesEvent` 公共构造受限**：iOS 上没有公共 API 直接构造鼠标按键事件。本测试通过 `PandaIOSTerminalView` 暴露 `internal simulateRightClick(at:)` / `simulateMiddleClick(at:)` 测试钩子方法注入事件，**生产代码不调用**这些方法，钩子只复用已经存在的菜单构建路径，不引入新业务分支。
2. **Universal Control 转入鼠标来源不可在单元测试中区分**：B.3 与 B.1 在单元测试层等价；真实三来源（蓝牙/USB/Universal Control）行为一致性留给 tasks.md 7.4 的真机手动验收。
3. **`UIEditMenuInteraction` 弹窗像素级位置不在测试范围**：测试只断言「菜单弹出」与「anchor 等于注入位置」，不验证系统弹窗在屏幕上的实际像素位置（受系统主题 / 安全区域影响，非确定性）。
4. **`TerminalCoordinator.perform` 的内部行为**（写入字节流、调用 `tv.copy`/`tv.paste`）不在本测试覆盖范围，由 tasks.md 5.1 的 `TerminalMenuActionExecutorTests` 在 macOS target 覆盖（iPad 与 macOS 共享同一 `perform` 实现，跨端共享测试）。
5. **`primarySelection` 缓冲**：iPad 端不维护该缓冲（spec 明确为已知边界），E 组反向断言验证即使缓冲被预置也不会被中键消费，确认该边界未被打破。

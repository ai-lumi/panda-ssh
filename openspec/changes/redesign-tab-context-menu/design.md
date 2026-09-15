# Design: 页签右键菜单重构

## Context

旧标签页右键菜单使用 SwiftUI `.contextMenu`，在 `UnifiedWorkspaceTabStrip` 重构中丢失。项目已有成熟的 NSMenu 模式——`PandaTerminalView` 通过 `rightMouseDown` → `buildNSMenu` → `NSMenu.popUpContextMenu` 构建终端内容区右键菜单，支持完整的 macOS 原生菜单外观（图标、分隔线、快捷键）。本变更复用该模式。

## Goals / Non-Goals

**Goals:**

- 恢复页签右键菜单功能（重连、关闭标签页、关闭其他、关闭全部）。
- macOS 端使用 NSMenu 直接构建，支持 SF Symbol 图标、键盘快捷键、分隔线分组。
- iPadOS 端使用 `.contextMenu`，条目集与 macOS 对齐。
- 菜单构建逻辑为纯值、可独立测试。

**Non-Goals:**

- 不改变 `WorkspaceStore` 已有的业务方法。
- 不改变终端内容区右键菜单、侧栏右键菜单、SFTP 文件行右键菜单。

## Decisions

### 1. 菜单条目与分组

菜单条目按以下顺序排列，以分隔线分为两组：

**第一组 — 会话操作（仅终端标签展示）：**

| 条目 | 图标 | 快捷键 | 条件 |
|------|------|--------|------|
| 重连 | `arrow.clockwise` | `⌘R` | 仅 `kind == .terminal` |

**第二组 — 关闭操作（所有标签展示）：**

| 条目 | 图标 | 快捷键 | 说明 |
|------|------|--------|------|
| 关闭标签页 | `xmark` | `⌘W` | 关闭当前右键标签 |
| 关闭其他标签页 | `xmark.circle` | `⌥⌘W` | 关闭除右键标签外的全部标签 |
| 关闭全部标签页 | `xmark.circle.fill` | `⇧⌘⌥W` | 关闭全部标签 |

**理由**：参考 Safari/Xcode 标签页菜单的分组模式——会话操作与关闭操作语义不同，用分隔线隔开。SFTP 标签不展示「重连」（而非禁用），减少噪声（与 `ui-workspace-optimization` 决策一致）。

**替代方案**：所有标签统一展示「重连」但 SFTP 禁用。**否决**：iPadOS 长按菜单中禁用项体验差。

### 2. macOS 右键事件捕获

在 `UnifiedWorkspaceTabStrip` 的 `tabButton(_:)` 返回的视图上叠加透明 `NSViewRepresentable`，重写 `rightMouseDown`。

```
TabRightClickCatcher (NSViewRepresentable)
  └── NSView subclass
        ├── rightMouseDown(with:) → 回调 tabID
        └── 透明、不拦截左键/滚轮（hit-test 穿透）
```

**理由**：与已有的 `MacOSTabStripWheelBridge` 模式一致，职责单一。每个标签按钮独立捕获右键，坐标自然落在标签范围内，无需手动计算 hit-test。

**替代方案**：在 `MonitorView` 中增加右键监听。**否决**：`MonitorView` 覆盖整个标签栏，需要额外 hit-test 判断哪个标签被右键，增加复杂度且与滚轮职责混合。

### 3. NSMenu 构建与弹出

复用 `PandaTerminalView.buildNSMenu` 的模式：

1. `TabContextMenuBuilder.items(for: tabKind)` 返回 `[TabMenuItem]`（纯值枚举）。
2. `TabContextMenuBuilder.buildNSMenu(from: tabID, tabKind:)` 构建 `NSMenu`：
   - 每个 `NSMenuItem` 设置 `image`（SF Symbol）、`keyEquivalent`、`keyEquivalentModifierMask`。
   - 分组边界处插入 `NSMenu.separatorItem`。
   - `representedObject` 携带 `TabMenuPayload(item: tabID)`。
3. `NSMenu.popUpContextMenu(menu, with: event, for: view)` 弹出。
4. `@objc handleMenuItem(_:)` 解包 payload，调用 `WorkspaceStore` 方法。

**SF Symbol 图标加载**：`NSImage(systemSymbolName: accessibilityDescription:)` 在 macOS 11+ 可用，项目目标 macOS 14 满足。

**`validateUserInterfaceItem` 覆盖**：与 `PandaTerminalView` 一致，需对携带 `TabMenuPayload` 的菜单项返回 `menuItem.isEnabled`，避免 AppKit 验证机制误禁用。

### 4. iPadOS 实现

在 `tabButton(_:)` 上挂 `.contextMenu`，条件编译 `#if !os(macOS)`。菜单内容按相同条目集构建（`Button` + `Label` + SF Symbol）。iPadOS 不支持键盘快捷键，不展示 `keyEquivalent`。

### 5. 纯值逻辑与可测试性

`TabContextMenuBuilder` 为 enum（无状态），暴露两个静态方法：

```swift
enum TabContextMenuBuilder {
    static func items(for kind: WorkspaceTab.Kind) -> [TabMenuItem]
    static func groups(for kind: WorkspaceTab.Kind) -> [[TabMenuItem]]
    // groups 返回按分隔线分组的二维数组，供 NSMenu 构建使用
}
```

`TabMenuItem` 为 `Equatable` enum，携带标题、图标名、快捷键。测试可直接断言条目集合与分组结构。

## Risks / Trade-offs

- **[NSMenu 与 SwiftUI 生命周期]** NSMenu 弹出期间 SwiftUI 视图可能重建（标签关闭） → payload 仅携带 `tabID`，action 执行时通过 `WorkspaceStore` 查找当前状态，不持有视图引用。
- **[右键捕获与滚轮桥接共存]** 两个 AppKit 层叠加在同一区域 → `TabRightClickCatcher` 只处理 `rightMouseDown`，不拦截 scrollWheel/leftMouseDown，事件自然穿透到下层 `MonitorView`。
- **[SF Symbol 可用性]** `arrow.clockwise` / `xmark` / `xmark.circle` / `xmark.circle.fill` 均在 macOS 11+ 可用，目标 macOS 14 无风险。

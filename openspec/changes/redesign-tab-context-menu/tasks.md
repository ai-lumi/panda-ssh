# Tasks: 页签右键菜单重构

## 1. 纯值菜单构建逻辑（TabContextMenuBuilder）

- [x] 1.1 新增 `apple/PandaSSHTests/TabContextMenuBuilderTests.swift`：
  - 终端标签 `items(for: .terminal)` 返回 `[.reconnect, .closeTab, .closeOthers, .closeAll]`
  - SFTP 标签 `items(for: .sftp)` 返回 `[.closeTab, .closeOthers, .closeAll]`（无 `.reconnect`）
  - `groups(for: .terminal)` 返回两组：`[.reconnect]` + `[.closeTab, .closeOthers, .closeAll]`
  - `groups(for: .sftp)` 返回一组：`[.closeTab, .closeOthers, .closeAll]`
  - 每个条目的 `title`、`symbolName`、`keyEquivalent`、`keyModifiers` 断言
- [x] 1.2 新增 `apple/PandaSSH/Workspace/TabContextMenuBuilder.swift`：
  - `enum TabMenuItem: Equatable`，携带 `title`、`symbolName`、`keyEquivalent`、`keyModifiers`
  - `enum TabContextMenuBuilder`，静态方法 `items(for:)` 和 `groups(for:)`
  - 让 1.1 测试通过

## 2. macOS NSMenu 构建

- [x] 2.1 新增测试：`TabContextMenuBuilder.buildNSMenu(tabID:tabKind:)` 返回的 NSMenu 结构断言
  - 终端标签：`NSMenuItem` 数量 = 4 条目 + 1 分隔线 = 5 项
  - SFTP 标签：`NSMenuItem` 数量 = 3 条目 = 3 项（无分隔线，因为只有一组）
  - 每个 `NSMenuItem` 的 `title`、`image`（非 nil）、`keyEquivalent` 断言
  - 分隔线项 `isSeparatorItem == true`
  - 每个非分隔线项的 `representedObject` 为 `TabMenuPayload`
- [x] 2.2 在 `TabContextMenuBuilder.swift` 中新增 `buildNSMenu(tabID:tabKind:)`（`#if os(macOS)`）：
  - 遍历 `groups(for:)`，组间插入 `NSMenu.separatorItem`
  - 每个条目创建 `NSMenuItem`，设置 `image`（`NSImage(systemSymbolName:)`)、`keyEquivalent`、`keyEquivalentModifierMask`
  - `representedObject` 携带 `TabMenuPayload(tabID:item:)`
  - 让 2.1 测试通过

## 3. macOS 右键事件捕获

- [x] 3.1 新增测试：`TabRightClickMonitor` 的 NSView 在右键时触发回调
  - 模拟右键 → 回调被调用
  - bounds 外右键 → 回调不被调用
  - `hitTest` 返回 nil（左键穿透）
- [x] 3.2 新增 `TabRightClickCatcher.swift`（`#if os(macOS)`）：
  - `NSViewRepresentable`，内部 NSView 子类 `hitTest` 返回 nil
  - `NSEvent.addLocalMonitorForEvents` 捕获 `rightMouseDown`
  - 不拦截左键/滚轮（`hitTest` 返回 nil，事件穿透）
  - 让 3.1 测试通过

## 4. 集成到 UnifiedWorkspaceTabStrip

- [x] 4.1 集成测试：由 `TabContextMenuBuilderTests`（NSMenu 结构）和 `TabRightClickMonitorTests`（右键捕获）覆盖
- [x] 4.2 修改 `UnifiedWorkspaceTabStrip.swift`：
  - macOS：在 `tabButton(_:)` 上叠加 `TabRightClickMonitor`（`.onTabRightClick`），回调中构建 NSMenu 并弹出
  - iPadOS：在 `tabButton(_:)` 上挂 `.contextMenu`，菜单内容按 `TabContextMenuBuilder.items(for:)` 构建
  - 菜单项 action 通过 `TabMenuActionHandler` → `WorkspaceStore` 方法执行

## 5. 验收

- [x] 5.1 `cargo test` 全绿（无 Rust 变更，确认不影响）
- [x] 5.2 macOS 端 `xcodebuild` 编译通过
- [ ] 5.3 手动验收：
  - 右键终端标签 → 菜单展示 5 项（重连 + 分隔线 + 关闭三项），图标/快捷键正确
  - 右键 SFTP 标签 → 菜单展示 3 项（关闭三项），无重连
  - 「重连」触发终端重连
  - 「关闭其他标签页」关闭其他标签
  - 「关闭全部标签页」关闭全部标签
  - iPadOS 长按标签 → 菜单条目与 macOS 一致（无快捷键）

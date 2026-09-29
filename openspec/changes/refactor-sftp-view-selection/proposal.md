# Proposal: SFTP 视图选择重构

> 创建日期：2026-09-28｜提案类型：重构（UI 交互层）｜范围：当前版本迁移收尾

## 背景

`SftpSessionStore`（`apple/PandaSSH/Workspace/SftpSessionStore.swift`）包含一组与 900+ 行 `SftpTabView` 深度耦合的选择属性和方法：

```swift
@Published var selectedLocalSet: Set<String> = []
@Published var selectedRemoteSet: Set<String> = []
@Published var isLocalMultiSelect: Bool = false
@Published var localAnchor: String?
// selectLocal/Remote、selectRange、toggleMultiSelect 等方法
```

原在 `migrate-business-logic-to-rust` Phase 4 任务 299-300 跟踪，标注为"待视图层重构为原生选择后再删除"。但这项工作本质是 SwiftUI 视图交互层重构（`List(selection:)` + 拖拽框选/Shift/Command 修饰键迁移），不属于"业务逻辑下沉 Rust"范畴，不应继续挂在 migrate 提案下。

## 问题

1. **代码冗余**：自定义 `selectedLocalSet`/`selectedRemoteSet` + `List(selection:)` 重复维护选择状态，二者需要同步
2. **复杂交互**：`SftpTabView` 900+ 行拖拽框选、Shift/Command 修饰键、右键菜单等逻辑与选择方法紧耦合，难以安全修改
3. **视图与状态混杂**：SftpSessionStore 同时承担导航状态和选择状态，违反单一职责
4. **已知缺陷**：右键菜单操作与当前选择集不同步（`improve-sftp-task-interactions` 任务 6.x 已识别）

## 目标

1. 用 SwiftUI `List(selection: Set<String>)` 原生绑定替换自定义选择属性和方法
2. 将拖拽框选、Shift/Command 修饰键、右键菜单交互迁移为 SwiftUI 原生手势
3. SftpSessionStore 瘦身为纯导航状态管理，消除所有选择相关属性和方法
4. 修复右键菜单与选择状态不同步的已知缺陷

## 非目标

- **不涉及 Rust 业务逻辑**：本次重构不改变任何传输、删除、连接的核心行为
- **不改变 FilePaneNavigator**：导航逻辑保持不变
- **不改变传输任务聚合**：TransferStore 的组级操作已由 `rust-sftp-task-aggregation` 收口，与本提案无关
- **不改变 TerminalSessionStore 或 ConnectionGate**：这两个已由 `migrate-business-logic-to-rust` Phase 4 收口

## 与其他提案的边界

| 提案 | 边界关系 |
|---|---|
| `migrate-business-logic-to-rust` | 从 Phase 4 拆出任务 299-300；migrate 其他 Phase 4 任务（TerminalSessionStore、ConnectionGate、pendingTofu）在批次B收口 |
| `rust-sftp-task-aggregation` | TransferStore 收口在批次B，本提案不涉及 |
| `improve-sftp-task-interactions` | 任务 6.x（右键选择修复）已识别同类问题，本提案在原生选择替换后一并解决 |

## 影响范围

- **文件**：`SftpSessionStore.swift`（瘦身为纯导航状态）、`SftpTabView.swift`（视图交互重构）、`FilePaneNavigator.swift`（选择绑定改造）、相关 XCTest
- **平台**：macOS + iPadOS 双端（共享源码，无 `#if os()` 分支）
- **行为**：选择、多选、范围选择、右键菜单、拖拽框选 — 这些是 UI 交互变更，核心业务逻辑不变

## 依赖与前置

前置：批次B（`migrate-business-logic-to-rust` Phase 4 其余任务、`rust-sftp-task-aggregation` Swift 收口、`improve-sftp-task-interactions` 类型化契约）全部完成。原因：批次B完成后 Swift 侧不再新增业务逻辑残留约束，本提案作为收尾的 UI 层重构。

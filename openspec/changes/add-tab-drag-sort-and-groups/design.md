## Context

当前页签栏（`UnifiedWorkspaceTabStrip`）以 `ForEach(workspace.tabs)` 线性渲染页签，顺序完全由 Rust 侧工作区管理器控制。Swift 侧 `WorkspaceStore` 通过 `syncFromFfi()` 同步页签列表，无排序或分组概念。

需要新增：
1. Swift 侧排序映射（不修改 Rust 侧顺序）
2. 分组数据结构和视觉呈现
3. 拖拽手势处理

## Goals / Non-Goals

**Goals:**
- 用户可通过拖拽改变页签显示顺序
- 用户可通过右键菜单创建/删除分组，将页签分配到分组
- 分组在视觉上聚集，有分隔标识
- 排序和分组仅会话内保持，不持久化

**Non-Goals:**
- 不修改 Rust 侧工作区管理器
- 不做持久化
- 不做自动分组
- 不支持跨窗口拖拽

## Decisions

### 决策 1：排序状态独立于 Rust 页签列表

**选择**：在 `WorkspaceStore` 中维护 `displayOrder: [UUID]` 数组，表示页签的显示顺序。Rust 侧 `tabs` 数组保持按打开时间的原始顺序不变。

**理由**：
- 避免修改 Rust FFI 接口，降低变更范围
- 排序是纯 UI 状态，不应污染业务层
- `displayOrder` 作为 `tabs` 的视图变换，渲染时按此顺序排列

**替代方案**：
- 在 Rust 侧添加 `reorder_tabs` 接口：增加 FFI 复杂度，且排序不需要持久化，不值得
- 直接用 `tabs` 数组排序：会破坏 Rust 侧顺序管理，影响其他依赖顺序的逻辑

### 决策 2：分组数据结构

**选择**：
```swift
struct TabGroup: Identifiable, Equatable {
    let id: UUID
    var name: String
    var tabIDs: [UUID]  // 有序，组内页签顺序
}

// WorkspaceStore 新增
@Published private(set) var groups: [TabGroup] = []
@Published private(set) var ungroupedTabIDs: [UUID] = []
```

**理由**：
- 分组是纯 Swift 侧概念，与 Rust 无关
- `tabIDs` 有序支持组内拖拽排序
- `ungroupedTabIDs` 显式管理未分组页签，便于渲染

**替代方案**：
- 在 `WorkspaceTab` 上添加 `groupID: UUID?`：查询分组需遍历所有页签，不如显式分组结构清晰
- 使用字典 `[UUID: [UUID]]` 映射：丢失分组元数据（名称、ID）

### 决策 3：拖拽实现方式

**选择**：macOS 和 iPadOS 均使用 SwiftUI 原生 `.onDrag` / `.onDrop` API，配合 `NSItemProvider` 传递页签 ID。

**理由**：
- 跨平台一致，代码复用度高
- SwiftUI 原生支持，无需 AppKit/UIKit 桥接
- 自动处理拖拽视觉反馈

**替代方案**：
- `DragGesture` 手动实现：需自行处理拖拽视觉、命中测试、动画，复杂度高
- `Transferable` 协议（iOS 16+/macOS 13+）：更现代，但需定义 `Codable` 传输类型，对简单 UUID 传递略显过度

### 决策 4：渲染顺序计算

**选择**：计算属性 `displayedTabs: [WorkspaceTab]` 按分组和排序生成最终渲染列表：
1. 按 `groups` 顺序，每组内按 `tabIDs` 顺序输出页签
2. 最后输出 `ungroupedTabIDs` 对应的页签

**理由**：
- 单一数据源（`displayOrder` + `groups`），渲染逻辑简单
- 分组和排序统一在一个计算属性中处理

### 决策 5：右键菜单扩展

**选择**：在 `TabContextMenuBuilder` 中新增分组相关菜单项：
- 新建分组
- 移动到分组 > (子菜单列出所有分组)
- 未分组
- 删除分组（当页签所在分组时显示）

**理由**：
- 复用现有右键菜单架构
- 分组操作放在右键菜单符合用户预期

### 决策 6：macOS 窗口拖动区域与页签命中区隔离

**选择**：窗口拖动能力仅附着在顶部 chrome 的显式空白区域；页签栏和侧栏按钮不得继承覆盖整个 chrome 的 `WindowDragView` 背景。

**理由**：`mouseDownCanMoveWindow` 在 AppKit 的鼠标按下阶段生效，覆盖页签栏时可能先于 SwiftUI `.onDrag` 接管拖动，导致用户拖页签时移动窗口。将两个命中区域拆开可使页签拖放直接接收事件，同时保留空白标题栏区域的窗口拖动。

**替代方案**：在页签栏背景中放置 `mouseDownCanMoveWindow == false` 的透明拦截视图。已排除：背景不保证成为页签点击时的命中视图，不能可靠改变窗口拖动判定。

## Risks / Trade-offs

**[风险] 拖拽与现有滚轮/浏览按钮交互冲突**
→ 缓解：拖拽仅在长按后触发，短按仍为选择操作；拖拽过程中禁用浏览按钮

**[风险] 排序映射与 Rust 侧页签列表不同步**
→ 缓解：新增/关闭页签时，`syncFromFfi()` 后需更新 `displayOrder`：新页签追加到末尾，关闭页签从映射中移除

**[权衡] 不持久化排序/分组**
→ 接受：用户每次启动需重新组织，但简化了实现，避免 Rust 侧数据模型变更

**[风险] 分组视觉分隔在页签过多时可能不明显**
→ 缓解：使用背景色块区分分组，而非仅依赖分隔线；分组标签使用醒目样式

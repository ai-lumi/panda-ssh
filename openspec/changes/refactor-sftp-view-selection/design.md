# Design: SFTP 视图选择重构

## 1. 整体方案

### 1.1 选择状态从 Store 迁移到 View

当前架构：
```
SftpSessionStore.selectedLocalSet (Published) → SftpTabView 绑定
SftpSessionStore.selectedRemoteSet (Published) → SftpTabView 绑定
```

目标架构：
```swift
// SftpSessionStore 不再包含选择属性
struct SftpSessionStore {
    // 仅保留导航状态：当前路径、刷新标记等
}

// SftpTabView 内部用 @State 管理选择
struct SftpTabView: View {
    @State private var localSelection: Set<String> = []
    @State private var remoteSelection: Set<String> = []
    
    var body: some View {
        // List(selection:) 原生绑定
        List(localFiles, selection: $localSelection) { ... }
        List(remoteFiles, selection: $remoteSelection) { ... }
    }
}
```

选择状态从 Store 层的 `@Published` 变为 View 层的 `@State`，因为选择是纯视图交互状态，不应跨 View 生命周期持久化或被其他 View 观察。

### 1.2 选择变化的事件通知

当前：通过 `@Published var selectedLocalSet` 的 `didSet` 触发传输注册等副作用。

改造后：在 `List(selection:)` 的 `.onChange` 中执行副作用注册：

```swift
.onChange(of: localSelection) { newSelection in
    // 注册传输候选项、更新右键菜单状态等
}
```

### 1.3 多选与范围选择

SwiftUI `List(selection:)` 原生支持：
- Command 点击：追加/移除单个条目
- Shift 点击：从 anchor 到当前条目的范围选择

但 SwiftUI 不自动维护 anchor，需要手动实现：

```swift
@State private var localAnchor: String?

func handleLocalShiftClick(_ item: String) {
    guard let anchor = localAnchor else { return }
    // 计算 anchor → item 的所有条目，全部加入选择集
}
```

### 1.4 拖拽框选

SwiftUI 原生不支持拖拽框选（按住鼠标拖拽覆盖多个条目）。方案：

```swift
List { ... }
    .overlay(
        DragGesture()
            .onChanged { value in
                // 计算拖拽矩形覆盖的条目
                dragSelectionRect = value.translation
            }
            .onEnded { value in
                // 将覆盖条目加入选择集
                localSelection = dragSelectionItems
                dragSelectionRect = nil
            }
    )
```

拖拽框选是 macOS 特有交互，iPadOS 不需要。用 `#if os(macOS)` 包裹。

### 1.5 右键菜单与选择同步

当前已知问题：右键菜单展示时，当前点击的条目可能不在选择集中，导致菜单操作作用于错误条目。

修复方案（复用 `improve-sftp-task-interactions` 任务 6.x 的设计）：

```swift
.contextMenu(forSelectionType: String.self, menu: { selectedItems in
    // 菜单操作基于 selectedItems（当前 List.selection）
}) { item in
    // 确保右键点击的条目在选择集中
    if !localSelection.contains(item) {
        localSelection = [item]
    }
}
```

SwiftUI `.contextMenu(forSelectionType:)` 原生支持基于选择集的菜单，替代当前自定义的 `NSMenu` 桥接。

## 2. 逐步迁移策略

分三阶段，每阶段独立可回滚：

| 阶段 | 内容 | 验证 |
|---|---|---|
| 1. 本地栏原生选择 | `selectedLocalSet` → `@State localSelection`；`List(selection:)`；Command/Shift 修饰键 | 编译通过；本地栏选择、多选、范围选择正常 |
| 2. 远程栏原生选择 | 同上，远程栏 | 同上 |
| 3. 拖拽框选 + 右键菜单 | macOS 拖拽框选手势；`.contextMenu(forSelectionType:)` | 框选、右键菜单与选择同步正常 |

## 3. 移除清单

迁移完成后，从 SftpSessionStore 删除：

| 属性/方法 | 当前位置 | 迁移后位置 |
|---|---|---|
| `selectedLocalSet` | SftpSessionStore.swift:650 | SftpTabView `@State localSelection` |
| `selectedRemoteSet` | SftpSessionStore.swift:656 | SftpTabView `@State remoteSelection` |
| `selectedLocal` | SftpSessionStore.swift:660 | 直接访问 `localSelection.first` |
| `selectedRemote` | SftpSessionStore.swift:664 | 直接访问 `remoteSelection.first` |
| `isLocalMultiSelect` | SftpSessionStore.swift:668 | 删除（SwiftUI List 自动支持）|
| `isRemoteMultiSelect` | SftpSessionStore.swift:674 | 删除 |
| `localAnchor` | SftpSessionStore.swift:678 | SftpTabView `@State localAnchor` |
| `selectLocal/Remote` | SftpSessionStore.swift | 删除（List(selection:) 自动处理）|
| `selectRange` | SftpSessionStore.swift | 迁移到 SftpTabView 内部 |
| `toggleMultiSelect` | SftpSessionStore.swift | 删除（List(selection:) 自动处理）|

## 4. 与 migrate 提案的拆分

原 migrate-business-logic-to-rust Phase 4 任务 299-300：

- 299：`SftpSessionStore` 选择逻辑 — 删除（移至本提案）
- 300：SFTP 视图改用 `List(selection:)` 原生选择 — 删除（移至本提案）

migrate Phase 4 完成后（批次B），这两项从 migrate tasks.md 移除，改为本提案跟踪。

## 5. SftpSessionStore 逻辑分类与归属

SftpSessionStore 实际包含三类逻辑，本提案仅覆盖第一类：

### 5.1 纯 UI 选择状态（本提案处理）

| 属性/方法 | 说明 | 迁移后位置 |
|---|---|---|
| `selectedLocalSet` | 本地栏选中集合 | SftpTabView `@State localSelection` |
| `selectedRemoteSet` | 远程栏选中集合 | SftpTabView `@State remoteSelection` |
| `localAnchor`/`remoteAnchor` | Shift 范围选择锚点 | SftpTabView `@State` |
| `selectLocal/Remote` | 点击选择 | 删除（List(selection:) 自动处理）|
| `selectRange`/`appendRange` | 范围选择 | 迁移到 SftpTabView 内部 |
| `toggleLocal/RemoteMultiSelect` | 多选开关 | 删除（List 自动支持）|

**这些是纯 SwiftUI 视图层状态**，不含业务决策，必须留在 Swift。

### 5.2 业务路由/编排（migrate 提案处理，本提案不处理）

以下方法包含业务决策分支（如"双击文件→上传/双击目录→进入"、"多选→批量/目录→目录上传/单文件→覆盖确认"），按 AGENTS.md"业务逻辑只在 panda-core"应下沉 Rust：

| 方法 | 业务决策 | 归属 |
|---|---|---|
| `doubleClickLocal` | 目录→进入，文件→上传 | migrate-business-logic-to-rust Phase 4.5 |
| `doubleClickRemote` | 目录→进入，文件→下载 | 同上 |
| `contextUpload` | 未选中→选中再上传，已选中→直接上传 | 同上 |
| `contextDownload` | 同上 | 同上 |
| `uploadSelected` | 多选→批量上传，目录→目录上传，单文件→覆盖确认 | 同上 |
| `downloadSelected` | 同上（下载方向）| 同上 |
| `deleteLocalBatch`/`deleteRemoteBatch` | 批量删除路由 | 同上 |
| `resolveBatchConflict`/`resolveConflict` | 冲突决策回传 | 同上 |

**这些方法在本提案期间保持不变**，选择状态迁移后它们仍能正常工作（只是数据源从 `@Published Set` 变成 `@State Set`，调用方式不变）。migrate 提案批次B完成后，这些方法下沉 Rust，Swift 侧退化为单一 FFI 入口调用。

### 5.3 已委托 Rust 的（无需处理）

| 方法 | FFI 入口 |
|---|---|
| `scanLocalItems` | `scanLocalBatch` |
| `scanRemoteItems` | `scanRemoteBatch` |
| `runOrchestration` | `orchestrateSftpTransfers` |

这些已经是正确的 FFI 桥接模式。Swift 侧的参数组装（如 `upload(localPaths:)` 中的路径拼接、`BatchItemRecord` 转换）可随 migrate 提案 Phase 4.5 一并下沉。

### 5.4 边界总结

```
SftpSessionStore 逻辑边界：

┌─────────────────────────────────────────────────────┐
│  本提案（批次C）：SwiftUI 视图选择重构                  │
│  ✓ selectedLocalSet/RemoteSet → List(selection:)     │
│  ✓ selectLocal/Remote/Range → SwiftUI 原生手势       │
│  ✗ 不处理：业务路由方法 doubleClick/uploadSelected...  │
├─────────────────────────────────────────────────────┤
│  migrate 提案 Phase 4.5（批次B 扩展）：业务路由下沉     │
│  ✓ doubleClickLocal/Remote → Rust 路由决策           │
│  ✓ uploadSelected/downloadSelected → Rust 路由决策   │
│  ✓ deleteBatch → Rust 路由决策                       │
│  ✓ resolveConflict → Rust 决策协议                   │
│  ✗ 不处理：纯 UI 选择状态（已由本提案处理）             │
└─────────────────────────────────────────────────────┘
```

两个提案解耦：本提案先完成选择状态迁移，migrate Phase 4.5 再完成业务路由下沉。二者独立可验证，不阻塞彼此。

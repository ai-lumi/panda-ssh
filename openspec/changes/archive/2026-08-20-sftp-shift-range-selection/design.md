## Context

当前 SFTP 文件栏的选中模型位于 `SftpSessionStore`：
- `selectedLocalSet` / `selectedRemoteSet` 保存当前选中条目名集合。
- `isLocalMultiSelect` / `isRemoteMultiSelect` 控制是否显示复选框。
- `selectLocal(_:append:)` / `selectRemote(_:append:)` 处理单点与追加切换。
- `SftpTabView.handleRowTap` 通过 `isCommandKeyPressed` 检测 ⌘ 键，并决定是替换还是追加。
- macOS 端已支持拖拽框选（`DragGesture` + `FileRowFrameKey`）。

范围选择需要引入一个与桌面文件管理器一致的“anchor/pivot”概念，并在点击手势中识别 Shift 修饰键。

## Goals / Non-Goals

**Goals:**
- 实现 Shift+单击范围选择，替换当前选中集合。
- 实现 ⌘+Shift+单击范围追加。
- 保持现有单点、⌘+多选、拖拽框选行为不变。
- 目录切换后自动清除 anchor，避免跨目录意外范围选择。
- 通过 XCTest 覆盖范围选择核心路径。

**Non-Goals:**
- 不修改批量传输、递归扫描、任务分组等业务逻辑；范围选择只改变哪些条目被选中。
- 不实现键盘方向键 + Shift、Cmd+A 全选、触摸板手势等扩展选择方式。
- 不修改 Rust 核心或 FFI。

## Decisions

### 1. Anchor 保存在 `SftpSessionStore` 而非 `SftpTabView`

**选择**：在 `SftpSessionStore` 增加 `localAnchor: String?` / `remoteAnchor: String?`。

**理由**：
- Anchor 是选中模型的语义扩展，与 `selectedLocalSet` 生命周期一致（都需要在目录切换时清除）。
- 放在模型层便于单元测试直接验证，无需构造视图。
- 视图层只负责检测修饰键并调用 `selectLocalRange(from:to:)` / `selectRemoteRange(from:to:)`。

**替代方案**：用 `@State` 保存在 `SftpTabView`。被拒绝，因为视图状态难以测试，且目录切换清除逻辑需要与模型同步。

### 2. Shift+单击替换集合，⌘+Shift+单击追加集合

**选择**：Shift+单击 = 选中 `[anchor, target]` 范围并替换；⌘+Shift+单击 = 将范围并集加入当前集合。

**理由**：
- 与 macOS Finder、Windows 资源管理器、VS Code 文件树行为一致，降低用户学习成本。
- 追加模式允许用户先 ⌘ 点选若干不连续项，再用 ⌘+Shift 补充连续块。

### 3. 范围选择后自动开启多选模式

**选择**：`selectLocalRange` / `selectRemoteRange` 内部设置 `isLocalMultiSelect = true` / `isRemoteMultiSelect = true`。

**理由**：
- 选中多项后用户需要复选框反馈，否则无法直观区分范围选择是否生效。
- 与现有显式多选模式共用同一 UI，不引入新视觉元素。

**风险**：若用户 Shift+误触后希望立即单选，需要再点一次单选按钮或单击一个条目。该行为与 Finder 一致，可接受。

### 4. 目录切换清除 anchor 与选中集合

**选择**：`enterLocal` / `goUpLocal` / `navigateLocal` 等路径变更方法在清除 `selectedLocalSet` 同时清除 `localAnchor`。

**理由**：
- Anchor 只在当前目录列表内有意义；跨目录范围选择没有意义且容易误选。
- 与现有“进入目录清除选中集合”行为保持一致。

### 5. 使用 `NSApp.currentEvent?.modifierFlags` 检测 Shift

**选择**：在 `SftpTabView` 中复用现有的 `isCommandKeyPressed` 模式，新增 `isShiftKeyPressed`。

**理由**：
- 项目已有 `isCommandKeyPressed` 基于 `NSApp.currentEvent?.modifierFlags` 工作，证明该机制在 SwiftUI `onTapGesture` 中可用。
- iPadOS 无此修饰键时返回 `false`，行为自然回退为单选；外接键盘的 iPadOS 则可使用 Shift。

**风险**：`NSApp.currentEvent` 在极端并发手势中可能不是当前手势的事件，但实践中点击手势与当前事件匹配度高。若后续发现不可靠，可迁移到 `NSEvent.addLocalMonitorForEventsMatchingMask` 在 SwiftUI 外层维护修饰键状态。

## Risks / Trade-offs

- **[Risk]** 现有测试依赖 `selectLocal(_:append:)` 的签名与行为；新增 anchor 逻辑可能导致部分现有测试需要更新。  
  **Mitigation**：保持 `selectLocal` / `selectRemote` 默认行为不变，anchor 更新作为副作用；更新受影响的断言而非接口。

- **[Risk]** Shift+单击与双击进入目录的手势可能冲突。  
  **Mitigation**：Shift+单击只在目标为文件时执行范围选择；若目标为目录，仍按现有逻辑处理（单选/进入）。

- **[Risk]** 拖拽框选与 anchor 概念不一致（框选不产生明确的单一条目 anchor）。  
  **Mitigation**：框选结束后将 anchor 设为框选范围内第一个条目（按列表顺序），使用户后续 Shift+单击可扩展选择；在 spec 中声明该行为。

- **[Trade-off]** iPadOS 纯触屏无法使用 Shift。  
  **Mitigation**：保留拖拽框选与显式多选模式；后续可单独规划触屏范围选择手势。

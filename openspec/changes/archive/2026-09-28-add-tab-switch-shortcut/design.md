## Context

当前 Panda SSH 工作区支持多页签操作，用户通过点击页签标题切换活动页签。本次变更在 SwiftUI 视图层添加键盘事件监听，实现 `Ctrl+Tab` 和 `Ctrl+Shift+Tab` 快捷键切换页签。此功能纯属 UI 交互层，不涉及 Rust 核心或 FFI 层。

## Goals / Non-Goals

**Goals:**
- 在 SSH 终端和 SFTP 文件浏览器内容区域获得焦点时，响应 `Ctrl+Tab` 和 `Ctrl+Shift+Tab` 快捷键。
- 实现循环切换逻辑：到达末尾后回到开头，反之亦然。
- 确保快捷键仅在内容区域获得焦点时生效，不影响侧栏、页签栏等其他区域。
- 同时支持 macOS 和 iPadOS（外接键盘）。

**Non-Goals:**
- 不实现自定义快捷键绑定。
- 不实现页签预览浮层或快速跳转面板。
- 不改变现有页签点击切换行为。

## Decisions

### 决策 1：使用 SwiftUI `.onKeyPress` 修饰符

**选择**：在页签内容视图（终端视图、SFTP 视图）上使用 SwiftUI 的 `.onKeyPress` 修饰符监听键盘事件。

**理由**：
- `.onKeyPress` 是 SwiftUI 原生键盘事件处理方式，支持 macOS 14+ 和 iPadOS 17+，与项目最低系统要求一致。
- 相比 `NSEvent` 监听器或 `UIKey` 处理，`.onKeyPress` 跨平台统一，无需条件编译。
- 可以精确控制焦点范围，只在内容区域获得焦点时触发。

**替代方案**：
- 使用 `.keyboardShortcut`：适用于菜单项和按钮，不适合页签内容区域的全局监听。
- 使用 `NSEvent.addLocalMonitorForEvents`（macOS）：需要条件编译，iPadOS 不支持。

### 决策 2：在 WorkspaceView 层级统一处理

**选择**：在 `WorkspaceView` 或共享的内容容器视图上添加键盘监听，而非在每个终端/SFTP 视图内部独立处理。

**理由**：
- 页签切换是工作区级别的操作，由工作区统一管理更符合职责划分。
- 避免在每个内容视图类型中重复实现相同逻辑。
- 便于维护循环切换逻辑，因为工作区持有完整的页签列表。

### 决策 3：焦点条件通过 `.focusable()` 控制

**选择**：确保终端和 SFTP 内容视图是可聚焦的（`.focusable()`），通过焦点状态判断是否响应快捷键。

**理由**：
- SwiftUI 的 `.onKeyPress` 只在视图获得焦点时触发，天然满足「仅在内容区域焦点时生效」的需求。
- 无需额外的焦点状态判断逻辑。

## Risks / Trade-offs

**[风险] 终端视图捕获 Tab 键** → 缓解：终端本身可能需要 `Tab` 键输入（如 shell 自动补全）。需确保 `Ctrl+Tab` 与纯 `Tab` 键区分，`.onKeyPress` 的 `KeyEquivalent` 和修饰符参数可以精确匹配组合键。

**[风险] iPadOS 外接键盘兼容性** → 缓解：`.onKeyPress` 在 iPadOS 17+ 对外接键盘完整支持。需在真机测试验证 `Ctrl+Tab` 不与系统快捷键冲突。

**[权衡] 循环切换 vs 边界停止** → 选择循环切换，符合主流终端应用（如 VS Code、iTerm2）的用户预期。

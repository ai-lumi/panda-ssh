## Why

macOS 统一工作区顶部页签栏在页签总宽度超出可视区时，最右侧页签无法显示完整，且点击右侧尖括号或滚动鼠标也无法将其完全显露。该问题发生在 `ScrollViewProxy.scrollTo(_:anchor:)` 固定使用 `.leading` 时：目标偏移被近似为某个页签的前缘，当目标偏移接近内容右边界（如因右侧浏览按钮出现导致可视区变窄，或最右页签较宽）时，无法滚动到足够位置。

## What Changes

- 在 `TabStripViewportState` 中增加纯值滚动目标计算：`contentWidth(from:)` 包含 HStack 尾部 padding，`scrollTarget(for:among:)` 根据目标偏移与页签宽度返回归一化 `anchorX`。
- 在 `UnifiedWorkspaceTabStrip` 中使用自适应 anchor 替代固定的 `.leading`，使实际滚动结果逼近计算出的目标偏移。
- 补充 `TabStripViewportStateTests` 用例，覆盖宽页签 trailing、线性插值、窄页签 leading 与 contentWidth 计算。
- 在 `openspec/specs/unified-workspace-chrome/spec.md` 中补充“最右侧页签完整显露”场景。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `unified-workspace-chrome`：页签容器在滚动或浏览到最右侧时，必须将最右页签完整内容（含关闭按钮）显露在可视区内。

## Impact

- 受影响代码：`apple/PandaSSH/Workspace/TabStripViewportState.swift`、`apple/PandaSSH/Workspace/UnifiedWorkspaceTabStrip.swift` 与 `apple/PandaSSHTests/TabStripViewportStateTests.swift`。
- 仅影响 macOS 统一顶部页签栏的滚动/浏览行为；iPadOS 系统导航栏页签不受影响。
- 不修改 Rust 核心、FFI 公开接口、SSH/SFTP 业务逻辑、密钥处理或窗口 chrome 布局策略。

## Non-goals

- 不重新设计页签栏视觉样式。
- 不改改变更侧栏、窗口标题栏或传输任务入口的行为。

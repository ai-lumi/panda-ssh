## Context

见 proposal.md - Why。当前 macOS 将完整页签栏作为一个 principal toolbar item；工具栏会依据可用空间处理项的溢出，导致页签栏自己的 `NSScrollView` 和翻页按钮不再拥有可靠的宽度与事件路径。

## Goals / Non-Goals

**Goals:**

- 让系统工具栏只承担窗口 chrome，而页签滚动只由页签栏自身承担。
- 保持现有滚轮、按钮按页滚动和自动定位活动页签的算法。

**Non-Goals:**

- 不改变页签控件的视觉样式、设置项或 iPadOS 内容区页签栏。
- 不新增独立的 AppKit 工具栏委托实现。

## Decisions

### 页签栏置于 detail 内容区第一行

macOS detail 使用垂直布局：页签栏、分隔线、已有内容。系统工具栏仍存在于其上方，因此保持标题栏融合和系统侧栏按钮；页签栏不再参与工具栏溢出布局。

替代方案是继续使用 principal item 并扩大最小宽度。窗口宽度仍可能不足，且会与工具栏规则耦合，不能保证翻页按钮可点击，故不采用。

### 以真实工作区宿主测试翻页

测试以 `WorkspaceView` 加载多个页签，而非仅测试独立 `WorkspaceTabBar`，确认页签栏在 detail 内容区获得可滚动宽度，翻页控制器能移动和复位。

## Risks / Trade-offs

- [Risk] 页签栏从标题栏移至内容区，垂直位置会下降一个工具栏高度 → 这与当前 workspace 规格一致，并换取稳定可用的翻页。
- [Risk] macOS 26 标题栏融合回退 → 保留系统工具栏、侧栏与现有融合相关配置，并以 macOS 构建及布局回归测试验证。

## Migration Plan

无需数据迁移。若回退，只需恢复 principal toolbar item；但会重新引入工具栏溢出竞争。

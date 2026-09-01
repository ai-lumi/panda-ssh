## Why

macOS 页签栏的关闭控件只在 X 图标附近可靠地触发，控件视觉上的其余区域不能关闭标签页。这使视觉边界与交互边界不一致。

## What Changes

- 将 macOS 页签关闭控件明确绘制为圆角矩形，并让整个圆角矩形作为关闭动作的命中区域。
- 为关闭控件的形状和最小命中尺寸增加回归测试。

## Non-goals

- 不改变标签页的关闭确认、会话释放、iPadOS 行为或页签栏布局。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `workspace`: 页签关闭入口的可点击范围与其可见圆角矩形一致。

## Impact

- `apple/PandaSSH/Workspace/WorkspaceTabButton.swift`
- `apple/PandaSSH/Workspace/WorkspaceTabPresentationMetrics.swift`
- `apple/PandaSSHTests/WorkspaceTabPresentationMetricsTests.swift`

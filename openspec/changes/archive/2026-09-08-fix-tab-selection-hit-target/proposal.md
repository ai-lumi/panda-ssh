## Why

页签视觉胶囊的高度大于标题内容，但选择操作只在标题附近响应。用户点击页签的上下留白时无法切换，视觉边界与交互边界不一致。

## What Changes

- 让整个页签胶囊容器响应选择操作。
- 关闭按钮保持独立操作；点击它不得同时触发页签选择。
- 为父容器的手势子视图隔离规则增加回归测试。

## Non-goals

- 不改变关闭确认、会话释放、页签布局或关闭按钮尺寸。

## Impact

- `apple/PandaSSH/Workspace/WorkspaceTabButton.swift`
- `apple/PandaSSH/Workspace/WorkspaceView.swift`
- `apple/PandaSSH/Workspace/WorkspaceTabPresentationMetrics.swift`
- `apple/PandaSSHTests/WorkspaceTabPresentationMetricsTests.swift`

## Why

macOS 将自定义页签栏作为系统工具栏的 principal item 承载，页签溢出时会与工具栏自动注入的悬停/溢出控件竞争空间和事件，导致自定义翻页不可用。该行为也不符合工作区规格中“页签栏位于系统工具栏带下方、右上角无多余溢出按钮”的要求。

## What Changes

- 将 macOS 页签栏从 principal 工具栏项移至 detail 内容区顶部，保留系统工具栏带。
- 保持自定义左右翻页按钮和鼠标滚轮翻页语义，避免系统工具栏溢出控件参与页签滚动。
- 增加真实工作区布局下的翻页回归测试，覆盖正常翻页、窄宽度溢出和页签数量未溢出边界。

## Non-goals

- 不改变 iPadOS 页签栏、SFTP/终端会话生命周期或页签溢出模式的持久化规则。
- 不替换现有横向滚动与翻页算法。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `workspace`: 修正 macOS 页签栏与系统工具栏的布局关系，并确保滚动模式的翻页控件可用且不与系统溢出控件冲突。

## Impact

- 影响 `apple/PandaSSH/Workspace/WorkspaceView.swift` 的 macOS detail 布局和页签栏测试。
- macOS 的系统工具栏继续保留；iPadOS 行为不变。

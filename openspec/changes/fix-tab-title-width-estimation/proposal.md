## Why

页签标题使用「字符数 × 8 pt」估算最大宽度。中文字符的实际字形宽度大于该估算，导致短标题被错误截断，而加入序号后反而可能完整显示。

## What Changes

- 标题宽度不再按字符数缩小；所有标题共用 180 pt 的最大可用宽度。
- 标题超出 180 pt 时仍由 SwiftUI 按既有规则省略。
- 增加中文短标题与超长标题的回归测试。

## Non-goals

- 不改变页签栏溢出模式、滚动行为、标题消歧规则、关闭按钮或页签高度。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `workspace`: 页签标题 SHALL 以实际字体布局决定是否省略，不得因字符数估算而提前截断。

## Impact

- `apple/PandaSSH/Workspace/WorkspaceTabPresentationMetrics.swift`
- `apple/PandaSSHTests/WorkspaceTabPresentationMetricsTests.swift`

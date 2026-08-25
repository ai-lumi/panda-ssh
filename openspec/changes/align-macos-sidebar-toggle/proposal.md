## Why

macOS 侧栏显示时，「隐藏侧栏」按钮位于侧栏内容区；侧栏隐藏后，系统的「显示侧栏」按钮位于窗口标题栏。相同操作在两种状态下垂直位置跳变，破坏了窗口工具栏的连续性。

## What Changes

- 让 macOS 系统侧栏切换按钮在侧栏可见与隐藏时都保留在标题栏，由系统维持同一控件的状态动画。
- 将「添加主机」与「新建分组」也移入侧栏列的系统标题栏工具栏。
- 移除侧栏内容区内整条自绘工具条，搜索框保持在标题栏下方。

## Non-goals

- 不改变添加主机、新建分组、搜索或页签的行为。
- 不改变 iPadOS 的侧栏布局和系统导航栏入口。
- 不引入 AppKit 自定义标题栏、私有 API 或新的依赖。

## Capabilities

### New Capabilities

<!-- 无。 -->

### Modified Capabilities

- `workspace`: 统一 macOS 侧栏工具栏项的位置与显隐动画。

## Impact

- `apple/PandaSSH/SidebarView.swift`：将三项侧栏操作归入原生 toolbar，并删除内容内顶栏。
- `apple/PandaSSHTests/WorkspaceChromePolicyTests.swift`：补充纯状态策略测试（如现有结构可覆盖）。
- macOS 14+：标题栏内的侧栏显隐入口位置变化；iPadOS 无影响。

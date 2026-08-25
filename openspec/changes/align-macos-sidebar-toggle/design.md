## Context

见 proposal.md - Why。前一方案把可见状态的系统 `sidebarToggle` 移除，再创建应用自定义按钮；隐藏时系统重新插入其按钮。这会使 SwiftUI 在不同位置销毁、重建控件，造成横向漂移动画。`SidebarView` 还保留内容内的自绘添加与分组按钮。

## Goals / Non-Goals

**Goals:**

- 让同一个系统侧栏切换按钮连续处理两种侧栏状态。
- 让三个侧栏操作都位于同一条系统标题栏工具栏中。
- 保留 macOS 26 保留系统工具栏以获得侧栏融合的既有约束。
- 限定修改到 `SidebarView` 和可测的窗口状态策略。

**Non-Goals:**

- 不控制系统在侧栏隐藏时所绘制按钮的精确横坐标或外观。
- 不替换 `NavigationSplitView`，不修改 SSH、数据模型和 iPadOS 代码路径。

## Decisions

1. 不再移除 `NavigationSplitView` 的系统 `sidebarToggle`。
   - 原因：同一系统 toolbar item 能自行保持位置与状态动画，避免应用和系统交替提供按钮。
   - 替代：用应用 toolbar item 模拟隐藏按钮。否决：系统切换时会重建为不同位置的控件，已被实际验收否定。

2. 将添加主机、新建分组作为侧栏列的 `.toolbar` 项，并删除 `sidebarTopBar`。
   - 原因：三个操作统一由原生 toolbar 排版，符合 Xcode 侧栏的视觉结构；搜索内容无需为自绘顶栏预留高度。

3. 以 `WorkspaceChromePolicy` 的状态逻辑确认两个状态都不移除系统按钮，并以 macOS 真机/预览验证实际位置。

## Risks / Trade-offs

- [Risk] macOS 会依窗口宽度把工具栏项压缩或溢出 → Mitigation：保持既有侧栏最小宽度 220pt，并人工验证最小窗口宽度。
- [Risk] 原生 toolbar placement 在 macOS 小版本中改变横向排序 → Mitigation：验收以 Xcode 式同一标题栏行和稳定的系统显隐按钮为准，不依赖未承诺的横向像素位置。
- [Risk] `SidebarView.swift` 正被其他会话编辑 → Mitigation：只修改 macOS 顶栏/toolbar 的局部区块，先备份并在写入前复核差异。

## Migration Plan

1. 先写失败的状态策略测试。
2. 将添加、分组操作迁至侧栏列原生 toolbar，并停止移除系统显隐按钮。
3. 运行相关 XCTest 和 macOS 构建；在侧栏显示、隐藏及最小宽度下手动验收。
4. 回滚方式：恢复备份中该局部区块，并删除此次独立变更目录；不影响用户的其他未提交修改。

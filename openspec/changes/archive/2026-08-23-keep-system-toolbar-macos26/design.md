# Design: macOS 26 保留系统工具栏

## Context

见 proposal.md - Why。现行实现（`macos-workspace-layout-refactor` 决策 8）用 `MainWindowChrome` 把 `window.toolbar = nil`，在 macOS 14/15 上真机验证可融合；macOS 26 行为变化导致该方案失效。本次通过独立探针程序（swiftc 直接编译的最小复现 + 真包几何测量）逐一验证了各可行路径，结论如下。

## Goals / Non-Goals

- Goals：侧栏融入标题栏；无重复显隐按钮；spec 与实现一致。
- Non-goals：见 proposal.md - Non-goals（不消除工具栏带、不自绘分栏、不动 iPadOS）。

## Decisions

1. **保留系统工具栏，不再 `toolbar = nil`**
   - 实测：macOS 26 上窗口持有可见 `NSToolbar` 时，侧栏面板自动延伸到窗口顶部（内容 y=8，与红绿灯同行）；`toolbar = nil` 时面板被强制压在标题栏下方 32pt。
   - 实测：融合由工具栏项驱动——在 AppKit 层剔除 `toggleSidebar` 项后，面板立即掉回 y=52。因此「保留工具栏但剔除系统项」不可行。
   - Alternative：`toolbarVisibility(.hidden, for: .windowToolbar)`（macOS 15+）——实测 `isVisible` 仍为 true，不生效，否决。
   - Alternative：空 `NSToolbar` + `isVisible = false`——实测几何等同无工具栏（面板压回 32pt），否决。

2. **侧栏列 `ignoresSafeArea(.container, edges: .top)`**
   - 配合可见工具栏，使侧栏内容顶到面板顶部（y=8）。这是唯一需要的 SwiftUI 布局改动。

3. **detail 列不做 ignoresSafeArea**
   - 实测：工具栏带由 AppKit 绘制在内容上层，detail 内容顶到 y=0 只会被带子遮住（页签栏不可见）。因此页签栏保持在带子下方。
   - Alternative：detail 卡片化（圆角材质容器）——已做实验并被否决（观感更差，已回滚）。

4. **移除自绘「显示侧栏」按钮**
   - 侧栏隐藏时系统切换按钮自动出现在标题栏（红绿灯右侧），自绘按钮与之重复且上下错位；隐藏按钮仍保留在侧栏顶条（侧栏可见时系统按钮不出现）。

5. **不采用负 padding 手工补偿 / 不改 AppKit 私有视图 frame**
   - 手工补偿（按实测位置动态上抬内容）会把内容抬出面板裁剪区（按钮消失）；强制改 `NSContainerConcentricGlassEffectView` 的 frame 会被系统布局反复重置（实测 7 秒 33 次拉锯并误伤列表视图）。两者均否决。

## Risks / Trade-offs

- **[Risk]** detail 区顶部的工具栏带被用户视为瑕疵 → **Mitigation**：spec 明确其为接受行为；备选（页签栏改为工具栏项/完全自绘分栏）成本高且历史上已两次放弃。
- **[Risk]** macOS 未来版本再次改变面板行为 → **Mitigation**：本设计只依赖公开机制（工具栏存在性 + safe area），不写死尺寸数值。
- **[Risk]** 系统切换按钮样式不可定制 → **Mitigation**：接受系统样式，与其余 macOS 应用一致。

## Migration Plan

代码已先行实现并验收（提交 `c4b1fbd`、`1478d86`），本变更仅同步 spec：归档时把 delta 合并回 `openspec/specs/workspace/spec.md` 的「主窗口工具栏精简」需求。回滚策略：恢复 `MainWindowChrome` 的 `toolbar = nil`（需同时恢复持续置 nil 的 KVO 逻辑）并回退 spec。

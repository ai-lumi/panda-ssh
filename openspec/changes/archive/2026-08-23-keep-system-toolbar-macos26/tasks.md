## 1. 实现（已先行完成并验收）

- [x] 1.1 `MainWindowChrome`：移除 `toolbar = nil` 及 KVO 防重建逻辑，保留系统工具栏（隐藏标题文字/透明标题栏/fullSizeContentView 不变）
- [x] 1.2 `SidebarView`：macOS 侧栏列加 `.ignoresSafeArea(.container, edges: .top)`，顶条按钮融入标题栏与红绿灯同一水平线
- [x] 1.3 `WorkspaceView`：移除自绘「显示侧栏」按钮（detailOnly 分支），显隐统一由系统切换按钮负责
- [x] 1.4 真机验收：侧栏融合、隐藏/显示侧栏无重复按钮、detail 工具栏带存在、页签栏正常
- [x] 1.5 实验并否决 detail 卡片化方案（观感更差，已回滚）

## 2. spec 同步（本变更主体）

- [x] 2.1 创建变更提案（proposal/design/spec delta/tasks）
- [x] 2.2 将 delta 合并回 `openspec/specs/workspace/spec.md`「主窗口工具栏精简」需求（用 sync-specs 工作流）
- [x] 2.3 归档本变更

## 3. 回归验证

- [x] 3.1 `xcodebuild -scheme PandaSSH-macOS test`：348 个测试全绿
- [x] 3.2 `xcodebuild -scheme PandaSSH-iOS test`（模拟器）：312 个测试全绿，iPadOS 添加入口截图确认

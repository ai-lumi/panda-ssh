## 1. 测试与状态策略

- [x] 1.1 先在 `WorkspaceChromePolicyTests` 写失败测试：macOS 侧栏可见、隐藏及 iPadOS 状态下都不移除系统侧栏按钮。
- [x] 1.2 以最小纯值策略实现测试所需的系统按钮保留规则。

## 2. macOS 侧栏标题栏对齐

- [x] 2.1 修改 `WorkspaceView`：不再移除 macOS 系统侧栏切换按钮。
- [x] 2.2 修改 `SidebarView`：将「添加主机」与「新建分组」移至侧栏列原生 toolbar，并移除整条内容内自绘顶栏；不改 iPadOS 分支。

## 3. 验证

- [x] 3.1 运行 `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS test`，确认相关 XCTest 通过。
- [ ] 3.2 运行 Swift 覆盖率检查，确认 lines 与 regions 均不低于 95%。
- [ ] 3.3 在 macOS 预览/应用中验证：侧栏可见时隐藏按钮位于标题栏；隐藏时系统按钮位于标题栏；最小侧栏宽度无重复或 `>>` 溢出按钮；iPadOS 无视觉回归。

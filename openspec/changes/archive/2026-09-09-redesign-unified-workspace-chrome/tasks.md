## 1. 共享状态与视觉契约

- [x] 1.1 先为共享 workspace shell/viewport 编写失败测试：覆盖正常多页签、无效尺寸或空页签等意外输入、零页签/大量页签边界；验证页签顺序、活动状态、边界夹取和显露规则不依赖平台。
- [x] 1.2 实现无条件编译的共享 `TabStripViewportState`、输入归一化和 `WorkspaceShell` 内容契约；禁止修改或删除旧页签栏实现。
- [x] 1.3 先编写条件编译边界测试/静态检查：覆盖 macOS 安全矩形、iPadOS 安全区入口和不允许业务逻辑分叉的异常场景。
- [x] 1.4 建立薄平台适配接口；将窗口控件、拖拽、安全区与系统导航限定在适配层，并记录每个新增 `#if os()` 的 UI/平台服务理由。

## 2. 独立页签栏与统一顶部 chrome

- [x] 2.1 先编写页签容器失败测试：覆盖鼠标离散步进的正常流程、混合/缺失滚轮 delta 的意外输入、触控板连续/惯性与首尾边界；验证浏览页签栏不切换会话。
- [x] 2.2 实现共享独立页签栏 UI，统一调用 viewport 状态来处理按钮、滚动与活动页签显露；补齐 macOS 鼠标滚轮到共享输入的薄桥接。
- [x] 2.3 先编写 workspace 顶部 chrome 失败测试：覆盖侧栏展开、侧栏隐藏的恢复入口、窄窗口与全屏边界；验证侧栏工具区和页签栏不重叠且 detail 不重复显示页签栏。
- [x] 2.4 实现共享顶部 chrome 排布与 macOS/iPadOS 展示适配，确保页面业务内容不通过平台条件编译分叉，且侧栏不被标题栏安全区二次下推。

## 3. macOS shell、iPadOS 适配与回退

- [x] 3.1 先编写 macOS XCTest：覆盖透明标题栏下的正常窗口、最小宽度/全屏等意外状态、红绿灯/拖拽/侧栏隐藏边界；验证工作区安全矩形和可访问恢复入口。
- [x] 3.2 先为 AppKit `NSSplitViewController` 宿主的收起/恢复、列宽边界与 hosting 更新编写失败测试；再实现其与 full-size 内容窗口、空白拖拽区的装配。不得使用 principal toolbar item 承载页签栏，并显式保持原生红绿灯可见。
- [x] 3.3 先编写 iPadOS XCTest：覆盖正常安全区/导航入口、旋转或紧凑宽度意外布局、零页签与大量页签边界；验证与 macOS 共享同一会话和页签规则。
- [x] 3.4 实现 iPadOS 薄适配，并保持其原生导航和安全区体验。
- [x] 3.5 先编写新旧路径切换失败测试：覆盖新 shell 正常启用、显式禁用/宿主不可用回退、反复切换边界；验证终端/SFTP 会话、顺序、活动状态和关闭确认不变。
- [x] 3.6 实现装配策略：新 shell 通过验证后设为默认，旧 `WorkspaceTabBar`/内容区路径完整保留且可回退。

## 4. 验收

- [x] 4.1 运行 macOS 与 iPadOS 的工作区 UI 回归、窗口缩放/侧栏/全屏/输入设备人工验证，并检查新路径没有重复顶部 chrome。
- [x] 4.2 运行 `cargo test`、`cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`、受影响 Swift tests、macOS/iPadOS 构建和 `openspec validate redesign-unified-workspace-chrome --strict`；确认 lines 与 regions 均不低于 95%。

## 完成记录

2026-09-09：用户 UI 验收通过，实现与自动验证完成；详细结果及 Swift 覆盖率未计算的边界见 verification.md。旧版清理由 remove-legacy-workspace-ui 完成。

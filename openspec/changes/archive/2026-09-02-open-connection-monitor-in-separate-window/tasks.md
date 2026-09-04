## 1. 独立窗口导航

- [x] 1.1 先修改 Swift XCTest：正常流程覆盖 macOS 从主机/终端工作区请求连接监控时保持主窗口状态、iPadOS 进入工作区监控页；意外操作覆盖重复请求不改变既有选择；边界条件覆盖空选择与无标签状态。
- [x] 1.2 在 macOS 注册稳定 ID 的连接监控 Window Scene，并将侧栏入口改为优先激活已有窗口、否则打开新窗口；iPadOS 保留工作区页面入口，监控 View 与数据逻辑保持共享。

## 2. 验证与规格收尾

- [x] 2.1 运行聚焦 Swift XCTest 与 macOS/iPadOS 全量 XCTest，确认主窗口不被覆盖、双平台导航策略及现有监控 Store 行为通过。
- [x] 2.2 运行 `cargo test`、`cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95`，并按既有顺序重建 Rust 绑定、XcodeGen 工程及 macOS/iOS 构建；所有硬门禁必须通过。
- [x] 2.3 运行 `openspec validate open-connection-monitor-in-separate-window --strict`，完成后归档并合并 workspace spec delta。

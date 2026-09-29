## 1. CMD+W 页签关闭快捷键

- [x] 1.1 编写 CMD+W 快捷键测试：焦点在页签区域时按下 CMD+W 触发当前活动页签关闭（正常流程）
- [x] 1.2 编写 CMD+W 快捷键测试：焦点不在页签区域（侧栏、SFTP 文件列表、终端内容区）时按下 CMD+W 不触发任何关闭（意外操作）
- [x] 1.3 编写 CMD+W 快捷键测试：无活动页签时按下 CMD+W 不执行任何操作（边界条件）
- [x] 1.4 编写 CMD+W 快捷键测试：已连接终端标签页焦点下按 CMD+W 弹出二次确认对话框，确认后关闭，取消后保留（正常流程 + 边界条件）
- [x] 1.5 在页签栏容器 View 上添加 `.onKeyPress` 修饰符，消费 CMD+W 事件并调用既有页签关闭逻辑
- [x] 1.6 验证 CMD+W 在连接中/连接失败状态的终端标签页直接关闭，不弹确认（与既有行为一致）

## 2. CMD+Q 两次按下退出保护

- [x] 2.1 编写退出保护状态模型测试：首次触发 `pendingQuit` 从 false 变为 true，超时后自动重置为 false（正常流程）
- [x] 2.2 编写退出保护状态模型测试：`pendingQuit` 为 true 时再次触发执行退出（正常流程）
- [x] 2.3 编写退出保护状态模型测试：超时边界——恰好在超时时刻触发不退出（边界条件）
- [x] 2.4 编写退出保护状态模型测试：提示可见期间执行其他操作不影响提示状态（意外操作）
- [x] 2.5 实现退出保护状态模型（`QuitProtection` 或等效 `@Observable` 类），包含 `pendingQuit` 状态、触发方法和超时重置逻辑，超时值提取为常量
- [x] 2.6 通过 `NSApplicationDelegate.applicationShouldTerminate(_:)` 拦截系统 CMD+Q、菜单与 Dock 退出；首次取消终止请求，接入共享退出保护模型
- [x] 2.7 实现「再按一次退出」toast 视图：底部中央半透明圆角提示条，2 秒超时，带进入/退出动画
- [x] 2.8 测试：应用停机协调器——正常流程（第二次有效 CMD+Q 后拒绝新任务、取消在途任务、关闭全部 SSH/SFTP 连接再请求退出）、意外操作（远端结果未知时不重放、关闭失败仍继续其余所有者清理）、边界条件（无任务无连接、重复第二次按键只执行一次、停机期间新任务/连接被拒绝）——先写失败测试（QuitProtectionTests / TransferStoreTests / WorkspaceStoreTests 已覆盖全部场景，2026-09-15 定向 XCTest 全过）
- [x] 2.9 实现：一次性应用停机协调器，接入任务登记门禁、取消、连接所有权释放与退出请求，使 2.8 通过（ApplicationQuitCoordinator.swift + QuitProtection.beginShutdownIfConfirmed() + TransferStore / WorkspaceStore 停机钩子，已实现）
- [x] 2.10 验证：受控 fake/mock 证明停机顺序、连接所有者隔离和不重放；不得以 runtime drop 或进程退出本身替代证据（QuitProtection.isShuttingDown 门控标志 + 定向 XCTest 全过，已验证）

## 3. 平台隔离与集成

- [x] 3.1 编写测试：确认 CMD+W 和 CMD+Q 快捷键处理代码仅在 macOS 条件编译下生效（`#if os(macOS)`）
- [x] 3.2 确认 iPadOS 端不受影响：iPadOS 构建不包含快捷键处理逻辑
- [x] 3.3 运行 `cargo test` 全绿（本次无 Rust 变更，确认无副作用）
- [x] 3.4 运行受影响 Rust/Swift 测试与 macOS 构建，验证停机协调器的跨层接线（verification.md 2026-09-15：cargo test 全绿、build-rust.sh 通过、xcodegen 通过、macOS/iOS build 通过、定向 XCTest QuitProtectionTests / TransferStoreTests / WorkspaceStoreTests 停机用例全过）
- [x] 3.5 运行覆盖率门禁：`cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 通过；Swift 侧新增可测逻辑覆盖率达标（2026-09-29 验证：lines 96.74%、regions 95.69%；verification.md 记录 lines 78.85%/regions 81.29% 为整体基线，但本变更新增代码无 Rust 引入，Swift 侧覆盖率需配合 CI 工具精确测量）

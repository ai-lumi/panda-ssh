## Context

见 proposal.md - Why。当前 `SidebarPage.connectionMonitor` 在双平台都驱动 `WorkspaceView` 内容分支；日志入口已在 macOS 使用带稳定 ID 的 SwiftUI Window Scene，并在侧栏动作中优先激活已有窗口。平台条件编译按项目约定可用于界面呈现差异。

## Goals / Non-Goals

**Goals:**
- 复用日志窗口的既有 Scene 与激活模式，为 macOS 提供单独的连接监控窗口。
- 让平台呈现策略可由 XCTest 验证，并保持监控视图本身完全共享。
- 保持 iPadOS 的工作区内导航及所有连接监控数据行为不变。

**Non-Goals:**
- 不修改监控 Store、FFI、Rust core 或连接生命周期。
- 不抽象通用窗口管理器，也不重构日志入口。

## Decisions

### 决策 1：macOS 使用独立 WindowGroup 与稳定窗口 ID

在 App Scene 中注册“连接监控”窗口，侧栏动作先按窗口标题查找并激活，找不到时通过稳定 ID 打开。这与日志窗口保持一致，避免为单个入口引入新的窗口协调层。

替代方案：在主窗口使用 sheet。放弃原因：sheet 仍附着并阻塞主窗口，不符合用户要求的独立监控窗口。

### 决策 2：保留 iPadOS 的 SidebarPage 分支

`SidebarPage.connectionMonitor`、`AppModel.showConnectionMonitor()` 与 `WorkspaceView` 分支继续服务 iPadOS；macOS 侧栏不再调用该状态变更。这样不改变 iPadOS 单窗口体验，也不复制监控页面。

替代方案：删除页面分支并让双平台都使用 Window Scene。放弃原因：会把本次 macOS 修正扩大为 iPadOS 多窗口产品变更。

### 决策 3：用平台呈现策略作为可测契约

增加轻量、无业务数据的呈现策略值，XCTest 在 macOS 断言独立窗口、在 iPadOS 断言工作区页面。窗口 Scene 的实际接线由双平台编译验证。

替代方案：只依赖 UI 源码检查。放弃原因：无法用自动化测试防止未来再次把 macOS 入口接回主窗口状态。

## Risks / Trade-offs

- [按标题激活窗口依赖窗口标题] → 使用与 Window Scene 完全一致的常量标题和 ID，并集中定义常量。
- [保留 macOS 可编译的工作区分支可能被误用] → 侧栏由平台呈现策略和条件编译决定动作，测试锁定 macOS 策略。
- [独立窗口有自己的 Store 刷新任务] → 这是预期的视图生命周期；窗口关闭后 SwiftUI 取消任务，不新增网络连接。

## Migration Plan

无需数据迁移。若独立窗口接线出现问题，可回退 macOS 侧栏动作和 Window Scene；iPadOS 与监控数据层不受影响。

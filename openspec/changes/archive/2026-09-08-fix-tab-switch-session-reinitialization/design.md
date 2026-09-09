## Context

见 proposal.md - Why。当前内容区只构造活动标签的视图，切换时 SwiftUI 会触发旧终端视图的 `onDisappear`；该生命周期回调关闭 shell，切回时便只能新建会话。

## Goals / Non-Goals

**Goals:**

- 已打开的终端标签保留各自稳定的 SwiftUI 身份和 `TerminalSessionStore`。
- 标签切换只改变可见性；关闭标签才释放对应终端资源。
- macOS 与 iPadOS 走同一工作区业务行为。

**Non-Goals:**

- 不保留未打开标签的预创建视图。
- 不改变 SFTP 页签或 Rust 连接池的资源策略。

## Decisions

### 用稳定的终端页签容器承载已打开会话

工作区同时挂载所有终端标签页；仅活动页签参与命中测试并显示。这样 `@StateObject` 的拥有者不会在标签切换时析构，原有 shell 连接继续由该对象持有。

替代方案是在 `WorkspaceStore` 中持有 `TerminalSessionStore`。该方案会让 UI 状态容器负责 SwiftTerm/连接对象的构造与资源释放，增加所有权和测试复杂度，故不采用。

### 保持关闭语义不变

标签从 `WorkspaceStore.tabs` 移除时，对应容器随 `ForEach` 移除而析构，现有终端关闭路径继续运行。切换只隐藏，关闭才销毁。

替代方案是移除 `onDisappear` 的关闭行为。它无法区分切换和真实关闭，容易留下孤立 shell，故不采用。

## Risks / Trade-offs

- [Risk] 多个已打开终端会同时占用内存和 shell 资源 → 这是连接池规范的明确语义；用户关闭标签后资源释放，后续可独立评估后台标签的内存预算。
- [Risk] 隐藏终端视图仍可能接收布局更新 → 非活动容器禁用命中测试，并通过回归测试确认不会触发新的连接尝试。

## Migration Plan

发布时无需数据迁移。若出现严重的后台终端渲染问题，可回退为当前单一活动视图策略，但会恢复已知的重初始化缺陷。

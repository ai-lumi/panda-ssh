## Context

见 proposal.md。现有 `TerminalTabView` 将每个连接阶段直接映射为独立子视图，连接中的行视图缺少填满内容画布的布局契约；终端则必须常驻以保持会话和焦点。

## Goals / Non-Goals

**Goals:**

- 用纯值呈现策略定义每个阶段的内容层级、对齐和终端尺寸所有权。
- 保持 macOS/iPadOS 一套阶段规则；平台差异只位于现有终端原生 view 包装层。

**Non-Goals:**

- 不修改 SSH/FFI 状态机、认证门控、重试语义或标题栏 chrome。

## Decisions

### 1. 终端标签由单一全尺寸内容画布承载

`TerminalTabView` SHALL 先创建全尺寸黑色画布，再由共享纯值 `TerminalContentPresentation` 选择 overlay：connecting 与 failed 为居中面板，shell 为唯一填满画布的终端原生视图。门控继续覆盖内容画布并保持现有 sheet 行为。

替代方案：将连接状态嵌在顶部或底部条。否决：它与工作区 chrome 争夺层级，且在内容视图常驻/尺寸变化时会产生错误锚点。

### 2. 尺寸变化只流向已连接终端

终端画布总是填满父级；SwiftTerm 包装层继续负责已有 PTY resize。connecting/failed overlay 使用父级可用矩形居中，且不观察尺寸来发起连接、重试或重建 `StateObject`。

### 3. 工作区可见性不决定会话生命周期

隐藏侧栏、窗口缩放和标签切换仅改可见矩形。既有常驻 terminal tab 策略继续保存 `TerminalSessionStore`；失败与连接中状态也通过同一标签 ID 维持其尝试代次。

## Risks / Trade-offs

- [Risk] SwiftUI overlay 与原生终端尺寸更新竞争 → 以连接中、shell、失败三态的尺寸与会话连续性测试覆盖。
- [Risk] 大窗口空态显得稀疏 → 居中面板限制最大阅读宽度，避免伪工具栏填充。

## Migration Plan

1. 先对纯值呈现策略写失败测试。
2. 接入全尺寸画布和三态 overlay，保留现有连接状态机。
3. 在 macOS/iPadOS 验证缩放、侧栏和标签切换；若失败，回退到现有 `TerminalTabView` 呈现分支，不关闭会话。

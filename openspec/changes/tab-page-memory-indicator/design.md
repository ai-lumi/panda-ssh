## Context

当前标签栏由 `WorkspaceTabItemView` 渲染，每个标签页有类型（terminal/sftp）、标题、关闭按钮。macOS 已支持 `.onHover` 用于背景色变化；iPadOS 已有 `.contextMenu` 支持长按。见 proposal.md - Why。

## Goals / Non-Goals

**Goals:**
- 为每个标签页提供内存占用估算接口。
- macOS 悬停、iPadOS 长按展示内存信息。
- 估算为近似值，数量级准确即可。

**Non-Goals:**
- 不实现精确内存统计（不调用系统级 API）。
- 不显示 CPU、网络等其他资源。
- 不实现自动清理或休眠。

## Decisions

### 决策 1：内存估算模型

**选择：**
- **终端标签页**：`memory = bufferLines × cols × MemoryLayout<Cell>.size`
  - `bufferLines` 来自 SwiftTerm `Terminal.getTopRow()` 或等效方法获取实际缓冲区行数。
  - `cols` 来自当前终端列数（通过 `TerminalView` 获取）。
  - `Cell` 为 SwiftTerm 内部字符单元结构大小。
- **SFTP 标签页**：`memory = (localEntries + remoteEntries) × entrySize + activeTransfers × transferOverhead`
  - `entrySize` 固定估算为 512 字节（文件名、属性、图标等）。
  - `transferOverhead` 固定估算为 1 KB 每个活跃传输任务。

**理由：**
- 终端缓冲区是标签页内存的主要消耗来源，SwiftTerm 提供了获取行数与列数的 API。
- SFTP 的内存消耗主要来自文件列表缓存，条目数可统计。
- 估算为近似值，不要求字节级精确。

**替代方案：** 使用 `task_info` 获取进程级 RSS。放弃原因：无法区分单个标签页；平台 API 差异大；过度设计。

### 决策 2：展示形式

**选择：**
- **macOS**：使用 `.help` modifier 或自定义 Tooltip，在悬停 500ms 后展示。
- **iPadOS**：在现有 `.contextMenu` 的 preview 区域或长按手势的附加 Popover 中展示。

**理由：**
- macOS 原生 Tooltip 最符合用户习惯；SwiftUI `.help` 简单易用。
- iPadOS 无 hover，长按是自然的替代交互；与现有上下文菜单结合避免新增手势冲突。

**替代方案：** 使用 `HoverEffect` / `UIPreviewInteraction`。放弃原因：过度复杂，与 SwiftUI 整合成本高。

### 决策 3：内存信息获取路径

**选择：**
- `WorkspaceStore` 新增 `memoryEstimate(for tabID: UUID) -> String` 方法。
- 终端标签页通过 `terminalSessions` 弱引用获取 `TerminalSessionStore`，再访问其 `TerminalView` 的缓冲区信息。
- SFTP 标签页通过 `SftpSessionStore`（需要新增注册机制，类似终端）获取文件列表状态。

**理由：**
- `WorkspaceStore` 作为标签页的中央协调器，最适合聚合各标签页的内存信息。
- 终端已有 `registerTerminal`/`unregisterTerminal` 机制，SFTP 需要补充类似机制。

## Risks / Trade-offs

- **[SwiftTerm API 无直接内存统计]** → 通过行数 × 列数 × Cell 大小估算，标注「约」。
- **[SFTP 内存估算不准]** → SFTP 内存占用通常较小（< 10MB），估算偏差可接受。
- **[悬停/长按与现有交互冲突]** → macOS 悬停仅展示 Tooltip 不拦截点击；iPadOS 长按与现有 `.contextMenu` 结合展示。
- **[频繁计算导致 CPU 开销]** → 内存估算仅在触发悬停/长按时按需计算，不做定时轮询。

## Why

用户同时打开多个终端或 SFTP 标签页时，难以感知单个标签页占用的内存资源。在长时间运行或大量输出场景下，某些标签页可能成为内存大户，用户需要一种轻量方式快速查看各标签页的内存消耗，以便决定是否关闭或调整。

## What Changes

- 新增「标签页内存指示」功能：macOS 上鼠标悬停标签页按钮时、iPadOS 上长按标签页按钮时，展示该标签页的内存占用估算。
- 终端标签页内存：基于 SwiftTerm 内部缓冲区实际行数 × 列数 × Cell 大小估算。
- SFTP 标签页内存：基于本地/远程文件列表条目数与传输任务状态的轻量估算。
- 内存显示以人类可读格式呈现（如「约 12 MB」），并在 tooltip/popover 中展示。

## Non-goals

- 不实现精确的内存占用统计（不涉及系统级 `task_info` 或 `vm_statistics`）。
- 不显示除内存外的其他资源（CPU、网络带宽）。
- 不实现自动内存清理或标签页休眠机制。

## Capabilities

### New Capabilities
- `tab-page-memory-indicator`: 标签页内存估算模型、平台触发方式（悬停/长按）与展示格式。

### Modified Capabilities
- `workspace`: 在「标签页右键上下文菜单」或相关标签页交互要求中补充内存指示的展示位置。

## Impact

- SwiftUI：`WorkspaceTabItemView` 增加悬停/长按触发逻辑；macOS 使用 Tooltip/Popover，iPadOS 使用长按手势 + Sheet/Popover。
- `WorkspaceStore`：需要为每个标签页维护内存估算接口，终端标签页通过 `TerminalSessionStore` 获取 SwiftTerm 缓冲区信息，SFTP 标签页通过 `SftpSessionStore` 获取文件列表状态。
- 不涉及 Rust core 改动。

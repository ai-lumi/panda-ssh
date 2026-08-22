# Proposal: 工作区 UI 优化（标签页、终端关闭、SFTP 交互）

## Why

当前工作区存在多处交互缺口与资源生命周期隐患：标签页缺少右键批量操作、关闭终端不询问即断开、关闭 SFTP 标签会立即调用 `disconnect_host` 导致排队中传输任务被迫新建连接并泄漏连接、SFTP 文件行多选时无右键菜单、双击文件无传输动作、路径导航不可输入、主窗口右上角有一个无意义的 `>>` 按钮。这些直接影响桌面 SSH 客户端的核心使用体验与连接资源正确性，应集中打磨。

## What Changes

- **移除** 主窗口右上角因侧栏工具栏空间不足而出现的 `>>` 折叠按钮：通过为侧栏设置最小宽度保证工具栏项（添加主机、新建分组等）完整展示，从而消除右侧折叠入口，双端不再出现该多余按钮。
- **新增** 标签页右键（macOS）/ 长按（iPadOS）上下文菜单：重连、关闭其他标签页、关闭全部标签页。
- **审查并明确** 关闭标签页时的连接释放：终端标签关闭 SHALL 断开其 shell 会话；某主机的最后一个标签页关闭时 SHALL 触发 `disconnect_host`（已有），但若该主机仍有活跃传输任务则推迟断开。
- **新增** 关闭 SSH 终端标签页时的二次确认对话框，样式遵循 macOS / iPadOS 原生弹窗规范；用户确认后才关闭并断开会话。
- **新增** 关闭 SFTP 标签页时进行中（running/queued/paused）的传输任务 SHALL 继续运行；当该主机最后一个标签页已关闭且最后一个活跃传输任务完成后，SHALL 自动调用 `disconnect_host` 释放连接。
- **新增** SFTP 文件行在单选与多选模式下均提供原生右键/长按上下文菜单；多选时菜单操作作用于整个选中集合。
- **新增** SFTP 文件列表双击「文件」SHALL 创建一个传输任务（本地文件→上传、远程文件→下载）；双击「目录」保持进入目录的既有行为不变。
- **新增** SFTP 文件浏览窗口顶部的路径导航 SHALL 支持直接输入路径跳转（参考 Windows 文件资源管理器地址栏）：点击面包屑区域进入可编辑输入态，回车跳转、Esc 取消。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `workspace`: 移除多余 `>>` 按钮；标签页右键菜单（重连/关闭其他/关闭全部）；SSH 终端关闭二次确认；SFTP 标签关闭与传输/连接释放的协调；SFTP 文件行多选上下文菜单；双击文件触发传输；路径导航可输入跳转。
- `transfers`: 传输任务在其源 SFTP 标签页关闭后 SHALL 继续运行，不因标签页关闭而被取消或失败。

## Impact

- **Swift UI**：`WorkspaceView` / `WorkspaceTabItemView`（标签右键菜单、关闭确认）、`WorkspaceStore`（关闭其他/全部、重连、关闭确认门控）、`TerminalTabView` / `TerminalSessionStore`（关闭确认、重连）、`SftpTabView`（双击文件传输、多选右键菜单、可编辑路径导航）、`SftpSessionStore`、`TransferStore`（与 `WorkspaceStore` 协调推迟断开）。
- **macOS / iPadOS 双端**：右键 vs 长按、原生确认弹窗（`.alert` / `.confirmationDialog`）、路径输入控件与键盘行为需分别适配；业务逻辑不在 `#if os()` 分支中。
- **Rust / FFI**：无新增导出。复用已有 `disconnect_host`；「重连」终端复用 `TerminalSessionStore.retry()` 既有能力，不新增 FFI。
- **测试**：Swift 侧 `WorkspaceStore` / `TransferStore` / `SftpSessionStore` 可测逻辑用 XCTest 覆盖（关闭其他/全部、推迟断开协调、双击文件传输、路径跳转解析）；Rust 侧无逻辑变更，不新增 Rust 测试。
- **依赖**：无新增第三方依赖。

## Non-goals

- 不修改连接池的空闲超时/长连接策略（归 `long-lived-connections` 提案；该提案已实现但未归档，本提案在其基础上构建，不重复改 spec）。
- 不实现「重连」之外的新终端会话能力（如会话恢复、滚动历史、多 tab 复制）。
- 不重构 SFTP 双栏布局结构，不改变文件列表的选中/框选/多选语义。
- 不改变传输任务本身的并发上限、暂停/继续/重试/覆盖确认语义。
- 不新增 SFTP 路径自动补全（仅支持输入完整路径跳转，回车校验后导航）。
- 不处理关闭「整个窗口」时的批量断开（仅针对单标签页关闭流程）。

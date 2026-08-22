## Context

参见 proposal.md。当前状态：

- `panda-core::batch` 的 `execute_batch_upload` / `execute_batch_download` 已支持 `BatchConflictCallback`（返回 `Overwrite`/`Skip`）——核心层具备冲突决策能力，但 `panda-ffi/src/batch_transfer.rs` 传入的回调固定返回 `Overwrite`，未向 UI 暴露决策流程。
- 批量任务状态 `BatchTransferStatusEnum` 为 Queued/Running/Completed/Failed/Cancelled，无「等待冲突确认」状态。
- macOS `WorkspaceView` 使用 `NavigationSplitView`，系统自动注入 `>>` 侧栏切换按钮，未隐藏。
- `Logger.log` 默认 `module: "App"`，大量调用点未显式传模块名，产生 spec 未定义模块名。

## Goals / Non-Goals

**Goals:**

- 批量传输遇到目标已存在时暂停该文件，向 Swift 侧返回结构化覆盖确认请求（源/目标大小与 mtime），等待用户决策后继续；跳过项计入 `skipped`，整个任务照常完成。
- macOS 主窗口隐藏系统自动注入的 `>>` 按钮。
- 日志记录不再出现 `App` 等非规范模块名。

**Non-Goals:**

- 不修改 spec 文本（见 proposal）。
- 不改变单文件传输冲突确认流程（已符合 spec）。
- 不新增「保留两者」决策。
- 不为批量任务新增暂停/继续（spec 未要求批量任务可暂停）。

## Decisions

### D1：批量冲突确认采用「任务进入 WaitingForConflict 状态 + 独立 resolve 接口」模式

沿用单文件传输「预检查 + 弹窗」思路无法直接用于批量任务（批量任务在 Rust 后台线程执行，不能阻塞等待 Swift 弹窗）。采用异步决策模型：

- `BatchTransferStatusEnum` 新增 `WaitingForConflict` 状态。
- `BatchTransferStatusRecord` 新增 `pending_conflict: Option<BatchConflictRecord>`（含 `item_source`、`item_destination`、`source_size`、`source_mtime`、`target_size`、`target_mtime`）。
- 新增 `batch_transfer_resolve_conflict(task_id, overwrite: bool)`：将决策回传 Rust；`overwrite=true` 覆盖写入，`false` 跳过该项目；随后任务继续后续项目。
- `conflict_cb` 内部通过 tokio `mpsc`/`oneshot` 等待 Swift 决策：回调里把冲突信息写入任务状态并 `await` 用户决策；取消时视为跳过。

理由：与 `transfers` spec 的单文件传输（`transfer_cancel` 等轮询模型）一致；`wait_while_paused` 已证明「后台任务 + 状态轮询」模式可行。
备选：FFI 同步阻塞弹窗——违反 AGENTS.md「Rust 侧不自行阻塞等待用户输入」的约定，弃用。
备选：Swift 侧先扫描出全部冲突再逐个确认——扫描与传输分离会导致 TOCTOU（扫描后文件状态变化），且大目录下 UI 延迟感知差，弃用。

### D2：批量任务取消语义

用户取消时若任务处于 `WaitingForConflict`，视为跳过当前项并终止任务（取消优先级最高）。`batch_transfer_cancel` 需唤醒等待中的回调。

### D3：`>>` 按钮隐藏方式

macOS 用 `NavigationSplitView` 时系统注入 `sidebar.toggle` 工具栏项。在 `WorkspaceView` 的 macOS 分支上使用 `.toolbar(removing: .sidebarToggle)`（macOS 14+ 可用），移除自动注入项。
备选：改为自定义 `HSplitView`——改动大且失去系统侧栏行为，弃用。

### D4：日志模块名规范化

- `Logger.log` 的默认模块名从 `"App"` 改为 `"Config"` 无意义——改为保留显式必传语义：`log(_:level:module:)` 的 `module` 保持参数但默认值改为 `"App"` 不再可行；直接方案：默认值改为 `"Config"`（配置/通用类别），并逐一点检全部调用点，确保只使用 `SSH`/`SFTP`/`Transfer`/`HostKey`/`Config`/`FFI` 六个模块名。
- 对 spec 未定义模块名的调用点，按语义归入最接近的模块（如 App 生命周期归 `Config`，连接失败归 `SSH`）。

## Risks / Trade-offs

- [批量冲突等待期间用户关闭任务/取消任务] → `cancel` 唤醒等待者，按跳过处理并终止；状态最终为 `Cancelled`，不留悬空等待。
- [`WaitingForConflict` 状态增加 Swift 侧映射负担] → `TransferStore` 中批量记录映射为 `.queued`（等待确认视同排队），UI 弹窗由 SftpSessionStore 轮询 `pending_conflict` 呈现；新增状态不改变既有状态机枚举的兼容性（FFI enum 增项对 Swift 绑定是向后兼容的）。
- [`.toolbar(removing:)` 在 macOS 14 以下不可用] → 项目最低部署目标 macOS 14+，无兼容问题。
- [日志模块名调整遗漏某个调用点] → 搜索 `Logger.shared.(debug|info|warning|error)` 全部调用点逐一核对，Swift 侧测试断言默认模块名不在白名单之外。

## Migration Plan

1. Rust：批量 FFI 增加状态与 resolve 接口 → `cargo test` 全绿。
2. Swift：`TransferStore`/`SftpSessionStore` 映射新状态并挂弹窗 → 双端 `xcodebuild` 通过。
3. macOS 工具栏移除 + 日志模块名点检 → 构建通过。
4. 无数据迁移；`.pandassh` 导出格式不受影响。

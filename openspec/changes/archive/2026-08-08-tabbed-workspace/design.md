## Context

现有代码中 `panda-core::ssh::SshSession` 只提供一次性 `exec` 与 `disconnect`，FFI 也只暴露同步的 `test_connection`/`sftp_*`。Swift 侧 `TerminalView.swift` 已引入 SwiftTerm 终端组件但尚未接上真实 SSH 通道。多标签页需要一个可同时存活多个 SSH 会话、并由 UI 驱动双向字节流的架构。

## Goals / Non-Goals

**Goals:**

- 一个标签页 = 一个服务器会话，类型为终端或 SFTP，互不影响。
- 标签页 UI 与会话状态由 Swift 侧统一管理，Rust 侧只负责通道与字节流。
- 复用现有认证链路（`SshSession::connect` + `Credentials`），不重写 SSH 握手。
- macOS 与 iPadOS 共享同一套工作区 UI 源码。

**Non-Goals:**

- 实现终端配色、字体、超链接、粘贴确认等外观/交互细节。
- 实现标签拖拽排序、跨窗口拆分、会话复用池。
- 将密码等密钥材料经 FFI 落盘（安全红线，维持钥匙串方案）。
- 在本次变更中实现传输任务列表（属于 `transfer-tasks`）。

## Decisions

### 标签页模型：Swift 侧 `WorkspaceTab` 枚举

`WorkspaceTab` 为 enum，承载 `id`、`hostId`、`type`（`.terminal` / `.sftp`）。Swift 侧持有一个 `[WorkspaceTab]` 数组与当前选中索引。标签栏用自定义 SwiftUI 组件实现（不依赖 `NSTabView`/`UITabView`，保证双端源码一致）；每个标签页内容由 `switch` 分发到终端视图或 SFTP 双栏视图。

### 终端标签页的通道：panda-core 新增交互式 shell 会话

在 `panda-core` 中新增 `ShellSession`，基于 `SshSession` 的已认证 `Handle` 打开 session channel，维护一个带缓冲的读写队列：

- `open(handle) -> ShellSession`
- `write(&[u8])` 将输入写入 channel
- 通过轮询/通知方式取出远端输出字节流
- `close()`

FFI 侧按「同步导出 + 全局 tokio runtime」约定封装：`shell_open(host_id, password, passphrase)` 返回会话句柄；`shell_write(handle, bytes)`；`shell_read(handle, max)` 非阻塞取回可读字节；`shell_close(handle)`。Swift 侧用定时器或 `Task` 轮询 `shell_read`，把字节喂给 SwiftTerm。

### SFTP 标签页：复用现有双栏 + 既有 sftp FFI

SFTP 标签页直接复用现有 `sftp_list`/`sftp_upload`/`sftp_download`，本地栏用 `FileManager`/`UIDocumentPicker` 目录访问，远程栏调 `sftp_list` 分页加载。本次只搭双栏骨架与目录切换，传输行为交给 `transfer-tasks` 变更。

### 会话生命周期

标签页打开即建立会话（终端为 shell 通道，SFTP 为 sftp 会话），关闭时按序 `close` → `disconnect`。连接失败在标签页内容区展示错误文案并允许「重试」/「关闭」，不崩溃、不影响其它标签页。每个标签页持有独立 `SshSession`，不做会话池。

### 打开策略与标题消歧

从主机打开「终端」/「SFTP」总是新建标签页，不做按主机的去重或激活已有标签。同一主机的多个标签页标题加序号消歧（如「web-prod」「web-prod (2)」），序号在标签数组刷新时按同主机标签的稳定顺序重算。

### 手动密码与指纹确认在多标签下的边界

- 未存钥匙串的密码按标签页独立持有：每个标签页各自弹密码框，输入的密码只挂在该标签页的会话上，关闭即销毁，不跨标签共享（用户可能用不同账号登录同一主机）。与 `authentication` 变更的「手动输入密码的会话作用域」一致。
- 指纹确认按主机串行：同一主机的多个待连接标签页只触发一次 TOFU 确认，其余等待该次结果；信任后指纹写入 known_hosts，后续连接直接命中 Match。与 `server-management` 变更的「首次连接确认」一致。

### 交互式终端输出与 SwiftTerm 接线

`TerminalView.swift` 接收 `shell_read` 字节流写入 SwiftTerm 的 `TerminalView`；SwiftTerm 的 `SendStringDelegate` 将按键输入转发给 `shell_write`。终端尺寸变化（resize）暂不推送给远端（Non-Goal）。

## Risks / Trade-offs

- [多个标签页各自持有一个 SSH 会话，资源占用随标签数线性增长] → 可接受；会话在标签关闭时立即释放，后续再做会话池/复用。
- [`shell_read` 轮询引入延迟] → 用短间隔（50–100ms）定时器，先保证双端一致的简单实现，后续可改推送式回调。
- [iPadOS 标签栏在紧凑宽度下拥挤] → 标签栏可横向滚动 + 用 SF Symbols 区分终端/SFTP 图标。

## Migration Plan

无数据迁移。现有 `test_connection`、`sftp_*` FFI 保持不变；新增 shell 相关导出函数为纯增量。既有 SwiftTerm 终端视图逐步从占位态切换到真实通道。

## Open Questions

- 终端标签页是否需要把窗口/pty 尺寸变化（resize）通知远端？当前按 Non-Goal 跳过，后续根据真实使用反馈补充。

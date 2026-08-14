## Context

本次变更源于 `transfer-tasks` 真实服务器联调：当 App 连接到 home 目录不是 `/home/<username>` 的 Synology 服务器时，SFTP 列表失败；同时发现侧栏交互、传输轮询、`init_store` 可测试性等连带问题。所有修复均为 bugfix/体验优化，不引入新能力。

## Goals / Non-Goals

**Goals:**

- SFTP 远程面板根目录应自动适配服务器实际 home 路径。
- 侧栏主机单击选中、面包屑显示符合 macOS/iPadOS 原生预期。
- 无传输任务时 App 空转 CPU/内存不增长。
- `panda-ffi` 集成测试可在同进程中独立初始化临时 store。
- 建立真实服务器回归测试，覆盖 SSH exec 与 SFTP 上传/下载。

**Non-Goals:**

- 不重构传输任务状态机或 UI 布局。
- 不改动 iCloud KV/钥匙串同步逻辑。
- 真实服务器测试不强制在 CI 中运行。

## Decisions

### SFTP 根目录解析

`russh-sftp` 会话初始工作目录即用户 home。`SftpClient::home_dir()` 调用 `canonicalize(".")` 获取绝对路径，由 FFI `sftp_home_dir` 暴露给 Swift。`SftpSessionStore.connect` 改为 async，在创建 `RemoteFilePaneSource` 前先查询该路径；解析失败时兜底到 `/`。

### 侧栏交互

- `HostRowView` 的双击打开终端手势改为 `simultaneousGesture(TapGesture(count: 2))`，让 List 的单击选中与双击打开同时生效。
- `FilePaneNavigator.breadcrumbs` 保留完整路径（含 rootTitle），但 `SftpTabView.paneHead` 渲染时 `dropFirst()`，因为栏头左侧标签已显示 rootTitle。

### 传输轮询按需启动

`TransferStore` 内部持有 `polling: AnyCancellable?`：
- `add()` / `retry()` 后调用 `startPollingIfNeeded()`，启动 100ms Timer。
- `tick()` / `cancel()` / `clearFinished()` 后若 `activeCount == 0` 则 `stopPollingIfIdle()`。
- `tick()` 仅当任务列表变化时才赋值 `tasks`，避免空转时持续发布 `ObservableObject` 更新。

### `init_store` 可重初始化

将 `static STORES: OnceLock<Stores>` 替换为 `static STORES: Mutex<Option<Arc<Stores>>>`，`init_store` 始终覆盖当前值。`stores()` 返回 `Arc<Stores>`。App 生命周期内仍只调用一次，测试可在每个用例中重初始化。

### 真实服务器测试

新增 `crates/panda-core/tests/real_server.rs`，包含：
- `ssh_connect_and_exec_pwd`
- `sftp_home_dir_matches_pwd`
- `sftp_list_remote_dir`
- `sftp_upload_and_download_round_trip`

默认 `#[ignore]`，通过 `PANDA_SSH_TEST_KEY` 可覆盖私钥路径。

## Risks / Trade-offs

- `init_store` 放宽为可重初始化后，如果 App 误调用多次，会切换配置目录。App 已有 `started` 标志防护，风险可控。
- 真实服务器测试依赖外部网络和密钥，不纳入默认门禁，回归前需手动执行。

## Migration Plan

无数据迁移。App 启动行为不变。

## Open Questions

None.

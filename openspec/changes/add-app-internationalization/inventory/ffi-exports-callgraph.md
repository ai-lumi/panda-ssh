# FFI 导出面 ↔ Swift 生产调用图盘点（任务 1.2 双向核实）

- 盘点对象：`crates/panda-ffi/src/` 全部 `#[uniffi::export]` 函数 × `apple/PandaSSH/` 生产调用图（排除 `PandaSSHTests`）。
- 核对基准：`apple/Rust/Generated/panda_ffi.swift`（生成绑定，完整 API 面）与 proposal.md `### FFI v2 迁移矩阵`。
- 方法：逐一读取 8 个 FFI 源文件中的 `#[uniffi::export]`，再对生成绑定的全部 101 个全局函数在 Swift 源内做全量反查。
- 行号基准：2026-02 当前工作区快照；Rust 侧行号指 `crates/panda-ffi/src/<file>.rs`。

## 总量速览

| 指标 | 数量 |
| --- | --- |
| `#[uniffi::export]` 导出函数总数 | **101** |
| 返回 `Result<_, PandaError>` 的导出 | **67** |
| 其中有 Swift 生产 UI 消费点的 | **52** |
| 无任何 Swift 生产消费点的 `Result<_, PandaError>` 导出 | **15**（见 c.3） |
| 矩阵明确遗漏的 `Result<_, PandaError>` 导出 | **1**（`transfer_groups`）+ **2 个边界存疑**（`scan_local_batch` / `scan_remote_batch`，见 c.2） |
| 矩阵需要修正/细化行号的行 | 第 2、4、6、9 行（详见 c.1） |

---

## (a) 全部 uniffi 导出清单（名称 / 签名 / 返回 / 错误来源）

错误来源标注：
- **[core]** 经 `From<panda_core::Error>` 直接映射（结构化变体或 `Core(other.to_string())` 兜底，lib.rs:138-174）
- **[FFI-check]** FFI 层结构化检查错误（`NotInitialized`/`UnknownHost`/`UnknownTransferTask`/`UnknownSftpHandle`/`UnknownShellHandle`/`MissingPassword` 等）
- **[Core(format!)]** `PandaError::Core(format!)` / `io::Error→Core` / 字符串包装
- **[无 Result]** 不返回 Result

### a.1 ffi_adapter.rs（2 个）

| 函数 | 签名要点 | 返回 | 错误来源 |
| --- | --- | --- | --- |
| `sftp_directory_path` | `(input: String)` | `Result<String, PandaError>` ✅ | [core] `sftp_path::directory_path` 校验失败 |
| `sftp_child_path` | `(directory, name)` | `String` | [无 Result] |

### a.2 ffi_telemetry.rs（7 个）

| 函数 | 签名要点 | 返回 | 错误来源 |
| --- | --- | --- | --- |
| `connection_telemetry_list` | `()` | `Vec<ConnectionTelemetryRecord>`（`last_error: Option<String>`） | [无 Result] |
| `connection_lifecycle_drain` | `()` | `Vec<ConnectionLifecycleRecord>`（`reason: String` 来自 core `LifecycleKind::description()`） | [无 Result] |
| `connection_health_check` | `(connection_id: u64)` | `Result<HealthStateEnum, PandaError>` ✅ | [core] 未知 id → `UnknownConnection(u64)` |
| `connection_failure_classify` | `(error_code: String)` | `ConnectionFailureFFIRecord`（`title`/`detail` 中文文案由 core 生成） | [无 Result]（错误码表外一律 `Error::Other` → Other 类） |
| `log_write` | `(level, module, message)` | `()` | [无 Result] |
| `log_entries` | `(limit: u32)` | `Vec<LogEntryRecord>`（`message: String` 原文） | [无 Result] |
| `log_clear` | `()` | `()` | [无 Result] |

### a.3 ffi_workspace.rs（25 个，全部无 Result）

`workspace_set_host_names`、`workspace_open_tab`、`workspace_close_tab`、`workspace_tab_list`、`workspace_host_connection_status`、`workspace_report_connection_status`、`workspace_close_other_tabs`、`workspace_close_all_tabs`、`workspace_confirm_close`、`workspace_cancel_close`、`workspace_pending_close`、`workspace_select_tab`、`workspace_active_tab_id`、`workspace_reset`；`preconnect_tofu_register_waiter`、`preconnect_tofu_resolve`、`preconnect_tofu_reset`；`terminal_session_register`、`terminal_session_phase`、`terminal_session_transition_to_shell`、`terminal_session_transition_to_failed`（入参 `message: String`，即失败文案由 Swift 传入）、`terminal_session_retry`、`terminal_session_close`、`terminal_session_is_stale`、`terminal_session_get`。
其中 `TerminalSessionRecord.failure_message: Option<String>` 与 `ConnectionFailureFFIRecord.title/detail` 同属跨 FFI 文本字段。

### a.4 ffi_transfers.rs（9 个）

| 函数 | 返回 | 错误来源 |
| --- | --- | --- |
| `start_transfer` | `Result<String, PandaError>` ✅ | [FFI-check] `load_host`→`UnknownHost`；任务内失败写快照 `error` 字段（非返回值） |
| `transfer_status` | `Result<TransferStatusRecord, PandaError>` ✅ | [Core(format!)] UUID 解析失败；[FFI-check] `UnknownTransferTask` |
| `transfer_list` | `Result<Vec<TransferStatusRecord>, PandaError>` ✅ | [无实际失败路径] 恒 `Ok`（快照含 `error: Option<String>`） |
| `transfer_groups` | `Result<Vec<TransferGroupRecord>, PandaError>` ✅ | [无实际失败路径] 恒 `Ok` |
| `transfer_cancel` | `Result<(), PandaError>` ✅ | [Core(format!)] UUID 解析；[FFI-check] `UnknownTransferTask` |
| `transfer_retry` | `Result<String, PandaError>` ✅ | [Core(format!)] UUID 解析 + `"task is not in a retryable state"`；[FFI-check] `UnknownTransferTask`/`load_host` |
| `transfer_pause` | `Result<(), PandaError>` ✅ | [Core(format!)] UUID 解析 + `"task is already terminal"`；[FFI-check] `UnknownTransferTask` |
| `transfer_resume` | `Result<(), PandaError>` ✅ | [Core(format!)] UUID 解析；[FFI-check] `UnknownTransferTask` |
| `transfer_change_counter` | `u64` | [无 Result] |

### a.5 batch_transfer.rs（8 个）+ task_aggregation.rs（1 个）

| 函数 | 返回 | 错误来源 |
| --- | --- | --- |
| `start_batch_upload` | `Result<String, PandaError>` ✅ | [FFI-check] `load_host` |
| `start_batch_download` | `Result<String, PandaError>` ✅ | [FFI-check] `load_host` |
| `scan_local_batch` | `Result<Vec<BatchItemRecord>, PandaError>` ✅ | [core] 扫描错误；[Core(format!)] `"scan_local_batch: task dropped"` |
| `scan_remote_batch` | `Result<Vec<BatchItemRecord>, PandaError>` ✅ | [core] 连接/扫描错误；[Core(format!)] credentials 包装 + `"task dropped"` |
| `batch_transfer_status` | `Result<BatchTransferStatusRecord, PandaError>` ✅ | [Core(format!)] UUID 解析；[FFI-check] `UnknownTransferTask` |
| `batch_transfer_list` | `Result<Vec<BatchTransferStatusRecord>, PandaError>` ✅ | [无实际失败路径] 恒 `Ok`（快照含 `error: Option<String>`） |
| `batch_transfer_cancel` | `Result<(), PandaError>` ✅ | [Core(format!)] UUID 解析；[FFI-check] `UnknownTransferTask` |
| `batch_transfer_resolve_conflict` | `Result<(), PandaError>` ✅ | [Core(format!)] UUID 解析 + `"batch task is not waiting..."` + `"no pending conflict decision channel"` + `"channel closed"`；[FFI-check] `UnknownTransferTask` |
| `aggregate_task_groups_ffi` | `AggregationResultRecord` | [无 Result] |

### a.6 ffi_store.rs（26 个，全部 `Result<_, PandaError>` ✅）

| 函数 | 返回 | 错误来源 |
| --- | --- | --- |
| `init_store` | `Result<(), PandaError>` | [Core(format!)] `io::Error`（建目录）+ 日志文件配置错误 |
| `list_hosts` | `Result<Vec<HostConfigRecord>, _>` | [core] TOML 读写；[FFI-check] `NotInitialized` |
| `search_hosts` | `Result<Vec<HostConfigRecord>, _>` | 同上（core `search_hosts` 纯函数不产错） |
| `save_host` | `Result<(), _>` | [core] upsert 错误 |
| `delete_host` | `Result<(), _>` | [core] 凭据/配置删除错误（含恢复逻辑） |
| `save_credential` | `Result<(), _>` | [core] 凭据写错误（含 `CredentialProtectionKeyRequired`/`CredentialUnlockFailed`） |
| `read_credential` | `Result<Option<String>, _>` | [core] |
| `delete_credential` | `Result<(), _>` | [core] |
| `set_credential_protection_key` | `Result<(), _>` | [core] `CredentialUnlockFailed` 等 |
| `credential_protection_enabled` | `Result<bool, _>` | [core] |
| `credential_resolve` | `Result<ResolvedCredentialEnum, _>` | [core]；[Core(format!)] `"host not found: {host_id}"` |
| `host_key_status` | `Result<KnownHostStatusEnum, _>` | [core] known_hosts 解析 |
| `accept_unknown_host_key` | `Result<(), _>` | [core] 密钥格式非法等 |
| `preconnect_evaluate` | `Result<PreconnectActionEnum, _>` | [core]；[Core(format!)] `"host not found: {host_id}"` |
| `list_groups` | `Result<Vec<GroupRecord>, _>` | [core] |
| `save_group` | `Result<(), _>` | [core] |
| `delete_group` | `Result<(), _>` | [core] 级联删除错误 |
| `move_group` | `Result<(), _>` | [core] 环/未知父错误 |
| `group_path` | `Result<String, _>` | [core] list 错误；未知 id 恒返回 `"根级"`（不报错） |
| `sidebar_tree` | `Result<Vec<SidebarNodeFFIRecord>, _>` | [core] |
| `config_export` | `Result<ExportManifestRecord, _>` | [Core(format!)] core config_archive 错误转字符串 |
| `config_import` | `Result<ImportResultRecord, _>` | [Core(format!)] 同上 |
| `init_snippets` | `Result<(), _>` | [Core(format!)] `io::Error` |
| `list_snippets` | `Result<Vec<SnippetRecord>, _>` | [core]；`NotInitialized` |
| `save_snippet` | `Result<(), _>` | [core] |
| `delete_snippet` | `Result<(), _>` | [core] |

### a.7 ffi_sessions.rs（23 个，全部 `Result<_, PandaError>` ✅）

| 函数 | 返回 | 错误来源 |
| --- | --- | --- |
| `test_connection` | `Result<String, _>`（成功文本 `"connected to user@host:port (exit status: …)"` 英文） | [core] 连接/认证/host key 错误；[FFI-check] `UnknownHost`/`MissingPassword`/`MissingPassphrase` |
| `sftp_list` / `sftp_upload` / `sftp_download` | `Result<Vec<RemoteFileRecord>,_>` / `Result<(),_>` ×2 | [core] 一次性连接 + SFTP 操作错误 |
| `sftp_check_upload_conflict` / `sftp_check_download_conflict` | `Result<Option<RemoteFileConflictRecord>, _>` | [core] |
| `sftp_remove_file` / `sftp_remove_dir` / `sftp_create_dir` | `Result<(), _>` | [core] |
| `sftp_home_dir` | `Result<String, _>` | [core] |
| `sftp_session_open` | `Result<SftpSessionRecord, _>` | [core]；长连接句柄注册 |
| `sftp_session_list` | `Result<Vec<RemoteFileRecord>, _>` | [core]；[FFI-check] `UnknownSftpHandle` |
| `sftp_session_check_upload_conflict` / `sftp_session_check_download_conflict` | `Result<Option<RemoteFileConflictRecord>, _>` | 同上 |
| `sftp_session_remove_file` / `sftp_session_remove_dir` / `sftp_session_create_dir` | `Result<(), _>` | 同上 |
| `sftp_session_close` | `Result<(), _>` | [core]；未知句柄幂等返回 Ok |
| `shell_open` | `Result<u64, _>` | [core] 连接/PTY 错误 |
| `shell_write` | `Result<(), _>` | [FFI-check] `UnknownShellHandle`；[core] `ShellInputBackpressure`/`ShellSessionClosed` |
| `shell_read` | `Result<Vec<u8>, _>` | 同上 |
| `shell_resize` | `Result<(), _>` | 同上 |
| `shell_close` | `Result<(), _>` | [FFI-check] `UnknownShellHandle`（已关闭句柄幂等 Ok） |

**合计**：101 个导出；`Result<_, PandaError>` 共 1+1+0+8+8+0+26+23 = **67** 个。

---

## (b) Swift 生产调用图（FFI 函数 → 调用点 → 呈现方式）

生产代码 = `apple/PandaSSH/**`（`AppConfig.useMockBackend` 默认 false，UI 走 `PandaCoreBackend`；Mock 目录不含 FFI 调用）。

### b.1 呈现通道总览

1. **`ConnectFailureView`**（ConnectionGate.swift:253）：`ConnectionFailure.title/detail`（title/detail 为 Swift 硬编码中文，`detail` 分支可能透传 FFI 文本）。
2. **`AppModel.lastError`**（PandaSSHApp.swift:116）：接收 `backend.startupError`。**注意：全仓库无任何视图渲染 `model.lastError`**——PandaCoreBackend 的 do-catch 错误当前实际不可见（这是迁移时需一并处理的呈现缺口）。
3. **Settings alert**：`importError`（SettingsView.swift:92-95）、`credentialProtectionError`（SettingsView.swift:102-105）。
4. **TransferPanelView**：`task.error` 直接 `Text(error)`（TransferPanelView.swift:189-190）。
5. **ConnectionMonitorView alert**：`errorMessage`（ConnectionMonitorView.swift:192-202）。
6. **Toast**：SftpTabView.swift:446 `error.localizedDescription`。
7. **`try?` 吞错降级**：列表/树/凭据解析类调用失败时静默回退空值。
8. **Logger 通道**：失败常转为 `Logger.shared.error/warning` 写入 Rust 日志（29 处调用，7 个文件），经 `log_entries` 回显到 LogView。

### b.2 逐函数调用点

#### 连接与 host key

| FFI 函数 | Swift 调用点 | 错误消费 |
| --- | --- | --- |
| `test_connection` | PandaCoreBackend.swift:122（经 PandaCoreBridge.checkConnection，bridge:110）——**仅用于 TOFU 探测**，成功值 `_ =` 丢弃 | catch → `UnknownHostKey`/`HostKeyMismatch` 结构化分支（backend:127-139）；其余 rethrow → ConnectionGate.probeUnknown:129-133 记日志并放行 |
| `host_key_status` | PandaCoreBackend.swift:34、106（bridge:116） | `try?` → 降级 `.unknown` / 保持 nil 指纹 |
| `accept_unknown_host_key` | PandaCoreBackend.swift:151（bridge:121，trustHost） | catch → `startupError`→`lastError`（当前无渲染点） |
| `connection_failure_classify` | **ConnectionGate.swift:216**（`ConnectionFailure.init(error:)`） | 仅消费 `record.detail`（→ `.other(record.detail)` → ConnectFailureView）；**`record.title` 无消费点**（Swift 用自有硬编码 title，ConnectionGate.swift:231-239） |
| `connection_telemetry_list` | **ConnectionMonitorView.swift:18**（默认闭包直接调生成全局函数）；`PandaCoreBridge.swift:281` 是**无调用者的死包装** | 快照字段；`last_error` 呈现于 **ConnectionMonitorView.swift:259-264**（红色 Label） |
| `connection_health_check` | **ConnectionMonitorView.swift:19**（默认闭包）；bridge:285 同为死包装 | catch → `errorSummary`（UnknownConnection 特判，ConnectionMonitorView.swift:66-72）→ alert |
| `connection_lifecycle_drain` | **无 Swift 消费点**（确认） | — |
| `preconnect_evaluate` | **无 Swift 消费点**（Mock 路径走纯 Swift `AppModel.preconnectAction`，PandaSSHApp.swift:293-298） | — |
| `preconnect_tofu_register_waiter/resolve/reset` | **无 Swift 消费点**（TOFU 串行化在 AppModel 用 continuation 实现，PandaSSHApp.swift:262-289） | — |
| `credential_resolve` | **CredentialResolver.swift:26** | `try?` → `needsManualInput` → 弹密码框 |
| `terminal_session_*`（9 个） | **无 Swift 消费点**（TerminalSessionStore 在 Swift 侧自建状态机） | — |

#### Store（主机/分组/片段/凭据/导入导出）

| FFI 函数 | Swift 调用点 | 错误消费 |
| --- | --- | --- |
| `init_store` | PandaCoreBridge.swift:64 ← PandaCoreBackend.init:14 | catch → `startupError`（AppModel init 读取，无渲染点）+ Logger |
| `init_snippets` | PandaCoreBridge.swift:263 ← PandaCoreBackend.init:15 | 同上 |
| `list_hosts` | bridge:69 ← PandaCoreBackend:26、163（`try?`→`[]`/nil） | 静默降级 |
| `search_hosts` | **SidebarView.swift:91** | `try?` → `[]` |
| `save_host` | bridge:73 ← PandaCoreBackend:72（saveHost）、:98（moveHost）、:176（clearCredentials） | catch → `startupError`；saveHost 失败返回 false → HostEditView.swift:234 保存按钮无提示 |
| `delete_host` | bridge:77 ← PandaCoreBackend:87 ← SidebarView:133 | catch → `startupError`（无渲染点） |
| `save_credential` | bridge:80 ← PandaCoreBackend:52、61 | `try?`/guard → return false（中止保存，无提示） |
| `read_credential` | bridge:81 ← **HostEditView.swift:180**（`try?`） | 静默降级 |
| `delete_credential` | bridge:82 ← PandaCoreBackend:76、178 | catch → `startupError` |
| `set_credential_protection_key` | bridge:84 ← **SettingsView.swift:212、225、237** | catch → `credentialProtectionError` → alert（SettingsView.swift:102-105） |
| `credential_protection_enabled` | bridge:86 ← **SettingsView.swift:52** | `try?` → false |
| `list_groups` | bridge:89 ← PandaCoreBackend:187、205 | `try?` → `[]` / nil |
| `save_group` | bridge:93 ← PandaCoreBackend:197、207 | catch → `startupError` |
| `delete_group` | bridge:99 ← PandaCoreBackend:216 ← SidebarView:143、WorkspaceStore:392 | catch → `startupError` |
| `move_group` | bridge:102-104（relocateGroup）——**无调用者**（PandaCoreBackend.moveHost 改 groupId 后走 `save_host`） | — |
| `group_path` | **HostDetailView.swift:67**、**SidebarView.swift:414**、**HostEditView.swift:65** | `try?` → 兜底 `"根级"` / 原名 |
| `sidebar_tree` | **SidebarView.swift:189** | `try?` → `[]` |
| `config_export` | **SettingsView.swift:264（macOS）/ 274（iPadOS）** | catch → `importError` → alert |
| `config_import` | **SettingsView.swift:296** | catch → `importError` → alert |
| `list_snippets` | bridge:267 ← PandaCoreBackend:225 | `try?` → `[]` |
| `save_snippet` | bridge:271 ← PandaCoreBackend:230 ← SnippetsView:42、47 | catch → `startupError`（无渲染点） |
| `delete_snippet` | bridge:275 ← PandaCoreBackend:238 ← SnippetsView:55 | catch → `startupError` |

#### SFTP（会话句柄型 + 一次性型）

| FFI 函数 | Swift 调用点 | 错误消费 |
| --- | --- | --- |
| `sftp_session_open` | **SftpSessionStore.swift:343**（默认 sessionOpener，经 bridge:136，FFIBackground 后台执行） | connect 失败 → SftpSessionStore.connect:489-495 → SftpTabView:856-861 `ConnectionFailure(error:)` → ConnectFailureView；`UnknownHostKey` 竞态回退 gate |
| `sftp_session_list` | **SftpSessionStore.swift:101**（bridge:145） | 导航失败 → `FilePaneNavigator.lastError`（SftpSessionStore:281）→ SftpTabView:445-447 toast / :881 ConnectFailureView |
| `sftp_session_close` | **SftpSessionStore.swift:346**（bridge:149） | 失败仅 Logger（close 路径） |
| `sftp_session_check_upload_conflict` | **SftpSessionStore.swift:1129**（bridge:153） | `try?`（:918）→ 视为无冲突直接传 |
| `sftp_session_check_download_conflict` | **SftpSessionStore.swift:1149**（bridge:157） | 同上（:930） |
| `sftp_session_remove_file` / `sftp_session_remove_dir` | **SftpSessionStore.swift:1065**（bridge:162/164 分流） | catch → 返回 `error.localizedDescription` 字符串 → UI 删除失败提示（deleteRemoteCore:1071-1075） |
| `sftp_session_create_dir` | bridge:168/239（createRemoteDir）——**无调用者**（新建远端目录功能未接线） | — |
| `sftp_home_dir` | bridge:125-127（resolveSftpHomeDir）——**无调用者**（openSession 只走 opener） | — |
| `sftp_list` / `sftp_upload` / `sftp_download` | **无 Swift 调用点**（连桥接包装都没有） | — |
| `sftp_check_upload_conflict` / `sftp_check_download_conflict`（hostID 一次性版） | bridge:181/200 包装存在，**无调用者**（UI 只用会话句柄版） | — |
| `sftp_remove_file` / `sftp_remove_dir` / `sftp_create_dir`（hostID 一次性版） | bridge:220/228/246 包装存在，**无调用者** | — |
| `sftp_directory_path` | **SftpSessionStore.swift:218、226、273**（地址栏路径归一化） | `try?` → 回退原始输入（:273 失败走 `lastError`→toast） |
| `sftp_child_path` | SftpSessionStore.swift:238、254、1017 | 无错误路径 |

#### Shell

| FFI 函数 | Swift 调用点 | 错误消费 |
| --- | --- | --- |
| `shell_open` | **ShellConnection.swift:37**（PandaShellConnection.open）← TerminalSessionStore.swift:80（connectionOpener 默认实现，FFIBackground） | catch → `ConnectionFailure(error:)`（TerminalSessionStore:97）→ ConnectFailureView（TerminalTabView:80） |
| `shell_write` | **ShellConnection.swift:50** ← TerminalTabView.swift:432（sendToShell） | `ShellInputBackpressure` → warning 日志保留会话（:434-436）；其余 → reportError → handleSessionEnd → 失败页 |
| `shell_read` | **ShellConnection.swift:54** ← TerminalTabView.swift:402（16ms 读循环） | catch → reportError → handleSessionEnd（`ShellSessionClosed` → 正常 ended） |
| `shell_resize` | **ShellConnection.swift:58** ← TerminalTabView.swift:456、464 | `try?` 吞错 |
| `shell_close` | **ShellConnection.swift:46（deinit）、62（close）**；TerminalSessionStore.swift:30（staleConnectionCloser 过期握手回收，:84） | 失败仅 Logger（TerminalSessionStore:86、169） |

#### 传输（单文件 + 批量）

| FFI 函数 | Swift 调用点（TransferStore.swift 的 FFITransferSource） | 错误消费 |
| --- | --- | --- |
| `transfer_change_counter` | :242 | 无错误路径 |
| `start_transfer` | **:256（`try!`）** | 失败即 crash 前提是 `load_host` 失败；任务运行期错误走快照 `error` 字段 → TransferPanelView:189-190 `Text(error)` |
| `transfer_cancel` | :270（`try?`） | 吞错 |
| `transfer_pause` | :274（`try?`） | 吞错 |
| `transfer_resume` | :278（`try?`） | 吞错 |
| `transfer_retry` | **:282（`try!`）** | 非 UUID/不可重试状态会 crash——`try!` 是迁移风险点 |
| `transfer_list` | **:286（`try?`）**；error 字段消费在 **:1005**（init(ffiRecord:)）→ TransferPanelView:189 | `try?` → `[]` |
| `transfer_status`（单任务） | **无 Swift 调用点** | — |
| `transfer_groups` | **无 Swift 调用点** | — |
| `start_batch_upload` | **:299（`try!`）** | 同 start_transfer |
| `start_batch_download` | **:318（`try!`）** | 同上 |
| `batch_transfer_cancel` | :328（`try?`） | 吞错 |
| `batch_transfer_list` | **:332（`try?`）**；error 字段消费在 **:1090**（:1081 init(ffiRecord: BatchTransferStatusRecord) 起的快照消费链）→ TransferPanelView:189 | `try?` → `[]` |
| `batch_transfer_status`（单任务） | **无 Swift 调用点** | — |
| `batch_transfer_resolve_conflict` | **SftpSessionStore.swift:444**（bridge:257，`try?`） | 吞错（失败仅留在 Rust 状态机） |
| `scan_local_batch` | **SftpSessionStore.swift:963** | 上层 catch → 传输出错呈现 |
| `scan_remote_batch` | **SftpSessionStore.swift:978** | 同上 |
| `aggregate_task_groups_ffi` | **SftpSessionStore.swift:998** | 无错误路径 |

#### 日志

| FFI 函数 | Swift 调用点 | 消费 |
| --- | --- | --- |
| `log_write` | **Logger.swift:104**（`Logger.log` 内；上游为全 app 29 处 `Logger.shared.debug/info/warning/error`，覆盖 PandaSSHApp、PandaCoreBackend、TerminalSessionStore、TerminalTabView、ConnectionGate、SftpSessionStore、ConnectionMonitorView 等） | 写入 Rust 环形缓冲 + 文件 |
| `log_entries` | **Logger.swift:134**（`refreshEntries`，1Hz 定时 + 写后立即刷新） | `message` 原文经 LogView.swift:41 `entry.formatted` 渲染给用户 |
| `log_clear` | Logger.swift:118 ← LogView.swift:24（清除按钮） | 无错误路径 |

#### 工作区（workspace_*，均无 Result）

被消费：`workspaceSetHostNames`（PandaSSHApp.swift:158、WorkspaceStore.swift:108、460）、`workspaceOpenTab`（WorkspaceStore:463）、`workspaceTabList`（:168、470）、`workspaceActiveTabId`（:507）、`workspacePendingClose`（:519）、`workspaceReportConnectionStatus`（:155、233）、`workspaceCloseTab`（:234）、`workspaceHostConnectionStatus`（:176）、`workspaceSelectTab`（:197）。
**未被消费**：`workspaceConfirmClose`、`workspaceCancelClose`、`workspaceCloseOtherTabs`、`workspaceCloseAllTabs`、`workspaceReset`（Swift 侧自行管理确认/批量关闭状态）。

---

## (c) 矩阵核对结论

### c.1 逐行结论

| 矩阵行 | 结论 | 说明 |
| --- | --- | --- |
| 第 1 行 `connection_failure_classify`（`ConnectionGate.swift:216`） | **已确认** | 行号准确。补充：仅 `detail` 被消费（:221-222），`title` 无消费点；v2 迁移只需覆盖 `detail` 的来源，`title` 迁移后可评估删除 |
| 第 2 行 `connection_telemetry_list`（`PandaCoreBridge.swift:281`、`ConnectionMonitorView.swift:259`） | **需修正** | `PandaCoreBridge.swift:281` 是**无调用者的死包装**（`connectionTelemetry()`），真实生产调用点为 **ConnectionMonitorView.swift:18**（默认闭包直调生成全局函数）；:259 是 `last_error` 呈现点，正确。切换点应改为 ConnectionMonitorView.swift:18 + :259；同时建议顺手清理两个死包装（bridge:280-286，含 `checkConnectionHealth`） |
| 第 3 行 `connection_lifecycle_drain`（无 UI 消费点） | **已确认** | 核实确无 Swift 消费点 |
| 第 4 行 `transfer_status` / `transfer_list`（"TransferStore 及传输面板"） | **需修正（细化）** | `transfer_list` 调用点 **TransferStore.swift:286**（`try?`），`error` 字段消费链 **:1005 → TransferPanelView.swift:189-190**；`transfer_status`（单任务）**无任何 Swift 调用点**，应在该行标注"不可从生产 UI 到达"或从矩阵移除其 v2 义务 |
| 第 5 行 `batch_transfer_status` / `batch_transfer_list`（`TransferStore.swift:1081` 起消费链） | **已确认（需细化）** | :1081 为 `init(ffiRecord: BatchTransferStatusRecord)`，`error` 消费在 :1090；`batch_transfer_list` 调用点 :332。`batch_transfer_status`（单任务）**无 Swift 调用点**，同上处理 |
| 第 6 行 `test_connection` 与 `sftp_*`/`sftp_session_*`（`PandaCoreBackend.swift`、`ConnectionGate`、SFTP 界面） | **已确认（需细化）** | `test_connection` 唯一调用点 PandaCoreBackend.swift:122（Reject 探测；成功值丢弃——v2 成功分支文案实际不可达 UI）。`sftp_session_*` 8 个全部 UI 可达（见 b.2）；但该行前缀同时隐式覆盖了一批**无 UI 消费点**的入口：`sftp_list`/`sftp_upload`/`sftp_download`（连 Swift 包装都没有）、`sftp_home_dir`（包装无调用者）、hostID 一次性版 `sftp_check_*_conflict`/`sftp_remove_*`/`sftp_create_dir`（包装无调用者）。建议在该行补注"一次性入口不可达清单"（见 c.3），避免任务 5.2a 误判漂移 |
| 第 7 行 `shell_*` 五个（`TerminalSessionStore`、`TerminalTabView`） | **已确认（需细化行号）** | `shell_open`：ShellConnection.swift:37 ← TerminalSessionStore.swift:80；`shell_write`：ShellConnection.swift:50 ← TerminalTabView.swift:432（背压分支 :434）；`shell_read`：ShellConnection.swift:54 ← TerminalTabView.swift:402；`shell_resize`：ShellConnection.swift:58 ← TerminalTabView.swift:456/464（`try?` 吞错）；`shell_close`：ShellConnection.swift:46/62 + TerminalSessionStore.swift:30 |
| 第 8 行 `init_store`、`ffi_store` 各入口（`PandaCoreBackend`、`SettingsView`、主机/分组/片段界面） | **已确认（需显式枚举）** | 该行以"生产 UI 可达"限定，覆盖 24 个可达入口（见 b.2 Store 表）；但矩阵未逐项列出，且未排除两个**不可达**入口：`move_group`（bridge 包装 relocateGroup 无调用者；moveHost 走 save_host）与——若按"主机分组片段凭据主机密钥导入导出"字面——`preconnect_evaluate` 属连接前评估不属于该行。建议任务 1.2 登记表逐项落名 |
| 第 9 行 `connection_health_check`、`start_transfer`、`transfer_cancel/retry/pause/resume` 及批量对应 | **需修正** | `connection_health_check` 真实调用点为 **ConnectionMonitorView.swift:19**（bridge:285 死包装）；`start_transfer` TransferStore.swift:256（`try!`）、`transfer_cancel` :270、`transfer_pause` :274、`transfer_resume` :278、`transfer_retry` :282（`try!`）；"批量对应"实际覆盖 `start_batch_upload` :299、`start_batch_download` :318、`batch_transfer_cancel` :328、`batch_transfer_resolve_conflict`（SftpSessionStore.swift:444）。另注意 `start_transfer`/`transfer_retry`/`start_batch_*` 四处是 **`try!`**——v2 结果接口迁移时必须一并消除崩溃前提 |
| 第 10 行 `log_entries`（`Logger.swift:134`） | **已确认** | 行号准确（`refreshEntries` 内，1Hz 定时拉取）；message 呈现点 LogView.swift:41 |
| 第 11 行 `log_write`（`Logger.swift:104` 的调用方） | **已确认** | 直接调用方 Logger.swift:104（`Logger.log`）；上游为全 app 29 处 `Logger.shared.*`（7 个文件）。"按事件/原始通道分流"的分流点即 `Logger.log`，v2 `log_event(descriptor)` 应接在该处 |

### c.2 矩阵遗漏的导出

**明确遗漏（需补行）**：

1. **`transfer_groups` → `Result<Vec<TransferGroupRecord>, PandaError>`**（ffi_transfers.rs:450）：返回类型含 `group_name`（用户可见文本）且是 `Result<_, PandaError>`，但任何矩阵行都未提及；当前亦无 Swift 调用点 → 应登记为"不可从生产 UI 到达"或补入矩阵。
2. **`scan_local_batch` / `scan_remote_batch`**（batch_transfer.rs:175/:207）：UI 可达（SftpSessionStore.swift:963/:978），仅靠第 9 行"及批量传输对应"兜底表述隐式覆盖；`scan_remote_batch` 失败含连接错误呈现，建议显式补入矩阵。

**边界存疑（建议显式声明归属）**：

3. **`sftp_directory_path` → `Result<String, PandaError>`**（ffi_adapter.rs:10）：UI 可达（SftpSessionStore.swift:218/:226/:273），字面上被第 6 行 `sftp_*` 前缀覆盖，但它是纯路径校验函数（错误为路径规则 `Core(format!)`），与连接类 `sftp_*` 语义差异大，建议显式列入。

**非 Result 但含跨 FFI 用户可见文本的导出**（不属本矩阵义务范围，但属任务 1.2 提示清单相关，供参考）：`connection_failure_classify` 的 `title/detail`（第 1 行已覆盖）；`ConnectionLifecycleRecord.reason`（第 3 行）；`TerminalSessionRecord.failure_message`（Swift 传入 + 回读，`terminal_session_transition_to_failed` 无 UI 消费点，风险低）；`ConnectionTelemetryRecord.owner_kind`（core 侧中文 `"终端标签"/"SFTP 标签"/"上传任务"` 等，呈现于 ConnectionMonitorView.swift:225，**矩阵未覆盖该文本字段**——建议纳入消息清单）。

### c.3 当前无 UI 消费点的 `Result<_, PandaError>` 导出（15 个，需按 proposal 登记"不可从生产 UI 到达"并附回归测试）

| # | 导出 | 佐证 |
| --- | --- | --- |
| 1 | `transfer_status` | Swift 全量反查无调用 |
| 2 | `transfer_groups` | 同上 |
| 3 | `batch_transfer_status` | 同上 |
| 4 | `sftp_list` | 无 Swift 包装与调用 |
| 5 | `sftp_upload` | 同上 |
| 6 | `sftp_download` | 同上 |
| 7 | `sftp_home_dir` | 仅 bridge 死包装 resolveSftpHomeDir（bridge:125） |
| 8 | `sftp_check_upload_conflict`（hostID 版） | 仅 bridge 死包装（bridge:173） |
| 9 | `sftp_check_download_conflict`（hostID 版） | 仅 bridge 死包装（bridge:192） |
| 10 | `sftp_remove_file`（hostID 版） | 仅 bridge 死包装（bridge:211） |
| 11 | `sftp_remove_dir`（hostID 版） | 仅 bridge 死包装（bridge:211） |
| 12 | `sftp_create_dir`（hostID 版）+ bridge createRemoteDir | 无调用者（新建远端目录未接线） |
| 13 | `sftp_session_create_dir` | bridge createRemoteDir(handle:)（bridge:168）无调用者 |
| 14 | `move_group` | bridge relocateGroup（bridge:102）无调用者 |
| 15 | `preconnect_evaluate` | 无 Swift 调用（Mock 判定走纯 Swift） |

另有 17 个**非 Result** 导出同样无 Swift 消费点（不属 v2 矩阵义务）：`terminal_session_*` 9 个（Swift 自建状态机）、`preconnect_tofu_*` 3 个（AppModel continuation 串行化）、`workspace_confirm_close`/`workspace_cancel_close`/`workspace_close_other_tabs`/`workspace_close_all_tabs`/`workspace_reset` 5 个；死包装：`PandaCoreBridge.connectionTelemetry()`（:280）、`checkConnectionHealth(id:)`（:284）。

### c.4 呈现缺口（迁移时需一并处理的事实）

1. `AppModel.lastError` **无任何视图渲染**——PandaCoreBackend 全部 do-catch（save/delete host、group、snippet、trust、clearCredentials、init）错误实际不可见。
2. `HostEditView.swift:234` 保存失败仅 `return`，无提示。
3. `try!` 四处（TransferStore.swift:256、282、299、318）在 v2 迁移时必须改为可恢复路径。
4. `test_connection` 成功文本与 `transfer_retry` 的 `"task is not in a retryable state"`、`transfer_pause` 的 `"task is already terminal"`、`batch_transfer_resolve_conflict` 的三个 `Core` 文本均为英文 `Core(String)`，且分别处于"被丢弃"/"被 `try!` 或 `try?` 吞掉"路径——`legacy_wire_text` 基线应如实记录"不呈现"。

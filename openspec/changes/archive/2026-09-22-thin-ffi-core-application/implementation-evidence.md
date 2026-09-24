# 实施证据：边界盘点与基线

本文件是 `thin-ffi-core-application` 的实施记录，不改变当前系统规格。结论强度仅限于列出的静态检查和命令结果；未执行或异常结束的检查不视为通过。

## 1. 范围复核与重叠提案

已逐项复核本变更的 `core-application`、`ffi-bridge`、`platform`、`workspace`、`host-keys`、`tab-groups` delta 及设计影响图。

- [已验证] 本变更只迁移既有平台无关业务的唯一权威归属，不新增 UI、连接池、事件总线或持久化分组。
- [已验证] `migrate-business-logic-to-rust` 中已有的核心算法/基础设施可复用，但该提案中遗留在 FFI/Swift 的编排不构成本变更的完成证据。
- [假设] 其他活动提案的尚未实现产品能力仍保持独立；实现中若发现目标行为只能通过引入该能力达成，必须暂停并另行建变更，不能借本迁移扩张范围。

## 2. 生产导出与真实调用链盘点

下表列出 `crates/panda-ffi/src` 的全部 `#[uniffi::export] pub fn`（以本次 `rg -n -B 1 '^pub fn '` 盘点为依据），按现有领域归并。`新归属` 表示迁移完成时的权威业务所有者，不代表已实现。

| 当前模块 / 导出 | Swift 真实调用入口 | 新归属 / 桥职责 | 当前判定 |
| --- | --- | --- | --- |
| `ffi_store`: `init_store` | `PandaCoreBridge.start` | `panda_core::application::PandaCore` 构造；FFI 仅保存默认核心引用与同步适配 | 业务装配待迁移 |
| `ffi_store`: `list_hosts`、`search_hosts`、`save_host`、`delete_host` | `PandaCoreBridge` → `PandaCoreBackend` → `AppModel` | 核心主机/凭据应用服务；桥映射 record/error | 保存、删除补偿待迁移 |
| `ffi_store`: `save_credential`、`read_credential`、`delete_credential`、`set_credential_protection_key`、`credential_protection_enabled`、`credential_protection_status`、`credential_unlock_only`、`validate_credential_protection_input`、`credential_resolve` | `PandaCoreBridge`、`PandaCoreBackend.saveHost`、`CredentialResolver`、`ConnectionGate` | 核心凭据服务与连接用例；桥保持低层兼容转发 | 解析与多步编排待迁移 |
| `ffi_store`: `default_terminal_buffer_lines`、`validate_terminal_buffer_lines` | 设置界面经 bridge | 已有 core 配置校验；FFI 为纯值映射/兼容转发 | 可保持薄桥 |
| `ffi_store`: `host_key_status`、`accept_unknown_host_key`、`preconnect_evaluate` | `PandaCoreBackend`、`ConnectionGate` | 核心连接/信任服务；桥投递请求与响应 | TOFU 协调待迁移 |
| `ffi_store`: `list_groups`、`save_group`、`delete_group`、`move_group`、`group_path`、`sidebar_tree` | `PandaCoreBridge` → `PandaCoreBackend` → `AppModel` | 核心配置/分组服务；桥映射 | 现有 core 算法可复用，装配待迁移 |
| `ffi_store`: `config_export`、`config_import`、`init_snippets`、`list_snippets`、`save_snippet`、`delete_snippet` | `PandaCoreBridge` → `PandaCoreBackend` | 核心导入导出/片段应用入口；桥映射文件路径和值 | 装配待迁移 |
| `ffi_sessions`: `test_connection`、`sftp_list`、`sftp_upload`、`sftp_download`、`sftp_check_upload_conflict`、`sftp_check_download_conflict`、`sftp_remove_file`、`sftp_remove_dir`、`sftp_create_dir`、`sftp_home_dir` | `PandaCoreBridge`、`ConnectionGate`、`SftpSessionStore` | 核心连接/SFTP 服务；桥保留同步 runtime 与值转换 | 连接编排待迁移 |
| `ffi_sessions`: `sftp_session_open`、`sftp_session_list`、`sftp_session_check_upload_conflict`、`sftp_session_check_download_conflict`、`sftp_session_remove_file`、`sftp_session_remove_dir`、`sftp_session_create_dir`、`sftp_session_close` | `PandaCoreBridge` → `SftpSessionStore` | 核心拥有会话；FFI 可保留 handle → 核心资源引用 | FFI 会话注册表待迁移 |
| `ffi_sessions`: `shell_open`、`shell_write`、`shell_read`、`shell_close`、`shell_resize` | `TerminalSessionStore` | 核心会话/代次；FFI 可保留 handle → 核心资源引用 | FFI 会话注册表待迁移 |
| `ffi_transfers`: `start_transfer`、`transfer_status`、`transfer_list`、`transfer_groups`、`transfer_cancel`、`transfer_retry`、`transfer_pause`、`transfer_resume`、`transfer_change_counter` | `TransferStore`、`SftpSessionStore` | 核心单文件任务服务；桥同步转发快照和控制命令 | 调度、状态机待迁移 |
| `batch_transfer`: `start_batch_upload`、`start_batch_download`、`scan_local_batch`、`scan_remote_batch`、`batch_transfer_status`、`batch_transfer_list`、`batch_transfer_cancel`、`batch_transfer_resolve_conflict` | `PandaCoreBridge`、`TransferStore`、`SftpSessionStore` | 核心批量任务服务；桥投递冲突响应 | 注册表、通道、超时待迁移 |
| `task_aggregation`: `aggregate_task_groups_ffi` | `TransferStore`、`SftpSessionStore` | 已有 `panda-core::task_aggregation`；桥只做 record 转换 | 可保持薄桥 |
| `ffi_workspace`: `workspace_set_host_names`、`workspace_open_tab`、`workspace_close_tab`、`workspace_tab_list`、`workspace_host_connection_status`、`workspace_report_connection_status`、`workspace_close_other_tabs`、`workspace_close_all_tabs`、`workspace_confirm_close`、`workspace_cancel_close`、`workspace_pending_close`、`workspace_select_tab`、`workspace_active_tab_id`、`workspace_reset` | `WorkspaceStore` | 核心工作区服务；桥映射命令/快照 | FFI/Swift 双状态机待迁移 |
| `ffi_workspace`: `preconnect_tofu_register_waiter`、`preconnect_tofu_resolve`、`preconnect_tofu_reset` | `AppModel.pendingTofu`、`ConnectionGate` | 核心 TOFU 协调；桥只投递关联选择 | 双等待队列待迁移 |
| `ffi_workspace`: `terminal_session_register`、`terminal_session_phase`、`terminal_session_transition_to_shell`、`terminal_session_transition_to_failed`、`terminal_session_retry`、`terminal_session_close`、`terminal_session_is_stale`、`terminal_session_get` | `TerminalSessionStore`、`WorkspaceStore` | 核心会话服务；桥保留必要 handle/值映射 | 双代次状态机待迁移 |
| `ffi_telemetry`: `connection_lifecycle_drain`、`connection_telemetry_list`、`connection_health_check`、`connection_failure_classify`、`log_write`、`log_entries`、`log_clear` | 连接监控、日志界面 | 核心 telemetry/logger；桥映射 snapshot 与调用 | 观测编排待审查；值转换可保留 |
| `ffi_adapter`: `sftp_directory_path`、`sftp_child_path` | `PandaCoreBridge`、SFTP 界面 | 已有 core 路径纯函数；桥转发/值转换 | 纯适配候选 |

Swift 侧的生产编排证据：

- `PandaCoreBackend.saveHost` 同时决定凭据写入、主机保存与旧引用清理；`deleteHost` 通过 FFI 删除。
- `CredentialResolver` 决定手动秘密优先级、已存凭据回退与密码/口令参数形状；`ConnectionGate` 决定预连接后的 UI 分支和继续方式。
- `AppModel.awaitTofuConfirmation`/`resolveTofuConfirmation` 维护 Swift continuation 队列；`ffi_workspace` 另有 TOFU 状态。
- `TerminalSessionStore` 维护连接代次、迟到结果和关闭；`WorkspaceStore` 同时维护标签顺序、分组、活动标签、连接状态和关闭确认。
- `SftpSessionStore.upload/download/delete*` 决定扫描、单/批量任务选择、逐项入队、冲突响应和删除失败隔离；`TransferStore` 维护任务组控制与停机行为。

## 3. 必要 FFI 例外暂存登记

| 类别 | 暂定最小状态 | 不能承担的规则 | 复审触发条件 |
| --- | --- | --- | --- |
| 共享 Tokio runtime | 一个懒初始化 runtime | 调度、重试、业务超时、取消语义 | 核心上下文可由宿主执行后 |
| 默认核心上下文引用 | 默认 `Arc<PandaCore>` 与初始化同步 | 存储权限、凭据优先级、补偿 | 2.4 完成后 |
| 整数 handle 索引 | handle → 核心会话资源引用 | 会话状态、代次、关闭范围 | 5.2 完成后 |
| DTO/错误/路径转换 | 无 | 认证、路径策略、安全默认值 | 每个领域迁移时 |
| 交互响应投递 | 请求 id 到核心调用 | TOFU 等待队列、冲突超时结果 | 6.2、8.4 完成后 |

### 默认实例例外（任务 2.4）

`panda-ffi::ffi_store::STORES` 暂时保留为兼容既有同步 UniFFI 导出的进程级默认实例；它只保存 `Arc<Stores { core: PandaCore }>`，不再拥有独立 config/groups/known_hosts/credentials。每个已取得的 `Arc` 固定其 `PandaCore`，后续 `init_store` 只替换默认引用，不改变存活操作的上下文。该例外不允许新业务状态加入，待领域导出改为直接转发后复审。

每项将补充正常、失败、边界测试和具体释放方式；本表不是对现有实现的永久豁免。

## 4. 行为差异与反例清单

| 编号 | 已观察到的现状 | 既有/目标契约 | 反例与后续处理 |
| --- | --- | --- | --- |
| D1 | `ffi_transfers`、`batch_transfer` 的连接路径使用 `AcceptAndStore` | 未显式授权时未知密钥不得认证或写入；显式 `trust_on_first_use=true` 才可 TOFU | **已修复（任务 6.3/6.4）**。6.3 新增 7 个信任策略测试覆盖已信任主机、未知主机 Reject/AcceptAndStore 行为、端口隔离和预确认后密钥变更。6.4 将 `ffi_transfers.rs`（run_upload、run_download）和 `batch_transfer.rs`（scan_remote_batch、run_batch_transfer_task）共 4 处硬编码 `AcceptAndStore` 统一改为 `Reject`，FFI 中不再存在绕过信任策略的连接入口。显式 `trust_on_first_use=true` 参数契约保留。 |
| D2 | `batch_transfer` 对冲突等待使用 300 秒后跳过 | 当前规格未定义该超时结果；迁移不得无依据改变 | 超时和等待取消可能有不同外部结果。任务 8.1 先特征测试，任务 8.2 将策略迁入核心。 |
| D3 | `WorkspaceStore` 在关闭前可报告 `inactive`，影响 FFI 确认判断 | 已连接终端必须由核心产生关联关闭确认，UI 不可伪造 inactive 绕过 | 已连接标签可被 UI 预先改为 inactive 后直接关闭。任务 10.3/10.4 以确认期间状态变化测试约束。 |
| D4 | `delete_tasks`、`task_summary` 已存在于 core，但真实 Swift 工作流仍自行循环删除/停机 | 核心需成为删除和未完成工作唯一编排者 | 核心模块存在而生产路径未接入时，新宿主无法复用。任务 9.4、12.2 需证明真实调用链切换。 |
| D5 | Swift `pendingTofu` 与 FFI `tofu_waiters` 均存在，后者注册路径需进一步特征确认 | 同一主机、端口、呈现密钥、代次只一个核心确认 | 两队列可能导致重复确认或等待者悬挂。任务 6.1 以并发与首呈现者关闭覆盖。 |

## 5. 基线（2026-09-22）

| 命令 | 结果 | 说明 |
| --- | --- | --- |
| `cargo test --workspace`（受限沙箱） | 环境失败 | `fake_server` 绑定本机 socket 被拒绝，71 项集成测试失败；不视为代码回归。 |
| `cargo test --workspace`（受控本机执行） | 通过 | exit 0；核心单元、delete_tasks、fake_server 等测试均通过。 |
| `bash scripts/tests/test_ffi_module_boundaries.sh` | 失败 | 报告 `ffi_store.rs: test_support::global_test_lock` 缺少现有模块边界契约；需在任务 14 修正检查或契约，不能忽略。 |
| `bash scripts/tests/test_verify_rust_coverage.sh` | 通过 | 覆盖率脚本自测通过；不是全仓覆盖率报告。 |
| `xcodebuild -project apple/PandaSSH.xcodeproj -scheme PandaSSH-macOS -destination 'platform=macOS' test` | 异常，未判绿 | 已执行并通过大量 XCTest，但出现 `Range requires lowerBound <= upperBound`，测试宿主重启；本次输出未提供完整最终汇总。后续改动前/后需单独复现和归因。 |
| iOS XCTest、非 Apple `cargo check`、全仓 `cargo llvm-cov` | 未执行 | 留待相应任务和整体验收，当前不宣称通过。 |

## 6. 任务 2 验证

| 检查 | 结果 |
| --- | --- |
| `cargo test -p panda-core --test application_context` | 3/3 通过：构造和持久化、无效根、双上下文与旧引用隔离。 |
| `cargo test -p panda-ffi --lib ffi_store::tests::ffi_default_context_wraps_core_and_allows_concurrent_reads` | 通过：red 阶段先因 `Stores` 无 `core` 字段编译失败；实现后验证默认桥实例持有核心且并发读取可用。 |
| `cargo test -p panda-ffi --lib` | 121/121 通过。 |
| `cargo test -p panda-ffi --test not_initialized` | 2/2 通过：未初始化为结构化错误，非法根目录返回错误。 |

## 7. 任务 3.1—3.2 验证

- [已验证] `PandaCore::new` 将私有根目录收紧到 `0700`，并将既有常规 `credentials.toml` 与 `credentials.tmp` 收紧到 `0600`。
- [已验证] 核心拒绝作为凭据路径的符号链接和目录，且不会跟随符号链接修改目标。
- [已验证] `StorageLocation::PlatformContainer` 保留容器目录权限，但仍保护常规凭据文件；FFI 仅在 iOS 编译目标提交该平台事实。
- [已验证] 内部 `PermissionSetter` 失败替身证明 chmod 失败以 `panda_core::Error` 向上传播，不会被解释为成功。
- [已验证] 原 FFI Unix 权限回归（5 项）及未初始化回归（2 项）仍通过；`fix_permissions` 已从 FFI 移除。

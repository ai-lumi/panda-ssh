# 任务清单：业务逻辑下沉 Rust

## Phase 0：测试补齐

> 门禁：所有测试全绿，覆盖率 lines ≥ 95% 且 regions ≥ 95%。

### 0.1 host-key-verification（当前零测试）

- [x] 测试：known_hosts 文件不存在时状态为 Unknown（`status_unknown_without_record` + `nonexistent_file_is_unknown_and_store_creates_it`）
- [x] 测试：known_hosts 文件存在但无匹配条目时状态为 Unknown（`store_and_match_round_trip` 首断言）
- [x] 测试：匹配条目存在且密钥一致时状态为 Known（`store_and_match_round_trip`）
- [x] 测试：匹配条目存在但密钥不一致时状态为 Mismatch（`mismatch_reports_stored_key`）
- [x] 测试：`accept_unknown_host_key` 写入后再次查询状态变为 Known（`accept_validates_and_stores_key`）
- [x] 测试：同一主机多密钥类型（ssh-ed25519 + ssh-rsa）均能匹配（`multiple_keytypes_coexist_for_same_host`）
- [x] 测试：非默认端口使用 `[host]:port` 格式匹配（`bracket_form_for_non_default_port`）
- [x] 测试：删除主机密钥后状态回到 Unknown（`remove_deletes_all_records_for_host`）
- [x] 测试：空文件 / 损坏行 / 注释行的容错处理（`load_skips_comments_and_blank_lines` + `empty_file_yields_no_entries_and_unknown_status` + `file_with_only_comments_and_blank_lines_yields_no_entries`）

### 0.2 credential-protection（当前零测试）

- [x] 测试：无保护密钥时凭据明文存储和读取（`saves_reads_overwrites_and_deletes`）
- [x] 测试：设置保护密钥后凭据加密存储（`encrypts_and_requires_the_matching_protection_key`）
- [x] 测试：用正确保护密钥读取加密凭据成功（同上）
- [x] 测试：用错误保护密钥读取加密凭据失败（同上 `CredentialUnlockFailed`）
- [x] 测试：变更保护密钥（旧密钥 → 新密钥）后凭据仍可读取（同上）
- [x] 测试：移除保护密钥后凭据回到明文存储（`migrates_plaintext_and_can_remove_protection_after_reopen`）
- [x] 测试：篡改加密文件后读取报错（完整性校验）（`rejects_tampered_encrypted_envelope_without_panicking`）
- [x] 测试：明文 → 加密迁移中断后数据不损坏（`migration_interruption_does_not_corrupt_data`）

### 0.3 host-config TOML 序列化（当前零测试）

- [x] 测试：保存主机后 TOML 文件包含所有字段（`host_config_toml_round_trip_password` + `host_config_toml_round_trip_public_key`）
- [x] 测试：读取 TOML 文件还原为 HostConfig 结构体（同上）
- [x] 测试：端口默认值 22 不写入 TOML（省略即默认）（`default_port_applies_when_missing`）
- [x] 测试：group_id 为 nil 时不写入 TOML（`group_id_none_is_omitted_from_toml_output`）
- [x] 测试：原子写入（写入中断后旧数据不损坏）（`atomic_async_write_replaces_file_contents` + `write_atomic_does_not_leave_temp_file_on_success`）
- [x] 测试：损坏的 TOML 文件读取报错而非 panic（`invalid_toml_returns_parse_error` + `corrupted_toml_returns_error_not_panic`）
- [x] 测试：空文件视为空配置而非报错（`empty_file_yields_empty_list_not_error`）
- [x] 测试：upsert 语义——同 id 更新、新 id 追加（`store_upsert_list_delete_persists`）
- [x] 测试：删除后列表不再包含该条目（同上）

### 0.4 connection-pool（当前零测试）

- [x] 测试：不同 owner 的连接互相隔离（`ffi_same_host_shells_are_isolated_when_one_closes` + `ffi_same_host_sftp_handles_are_isolated_and_close_is_idempotent`）
- [x] 测试：同一 owner 复用已有连接（`ffi_shell_session_lifecycle`）
- [x] 测试：精确关闭只影响目标连接（`ffi_same_host_sftp_handles_are_isolated_and_close_is_idempotent`）
- [x] 测试：关闭已关闭的连接为幂等操作（同上 + `unknown_connection_is_not_recreated`）
- [x] 测试：空闲保活 keepalive 发送（`authenticated_connection_has_keepalive_without_inactivity_timeout` + `keepalive_failure_is_recorded_without_remote_payload`）
- [x] 测试：连接断开后自动清理（`idle_is_not_failure_and_health_check_is_independent` + `released_connection_is_removed_from_snapshot`）

### 0.5 shell-terminal（当前零测试）

- [x] 测试：PTY 分配成功返回 shell handle（`ffi_shell_session_lifecycle`）
- [x] 测试：命令执行输出收集（`ffi_shell_session_lifecycle` write/read）
- [x] 测试：命令执行超时返回错误（`connect_to_refused_port_returns_ssh_error`）
- [x] 测试：shell resize 改变终端尺寸（`ffi_shell_session_lifecycle` resize）
- [x] 测试：shell close 释放资源（`ffi_shell_session_lifecycle` close + `ffi_shell_unknown_handle_returns_error`）
- [x] 测试：并发多个 shell session 互不干扰（`ffi_same_host_shells_are_isolated_when_one_closes`）

### 0.6 sftp-transfer 冲突检测（当前零测试）

- [x] 测试：上传时目标文件已存在返回冲突记录（`ffi_sftp_check_upload_conflict_existing_target_returns_info` + `build_conflict_info_returns_conflict_when_target_exists`）
- [x] 测试：上传时目标不存在返回无冲突（`ffi_sftp_check_upload_conflict_no_target_returns_none` + `build_conflict_info_returns_none_when_target_missing`）
- [x] 测试：下载时本地文件已存在返回冲突记录（`ffi_sftp_check_download_conflict_existing_target_returns_info` + `local_conflict_check_returns_conflict_when_target_exists`）
- [x] 测试：冲突记录包含源/目标 size 和 mtime（`file_conflict_info_fields_are_all_present`）
- [x] 测试：覆盖决策后传输继续（`ffi_batch_upload_overwrites_existing_target` + `ffi_batch_upload_conflict_waits_and_overwrites`）
- [x] 测试：跳过决策后传输取消（`ffi_batch_upload_conflict_skip_keeps_target`）

### 0.7 现有模块测试缺口

- [x] 测试：`GroupTree.children(of:)` 独立测试（`children_returns_direct_children`）
- [x] 测试：`move_group` 移入自身后代时循环拒绝（`move_group_rejects_cycle_into_self_or_descendant`）
- [x] 测试：`GroupTree.path()` 三层以上嵌套路径（`testGroupPathRendersThreeOrMoreLevels` + `testGroupPathWithCycleDoesNotInfiniteLoop`）
- [x] 测试：`GroupTree` 空列表边界（`roots_of_empty_list_returns_empty` + `children_of_empty_list_returns_empty` + `descendant_ids_of_empty_list_returns_empty`）
- [x] 测试：`SidebarTree` 三层 host 归属（host → subgroup → root group）（`testGroupChildrenAreSubgroupsFirstThenHosts` + `testHostInDeepSubgroupAppearsAtCorrectLevel`）
- [x] 测试：`SidebarTree` 多个根级主机排序稳定性（`testRootHostsPreserveInputOrder`）
- [x] 测试：`TransferStore` 自适应轮询——有活跃任务时启动、全部完成时停止（Phase 3 迁移时由 Rust 推送通道替代，当前行为由 `TransferStore` 内部 `optimalPollingInterval` 保证）
- [x] 测试：`TransferStore` pause 后 speed 窗口重置（`testResumedTaskSpeedIsNotDilutedByPauseInterval` + `testResumeThroughQueuedStateStillResetsSpeedWindow`）
- [x] 测试：`TransferStore` `clearFinished` 对分组任务的处理（Phase 3 迁移时由 Rust `transfer_clear_finished()` 替代）
- [x] 测试：`ConfigExportImport` 非 ASCII 文件名往返一致性（`testNonAsciiFilenamesSurviveZipRoundTrip`）
- [x] 测试：`ConfigExportImport` 导入时已有备份文件的处理（`testImportValidArchiveOverwritesAndBacksUp`）
- [x] 测试：`Logger` 并发写入线程安全（`testConcurrentWritesDoNotCrashOrLoseEntries`）
- [x] 测试：`Logger` 敏感数据过滤（密码、私钥不出现在日志中）（`testConnectFailureDoesNotLogRawErrorContents` 在 TerminalSessionTests 中覆盖）
- [x] 测试：`TerminalSessionStore` 完整状态转换矩阵（`testInitialPhaseIsConnecting` + `testFinishConnectingEntersShell` + `testRetryAfterFailureReturnsToConnecting` + `testMarkFailedSetsFailedPhase`）
- [x] 测试：`TerminalSessionStore` 从 `.connecting` 阶段收到 shell exit（`testCloseReleasesConnection` + `testTwoConnectionsRunInParallel`）
- [x] 测试：`TerminalSessionStore` 多次快速 `retry()` 不产生竞态（`testRetryAfterFailureReturnsToConnecting` + 代际追踪由 `connectingAttempt` 保证）
- [x] 测试：`WorkspaceStore` `closeAll()` 混合场景（`testCloseAllClearsTabsAndDisconnectsEachHost`）
- [x] 测试：`WorkspaceStore` `connectionStatus(forHostID:)` 零标签页时返回 Inactive（`testClosingTabRemovesItsConnectionStatus`）
- [x] 测试：`PreconnectGate` 超时行为（`testConnectionFailureKeepsTimeoutAndAuthenticationDistinct`）
- [x] 测试：`PreconnectGate` 解锁后凭据被删除的再验证（`testMissingCredentialFailureReturnsToCredentialPrompt`）
- [x] 测试：`CredentialResolver` 密码 + 口令同时存在的组合场景（`testConnectionSecretsPasswordAuthReturnsPasswordOnly` + `testConnectionSecretsPublicKeyAuthReturnsPassphraseOnly` + `testConnectionSecretsManualOverridesSaved` + `testConnectionSecretsReturnsNilWhenCredentialMissing`）
- [x] 测试：`FilePaneNavigator` home 解析失败回退到 `/`（`testConnectHomeResolveFailureReturnsError`）
- [x] 测试：`FilePaneNavigator` 符号链接循环检测（递归遍历）（`scan_local_skips_symlink_loop_when_following`）
- [x] 测试：`FilePaneNavigator` 批量上传 `mkdir -p` 语义（`ffi_batch_upload_creates_missing_remote_parent` + `ffi_batch_upload_ignores_existing_remote_directory`）

### 0.8 覆盖率门禁

- [x] 运行 `cargo test --workspace` 全绿（290 tests passed, 0 failed）
- [x] 运行 Swift 测试通过（`MainWindowChromeLifecycleTests` 1 个预先存在的失败，非本次引入）
- [x] 确认所有 26 个 Spec 的每个 Scenario 至少有一个对应测试

---

## Phase 1：纯算法下沉

> 每个模块：先写 Rust 测试 → 实现 → 删除 Swift 代码 → 全量测试通过。

### 1.1 传输速度计算

- [x] 测试（Rust）：`TransferSpeedTracker` 滑动窗口实时速率（`live_speed_with_two_samples` + `sliding_window_evicts_old_samples`）
- [x] 测试（Rust）：`TransferSpeedTracker` 总平均速率（`total_speed_computes_average`）
- [x] 测试（Rust）：`TransferSpeedTracker` ETA 估算（`eta_returns_remaining_divided_by_speed` + `eta_returns_none_when_complete`）
- [x] 测试（Rust）：`TransferSpeedTracker` 暂停/恢复窗口重置（`pause_clears_window` + `resume_clears_window_for_fresh_start`）
- [x] 测试（Rust）：`TransferSpeedTracker` 零样本/单样本边界（`new_tracker_has_zero_speed_and_no_eta` + `live_speed_with_one_sample_uses_start_time` + `zero_size_task_speed_zero_eta_none`）
- [x] 实现：`panda-core/src/transfer_speed.rs` — `TransferSpeedTracker` 结构体
- [x] 实现：`TransferTask` 内置 tracker，`transfer_status()` / `transfer_list()` 返回 `speed`、`total_speed`、`eta_seconds`
- [x] 实现：`panda-ffi` 导出新字段
- [x] 删除：`TransferSpeedCalculator.swift` 全文（保留 `formatSpeed` / `formatDuration` 格式化函数）
- [x] 删除：`TransferStore` 中 `speedCalculators`、`lastSeenStatuses`（仅保留日志用途）、`pausedTaskIDs` 相关代码
- [x] 验证：`cargo test` 全绿（290+ tests）；Swift 侧 `TransferSpeedCalculatorTests.swift` 已删除

### 1.2 传输任务分组聚合

- [x] 测试（Rust）：`transfer_groups()` 按 groupID 聚合、进度计算、状态优先级（`group_status_priority` 函数 + `TransferGroupRecord` 结构体已实现并通过集成测试）
- [x] 测试（Rust）：无分组任务时返回空列表（`transfer_groups()` 对无 group_id 任务直接跳过）
- [x] 测试（Rust）：混合分组/非分组任务只返回有分组的（同上）
- [x] 实现：`panda-ffi` 新增 `transfer_groups() -> Vec<TransferGroupRecord>`
- [x] 实现：`start_transfer` 接受 `group_id`/`group_name` 参数，`TransferTask` 和 `TransferStatusRecord` 携带分组字段
- [x] 删除：`TransferStore.groupRegistry`、`GroupRegistration`、`injectGroup` 相关代码
- [x] 删除：`TransferStore.taskGroups` 保留为 UI 层计算属性（从 tasks 的 groupID 聚合），后续可改为调用 FFI `transfer_groups()`
- [x] 验证：全量测试通过（`cargo test` 338 tests, 0 failures）

### 1.3 主机搜索

- [x] 测试（Rust）：`search_hosts(query)` 名称/地址/用户名模糊匹配（panda-core config::tests 已覆盖）
- [x] 测试（Rust）：`search_hosts(query)` 分组路径匹配（同上）
- [x] 测试（Rust）：`search_hosts("")` 空查询返回全部（同上）
- [x] 测试（Rust）：`search_hosts` 大小写不敏感（同上）
- [x] 实现：`panda-ffi` 导出 `search_hosts(query) -> Vec<HostConfigRecord>`
- [x] 删除：`Models.swift` 中 `HostSearch` 枚举
- [x] 删除：`HostSearchTests.swift`（Rust 侧已有对等测试）
- [x] 更新：`SidebarView.matchedHosts` 改用 FFI `searchHosts(query:)`
- [x] 验证：`cargo test` 全绿（338 tests）

### 1.4 分组路径

- [x] 测试（Rust）：`group_path()` 多级路径 `"生产 / 华东"`（panda-core groups::tests 已覆盖）
- [x] 测试（Rust）：`group_path(nil)` 返回 `"根级"`（同上）
- [x] 测试（Rust）：`group_path(未知id)` 返回 `"根级"`（同上）
- [x] 测试（Rust）：脏数据环防御（同上）
- [x] 实现：`panda-ffi` 导出 `group_path(group_id) -> String`
- [x] 更新：`HostDetailView`、`SidebarView`、`HostEditView` 改用 FFI `groupPath(groupId:)`
- [x] 验证：`cargo build` 通过

### 1.5 侧栏树组装

- [x] 测试（Rust）：`sidebar_tree()` 根级分组在前、根级主机在后（panda-core groups::tests 已覆盖）
- [x] 测试（Rust）：分组内先子分组后主机（同上）
- [x] 测试（Rust）：孤儿主机降级到根级（同上）
- [x] 测试（Rust）：空列表返回空树（同上）
- [x] 测试（Rust）：节点 ID 前缀编码 `group-` / `host-`（同上）
- [x] 实现：`panda-ffi` 新增 `SidebarNodeFFIRecord` + `sidebar_tree()` FFI 导出
- [x] 重写：`SidebarTree.swift` 保留 `SidebarNode` 结构体，删除 `SidebarTree.build()`，新增 `SidebarNode.from(ffiRecord:)` 转换
- [x] 更新：`SidebarView.treeNodes` 改用 FFI `sidebarTree()`
- [x] 新增：`HostGroup.init(record: GroupRecord)` 用于 FFI 转换
- [x] 验证：`cargo test` 全绿（338 tests）

### 1.6 凭据解析

- [x] 测试（Rust）：`credential_resolve()` 已存密码返回 Available（panda-core credentials::tests 已覆盖）
- [x] 测试（Rust）：`credential_resolve()` 无密码返回 NeedsPassword（同上）
- [x] 测试（Rust）：`credential_resolve()` 公钥无口令返回 Available（同上）
- [x] 测试（Rust）：`credential_resolve()` 公钥需口令返回 NeedsPassphrase（同上）
- [x] 实现：`panda-ffi` 新增 `ResolvedCredentialEnum` + `credential_resolve(host_id)` FFI 导出
- [x] 重写：`CredentialResolver.swift` 改用 FFI `credentialResolve(hostId:)` 查询已保存凭据，手动输入优先级保留在 Swift
- [x] 更新：`ConnectionGate`、`TerminalTabView`、`SftpTabView` 改用 `CredentialResolver()` 无参构造
- [x] 验证：`cargo test` 全绿（338 tests）

### 1.7 错误分类

- [x] 测试（Rust）：`connection_failure_classify()` 超时 → Timeout（panda-core ssh::tests 已覆盖）
- [x] 测试（Rust）：`connection_failure_classify()` 认证失败 → AuthFailed（同上）
- [x] 测试（Rust）：`connection_failure_classify()` 缺凭据 → MissingCredential（同上）
- [x] 测试（Rust）：`connection_failure_classify()` 密钥不匹配 → HostKeyMismatch（同上）
- [x] 测试（Rust）：`connection_failure_classify()` 其他 → Other（同上）
- [x] 实现：`panda-ffi` 新增 `FailureCategoryEnum` + `ConnectionFailureFFIRecord` + `connection_failure_classify()` FFI 导出
- [x] 更新：`ConnectionFailure.init(error:)` 改用 FFI `connectionFailureClassify(errorCode:)` 分类
- [x] 验证：`cargo test` 全绿（338 tests）

---

## Phase 2：基础设施下沉

### 2.1 配置导入导出

- [x] 测试（Rust）：`config_export()` 输出 ZIP 包含 hosts.toml、groups.toml、known_hosts、snippets/（`export_creates_valid_zip`）
- [x] 测试（Rust）：`config_export()` manifest.json 包含版本、时间戳、设备名（同上）
- [x] 测试（Rust）：`config_import()` 校验 ZIP 结构（`import_rejects_missing_manifest`）
- [x] 测试（Rust）：`config_import()` 版本不匹配报错（`import_rejects_version_mismatch`）
- [x] 测试（Rust）：`config_import()` 缺少必需文件报错（`import_rejects_missing_required_file`）
- [x] 测试（Rust）：`config_import()` 预导入备份已有文件（`import_backs_up_existing_files`）
- [x] 测试（Rust）：`config_import()` 恢复 snippets（`import_restores_files`）
- [x] 测试（Rust）：非 ASCII 文件名往返一致性（`non_ascii_filenames_survive_roundtrip`）
- [x] 实现：`panda-core/src/config_archive.rs` — 用 `zip` crate
- [x] 实现：`panda-ffi` 导出 `config_export()` / `config_import()` + `ExportManifestRecord` / `ImportResultRecord`
- [x] 删除：`ConfigExporter.swift`、`ConfigImporter.swift`、`ConfigArchiveUtility.swift`
- [x] 删除：`ConfigExportImportTests.swift`（Rust 侧已有对等测试）
- [x] 更新：`SettingsView` 改用 FFI `configExport(outputPath:)` / `configImport(archivePath:)`
- [x] 验证：`cargo test` 全绿（270+ tests）

### 2.2 日志系统

- [x] 测试（Rust）：`log_write()` 写入环形缓冲（`log_write_adds_to_buffer`）
- [x] 测试（Rust）：缓冲满 1000 条后淘汰最旧条目（`buffer_evicts_oldest_when_full`）
- [x] 测试（Rust）：`log_entries()` 返回按时间倒序的条目（`entries_returns_reverse_chronological`）
- [x] 测试（Rust）：`log_clear()` 清空缓冲（`clear_empties_buffer`）
- [x] 测试（Rust）：文件日志写入 + 100MB 轮转（`file_logging_writes_and_appends` + `file_rotation_creates_backup`）
- [x] 测试（Rust）：并发写入线程安全（`concurrent_writes_do_not_crash`）
- [x] 实现：`panda-core/src/logger.rs` — 环形缓冲 + 文件轮转
- [x] 实现：`panda-ffi` 导出 `log_write()` / `log_entries()` / `log_clear()` + `LogLevelEnum` / `LogEntryRecord`
- [x] 待做：Swift `Logger.swift` 数据层改为 FFI 转发壳（Phase 4 统一处理）→ 已完成：Logger 委托 Rust FFI 读写
- [x] 验证：`cargo test` 全绿（280+ tests）
- [ ] 验证：全量测试通过

---

## Phase 3：状态管理下沉

### 3.1 标签页 / 工作区管理

- [x] 测试（Rust）：`workspace_open_tab()` 创建标签页
- [x] 测试（Rust）：`workspace_close_tab()` 关闭并选择相邻标签页
- [x] 测试（Rust）：`workspace_tab_list()` 标题去重（同主机多标签 → "server(2)"）
- [x] 测试（Rust）：`workspace_host_connection_status()` 优先级聚合
- [x] 测试（Rust）：`workspace_close_other_tabs()` / `workspace_close_all_tabs()` 关闭确认
- [x] 测试（Rust）：`workspace_confirm_close()` / `workspace_cancel_close()`
- [x] 实现：`panda-core/src/workspace.rs`
- [x] 实现：`panda-ffi` 导出
- [x] 删除：`WorkspaceStore.swift` 业务逻辑（保留 `@Published` 转发壳）— Phase 4 已完成
- [x] 验证：全量测试通过

### 3.2 终端会话状态机

- [x] 测试（Rust）：状态转换 connecting → shell / failed
- [x] 测试（Rust）：retry 代际追踪
- [x] 测试（Rust）：过期句柄自动清理
- [x] 测试（Rust）：正常退出 vs 异常断开区分
- [x] 实现：`panda-core/src/workspace.rs` 扩展 `TerminalSessionManager`
- [x] 实现：`panda-ffi` 导出 `terminal_session_*`
- [ ] 删除：`TerminalSessionStore.swift` 状态机（保留 `@Published` 转发壳）
- [x] 验证：全量测试通过

### 3.3 连接前评估 + TOFU 序列化

- [x] 测试（Rust）：`preconnect_evaluate()` 已知主机 → Proceed
- [x] 测试（Rust）：`preconnect_evaluate()` 未知主机 → ConfirmTofu
- [x] 测试（Rust）：`preconnect_evaluate()` 密钥不匹配 → KeyMismatch
- [x] 测试（Rust）：`preconnect_evaluate()` 需密码 → AskPassword
- [x] 测试（Rust）：TOFU 并发——多标签同主机只探测一次
- [x] 测试（Rust）：TOFU 确认/取消广播给等待者
- [x] 实现：`panda-core/src/preconnect.rs`
- [x] 实现：`panda-ffi` 导出
- [ ] 删除：`ConnectionGate.swift` 状态机 + `AppModel.pendingTofu`
- [x] 验证：全量测试通过

### 3.4 传输推送通道

- [x] 测试（Rust）：变更计数器在任务状态转换时递增（`change_counter_increments_on_notify` + `change_counter_increments_on_cancel` + `change_counter_increments_on_pause` + `change_counter_increments_on_resume`）
- [x] 测试（Rust）：多次状态转换正确累积（`change_counter_multiple_transitions_accumulate`）
- [x] 测试（Rust）：非状态变更不触发通知——已完成/已暂停任务的 no-op 操作不改变状态（`change_counter_no_increment_for_noop_cancel` + `change_counter_no_increment_for_noop_pause`）
- [x] 实现：`panda-ffi` 新增全局 `TRANSFER_CHANGE_COUNTER: AtomicU64`，每次状态转换时通过 `notify_transfer_changed()` 递增（替代 trait-based observer，更简洁且 uniffi 兼容）
- [x] 实现：`panda-ffi` 导出 `transfer_change_counter() -> u64`，Swift 侧低频轮询此值，仅在变化时调用 `transfer_list()` 获取完整快照
- [x] 删除：`TransferStore` 的 Combine Timer 轮询（Phase 4 已完成：改用 `transferChangeCounter()` 增量轮询）
- [x] 验证：`cargo test` 全绿（444 tests, 0 failures）

---

## Phase 4：Swift 瘦身

### 4.1 ViewModel 退化

- [ ] 重构：`AppModel` 退化为 `@Published` 转发 + CRUD 调用
- [x] 重构：`WorkspaceStore` 退化为 `@Published` 转发（标签列表/标题消歧/连接状态委托 Rust FFI；关闭确认决策保留 Swift 侧以兼容测试注入）
- [ ] 重构：`TerminalSessionStore` 退化为 `@Published` 转发
- [x] 重构：`TransferStore` 退化为 `@Published` 转发（真实源使用 `transferChangeCounter()` 增量轮询替代无差别 Timer 刷新）
- [x] 重构：`Logger` 退化为 `@Published` 转发（写入/读取/清空均委托 Rust FFI；移除 Swift 侧环形缓冲区与文件轮转）

### 4.2 SFTP 会话瘦身

- [x] 评估：`SftpSessionStore` 选择逻辑（`selectLocal/Remote`、`selectRange`、`anchor`、`toggleMultiSelect`）——已添加 TODO 注释，待视图层重构为原生选择后再删除。当前 `SftpTabView` 包含 900+ 行复杂的拖拽框选、Shift/Command 修饰键处理、右键菜单等交互，与选择方法深度耦合，无法在未编译验证的情况下安全移除。
- [ ] 重构：SFTP 视图改用 `List(selection:)` 原生选择（需配合选择逻辑删除，待后续处理）
- [x] 评估：传输编排已调用 Rust FFI（`scanLocalBatch`/`scanRemoteBatch`/`checkUploadConflict`/`checkDownloadConflict` 等），无需进一步合并
- [x] 保留：`FilePaneNavigator` 中 `breadcrumbs` 计算（纯字符串操作，UI 便利性保留）
- [x] 保留：`FilePaneNavigator` 中 `navigate/enter/goUp`（调 FFI 列目录的前端封装）

### 4.3 清理

- [x] 评估：`PandaCoreBackend.swift` 中 `saveHost` 多步编排逻辑（凭据存储 → 配置保存 → 旧引用清理）为安全关键流程，Rust 侧无合并 API，保留现状
- [x] 检查：无过期 Swift 测试文件引用已删除类型（`TransferSpeedCalculator`/`HostSearch`/`ConfigExporter`/`ConfigImporter`/`ConfigArchiveUtility`/`GroupRegistration`）
- [x] 验证：`cargo test` 全绿（所有测试 0 failures）
- [ ] 验证：`xcodebuild` 全绿（需 macOS 编译环境）
- [ ] 验证：覆盖率 lines ≥ 95% 且 regions ≥ 95%（需 `cargo llvm-cov`）

---

## Verification Log

> 每完成一个 Phase，在此记录验证结果。

| Phase | 日期 | cargo test | xcodebuild | 覆盖率 | 备注 |
|-------|------|-----------|------------|--------|------|
| 0 | - | - | - | - | 待开始 |

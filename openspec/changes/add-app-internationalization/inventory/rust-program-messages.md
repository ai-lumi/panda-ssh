# Rust 侧程序自定义消息盘点报告

> 范围：`crates/panda-core/src/*.rs`（全部 20 个文件）与 `crates/panda-ffi/src/*.rs`（全部源文件）。
> 目的：为 OpenSpec 变更 `add-app-internationalization` 盘点「程序自行定义的、会（或可能）呈现给用户的错误说明与消息」，与依赖库错误原文（透传）区分开。
> 排除项：`Debug` 输出、`assert!`/`expect`/panic 消息（如 `ffi_runtime.rs:10` 的 `expect("failed to create tokio runtime")`）、`#[cfg(test)]` 测试专用消息、`bin/uniffi-bindgen.rs`。
> 透传说明：`xxx.to_string()` / `format!("{e}")` 中只有「程序写的前缀/说明」需要翻译；依赖错误的原始 `Display` 不翻译，但会在 FFI 兜底 `PandaError::Core(String)` 中原样到达 Swift，需在 UI 层决定展示策略。

**条目格式**：`来源文件:行号 | 符号 | 原文（逐字） | 语言 | 参数 | 到达用户路径 | 分类`

---

## 一、thiserror 错误变体（`#[error("...")]`）

### 1.1 panda-core 核心错误 `Error`（crates/panda-core/src/lib.rs:50-118，20 个变体）

- crates/panda-core/src/lib.rs:53 | `Error::Io` | `io error: {0}` | 英 | `{0}`=std::io::Error | 错误通道 → FFI `From` → `PandaError::Core(to_string)` → Swift 异常；或经 `connection_failure_classify` 变为「连接失败」详情 | 混合（程序前缀 `io error:` + 依赖透传）
- crates/panda-core/src/lib.rs:56 | `Error::TomlParse` | `toml parse error: {0}` | 英 | `{0}`=toml 解析错误 | 同上 | 混合（程序前缀 + 依赖透传）
- crates/panda-core/src/lib.rs:59 | `Error::TomlSerialize` | `toml serialize error: {0}` | 英 | `{0}` | 同上 | 混合（程序前缀 + 依赖透传）
- crates/panda-core/src/lib.rs:62 | `Error::Ssh` | `ssh error: {0}` | 英 | `{0}`=russh 错误 | 同上 | 混合（程序前缀 + 依赖透传）
- crates/panda-core/src/lib.rs:65 | `Error::Key` | `key error: {0}` | 英 | `{0}` | 同上 | 混合（程序前缀 + 依赖透传）
- crates/panda-core/src/lib.rs:68 | `Error::Sftp` | `sftp error: {0}` | 英 | `{0}`=russh-sftp 错误 | 同上 | 混合（程序前缀 + 依赖透传）
- crates/panda-core/src/lib.rs:71 | `Error::HostKeyMismatch` | `host key mismatch for {host}: stored {stored_fingerprint}, presented {presented_fingerprint}` | 英 | `host`、`stored_fingerprint`、`presented_fingerprint` | TOFU 主机密钥变更拦截 → 连接失败分类「主机密钥变更」详情 / Swift 告警 UI | 程序自定义说明（必须翻译）
- crates/panda-core/src/lib.rs:78 | `Error::UnknownHostKey` | `unknown host key for {host}: fingerprint {fingerprint}` | 英 | `host`、`fingerprint` | TOFU 首次连接确认 → 「未知主机密钥」详情 / Swift 告警 UI | 程序自定义说明（必须翻译）
- crates/panda-core/src/lib.rs:85 | `Error::AuthFailed` | `authentication failed` | 英 | 无 | 连接失败分类「认证失败」；`connection_failure_classify` 以枚举匹配，文案另译 | 程序自定义说明
- crates/panda-core/src/lib.rs:88 | `Error::MissingPassphrase` | `private key passphrase is required` | 英 | 无 | 加密私钥未提供口令 → 「缺少凭据」分类；FFI 另有带 host 的结构化变体 | 程序自定义说明
- crates/panda-core/src/lib.rs:91 | `Error::Timeout` | `operation timed out` | 英 | 无 | 连接/操作超时 → 「连接超时」分类 | 程序自定义说明
- crates/panda-core/src/lib.rs:94 | `Error::ShellSessionClosed` | `shell session closed` | 英 | 无 | 终端会话关闭提示；同时是 `classify_shell_exit` 的英文匹配子串（见风险节） | 程序自定义说明
- crates/panda-core/src/lib.rs:97 | `Error::ShellInputBackpressure` | `shell input is temporarily backpressured` | 英 | 无 | 终端输入背压提示（Swift 侧有结构化映射） | 程序自定义说明
- crates/panda-core/src/lib.rs:100 | `Error::ShellExitStatus` | `shell exited with status {0}` | 英 | `{0}`=u32 退出码 | 远端 shell 非零退出 → 终端 UI | 程序自定义说明
- crates/panda-core/src/lib.rs:103 | `Error::UnknownConnection` | `unknown connection telemetry id {0}` | 英 | `{0}`=u64 | FFI 遥测调用错误 → Swift 异常 | 程序自定义说明
- crates/panda-core/src/lib.rs:106 | `Error::Cancelled` | `operation cancelled` | 英 | 无 | 用户取消操作 → Swift | 程序自定义说明
- crates/panda-core/src/lib.rs:109 | `Error::CredentialProtectionKeyRequired` | `credential protection key is required` | 英 | 无 | 凭据保护密钥缺失 → 解锁 UI | 程序自定义说明
- crates/panda-core/src/lib.rs:112 | `Error::CredentialUnlockFailed` | `credential protection key cannot decrypt the credential file` | 英 | 无 | 凭据解锁失败 → 解锁 UI | 程序自定义说明
- crates/panda-core/src/lib.rs:115 | `Error::InvalidCredentialFile` | `credential file is invalid` | 英 | 无 | 凭据文件损坏 → 解锁 UI | 程序自定义说明
- crates/panda-core/src/lib.rs:118 | `Error::Other` | `{0}` | 依调用点 | `{0}`=String | 各构造点直达 Swift（清单见第二节） | 混合（取决于调用点）

### 1.2 panda-core `ImportError`（crates/panda-core/src/config_archive.rs:28-39，5 个变体）

- crates/panda-core/src/config_archive.rs:30 | `ImportError::MissingManifest` | `archive is missing manifest.json` | 英 | 无 | 配置导入（config_import FFI）失败 → 设置 UI | 程序自定义说明
- crates/panda-core/src/config_archive.rs:32 | `ImportError::VersionMismatch` | `manifest version {0} is not supported (expected 1)` | 英 | `{0}`=u32 版本号 | 同上 | 程序自定义说明
- crates/panda-core/src/config_archive.rs:34 | `ImportError::MissingRequiredFile` | `archive is missing required file: {0}` | 英 | `{0}`=文件名 | 同上 | 程序自定义说明
- crates/panda-core/src/config_archive.rs:36 | `ImportError::Io` | `io error: {0}` | 英 | `{0}` | 同上 | 混合（程序前缀 + 依赖透传）
- crates/panda-core/src/config_archive.rs:38 | `ImportError::Zip` | `zip error: {0}` | 英 | `{0}` | 同上 | 混合（程序前缀 + 依赖透传）

### 1.3 panda-ffi `PandaError`（crates/panda-ffi/src/lib.rs:84-135，20 个变体，全为 Swift 直接展示）

- crates/panda-ffi/src/lib.rs:86 | `PandaError::AuthFailed` | `authentication failed` | 英 | 无 | FFI 结构化错误 → Swift `LocalizedError` | 程序自定义说明
- crates/panda-ffi/src/lib.rs:88 | `PandaError::Timeout` | `operation timed out` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:90 | `PandaError::HostKeyMismatch` | `host key mismatch: stored {stored_fingerprint}, presented {presented_fingerprint}` | 英 | `stored_fingerprint`、`presented_fingerprint` | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:95 | `PandaError::UnknownHostKey` | `unknown host key for {host}: fingerprint {fingerprint}` | 英 | `host`、`fingerprint` | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:103 | `PandaError::NotInitialized` | `store not initialized; call init_store() first` | 英 | 无 | 初始化时序错误 → Swift | 程序自定义说明
- crates/panda-ffi/src/lib.rs:105 | `PandaError::UnknownHost` | `no host with id {0}` | 英 | `{0}`=host id | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:107 | `PandaError::MissingPassword` | `host {0} uses password auth but no password was provided` | 英 | `{0}`=host id | 连接前校验 → 连接失败 UI | 程序自定义说明
- crates/panda-ffi/src/lib.rs:109 | `PandaError::MissingPassphrase` | `host {0} uses an encrypted private key but no passphrase was provided` | 英 | `{0}`=host id | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:111 | `PandaError::UnknownShellHandle` | `unknown shell session handle {0}` | 英 | `{0}`=u64 | 终端调用错误 → Swift | 程序自定义说明
- crates/panda-ffi/src/lib.rs:113 | `PandaError::ShellSessionClosed` | `shell session closed` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:115 | `PandaError::ShellInputBackpressure` | `shell input is temporarily backpressured` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:117 | `PandaError::ShellExitStatus` | `shell exited with status {0}` | 英 | `{0}`=u32 | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:119 | `PandaError::UnknownSftpHandle` | `unknown SFTP session handle {0}` | 英 | `{0}`=u64 | SFTP 调用错误 → Swift | 程序自定义说明
- crates/panda-ffi/src/lib.rs:121 | `PandaError::Cancelled` | `operation cancelled` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:123 | `PandaError::CredentialProtectionKeyRequired` | `credential protection key is required` | 英 | 无 | 凭据解锁 UI | 程序自定义说明
- crates/panda-ffi/src/lib.rs:125 | `PandaError::CredentialUnlockFailed` | `credential protection key cannot decrypt the credential file` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:127 | `PandaError::InvalidCredentialFile` | `credential file is invalid` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/lib.rs:129 | `PandaError::UnknownTransferTask` | `unknown transfer task {0}` | 英 | `{0}`=任务 id | 传输任务调用错误 → Swift | 程序自定义说明
- crates/panda-ffi/src/lib.rs:131 | `PandaError::UnknownConnection` | `unknown connection {0}` | 英 | `{0}`=u64 | 遥测调用错误 → Swift | 程序自定义说明
- crates/panda-ffi/src/lib.rs:134 | `PandaError::Core` | `{0}` | 依内容 | `{0}`=String | 兜底透传（core 错误 `to_string()` 及各处 `Core(format!(...))` 说明，见下） | 混合

---

## 二、程序自定义包装上下文（`format!` / 字符串字面量进入错误通道）

### 2.1 panda-core `Error::Other` 及同类构造点

- crates/panda-core/src/ssh.rs:447 | TOFU 主机密钥校验 | `format!("host key check failed: {io}")` | 英 | `{io}`=io 错误 | TOFU 流程失败 → 连接失败分类「连接失败」详情 → Swift | 混合（程序前缀 + 依赖透传）
- crates/panda-core/src/ssh.rs:806 | `send_shell_input` | `"shell 输入通道已意外关闭"` | 中 | 无 | 终端输入失败 → 终端 UI | 程序自定义说明（必须翻译）
- crates/panda-core/src/ssh.rs:823 | 终端 resize | `"failed to send resize notification"` | 英 | 无 | 终端窗口尺寸变更失败 → 终端 UI | 程序自定义说明
- crates/panda-core/src/ssh.rs:847 | 终端读取任务兜底 | `"SSH 连接异常"` | 中 | 无 | 终端会话失败消息（failure_message）→ 终端 UI | 程序自定义说明
- crates/panda-core/src/ssh.rs:864-865 | 终端后台任务异常 | `"终端后台任务异常结束"` | 中 | 无 | 同一文案写入两处：`telemetry.fail`（last_error）与 `Error::Other`（failure_message）→ 终端 UI / 遥测 | 程序自定义说明
- crates/panda-core/src/groups.rs:205 | `move_group` | `format!("no group with id {id}")` | 英 | `{id}` | 分组操作失败 → Swift | 程序自定义说明
- crates/panda-core/src/groups.rs:208 | `move_group` | `format!("no group with id {parent}")` | 英 | `{parent}` | 同上 | 程序自定义说明
- crates/panda-core/src/groups.rs:211-213 | `move_group` | `format!("moving group {id} under {parent} would create a cycle")` | 英 | `{id}`、`{parent}` | 同上 | 程序自定义说明
- crates/panda-core/src/groups.rs:227,232 | `group_path` | `"根级"` | 中 | 无 | 分组面包屑/显示串（经 FFI `group_path`/`search_hosts` 到 UI；非错误，但为程序定义的用户可见文本） | 程序自定义说明（必须翻译）
- crates/panda-core/src/sftp_path.rs:8-10 | `directory_path` | `"请输入以 / 开头且不含 NUL 的完整绝对路径"` | 中 | 无 | 地址栏校验 → FFI `sftp_directory_path` 直达 UI | 程序自定义说明（必须翻译）
- crates/panda-core/src/sftp.rs:458 | 目录遍历 | `format!("{} is not a directory", current)` | 英 | `{current}`=路径 | SFTP 导航失败 → Swift | 程序自定义说明
- crates/panda-core/src/config.rs:183 | `write_atomic_async` | `format!("spawn_blocking failed: {e}")` | 英 | `{e}` | 配置写盘失败 → Swift | 混合（程序前缀 + 依赖透传）
- crates/panda-core/src/credentials.rs:139 | 凭据校验 | `"credential reference and secret must be non-empty"` | 英 | 无 | 凭据保存失败 → Swift | 程序自定义说明
- crates/panda-core/src/credentials.rs:213 | 密钥派生 | `"credential key derivation failed"` | 英 | 无 | 凭据加解密失败 → 解锁 UI | 程序自定义说明
- crates/panda-core/src/credentials.rs:219 | 加密密钥 | `"invalid credential key"` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/credentials.rs:221 | 加密失败 | `"credential encryption failed"` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/credentials.rs:226 | 解密密钥 | `"invalid credential key"` | 英 | 无 | 同上（与 219 同文案不同分支） | 程序自定义说明
- crates/panda-core/src/hostkey.rs:50-52 | `fingerprint_sha256` | `format!("malformed public key: {openssh_key_str:?}")` | 英 | `{openssh_key_str:?}`（Debug 格式） | known_hosts 解析失败 → Swift | 程序自定义说明（注意内嵌 Debug 格式的原始输入）
- crates/panda-core/src/hostkey.rs:55 | `fingerprint_sha256` | `format!("bad base64 in public key: {e}")` | 英 | `{e}`=base64 错误 | 同上 | 混合（程序前缀 + 依赖透传）
- crates/panda-core/src/batch.rs:151-152 | 本地批量扫描 | `format!("max scan depth exceeded at {}", …)` | 英 | 路径 | 批量扫描失败 → Swift | 程序自定义说明
- crates/panda-core/src/batch.rs:259-260 | 远端批量扫描 | `format!("max scan depth exceeded at {}", …)` | 英 | 路径 | 同上 | 程序自定义说明
- crates/panda-core/src/batch.rs:365,384,424,471,492,532 | 批量传输逐项失败（上传 3 处 + 下载 3 处） | `format!("{} -> {}: {}", item.source, item.destination, e)` | 混合 | 源路径、目标路径、错误 | `BatchOutcome.errors` → FFI 拼接（见 3.2）→ 批量任务 `error` 字段 → UI | 混合（路径为数据；`e` 为依赖透传；格式为程序定义）

### 2.2 panda-core `Result<(), String>` 中文错误（WorkRegistry，crates/panda-core/src/task_summary.rs）

- crates/panda-core/src/task_summary.rs:97 | `WorkRegistry::ensure_accepting` | `"应用正在退出，不能启动新任务"` | 中 | 无 | 应用退出期间启动任务被拒 → Swift | 程序自定义说明（必须翻译）
- crates/panda-core/src/task_summary.rs:102 | `WorkRegistry::begin` | `"准备操作已登记"` | 中 | 无 | 任务登记冲突 → Swift | 程序自定义说明
- crates/panda-core/src/task_summary.rs:110 | `WorkRegistry::attach` | `"准备操作不存在"` | 中 | 无 | 任务挂接失败 → Swift | 程序自定义说明
- crates/panda-core/src/task_summary.rs:112 | `WorkRegistry::attach` | `"准备操作已经结束"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/task_summary.rs:115 | `WorkRegistry::attach` | `"任务已属于其他操作"` | 中 | 无 | 同上 | 程序自定义说明

### 2.3 panda-core `DeleteError`（crates/panda-core/src/delete_tasks.rs）

- crates/panda-core/src/delete_tasks.rs:64 | `DeleteTask::fail_to_start`（类型校验） | `"删除任务类型无效"` | 中 | 无 | 删除任务启动失败 → 任务列表 UI | 程序自定义说明（必须翻译）
- crates/panda-core/src/delete_tasks.rs:65 | `DeleteTask::new` | `"删除目标不能为空"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/delete_tasks.rs:70 | `DeleteTask::new`（路径安全校验） | `"拒绝空目标、根目录、相对路径或越界路径"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/delete_tasks.rs:35 | `children` | `"文件名不是有效 UTF-8"` | 中 | 无 | 删除过程逐项错误（`errors` 列表）→ 任务详情 UI | 程序自定义说明
- crates/panda-core/src/delete_tasks.rs:138 | `run`（越界检查） | `"目录包含越界名称"` | 中 | `fatal=true` | 同上（致命错误） | 程序自定义说明
- crates/panda-core/src/delete_tasks.rs:47 | `local_error` | `DeleteError::new(error.to_string(), false)` | 依 io | io 错误 | 删除过程逐项错误 → UI | 依赖错误透传（原文排除，但 message 会进 UI）

### 2.4 panda-ffi `PandaError::Core(...)` 程序说明

- crates/panda-ffi/src/ffi_store.rs:219 | `credential_resolve` | `PandaError::Core(format!("host not found: {host_id}"))` | 英 | `{host_id}` | 凭据解析失败 → Swift | 程序自定义说明
- crates/panda-ffi/src/ffi_store.rs:307 | `preconnect_evaluate` | `PandaError::Core(format!("host not found: {host_id}"))` | 英 | `{host_id}` | 预连接失败 → Swift | 程序自定义说明
- crates/panda-ffi/src/ffi_store.rs:434 | `config_export` | `.map_err(|e| PandaError::Core(e.to_string()))`（ImportError） | 英 | `{e}` | 配置导出失败 → 设置 UI | 依赖错误透传（ImportError 文案见 1.2，其程序前缀需翻译）
- crates/panda-ffi/src/ffi_store.rs:451 | `config_import` | `.map_err(|e| PandaError::Core(e.to_string()))`（ImportError） | 英 | `{e}` | 同上 | 依赖错误透传（同上）
- crates/panda-ffi/src/ffi_sessions.rs:291-294 | `test_connection` 成功消息 | `format!("connected to {}@{}:{} (exit status: {:?})", …)` | 英 | 用户名、主机、端口、退出状态 | 连接测试成功提示 → Swift（成功文本也是程序定义的用户可见文本） | 程序自定义说明（必须翻译）
- crates/panda-ffi/src/ffi_transfers.rs:271 | 传输任务退出 | `*task.error = Some("semaphore closed".to_string())` | 英 | 无 | 传输任务 `error` 字段 → 传输列表 UI | 程序自定义说明
- crates/panda-ffi/src/ffi_transfers.rs:310 | 传输失败 | `*task.error = Some(e.to_string())` | 依错误 | `{e}` | 同上 | 依赖错误透传（原文排除）
- crates/panda-ffi/src/ffi_transfers.rs:323,326,360,363 | 上传/下载错误映射 | `panda_core::Error::Other(e.to_string())` | 依错误 | `{e}` | 传输失败 → Swift | 依赖错误透传
- crates/panda-ffi/src/ffi_transfers.rs:541-542 | `transfer_retry` | `PandaError::Core("task is not in a retryable state".to_string())` | 英 | 无 | 重试被拒 → Swift | 程序自定义说明
- crates/panda-ffi/src/ffi_transfers.rs:580 | `transfer_pause` | `PandaError::Core("task is already terminal".to_string())` | 英 | 无 | 暂停被拒 → Swift | 程序自定义说明
- crates/panda-ffi/src/ffi_transfers.rs:399,503,526,570,599 | UUID 解析失败（5 处） | `PandaError::Core(e.to_string())`（uuid::Error） | 英 | `{e}` | 各传输操作 → Swift | 依赖错误透传
- crates/panda-ffi/src/batch_transfer.rs:201 | `scan_local_batch` | `PandaError::Core("scan_local_batch: task dropped".into())` | 英 | 无 | 批量扫描失败 → Swift | 程序自定义说明
- crates/panda-ffi/src/batch_transfer.rs:249 | `scan_remote_batch` | `PandaError::Core("scan_remote_batch: task dropped".into())` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/batch_transfer.rs:219 | 扫描错误映射 | `PandaError::Core(e)`（core Error → Core(String)） | 依错误 | `{e}` | 批量扫描失败 → Swift | 兜底透传（混合，取决于 core 错误）
- crates/panda-ffi/src/batch_transfer.rs:314,331,341,412,471 | 批量传输逐项失败（5 处） | `*task.error = Some(e.to_string())` | 依错误 | `{e}` | 批量任务 `error` 字段 → 传输列表 UI | 依赖错误透传
- crates/panda-ffi/src/batch_transfer.rs:459 | 批量传输汇总 | `*task.error = Some(outcome.errors.join("; "))` | 混合 | `BatchOutcome.errors` 列表 | 批量任务 `error` 字段 → UI（内容来自 2.1 的 6 处 `{} -> {}` 格式化） | 混合（格式为程序定义）
- crates/panda-ffi/src/batch_transfer.rs:546-547 | 冲突决策 | `PandaError::Core("batch task is not waiting for a conflict decision".to_string())` | 英 | 无 | 批量冲突确认 → Swift | 程序自定义说明
- crates/panda-ffi/src/batch_transfer.rs:557 | 冲突决策 | `PandaError::Core("no pending conflict decision channel".to_string())` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/batch_transfer.rs:568 | 冲突决策 | `PandaError::Core("conflict decision channel closed".to_string())` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/batch_transfer.rs:491,512,535 | UUID 解析失败（3 处） | `PandaError::Core(e.to_string())` | 英 | `{e}` | 批量操作 → Swift | 依赖错误透传
- crates/panda-ffi/src/batch_transfer.rs:485 | 批量凭据写入 | `store_credentials_for(cfg, …).map_err(|e| e.to_string())` → `String` 错误 | 依错误 | `{e}` | 批量传输启动失败 → Swift | 依赖错误透传
- crates/panda-ffi/src/lib.rs:171 | `From<panda_core::Error>` 兜底 | `PandaError::Core(other.to_string())` | 依错误 | core 错误 Display | 所有未结构化映射的 core 错误 → Swift（含 1.1 的全部英文文案与 2.1 的中英 Other 文案） | 兜底透传（Display 文案本身见 1.1/2.1）
- crates/panda-ffi/src/lib.rs:176-180 | `From<std::io::Error>` | `PandaError::Core(e.to_string())` | 依系统 | io 错误 | 文件操作错误 → Swift | 依赖错误透传

---

## 三、日志事件 / 消息（logger.rs 体系）

### 3.1 日志写入 API（crates/panda-core/src/logger.rs）

- crates/panda-core/src/logger.rs:75-130 | `Logger::log/debug/info/warning/error(level, module, message)` | （API，无固定文案） | — | `module`、`message` | 环形内存缓冲 + 轮转文件 → FFI `log_entries` → 日志查看器 UI | 程序自定义消息的载体
- crates/panda-core/src/logger.rs:193-199 | `record_persistence_failure` | `LogEntry { module: "Config", level: Error, message: "日志文件不可写，当前仅保留内存日志" }` | 中 | 无 | 日志查看器 UI | 程序自定义说明（必须翻译）
- crates/panda-core/src/logger.rs:209,269 | 文件行格式 / 导出格式 | `format!(…)`（时间戳/module/level/message 拼接） | 混合 | 多项 | 日志文件 | 混合（结构化模板，非独立文案）

### 3.2 程序写入的日志调用点（生产代码）

- crates/panda-core/src/ssh.rs:663 | 终端握手 | `warning("SSH", "终端 TERM 环境变量未被远端接受")` | 中 | 无 | 日志查看器 | 程序自定义说明（必须翻译）
- crates/panda-core/src/ssh.rs:701 | 终端 resize | `warning("SSH", "终端尺寸同步失败")` | 中 | 无 | 日志查看器 | 程序自定义说明
- crates/panda-core/src/ssh.rs:761 | 终端关闭 | `warning("SSH", "终端通道关闭请求失败")` | 中 | 无 | 日志查看器 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:267-278 | `record_event` | `format!("host={}; connection={}; owner={}#{}; {}", address, connection_id, owner_kind, owner_id, kind.description())` | 混合 | 地址、连接 id、owner 标签/id、生命周期文案 | 日志查看器（连接生命周期事件行） | 混合（结构为程序定义；owner 标签与 `description()` 为中文程序文案；地址/id 为数据）

### 3.3 进入日志/遥测的程序定义标签（owner_kind）

- crates/panda-ffi/src/ffi_sessions.rs:92 | SFTP 客户端创建 | `set_owner("SFTP 操作", …)` | 中 | 无 | 遥测 owner_kind → 事件行/生命周期记录 → UI | 程序自定义说明
- crates/panda-ffi/src/ffi_sessions.rs:135 | 终端会话 | `set_owner("SFTP 标签", …)` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/ffi_sessions.rs:288 | 连接测试 | `set_owner("连接探测", …)` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/ffi_sessions.rs:502 | 终端标签 | `set_owner("终端标签", …)` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/ffi_transfers.rs:336 | 上传任务 | `set_owner("上传任务", …)` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/ffi_transfers.rs:373 | 下载任务 | `set_owner("下载任务", …)` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/batch_transfer.rs:229 | 批量扫描 | `set_owner("批量扫描", …)` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-ffi/src/batch_transfer.rs:336 | 批量传输 | `set_owner("批量传输", …)` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:170 | `ConnectionRecord::new` 默认值 | `"未关联"` | 中 | 无 | owner_kind 缺省值 → 事件行/生命周期记录 | 程序自定义说明

---

## 四、FFI 层错误包装与映射（core → PandaError）

- crates/panda-ffi/src/lib.rs:143-171 | `From<panda_core::Error> for PandaError` | 结构化映射（AuthFailed/Timeout/HostKeyMismatch/UnknownHostKey/Shell* /Cancelled/Credential* 等）+ 兜底 `other => PandaError::Core(other.to_string())` | — | — | Swift 异常 | 兜底透传点（行 171）：core 的 Display 文案（1.1）与 Other 文案（2.1）在此原样进入 Swift
- crates/panda-ffi/src/lib.rs:176-180 | `From<std::io::Error>` | `PandaError::Core(e.to_string())` | 依系统 | io 错误 | Swift 异常 | 依赖错误透传
- crates/panda-ffi/src/ffi_telemetry.rs:248-266 | `connection_failure_classify(error_code: String)` | 按错误码字符串重建 `Error`：`"Timeout" => Error::Timeout` 等 8 个固定码 + `other => Error::Other(other.to_string())` | — | 错误码 | Swift 调用分类 → 中文标题/详情（见第五节） | 混合（固定码为枚举名，不受翻译影响；`other` 分支依赖传入消息原文）
- crates/panda-ffi/src/ffi_adapter.rs | `sftp_directory_path` 等直通导出 | core 错误经 `From` 直接转 `PandaError` | — | — | 地址栏等 UI | 透传（文案见 2.1）

---

## 五、特定字段的最终文本生成点

### 5.1 连接失败分类（`connection_failure_classify`，crates/panda-core/src/ssh.rs:916-961）

- crates/panda-core/src/ssh.rs:920-922 | `Error::Timeout` 分支 | 标题 `"连接超时"`；详情 `"服务器在规定时间内未响应,请检查网络连接或服务器状态。"` | 中 | 无 | FFI `connection_failure_classify` → Swift 连接失败弹窗/卡片 | 程序自定义说明（必须翻译）
- crates/panda-core/src/ssh.rs:925-927 | `Error::AuthFailed` | 标题 `"认证失败"`；详情 `"用户名或密码不正确,请检查凭据。"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/ssh.rs:930-935 | `MissingPassphrase`/`Credential*` | 标题 `"缺少凭据"`；详情 `format!("{error}")` | 混合 | core 错误 Display（英文） | 同上 | 混合（中文标题 + 依赖/英文详情；翻译 Display 后该详情会变化，见风险节）
- crates/panda-core/src/ssh.rs:938-946 | `Error::HostKeyMismatch` | 标题 `"主机密钥变更"`；详情 `format!("主机 {host} 的密钥与已存储的不匹配。\n已存储: {stored}\n当前: {presented}\n这可能是中间人攻击,也可能是服务器重装。")` | 中 | `host`、`stored`、`presented` | 同上 | 程序自定义说明（必须翻译）
- crates/panda-core/src/ssh.rs:950-954 | `Error::UnknownHostKey` | 标题 `"未知主机密钥"`；详情 `format!("{error}")` | 混合 | core 错误 Display（英文，含指纹） | 同上 | 混合
- crates/panda-core/src/ssh.rs:957-959 | 兜底 `other` | 标题 `"连接失败"`；详情 `format!("{other}")` | 混合 | 错误原文 | 同上 | 混合（中文标题 + 透传详情）

### 5.2 遥测 `last_error`（双轨）

- crates/panda-core/src/telemetry.rs:320-326 | `ConnectionRegistry::fail(id, error: String)` | `last_error = Some(sanitize_error(error))`（截断 256 字符） | 依调用点 | 错误字符串 | `ConnectionTelemetrySnapshot.last_error` / 生命周期记录 → Swift/UI | 透传载体
  - 程序文案进入点（中文）：crates/panda-core/src/ssh.rs:731 `"远端 shell 以非零退出码结束"`、ssh.rs:738 `"SSH 通道在未收到关闭通知前结束"`、ssh.rs:864 `"终端后台任务异常结束"` | 中 | 无 | 同上 | 程序自定义说明（必须翻译）
  - 程序文案进入点（英文）：crates/panda-core/src/ssh.rs:244 `"Socket EOF"` | 英 | 无 | 同上 | 程序自定义说明
  - 依赖透传进入点：crates/panda-core/src/ssh.rs:252,273,692 `fail(self.telemetry_id, error.to_string())` | 依错误 | `{error}` | 同上 | 依赖错误透传
- crates/panda-core/src/telemetry.rs:332-335 | `fail_with_event` | `last_error = kind.description()` | 中/英混合 | 见 5.3 | 同上 | 程序自定义说明

### 5.3 生命周期 `reason`（`LifecycleKind::description`，crates/panda-core/src/telemetry.rs:31-46，12 条固定文案）

- crates/panda-core/src/telemetry.rs:33 | `LifecycleKind::Connected` | `"连接成功"` | 中 | 无 | `ConnectionLifecycleRecord.reason`（crates/panda-ffi/src/ffi_telemetry.rs:175）→ Swift 生命周期列表/UI | 程序自定义说明（必须翻译）
- crates/panda-core/src/telemetry.rs:34 | `ConnectionTimeout` | `"连接或握手超时"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:35 | `AuthenticationFailed` | `"SSH 认证失败"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:36 | `SftpOperationFailed` | `"SFTP 操作失败"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:37 | `ShellExit` | `"Channel 正常结束"` | 中（含英文词 Channel） | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:38 | `ExplicitClose` | `"显式关闭"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:39 | `SocketEof` | `"Socket EOF"` | 英 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:40 | `ReadError` | `"Socket 读取失败"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:41 | `WriteError` | `"Socket 写入失败"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:42 | `KeepaliveFailed` | `"SSH keepalive 失败"` | 中（含英文词） | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:43 | `TransportError` | `"SSH 传输异常"` | 中 | 无 | 同上 | 程序自定义说明
- crates/panda-core/src/telemetry.rs:44 | `Released` | `"所有者释放"` | 中 | 无 | 同上 | 程序自定义说明

### 5.4 传输任务 `error` 字段

- crates/panda-ffi/src/ffi_transfers.rs:271 | 信号量关闭 | `Some("semaphore closed")` | 英 | 无 | `TransferStatusRecord.error` → 传输列表 UI | 程序自定义说明
- crates/panda-ffi/src/ffi_transfers.rs:310 | 上传/下载失败 | `Some(e.to_string())` | 依错误 | `{e}` | 同上 | 依赖错误透传
- crates/panda-ffi/src/batch_transfer.rs:314,331,341,412,471 | 批量逐项失败 | `Some(e.to_string())` | 依错误 | `{e}` | 同上 | 依赖错误透传
- crates/panda-ffi/src/batch_transfer.rs:459 | 批量汇总 | `Some(outcome.errors.join("; "))` | 混合 | 见 2.1 batch.rs 6 处 | 同上 | 混合（`{} -> {}` 格式为程序定义）

### 5.5 其他用户可见程序文本（非错误，顺带登记）

- crates/panda-core/src/groups.rs:227,232 | `group_path` | `"根级"` | 中 | 无 | 分组显示串 → UI | 程序自定义说明
- crates/panda-core/src/workspace.rs:82-90 | `compute_disambiguated_titles` | `format!("{base} ({ordinal})")` | 数字后缀 | `base`、`ordinal` | 标签页标题（如 `server (2)`）→ UI | 程序自定义格式（需按各语言本地化复数/序数规则评审）
- crates/panda-ffi/src/ffi_sessions.rs:291-294 | `test_connection` 成功消息 | `format!("connected to {}@{}:{} (exit status: {:?})", …)` | 英 | 用户名、主机、端口、状态 | 连接测试成功提示 → UI | 程序自定义说明（必须翻译）

---

## 六、i18n 耦合风险点（翻译时必须处理）

1. **`classify_shell_exit` 依赖英文错误消息子串匹配**（crates/panda-core/src/workspace.rs:265-292）：以 `msg.contains("shell session closed") / "ShellSessionClosed" / "timeout" / "timed out" / "auth" / "authentication" / "host key"` 对错误消息分类。若 `Error::ShellSessionClosed`、`Error::Timeout`、`Error::AuthFailed` 等 Display 文案被翻译，该分类将静默失效。建议：翻译前改为结构化错误码（enum）传递，或保证匹配使用不可变的错误码。
2. **`connection_failure_classify` 的混合详情**（ssh.rs:935,954,959）：「缺少凭据」「未知主机密钥」「连接失败」三个分支的详情直接内嵌 `Error` 的英文 Display。翻译 Display 后，中文 UI 的详情会随语言变化，需要为这三个分支设计独立的本地化详情模板，而不是 `format!("{error}")`。
3. **`ffi_telemetry.rs:connection_failure_classify` 的错误码协议**（crates/panda-ffi/src/ffi_telemetry.rs:248-258）：Swift 按英文错误码字符串（`"Timeout"` 等）调用分类。错误码是枚举名，不应被翻译（保持为协议常量）；但 `other => Error::Other(other.to_string())` 分支依赖传入消息原文。
4. **`is_already_exists_message`**（crates/panda-core/src/sftp.rs）：按 SFTP 服务器返回消息的英文子串判断「已存在」——属依赖侧行为，不受应用翻译影响，但翻译批量冲突提示时需依赖该分类结果。
5. **`hostkey.rs:51` 的 Debug 格式**：`malformed public key: {openssh_key_str:?}` 内嵌原始公钥的 Debug 输出，翻译文案时保留该参数但不应本地化参数本身。

---

## 七、统计

| 类别 | 数量 | 语言分布 |
| --- | --- | --- |
| panda-core `Error` 变体 | 20 | 全英文（`Other` 内容依调用点） |
| panda-core `ImportError` 变体 | 5 | 全英文 |
| panda-ffi `PandaError` 变体 | 20 | 全英文（`Core` 内容依透传） |
| **thiserror 错误变体合计** | **45** | 英文 45（其中 8 个变体含程序前缀 + 依赖透传的混合文案） |
| 程序自定义包装上下文（core，`Error::Other` / `Result<(),String>` / `DeleteError` / batch errors / group_path） | 34 条构造点 | 中文 13、英文 19、混合（格式化含依赖原文）2 |
| 程序自定义包装上下文（FFI，`Core(format!)` / 字面量 / 成功消息） | 16 条 | 英文 12、混合 2、透传登记 2+ |
| 日志程序文案 | 4 条（logger 1 + ssh warning 3） | 中文 4 |
| 遥测程序文案 | `LifecycleKind::description` 12 条 + `fail` 程序文案 4 条 | 中文 14、英文 2（含 `Socket EOF` 两处） |
| owner_kind 标签 | 9 条（8 处 set_owner + 默认「未关联」） | 中文 9 |
| **中英总体分布** | 程序自定义用户可见文案约 89 条 | 中文约 44 条（分类文案/遥测/任务登记/删除/路径校验/日志），英文约 40 条（错误变体与 FFI 说明），混合约 15 条（程序前缀+依赖透传） |
| 依赖错误透传点（原文排除、仅登记） | 约 20 处（io/toml/russh/sftp/zip/uuid 等的 `to_string()` 进入错误通道） | — |
| i18n 耦合风险点 | 4 处（classify_shell_exit、connection_failure_classify 详情、错误码协议、SFTP 服务器消息匹配） | — |

**必须翻译（程序自定义说明）的高优先级清单**：连接失败分类 6 组标题/详情、`LifecycleKind` 12 条、遥测 fail 程序文案 4 条、`WorkRegistry` 5 条、`DeleteError` 5 条、`sftp_path` 1 条、`logger` 1 条、ssh warning 3 条、owner 标签 9 条、`group_path` "根级"、`test_connection` 成功消息、以及 core/FFI `#[error]` 变体中的 37 条非兜底英文文案。

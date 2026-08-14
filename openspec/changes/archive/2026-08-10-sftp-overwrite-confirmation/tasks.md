## 1. panda-core 冲突检测能力

### 测试

- [x] 1.1 编写 `SftpClient` 上传冲突检测测试：
  - 正常流程：远端目标不存在时返回无冲突。
  - 意外操作：远端目标已存在时返回冲突，字段包含源/目标大小与 mtime。
  - 边界条件：远端 SFTP 服务器不返回 mtime 时，`target_mtime` 为 `None`。
- [x] 1.2 编写本地文件元数据读取测试（下载冲突检测）：
  - 正常流程：本地目标不存在时返回无冲突。
  - 意外操作：本地目标已存在时返回冲突。
  - 边界条件：本地文件权限不足导致元数据读取失败时返回结构化错误。
- [x] 1.3 编写冲突信息结构序列化/字段完整性测试。

### 实现

- [x] 1.4 在 `crates/panda-core/src/sftp.rs` 中新增 `FileConflictInfo` / `OverwritePrompt` 结构体，字段：`source_size`、`source_mtime`、`target_size`、`target_mtime`。
- [x] 1.5 新增 `SftpClient::check_upload_conflict(local, remote)`，读取本地与远端元数据，返回 `Option<OverwritePrompt>` 或错误。
- [x] 1.6 新增 `SftpClient::check_download_conflict(remote, local)`，读取远端与本地元数据，返回 `Option<OverwritePrompt>` 或错误。
- [x] 1.7 为 `panda-core::Error` 新增目标文件元数据读取失败的结构化错误变体。
- [x] 1.8 运行 `cargo test -p panda-core` 并确保全绿。

## 2. panda-ffi 暴露预检查接口

### 测试

- [x] 2.1 编写 FFI 绑定测试：
  - 正常流程：目标不存在时 `sftp_check_upload_conflict` / `sftp_check_download_conflict` 返回 `None`。
  - 意外操作：目标已存在时返回包含大小与 mtime 的记录。
  - 边界条件：未初始化 store 时调用预检查接口返回 `NotInitialized`。
- [x] 2.2 生成 Swift 绑定后验证 `RemoteFileConflictRecord` 字段完整。

### 实现

- [x] 2.3 在 `crates/panda-ffi/src/lib.rs` 新增 `RemoteFileConflictRecord`（uniffi Record），字段：`source_size: u64`、`source_mtime: Option<u64>`、`target_size: u64`、`target_mtime: Option<u64>`。
- [x] 2.4 新增 `#[uniffi::export]` 函数 `sftp_check_upload_conflict(host_id, local_path, remote_path, password, passphrase, trust_on_first_use) -> Result<Option<RemoteFileConflictRecord>, PandaError>`。
- [x] 2.5 新增 `#[uniffi::export]` 函数 `sftp_check_download_conflict(host_id, remote_path, local_path, password, passphrase, trust_on_first_use) -> Result<Option<RemoteFileConflictRecord>, PandaError>`。
- [x] 2.6 运行 `cargo test -p panda-ffi` 与 `cargo build` 全绿。

## 3. SwiftUI 覆盖确认弹窗

### 测试

- [x] 3.1 编写 ViewModel/AppModel 逻辑测试（使用 `MockBackend`）：
  - 正常流程：预检查无冲突时直接发起传输。
  - 意外操作：预检查返回冲突时触发弹窗状态，用户选择「跳过」后不发起传输。
  - 边界条件：预检查接口抛出错误时，错误被正确展示且不卡死 UI。

### 实现

- [x] 3.2 在 `apple/PandaSSH` 的 SFTP 传输入口（上传/下载）调用新增预检查 FFI 接口。
- [x] 3.3 新增覆盖确认弹窗 View/Modifier，展示源文件与目标文件的大小、最后修改时间，并提供「覆盖」/「跳过」按钮。
- [x] 3.4 用户选择「覆盖」后调用现有 `sftp_upload` / `sftp_download` 或 `start_transfer`；选择「跳过」则取消本次传输。
- [x] 3.5 处理 mtime 本地化格式化（macOS / iPadOS 使用同一 `DateFormatter` 逻辑）。
- [x] 3.6 运行对应 Swift target 的单元测试并确保通过。

## 4. 验收与归档

- [x] 4.1 运行 `cargo test --workspace` 全绿。
- [x] 4.2 运行 `cargo llvm-cov --workspace --tests --fail-under-lines 95 --fail-under-regions 95` 通过。
- [x] 4.3 运行 `apple/Scripts/build-rust.sh` 与 `xcodegen` 后，macOS / iOS 双端 `xcodebuild` 编译通过。
- [x] 4.4 将本 change 的 spec delta 合并回 `openspec/specs/`。
- [x] 4.5 归档 change 到 `openspec/changes/` 的归档目录。

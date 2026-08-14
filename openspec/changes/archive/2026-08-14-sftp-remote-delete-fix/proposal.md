# SFTP 远程删除修复

## Why

SFTP 删除远程文件或目录时总是失败，原因有三：

1. **路径拼接产生双斜杠**：Swift 侧使用 `path + "/" + name`，当 `path` 为 `/` 时拼接出 `//name`，部分 SFTP 服务器会拒绝
2. **错误信息被完全吞掉**：`deleteRemote` 的 `catch` 块只返回 `false`，Rust 侧返回的具体错误（权限拒绝、目录非空、文件不存在等）全部丢失，UI 只能显示笼统的「删除失败」
3. **`remove_dir` 只能删除空目录**：Rust 侧 `sftp_remove_dir` 直接调用 `russh_sftp::rmdir()`，等价于 `rmdir` 命令。远程目录非空时服务器返回 `Failure`，但 Swift 侧又把这个错误吞掉了

## What Changes

### Rust `panda-core`

- `SftpClient` 新增 `remove_all` 方法：先查询 `metadata` 判断类型，文件直接 `remove_file`，目录先递归清空内容（`list_dir` + 逐条 `remove_all`）再 `remove_dir`
- 路径规范化：`remove_all` 入口统一 `trim_end_matches('/')`，避免尾部斜杠导致的匹配失败
- 递归实现使用 `Box::pin` 解决 async fn 递归的无限大小 future 问题

### Rust FFI `panda-ffi`

- `sftp_remove_dir` 内部改调用 `sftp.remove_all()`，保留原有 FFI 签名不变（Swift 侧无需重新生成绑定）

### Swift `SftpSessionStore`

- 新增 `joinPath(_:_:)` 辅助函数：当目录已以 `/` 结尾时不重复拼接，避免双斜杠
- `deleteLocal` / `deleteRemote` 返回值从 `Bool` 改为 `String?`（成功返回 `nil`，失败返回错误描述）
- 错误信息写入日志模块，同时带回 UI

### Swift `SftpTabView`

- 删除确认弹框的 `Task` 中接收 `String?` 错误，成功 toast 显示「已删除 xxx」，失败 toast 显示「删除 xxx 失败：具体原因」

### 测试

- `ffi_fake_server.rs` 新增 `ffi_sftp_remove_all_recursive` 集成测试：验证嵌套目录 `/nested/subdir` + 文件 `/nested/file.txt` 的递归删除
- fake server 的 `opendir` 规范化路径尾部斜杠，保证 `readdir` 与 `parent_of` 一致
- 额外验证：用 `sftp_remove_dir` 删除单个文件（`/standalone.txt`）、删除以斜杠结尾的目录（`/trailing/`）

## Impact

- `crates/panda-core/src/sftp.rs`
- `crates/panda-ffi/src/lib.rs`
- `crates/panda-ffi/tests/ffi_fake_server.rs`
- `apple/PandaSSH/Workspace/SftpSessionStore.swift`
- `apple/PandaSSH/Workspace/SftpTabView.swift`

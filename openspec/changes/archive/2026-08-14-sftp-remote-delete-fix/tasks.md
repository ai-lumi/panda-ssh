# Tasks

- [x] 1.1 Rust `SftpClient` 新增 `remove_all` 递归删除方法
- [x] 1.2 `remove_all` 入口统一 trim 尾部斜杠，避免路径不匹配
- [x] 1.3 `sftp_remove_dir` FFI 改调用 `remove_all`
- [x] 1.4 Swift `SftpSessionStore` 新增 `joinPath` 安全路径拼接
- [x] 1.5 Swift `deleteLocal` / `deleteRemote` 返回详细错误消息
- [x] 1.6 Swift `SftpTabView` 删除弹框显示具体错误原因
- [x] 1.7 fake server `opendir` 规范化尾部斜杠，保证 readdir/parent_of 一致
- [x] 1.8 集成测试 `ffi_sftp_remove_all_recursive` 覆盖递归删除、文件删除、斜杠目录删除
- [x] 1.9 `cargo test` 全绿 + 覆盖率通过（lines 96.49%，regions 95.62%）
- [x] 1.10 `xcodebuild -scheme PandaSSH-macOS` 通过
- [x] 1.11 归档

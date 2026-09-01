# `panda_ffi::batch_transfer`

源文件：`crates/panda-ffi/src/batch_transfer.rs`

## 直接依赖

- `panda_core::batch`：批量扫描、上传、下载、冲突策略。
- `panda_core::connection_pool`、`SftpClient`、`KnownHosts`：连接复用与 SFTP 会话。
- `crate::{load_host, runtime, stores, PandaError}`：FFI 存储、运行时和错误边界。
- `std::sync` 原子值、互斥锁和通道：任务状态与覆盖确认。
- `uuid::Uuid`：任务标识。

## 被依赖方

- `panda_ffi` crate root：重新导出 UniFFI API。
- `PandaSSH.Workspace.FFITransferSource`：Swift 侧启动、轮询、取消与解决冲突。
- `crates/panda-ffi/tests/ffi_fake_server.rs`：FFI 集成测试。

## 跨语言边界

该模块将 Rust 异步任务映射为 Swift 可轮询的同步 UniFFI API。等待用户冲突决策必须保持异步，不能阻塞 Tokio 工作线程。


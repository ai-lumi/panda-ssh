# `panda_core::batch`

源文件：`crates/panda-core/src/batch.rs`

## 直接依赖

- `crate::sftp::SftpClient`：文件冲突检查、上传和下载。
- `crate::{Error, Result}`：统一错误与取消语义。
- `tokio::fs`：本地目录创建和异步文件系统操作。
- `std::path::PathBuf`、原子取消标记与回调 `Arc`：批量计划与执行控制。

## 被依赖方

- `panda_ffi::batch_transfer`：FFI 批量扫描与执行任务。
- `panda_core` 集成测试：扫描、取消、错误与冲突策略验证。

## 边界

模块定义平台无关的扫描和执行规则；不持有 Swift/UI 状态，也不决定用户的覆盖确认界面。


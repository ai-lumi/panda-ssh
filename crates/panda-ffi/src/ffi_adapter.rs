//! 无状态的 FFI 纯值适配器。
//!
//! 本模块不得访问 store、runtime、会话/任务注册表或网络；仅保留可由 core
//! 契约直接验证的输入输出转发。覆盖率门禁可单独审查此边界。

use crate::PandaError;

/// 共享地址栏规则；纯同步调用，不执行文件系统或网络操作。
#[uniffi::export]
pub fn sftp_directory_path(input: String) -> Result<String, PandaError> {
    Ok(panda_core::sftp_path::directory_path(&input)?)
}

/// 浏览和传输共用跨平台的目录与条目名拼接。
#[uniffi::export]
pub fn sftp_child_path(directory: String, name: String) -> String {
    panda_core::sftp_path::join_path(&directory, &name)
}

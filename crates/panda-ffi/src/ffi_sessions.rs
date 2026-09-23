//! SSH 会话、SFTP 会话句柄与交互式 Shell 的 FFI 导出。
//!
//! 本模块是纯适配层：会话注册、句柄分配与连接编排全部委托给 `PandaCore`，
//! FFI 只负责跨语言类型转换与同步/异步桥接。

use std::path::PathBuf;

use panda_core::{AuthMethod, HostConfig};

use crate::ffi_runtime::runtime;
use crate::ffi_store::{load_host, stores};
use crate::{PandaError, RemoteFileConflictRecord, RemoteFileRecord, SftpSessionRecord};

type CoreResult<T> = Result<T, panda_core::Error>;

fn manual_secret_for<'a>(
    cfg: &'a HostConfig,
    password: &'a Option<String>,
    passphrase: &'a Option<String>,
) -> Option<&'a str> {
    match cfg.auth {
        AuthMethod::Password { .. } => password.as_deref(),
        AuthMethod::PublicKey { .. } => passphrase.as_deref(),
    }
}

fn remote_file_records(files: Vec<panda_core::RemoteFile>) -> Vec<RemoteFileRecord> {
    files
        .into_iter()
        .map(|file| RemoteFileRecord {
            name: file.name,
            path: file.path,
            is_dir: file.is_dir,
            size: file.size,
            modified: file
                .modified
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|duration| duration.as_secs()),
        })
        .collect()
}

/// 在共享 runtime 上执行核心异步操作，将 `panda_core::Error` 转换为 `PandaError`。
fn block_core<T>(
    future: impl std::future::Future<Output = CoreResult<T>>,
) -> Result<T, PandaError> {
    runtime().block_on(future).map_err(Into::into)
}

// ---------------------------------------------------------------------------
// SFTP session API（持久标签会话）
// ---------------------------------------------------------------------------

/// 为一个 SFTP 标签建立独立 Transport，并返回后续操作使用的稳定句柄。
#[uniffi::export]
pub fn sftp_session_open(
    host_id: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<SftpSessionRecord, PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(&host_id, secret, trust_on_first_use, None, None)
            .await?;
        let connection_id = core.sftp_session_connection_id(handle).await?;
        let home_dir = core.sftp_session_home_dir(handle).await?;
        Ok(SftpSessionRecord {
            handle,
            connection_id,
            home_dir,
        })
    })
}

#[uniffi::export]
pub fn sftp_session_list(handle: u64, path: String) -> Result<Vec<RemoteFileRecord>, PandaError> {
    let core = &stores()?.core;
    block_core(async {
        let files = core.sftp_session_list(handle, &path).await?;
        Ok(remote_file_records(files))
    })
}

#[uniffi::export]
pub fn sftp_session_check_upload_conflict(
    handle: u64,
    local_path: String,
    remote_path: String,
) -> Result<Option<RemoteFileConflictRecord>, PandaError> {
    let core = &stores()?.core;
    block_core(async {
        Ok(core
            .sftp_session_check_upload_conflict(handle, PathBuf::from(&local_path).as_path(), &remote_path)
            .await?
            .map(RemoteFileConflictRecord::from))
    })
}

#[uniffi::export]
pub fn sftp_session_check_download_conflict(
    handle: u64,
    remote_path: String,
    local_path: String,
) -> Result<Option<RemoteFileConflictRecord>, PandaError> {
    let core = &stores()?.core;
    block_core(async {
        Ok(core
            .sftp_session_check_download_conflict(handle, &remote_path, PathBuf::from(&local_path).as_path())
            .await?
            .map(RemoteFileConflictRecord::from))
    })
}

#[uniffi::export]
pub fn sftp_session_remove_file(handle: u64, remote_path: String) -> Result<(), PandaError> {
    let core = &stores()?.core;
    block_core(async {
        core.sftp_session_remove_file(handle, &remote_path).await?;
        Ok(())
    })
}

#[uniffi::export]
pub fn sftp_session_remove_dir(handle: u64, remote_path: String) -> Result<(), PandaError> {
    let core = &stores()?.core;
    block_core(async {
        core.sftp_session_remove_dir(handle, &remote_path).await?;
        Ok(())
    })
}

#[uniffi::export]
pub fn sftp_session_create_dir(handle: u64, remote_path: String) -> Result<(), PandaError> {
    let core = &stores()?.core;
    block_core(async {
        core.sftp_session_create_dir(handle, &remote_path).await?;
        Ok(())
    })
}

/// 带代次跟踪的 SFTP 会话打开：核心负责代次校验与句柄注册。
#[uniffi::export]
pub fn sftp_session_open_tracked(
    host_id: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
    session_id: String,
    generation: u32,
) -> Result<SftpSessionRecord, PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(
                &host_id,
                secret,
                trust_on_first_use,
                Some(&session_id),
                Some(generation),
            )
            .await?;
        let connection_id = core.sftp_session_connection_id(handle).await?;
        let home_dir = core.sftp_session_home_dir(handle).await?;
        Ok(SftpSessionRecord {
            handle,
            connection_id,
            home_dir,
        })
    })
}

/// 精确关闭一个 SFTP 标签句柄。重复关闭为幂等 no-op。
#[uniffi::export]
pub fn sftp_session_close(handle: u64) -> Result<(), PandaError> {
    let core = &stores()?.core;
    block_core(async {
        core.close_sftp_session(handle).await?;
        Ok(())
    })
}

// ---------------------------------------------------------------------------
// 一次性 SFTP 操作（每次建立独立连接，完成后释放）
// ---------------------------------------------------------------------------

/// Connect and run `true` to verify auth; returns a human-readable summary.
#[uniffi::export]
pub fn test_connection(
    host_id: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<String, PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(core.test_connection(&host_id, secret, trust_on_first_use))
}

#[uniffi::export]
pub fn sftp_list(
    host_id: String,
    path: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<Vec<RemoteFileRecord>, PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(&host_id, secret, trust_on_first_use, None, None)
            .await?;
        let result = async {
            let files = core.sftp_session_list(handle, &path).await?;
            Ok(remote_file_records(files))
        }
        .await;
        core.close_sftp_session(handle).await?;
        result
    })
}

#[uniffi::export]
pub fn sftp_upload(
    host_id: String,
    local_path: String,
    remote_path: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<(), PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let local = PathBuf::from(local_path);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(&host_id, secret, trust_on_first_use, None, None)
            .await?;
        let result = core.sftp_session_upload(handle, &local, &remote_path).await;
        core.close_sftp_session(handle).await?;
        result
    })
}

#[uniffi::export]
pub fn sftp_download(
    host_id: String,
    remote_path: String,
    local_path: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<(), PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let local = PathBuf::from(local_path);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(&host_id, secret, trust_on_first_use, None, None)
            .await?;
        let result = core.sftp_session_download(handle, &remote_path, &local).await;
        core.close_sftp_session(handle).await?;
        result
    })
}

#[uniffi::export]
pub fn sftp_check_upload_conflict(
    host_id: String,
    local_path: String,
    remote_path: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<Option<RemoteFileConflictRecord>, PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(&host_id, secret, trust_on_first_use, None, None)
            .await?;
        let result = core
            .sftp_session_check_upload_conflict(
                handle,
                PathBuf::from(&local_path).as_path(),
                &remote_path,
            )
            .await?
            .map(RemoteFileConflictRecord::from);
        core.close_sftp_session(handle).await?;
        Ok(result)
    })
}

#[uniffi::export]
pub fn sftp_check_download_conflict(
    host_id: String,
    remote_path: String,
    local_path: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<Option<RemoteFileConflictRecord>, PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(&host_id, secret, trust_on_first_use, None, None)
            .await?;
        let result = core
            .sftp_session_check_download_conflict(
                handle,
                &remote_path,
                PathBuf::from(&local_path).as_path(),
            )
            .await?
            .map(RemoteFileConflictRecord::from);
        core.close_sftp_session(handle).await?;
        Ok(result)
    })
}

#[uniffi::export]
pub fn sftp_remove_file(
    host_id: String,
    remote_path: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<(), PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(&host_id, secret, trust_on_first_use, None, None)
            .await?;
        let result = core.sftp_session_remove_file(handle, &remote_path).await;
        core.close_sftp_session(handle).await?;
        result
    })
}

#[uniffi::export]
pub fn sftp_remove_dir(
    host_id: String,
    remote_path: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<(), PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(&host_id, secret, trust_on_first_use, None, None)
            .await?;
        let result = core.sftp_session_remove_dir(handle, &remote_path).await;
        core.close_sftp_session(handle).await?;
        result
    })
}

#[uniffi::export]
pub fn sftp_create_dir(
    host_id: String,
    remote_path: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<(), PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(&host_id, secret, trust_on_first_use, None, None)
            .await?;
        let result = core.sftp_session_create_dir(handle, &remote_path).await;
        core.close_sftp_session(handle).await?;
        result
    })
}

#[uniffi::export]
pub fn sftp_home_dir(
    host_id: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<String, PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(async {
        let handle = core
            .open_sftp_session(&host_id, secret, trust_on_first_use, None, None)
            .await?;
        let result = core.sftp_session_home_dir(handle).await;
        core.close_sftp_session(handle).await?;
        result
    })
}

// ---------------------------------------------------------------------------
// Interactive shell API
// ---------------------------------------------------------------------------

#[uniffi::export]
pub fn shell_open(
    host_id: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<u64, PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(core.open_shell_session(&host_id, secret, trust_on_first_use, None, None))
}

/// 带代次跟踪的 Shell 会话打开：核心负责代次校验与句柄注册。
#[uniffi::export]
pub fn shell_open_tracked(
    host_id: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
    session_id: String,
    generation: u32,
) -> Result<u64, PandaError> {
    let cfg = load_host(&host_id)?;
    let secret = manual_secret_for(&cfg, &password, &passphrase);
    let core = &stores()?.core;
    block_core(core.open_shell_session(
        &host_id,
        secret,
        trust_on_first_use,
        Some(&session_id),
        Some(generation),
    ))
}

/// 取消会话：递增代次并使该会话的全部句柄失效。
#[uniffi::export]
pub fn session_cancel(session_id: String) {
    if let Ok(stores) = stores() {
        stores.core.cancel_session(&session_id);
    }
}

/// 检查指定代次是否已过期。
#[uniffi::export]
pub fn session_is_stale(session_id: String, generation: u32) -> bool {
    match stores() {
        Ok(stores) => stores.core.is_session_stale(&session_id, generation),
        Err(_) => true,
    }
}

/// 查询指定代次的会话是否仍有活跃句柄。
#[uniffi::export]
pub fn session_has_active(session_id: String, generation: u32) -> bool {
    match stores() {
        Ok(stores) => stores.core.has_active_session(&session_id, generation),
        Err(_) => false,
    }
}

#[uniffi::export]
pub fn shell_write(handle: u64, data: Vec<u8>) -> Result<(), PandaError> {
    Ok(stores()?.core.shell_write(handle, &data)?)
}

#[uniffi::export]
pub fn shell_read(handle: u64, max: u64) -> Result<Vec<u8>, PandaError> {
    Ok(stores()?.core.shell_read(handle, max as usize)?)
}

#[uniffi::export]
pub fn shell_close(handle: u64) -> Result<(), PandaError> {
    let core = &stores()?.core;
    block_core(async {
        core.close_shell_session(handle).await?;
        Ok(())
    })
}

#[uniffi::export]
pub fn shell_resize(handle: u64, cols: u64, rows: u64) -> Result<(), PandaError> {
    Ok(stores()?.core.shell_resize(handle, cols as u32, rows as u32)?)
}

#[cfg(test)]
#[path = "tests/ffi_sessions_tests.rs"]
mod tests;

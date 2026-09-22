//! SSH 会话、SFTP 会话句柄与交互式 Shell 的 FFI 导出。
//!
//! 本模块拥有 Shell/SFTP 会话注册表与连接辅助逻辑：句柄分配、精确关闭与
//! 幂等语义都在这里维护；主机配置与凭据直接从 store 模块访问。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use panda_core::{
    HostConfig, KnownHosts, SftpClient, ShellSession, SshSession, UnknownHostKeyPolicy,
};
use tokio::sync::Mutex as AsyncMutex;

use crate::ffi_runtime::runtime;
use crate::ffi_store::{credentials_for, load_host, stores};
use crate::{PandaError, RemoteFileConflictRecord, RemoteFileRecord, SftpSessionRecord};

// ---------------------------------------------------------------------------
// Session registries
// ---------------------------------------------------------------------------

static SHELL_SESSIONS: OnceLock<Mutex<HashMap<u64, Arc<Mutex<ShellSession>>>>> = OnceLock::new();
static NEXT_SHELL_ID: AtomicU64 = AtomicU64::new(1);

struct OwnedSftpSession {
    session: Arc<SshSession>,
    client: Option<SftpClient>,
}

static SFTP_SESSIONS: OnceLock<Mutex<HashMap<u64, Arc<AsyncMutex<OwnedSftpSession>>>>> =
    OnceLock::new();
static NEXT_SFTP_ID: AtomicU64 = AtomicU64::new(1);

fn shell_sessions() -> &'static Mutex<HashMap<u64, Arc<Mutex<ShellSession>>>> {
    SHELL_SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_shell_id() -> u64 {
    NEXT_SHELL_ID.fetch_add(1, Ordering::SeqCst)
}

fn sftp_sessions() -> &'static Mutex<HashMap<u64, Arc<AsyncMutex<OwnedSftpSession>>>> {
    SFTP_SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_sftp_id() -> u64 {
    NEXT_SFTP_ID.fetch_add(1, Ordering::SeqCst)
}

fn sftp_session(handle: u64) -> Result<Arc<AsyncMutex<OwnedSftpSession>>, PandaError> {
    sftp_sessions()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&handle)
        .cloned()
        .ok_or(PandaError::UnknownSftpHandle(handle))
}

// ---------------------------------------------------------------------------
// Connection helpers
// ---------------------------------------------------------------------------

/// 建立一条由当前调用方显式拥有的独立 SSH Transport。
/// Unknown host keys follow `trust_on_first_use`.
async fn connect_session(
    cfg: &HostConfig,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<Arc<SshSession>, PandaError> {
    let creds = credentials_for(cfg, password.clone(), passphrase.clone())?;
    let mut known_hosts = KnownHosts::new(stores()?.known_hosts.path().to_path_buf());
    let policy = if trust_on_first_use {
        UnknownHostKeyPolicy::AcceptAndStore
    } else {
        UnknownHostKeyPolicy::Reject
    };
    let session = SshSession::connect_shared(cfg, creds, &mut known_hosts, policy).await?;
    Ok(session)
}

/// 为独立操作建立专属连接，调用方必须持有返回的 Transport 直到操作结束。
async fn open_sftp_session(
    cfg: &HostConfig,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<(Arc<SshSession>, SftpClient), PandaError> {
    let session = connect_session(cfg, password, passphrase, trust_on_first_use).await?;
    session.set_owner("SFTP 操作", cfg.id.clone());
    let sftp = SftpClient::new(&session).await?;
    Ok((session, sftp))
}

/// 关闭 SFTP Channel；Transport 在调用方的独立操作作用域结束时释放。
async fn close_sftp(sftp: SftpClient) -> Result<(), PandaError> {
    sftp.close().await?;
    Ok(())
}

// ---------------------------------------------------------------------------
// SSH / SFTP API
// ---------------------------------------------------------------------------

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

/// 为一个 SFTP 标签建立独立 Transport，并返回后续操作使用的稳定句柄。
#[uniffi::export]
pub fn sftp_session_open(
    host_id: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<SftpSessionRecord, PandaError> {
    let cfg = load_host(&host_id)?;
    runtime().block_on(async {
        let handle = next_sftp_id();
        let session = connect_session(&cfg, password, passphrase, trust_on_first_use).await?;
        session.set_owner("SFTP 标签", handle.to_string());
        let connection_id = session.telemetry_id();
        let client = SftpClient::new(&session).await?;
        let home_dir = client.home_dir().await?;
        sftp_sessions()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(
                handle,
                Arc::new(AsyncMutex::new(OwnedSftpSession {
                    session,
                    client: Some(client),
                })),
            );
        Ok(SftpSessionRecord {
            handle,
            connection_id,
            home_dir,
        })
    })
}

#[uniffi::export]
pub fn sftp_session_list(handle: u64, path: String) -> Result<Vec<RemoteFileRecord>, PandaError> {
    let owned = sftp_session(handle)?;
    runtime().block_on(async {
        let guard = owned.lock().await;
        let client = guard
            .client
            .as_ref()
            .ok_or(PandaError::UnknownSftpHandle(handle))?;
        Ok(remote_file_records(client.list_dir(&path).await?))
    })
}

#[uniffi::export]
pub fn sftp_session_check_upload_conflict(
    handle: u64,
    local_path: String,
    remote_path: String,
) -> Result<Option<RemoteFileConflictRecord>, PandaError> {
    let owned = sftp_session(handle)?;
    runtime().block_on(async {
        let guard = owned.lock().await;
        let client = guard
            .client
            .as_ref()
            .ok_or(PandaError::UnknownSftpHandle(handle))?;
        Ok(client
            .check_upload_conflict(PathBuf::from(local_path).as_path(), &remote_path)
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
    let owned = sftp_session(handle)?;
    runtime().block_on(async {
        let guard = owned.lock().await;
        let client = guard
            .client
            .as_ref()
            .ok_or(PandaError::UnknownSftpHandle(handle))?;
        Ok(client
            .check_download_conflict(&remote_path, PathBuf::from(local_path).as_path())
            .await?
            .map(RemoteFileConflictRecord::from))
    })
}

#[uniffi::export]
pub fn sftp_session_remove_file(handle: u64, remote_path: String) -> Result<(), PandaError> {
    let owned = sftp_session(handle)?;
    runtime().block_on(async {
        let guard = owned.lock().await;
        guard
            .client
            .as_ref()
            .ok_or(PandaError::UnknownSftpHandle(handle))?
            .remove_file(&remote_path)
            .await?;
        Ok(())
    })
}

#[uniffi::export]
pub fn sftp_session_remove_dir(handle: u64, remote_path: String) -> Result<(), PandaError> {
    let owned = sftp_session(handle)?;
    runtime().block_on(async {
        let guard = owned.lock().await;
        guard
            .client
            .as_ref()
            .ok_or(PandaError::UnknownSftpHandle(handle))?
            .remove_all(&remote_path)
            .await?;
        Ok(())
    })
}

#[uniffi::export]
pub fn sftp_session_create_dir(handle: u64, remote_path: String) -> Result<(), PandaError> {
    let owned = sftp_session(handle)?;
    runtime().block_on(async {
        let guard = owned.lock().await;
        guard
            .client
            .as_ref()
            .ok_or(PandaError::UnknownSftpHandle(handle))?
            .create_dir(&remote_path)
            .await?;
        Ok(())
    })
}

/// 精确关闭一个 SFTP 标签句柄。重复关闭为幂等 no-op。
#[uniffi::export]
pub fn sftp_session_close(handle: u64) -> Result<(), PandaError> {
    let owned = sftp_sessions()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&handle);
    let Some(owned) = owned else { return Ok(()) };
    runtime().block_on(async {
        let mut guard = owned.lock().await;
        if let Some(client) = guard.client.take() {
            client.close().await?;
        }
        guard.session.disconnect().await?;
        Ok(())
    })
}

/// Connect and run `true` to verify auth; returns a human-readable summary.
///
/// `trust_on_first_use`: `false` rejects unknown host keys with
/// `UnknownHostKey` (carrying the presented key and fingerprint) without
/// writing known_hosts; `true` accepts and stores them (TOFU).
#[uniffi::export]
pub fn test_connection(
    host_id: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<String, PandaError> {
    let cfg = load_host(&host_id)?;
    runtime().block_on(async {
        let session = connect_session(&cfg, password, passphrase, trust_on_first_use).await?;
        session.set_owner("连接探测", host_id.clone());
        let output = session.exec("true").await?;
        session.disconnect().await?;
        Ok(format!(
            "connected to {}@{}:{} (exit status: {:?})",
            cfg.username, cfg.host, cfg.port, output.exit_status
        ))
    })
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
    runtime().block_on(async {
        let (_session, sftp) =
            open_sftp_session(&cfg, password, passphrase, trust_on_first_use).await?;
        let files = sftp.list_dir(&path).await?;
        close_sftp(sftp).await?;
        Ok(remote_file_records(files))
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
    runtime().block_on(async {
        let (_session, sftp) =
            open_sftp_session(&cfg, password, passphrase, trust_on_first_use).await?;
        sftp.upload(PathBuf::from(&local_path).as_path(), &remote_path, None)
            .await?;
        close_sftp(sftp).await?;
        Ok(())
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
    runtime().block_on(async {
        let (_session, sftp) =
            open_sftp_session(&cfg, password, passphrase, trust_on_first_use).await?;
        sftp.download(&remote_path, PathBuf::from(&local_path).as_path())
            .await?;
        close_sftp(sftp).await?;
        Ok(())
    })
}

/// 上传前预检查：若远端目标已存在，返回源文件与目标文件的大小及修改时间。
/// 返回 `None` 表示目标不存在，可以直接上传。
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
    runtime().block_on(async {
        let (_session, sftp) =
            open_sftp_session(&cfg, password, passphrase, trust_on_first_use).await?;
        let conflict = sftp
            .check_upload_conflict(PathBuf::from(&local_path).as_path(), &remote_path)
            .await?;
        close_sftp(sftp).await?;
        Ok(conflict.map(RemoteFileConflictRecord::from))
    })
}

/// 下载前预检查：若本地目标已存在，返回源文件与目标文件的大小及修改时间。
/// 返回 `None` 表示目标不存在，可以直接下载。
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
    runtime().block_on(async {
        let (_session, sftp) =
            open_sftp_session(&cfg, password, passphrase, trust_on_first_use).await?;
        let conflict = sftp
            .check_download_conflict(&remote_path, PathBuf::from(&local_path).as_path())
            .await?;
        close_sftp(sftp).await?;
        Ok(conflict.map(RemoteFileConflictRecord::from))
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
    runtime().block_on(async {
        let (_session, sftp) =
            open_sftp_session(&cfg, password, passphrase, trust_on_first_use).await?;
        sftp.remove_file(&remote_path).await?;
        close_sftp(sftp).await?;
        Ok(())
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
    runtime().block_on(async {
        let (_session, sftp) =
            open_sftp_session(&cfg, password, passphrase, trust_on_first_use).await?;
        sftp.remove_all(&remote_path).await?;
        close_sftp(sftp).await?;
        Ok(())
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
    runtime().block_on(async {
        let (_session, sftp) =
            open_sftp_session(&cfg, password, passphrase, trust_on_first_use).await?;
        sftp.create_dir(&remote_path).await?;
        close_sftp(sftp).await?;
        Ok(())
    })
}

/// Resolve the user's SFTP home directory.
/// SFTP sessions start in the user's home; `canonicalize(".")` returns its
/// absolute path, which the UI uses as the initial remote pane root.
#[uniffi::export]
pub fn sftp_home_dir(
    host_id: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<String, PandaError> {
    let cfg = load_host(&host_id)?;
    runtime().block_on(async {
        let (_session, sftp) =
            open_sftp_session(&cfg, password, passphrase, trust_on_first_use).await?;
        let home = sftp.home_dir().await?;
        close_sftp(sftp).await?;
        Ok(home)
    })
}

// ---------------------------------------------------------------------------
// Interactive shell API
// ---------------------------------------------------------------------------

/// Open an interactive shell session for `host_id`.
///
/// Returns a session handle that can be passed to `shell_write`, `shell_read`
/// and `shell_close`. The SSH connection and shell channel are kept alive
/// until `shell_close` is called.
#[uniffi::export]
pub fn shell_open(
    host_id: String,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<u64, PandaError> {
    let cfg = load_host(&host_id)?;
    runtime().block_on(async {
        let session = connect_session(&cfg, password, passphrase, trust_on_first_use).await?;
        let shell = ShellSession::open(Arc::clone(&session)).await?;
        // 只为成功打开的句柄分配连续编号，并与发布处于同一临界区。
        // 因此已发行但不在表内的编号一定已被关闭，无需永久保存关闭集合。
        let mut sessions = shell_sessions()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let id = next_shell_id();
        session.set_owner("终端标签", id.to_string());
        sessions.insert(id, Arc::new(Mutex::new(shell)));
        Ok(id)
    })
}

/// Write input bytes to the shell session.
#[uniffi::export]
pub fn shell_write(handle: u64, data: Vec<u8>) -> Result<(), PandaError> {
    let session = shell_sessions()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&handle)
        .cloned()
        .ok_or(PandaError::UnknownShellHandle(handle))?;
    let result = session
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .write(&data);
    Ok(result?)
}

/// Read up to `max` bytes produced by the remote shell. Returns an empty
/// vector when no output is currently buffered.
#[uniffi::export]
pub fn shell_read(handle: u64, max: u64) -> Result<Vec<u8>, PandaError> {
    let session = shell_sessions()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&handle)
        .cloned()
        .ok_or(PandaError::UnknownShellHandle(handle))?;
    let result = session
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .read(max as usize);
    Ok(result?)
}

/// Close the shell session and disconnect the underlying SSH connection.
#[uniffi::export]
pub fn shell_close(handle: u64) -> Result<(), PandaError> {
    let removed = shell_sessions()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&handle);
    let Some(session) = removed else {
        return if handle > 0 && handle < NEXT_SHELL_ID.load(Ordering::SeqCst) {
            Ok(())
        } else {
            Err(PandaError::UnknownShellHandle(handle))
        };
    };
    runtime().block_on(
        session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .close(),
    )?;
    Ok(())
}

/// Notify the remote PTY that the terminal window has been resized.
#[uniffi::export]
pub fn shell_resize(handle: u64, cols: u64, rows: u64) -> Result<(), PandaError> {
    let session = shell_sessions()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&handle)
        .cloned()
        .ok_or(PandaError::UnknownShellHandle(handle))?;
    let result = session
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .resize(cols as u32, rows as u32);
    Ok(result?)
}

#[cfg(test)]
#[path = "tests/ffi_sessions_tests.rs"]
mod tests;

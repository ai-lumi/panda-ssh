//! UniFFI bindings exposing panda-core to Swift.
//!
//! All exported functions are synchronous from the caller's perspective;
//! async work runs on a lazily created global tokio runtime.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use panda_core::{
    AuthMethod, ConfigStore, CredentialStore, Credentials, Group, GroupStore, HostConfig, KnownHosts, SftpClient,
    ShellSession, SshSession, TomlConfigStore, TomlGroupStore, UnknownHostKeyPolicy,
};
use tokio::runtime::Runtime;
use uuid::Uuid;

uniffi::setup_scaffolding!();

mod batch_transfer;
pub use batch_transfer::{
    batch_transfer_cancel, batch_transfer_list, batch_transfer_resolve_conflict,
    batch_transfer_status, scan_local_batch, scan_remote_batch, start_batch_download,
    start_batch_upload, BatchConflictRecord, BatchItemRecord, BatchTransferDirectionEnum,
    BatchTransferStatusEnum, BatchTransferStatusRecord,
};

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

/// Structured error surface for Swift: every variant is programmatically
/// distinguishable, so the UI can branch on `AuthFailed`, `Timeout` and
/// host-key problems without parsing strings.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PandaError {
    #[error("authentication failed")]
    AuthFailed,
    #[error("operation timed out")]
    Timeout,
    #[error("host key mismatch: stored {stored_fingerprint}, presented {presented_fingerprint}")]
    HostKeyMismatch {
        stored_fingerprint: String,
        presented_fingerprint: String,
    },
    #[error("unknown host key for {host}: fingerprint {fingerprint}")]
    UnknownHostKey {
        host: String,
        /// Presented OpenSSH public key string — pass it to
        /// `accept_unknown_host_key` when the user trusts it.
        presented: String,
        fingerprint: String,
    },
    #[error("store not initialized; call init_store() first")]
    NotInitialized,
    #[error("no host with id {0}")]
    UnknownHost(String),
    #[error("host {0} uses password auth but no password was provided")]
    MissingPassword(String),
    #[error("host {0} uses an encrypted private key but no passphrase was provided")]
    MissingPassphrase(String),
    #[error("unknown shell session handle {0}")]
    UnknownShellHandle(u64),
    #[error("operation cancelled")]
    Cancelled,
    #[error("credential protection key is required")]
    CredentialProtectionKeyRequired,
    #[error("credential protection key cannot decrypt the credential file")]
    CredentialUnlockFailed,
    #[error("credential file is invalid")]
    InvalidCredentialFile,
    #[error("unknown transfer task {0}")]
    UnknownTransferTask(String),
    /// Fallback for everything without a dedicated category.
    #[error("{0}")]
    Core(String),
}

impl From<panda_core::Error> for PandaError {
    fn from(e: panda_core::Error) -> Self {
        match e {
            panda_core::Error::AuthFailed => PandaError::AuthFailed,
            panda_core::Error::MissingPassphrase => PandaError::MissingPassphrase(String::new()),
            panda_core::Error::Timeout => PandaError::Timeout,
            panda_core::Error::HostKeyMismatch {
                stored_fingerprint,
                presented_fingerprint,
                ..
            } => PandaError::HostKeyMismatch {
                stored_fingerprint,
                presented_fingerprint,
            },
            panda_core::Error::UnknownHostKey {
                host,
                presented,
                fingerprint,
            } => PandaError::UnknownHostKey {
                host,
                presented,
                fingerprint,
            },
            panda_core::Error::Cancelled => PandaError::Cancelled,
            panda_core::Error::CredentialProtectionKeyRequired => PandaError::CredentialProtectionKeyRequired,
            panda_core::Error::CredentialUnlockFailed => PandaError::CredentialUnlockFailed,
            panda_core::Error::InvalidCredentialFile => PandaError::InvalidCredentialFile,
            other => PandaError::Core(other.to_string()),
        }
    }
}

impl From<std::io::Error> for PandaError {
    fn from(e: std::io::Error) -> Self {
        PandaError::Core(e.to_string())
    }
}

// ---------------------------------------------------------------------------
// Exported types
// ---------------------------------------------------------------------------

/// Mirror of `panda_core::AuthMethod` with FFI-friendly field types.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum AuthMethodEnum {
    Password { password_ref: Option<String> },
    PublicKey {
        key_path: String,
        passphrase_ref: Option<String>,
    },
}

/// Mirror of `panda_core::HostConfig`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HostConfigRecord {
    /// Empty string means "create a new id on save".
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: AuthMethodEnum,
    pub notes: Option<String>,
    /// Owning group id; `None` means root level.
    pub group_id: Option<String>,
}

/// Mirror of `panda_core::Group`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct GroupRecord {
    /// Empty string means "create a new id on save".
    pub id: String,
    pub name: String,
    /// Parent group id; `None` means a root-level group.
    pub parent_id: Option<String>,
}

/// Flat, FFI-friendly view of a remote directory entry.
/// `modified` is seconds since the Unix epoch.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RemoteFileRecord {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: Option<u64>,
}

/// SFTP 覆盖确认所需信息：源文件与目标文件的大小、最后修改时间。
/// `*_mtime` 为 Unix 时间戳（秒），无法获取时为 `None`。
#[derive(Debug, Clone, uniffi::Record)]
pub struct RemoteFileConflictRecord {
    pub source_size: u64,
    pub source_mtime: Option<u64>,
    pub target_size: u64,
    pub target_mtime: Option<u64>,
}

impl From<panda_core::FileConflictInfo> for RemoteFileConflictRecord {
    fn from(info: panda_core::FileConflictInfo) -> Self {
        Self {
            source_size: info.source_size,
            source_mtime: info.source_mtime,
            target_size: info.target_size,
            target_mtime: info.target_mtime,
        }
    }
}

/// File-level host key status (no connection needed). Without a presented
/// key only `Unknown` / `Known` are reachable; a genuine key change surfaces
/// as `PandaError::HostKeyMismatch` at connect time.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum KnownHostStatusEnum {
    /// No known_hosts record for this host/port.
    Unknown,
    /// A record exists; carries its SHA256 colon-separated fingerprint and
    /// key type (e.g. `ssh-ed25519`).
    Known { fingerprint: String, key_type: String },
}

impl From<AuthMethodEnum> for AuthMethod {
    fn from(a: AuthMethodEnum) -> Self {
        match a {
            AuthMethodEnum::Password { password_ref } => AuthMethod::Password { password_ref },
            AuthMethodEnum::PublicKey {
                key_path,
                passphrase_ref,
            } => AuthMethod::PublicKey {
                key_path: PathBuf::from(key_path),
                passphrase_ref,
            },
        }
    }
}

impl From<AuthMethod> for AuthMethodEnum {
    fn from(a: AuthMethod) -> Self {
        match a {
            AuthMethod::Password { password_ref } => AuthMethodEnum::Password { password_ref },
            AuthMethod::PublicKey {
                key_path,
                passphrase_ref,
            } => AuthMethodEnum::PublicKey {
                key_path: key_path.to_string_lossy().into_owned(),
                passphrase_ref,
            },
        }
    }
}

impl From<HostConfigRecord> for HostConfig {
    fn from(r: HostConfigRecord) -> Self {
        HostConfig {
            id: r.id,
            name: r.name,
            host: r.host,
            port: r.port,
            username: r.username,
            auth: r.auth.into(),
            notes: r.notes,
            group_id: r.group_id,
        }
    }
}

impl From<HostConfig> for HostConfigRecord {
    fn from(c: HostConfig) -> Self {
        HostConfigRecord {
            id: c.id,
            name: c.name,
            host: c.host,
            port: c.port,
            username: c.username,
            auth: c.auth.into(),
            notes: c.notes,
            group_id: c.group_id,
        }
    }
}

impl From<GroupRecord> for Group {
    fn from(r: GroupRecord) -> Self {
        Group {
            id: r.id,
            name: r.name,
            parent_id: r.parent_id,
        }
    }
}

impl From<Group> for GroupRecord {
    fn from(g: Group) -> Self {
        GroupRecord {
            id: g.id,
            name: g.name,
            parent_id: g.parent_id,
        }
    }
}

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub(crate) fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("failed to create tokio runtime"))
}

/// Stores rooted at the app-provided config directory.
struct Stores {
    config: TomlConfigStore,
    groups: TomlGroupStore,
    known_hosts: KnownHosts,
    credentials: CredentialStore,
}

static STORES: Mutex<Option<Arc<Stores>>> = Mutex::new(None);

pub(crate) fn stores() -> Result<Arc<Stores>, PandaError> {
    STORES.lock().unwrap().clone().ok_or(PandaError::NotInitialized)
}

static SHELL_SESSIONS: OnceLock<Mutex<HashMap<u64, ShellSession>>> = OnceLock::new();
static NEXT_SHELL_ID: AtomicU64 = AtomicU64::new(1);

fn shell_sessions() -> &'static Mutex<HashMap<u64, ShellSession>> {
    SHELL_SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_shell_id() -> u64 {
    NEXT_SHELL_ID.fetch_add(1, Ordering::SeqCst)
}

// ---------------------------------------------------------------------------
// Store API
// ---------------------------------------------------------------------------

/// Initialize the config store and known_hosts under `config_dir`
/// (the app passes its App Group container path). 允许重新初始化,
/// 使 panda-ffi 的集成测试可以在同进程中切换临时目录;App 仍只调用一次。
#[uniffi::export]
pub fn init_store(config_dir: String) -> Result<(), PandaError> {
    let dir = PathBuf::from(config_dir);
    std::fs::create_dir_all(&dir)?;
    *STORES.lock().unwrap() = Some(Arc::new(Stores {
        config: TomlConfigStore::new(dir.join("hosts.toml")),
        groups: TomlGroupStore::new(dir.join("groups.toml")),
        known_hosts: KnownHosts::new(dir.join("known_hosts")),
        credentials: CredentialStore::new(dir.join("credentials.toml")),
    }));
    Ok(())
}

#[uniffi::export]
pub fn list_hosts() -> Result<Vec<HostConfigRecord>, PandaError> {
    let hosts = stores()?.config.list()?;
    Ok(hosts.into_iter().map(HostConfigRecord::from).collect())
}

/// Insert or update a host. An empty `id` generates a fresh UUID.
#[uniffi::export]
pub fn save_host(host: HostConfigRecord) -> Result<(), PandaError> {
    let mut config: HostConfig = host.into();
    if config.id.is_empty() {
        config.id = Uuid::new_v4().to_string();
    }
    Ok(stores()?.config.upsert(config)?)
}

#[uniffi::export]
pub fn delete_host(id: String) -> Result<(), PandaError> {
    let stores = stores()?;
    let password_ref = format!("host.{id}.password");
    let passphrase_ref = format!("host.{id}.passphrase");
    let previous_password = stores.credentials.get(&password_ref)?;
    let previous_passphrase = stores.credentials.get(&passphrase_ref)?;

    // 先验证并删除凭据；若任一步失败，恢复已经删除的条目且不修改 hosts.toml。
    stores.credentials.delete(&password_ref)?;
    if let Err(error) = stores.credentials.delete(&passphrase_ref) {
        restore_credential(&stores.credentials, &password_ref, previous_password)?;
        return Err(error.into());
    }
    if let Err(error) = stores.config.delete(&id) {
        restore_credential(&stores.credentials, &password_ref, previous_password)?;
        restore_credential(&stores.credentials, &passphrase_ref, previous_passphrase)?;
        return Err(error.into());
    }
    Ok(())
}

fn restore_credential(store: &CredentialStore, reference: &str, secret: Option<String>) -> Result<(), panda_core::Error> {
    match secret {
        Some(secret) => store.save(reference.to_owned(), secret),
        None => store.delete(reference),
    }
}

/// 保存本地凭据；秘密仅写入配置目录的 credentials.toml。
#[uniffi::export]
pub fn save_credential(reference: String, secret: String) -> Result<(), PandaError> {
    Ok(stores()?.credentials.save(reference, secret)?)
}

#[uniffi::export]
pub fn read_credential(reference: String) -> Result<Option<String>, PandaError> {
    Ok(stores()?.credentials.get(&reference)?)
}

#[uniffi::export]
pub fn delete_credential(reference: String) -> Result<(), PandaError> {
    Ok(stores()?.credentials.delete(&reference)?)
}

/// 用当前保护密钥解锁凭据文件，并用新密钥重写；新密钥为空时迁回明文格式。
#[uniffi::export]
pub fn set_credential_protection_key(current_key: Option<String>, new_key: Option<String>) -> Result<(), PandaError> {
    Ok(stores()?.credentials.set_protection_key(current_key, new_key)?)
}

#[uniffi::export]
pub fn credential_protection_enabled() -> Result<bool, PandaError> {
    Ok(stores()?.credentials.is_protected()?)
}

// ---------------------------------------------------------------------------
// Host key API
// ---------------------------------------------------------------------------

/// File-level host key status for `host:port` (no connection is made):
/// `Unknown` when no known_hosts record exists, otherwise `Known` with the
/// recorded fingerprint and key type. The UI uses this before connecting to
/// decide between connecting directly and prompting for TOFU confirmation.
#[uniffi::export]
pub fn host_key_status(host: String, port: u16) -> Result<KnownHostStatusEnum, PandaError> {
    match stores()?.known_hosts.status(&host, port)? {
        panda_core::KnownHostStatus::Unknown => Ok(KnownHostStatusEnum::Unknown),
        panda_core::KnownHostStatus::Known {
            fingerprint,
            key_type,
        } => Ok(KnownHostStatusEnum::Known {
            fingerprint,
            key_type,
        }),
    }
}

/// Store a presented host key after the user confirmed its fingerprint.
/// `key` MUST be the `presented` key captured from a `Reject`-policy probe
/// (`UnknownHostKey` error), not a key from a fresh handshake — storing the
/// probed key closes the TOCTOU window between probe and reconnect.
#[uniffi::export]
pub fn accept_unknown_host_key(host: String, port: u16, key: String) -> Result<(), PandaError> {
    Ok(stores()?.known_hosts.accept(&host, port, &key)?)
}

// ---------------------------------------------------------------------------
// Group API
// ---------------------------------------------------------------------------

#[uniffi::export]
pub fn list_groups() -> Result<Vec<GroupRecord>, PandaError> {
    let groups = stores()?.groups.list()?;
    Ok(groups.into_iter().map(GroupRecord::from).collect())
}

/// Insert or update a group. An empty `id` generates a fresh UUID.
#[uniffi::export]
pub fn save_group(group: GroupRecord) -> Result<(), PandaError> {
    let mut g: Group = group.into();
    if g.id.is_empty() {
        g.id = Uuid::new_v4().to_string();
    }
    Ok(stores()?.groups.upsert(g)?)
}

/// Delete a group: hosts under it (including hosts of subgroups) move back
/// to root level with their data intact; subgroups are deleted too.
#[uniffi::export]
pub fn delete_group(id: String) -> Result<(), PandaError> {
    let stores = stores()?;
    Ok(panda_core::delete_group_cascade(&stores.groups, &stores.config, &id)?)
}

/// Change a group's parent (`None` moves it to root level). Refuses moves
/// that would create a cycle (into itself or a descendant).
#[uniffi::export]
pub fn move_group(id: String, new_parent_id: Option<String>) -> Result<(), PandaError> {
    Ok(panda_core::move_group(
        &stores()?.groups,
        &id,
        new_parent_id.as_deref(),
    )?)
}

// ---------------------------------------------------------------------------
// Connection helpers
// ---------------------------------------------------------------------------

pub(crate) fn load_host(host_id: &str) -> Result<HostConfig, PandaError> {
    stores()?
        .config
        .get(host_id)?
        .ok_or_else(|| PandaError::UnknownHost(host_id.to_string()))
}

/// Build credentials from the host's auth method; secrets are supplied by
/// the caller from the local credential store or the current session.
pub(crate) fn credentials_for(
    cfg: &HostConfig,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<Credentials, PandaError> {
    match &cfg.auth {
        AuthMethod::Password { .. } => password
            .map(Credentials::Password)
            .ok_or_else(|| PandaError::MissingPassword(cfg.name.clone())),
        AuthMethod::PublicKey { key_path, .. } => Ok(Credentials::KeyFile {
            path: key_path.clone(),
            passphrase: passphrase.filter(|value| !value.is_empty()),
        }),
    }
}

/// 从连接池获取已有会话，或新建并放入池中。
/// Unknown host keys follow `trust_on_first_use`.
async fn get_or_create_session(
    host_id: &str,
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
    Ok(panda_core::connection_pool::global_pool()
        .get_or_create(
            host_id.to_string(),
            cfg,
            creds,
            &mut known_hosts,
            policy,
        )
        .await?)
}

/// 从连接池获取会话并打开 SFTP 频道。
async fn open_sftp_session(
    host_id: &str,
    cfg: &HostConfig,
    password: Option<String>,
    passphrase: Option<String>,
    trust_on_first_use: bool,
) -> Result<(Arc<SshSession>, SftpClient), PandaError> {
    let session = get_or_create_session(host_id, cfg, password, passphrase, trust_on_first_use).await?;
    let sftp = SftpClient::new(&session).await?;
    Ok((session, sftp))
}

/// 关闭 SFTP 客户端，保留底层 SSH 连接在池中复用。
async fn close_sftp(sftp: SftpClient) -> Result<(), PandaError> {
    sftp.close().await?;
    Ok(())
}

// ---------------------------------------------------------------------------
// SSH / SFTP API
// ---------------------------------------------------------------------------

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
        let session = get_or_create_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
        let output = session.exec("true").await?;
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
        let (_, sftp) =
            open_sftp_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
        let files = sftp.list_dir(&path).await?;
        close_sftp(sftp).await?;
        Ok(files
            .into_iter()
            .map(|f| RemoteFileRecord {
                name: f.name,
                path: f.path,
                is_dir: f.is_dir,
                size: f.size,
                modified: f
                    .modified
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs()),
            })
            .collect())
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
        let (_, sftp) =
            open_sftp_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
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
        let (_, sftp) =
            open_sftp_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
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
        let (_, sftp) =
            open_sftp_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
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
        let (_, sftp) =
            open_sftp_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
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
        let (_, sftp) =
            open_sftp_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
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
        let (_, sftp) =
            open_sftp_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
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
        let (_, sftp) =
            open_sftp_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
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
        let (_, sftp) =
            open_sftp_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
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
        let session = get_or_create_session(&host_id, &cfg, password, passphrase, trust_on_first_use).await?;
        let shell = ShellSession::open(session).await?;
        let id = next_shell_id();
        shell_sessions().lock().unwrap().insert(id, shell);
        Ok(id)
    })
}

/// Write input bytes to the shell session.
#[uniffi::export]
pub fn shell_write(handle: u64, data: Vec<u8>) -> Result<(), PandaError> {
    let sessions = shell_sessions().lock().unwrap();
    let session = sessions
        .get(&handle)
        .ok_or(PandaError::UnknownShellHandle(handle))?;
    Ok(session.write(&data)?)
}

/// Read up to `max` bytes produced by the remote shell. Returns an empty
/// vector when no output is currently buffered.
#[uniffi::export]
pub fn shell_read(handle: u64, max: u64) -> Result<Vec<u8>, PandaError> {
    let sessions = shell_sessions().lock().unwrap();
    let session = sessions
        .get(&handle)
        .ok_or(PandaError::UnknownShellHandle(handle))?;
    Ok(session.read(max as usize)?)
}

/// Close the shell session and disconnect the underlying SSH connection.
#[uniffi::export]
pub fn shell_close(handle: u64) -> Result<(), PandaError> {
    let mut session = shell_sessions()
        .lock()
        .unwrap()
        .remove(&handle)
        .ok_or(PandaError::UnknownShellHandle(handle))?;
    runtime().block_on(async { Ok(session.close().await?) })
}

/// Notify the remote PTY that the terminal window has been resized.
#[uniffi::export]
pub fn shell_resize(handle: u64, cols: u64, rows: u64) -> Result<(), PandaError> {
    let sessions = shell_sessions().lock().unwrap();
    let session = sessions
        .get(&handle)
        .ok_or(PandaError::UnknownShellHandle(handle))?;
    Ok(session.resize(cols as u32, rows as u32)?)
}

/// 断开指定主机的全部 SSH 连接，从连接缓存中移除。
/// 当用户关闭最后一个指向该主机的标签页时调用。
/// 若有正在进行的操作持有会话引用，会话在操作完成后断开。
#[uniffi::export]
pub fn disconnect_host(host_id: String) -> Result<(), PandaError> {
    runtime().block_on(async {
        panda_core::connection_pool::global_pool()
            .disconnect_host(&host_id)
            .await;
        Ok(())
    })
}

// ---------------------------------------------------------------------------
// Transfer task registry
// ---------------------------------------------------------------------------

const TRANSFER_CONCURRENCY: usize = 3;

/// Direction of a transfer task.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum TransferDirectionEnum {
    Upload,
    Download,
}

/// Lifecycle state of a transfer task.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TransferStatusEnum {
    Queued,
    Running,
    Paused,
    Completed,
    Failed,
    Cancelled,
}

/// FFI-friendly snapshot of a transfer task.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TransferStatusRecord {
    pub id: String,
    pub direction: TransferDirectionEnum,
    pub host_id: String,
    pub local_path: String,
    pub remote_path: String,
    pub size: u64,
    pub transferred: u64,
    pub status: TransferStatusEnum,
    pub error: Option<String>,
    /// 单调递增版本号；任何状态/进度/错误变更时自动递增。
    pub version: u64,
}

/// Internal task record, shared between the registry and the async worker.
#[derive(Clone)]
struct TransferTask {
    id: Uuid,
    direction: TransferDirectionEnum,
    host_id: String,
    local_path: String,
    remote_path: String,
    password: Option<String>,
    passphrase: Option<String>,
    size: u64,
    status: Arc<std::sync::Mutex<TransferStatusEnum>>,
    transferred: Arc<AtomicU64>,
    error: Arc<std::sync::Mutex<Option<String>>>,
    cancel: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    resume_notify: Arc<tokio::sync::Notify>,
    version: Arc<AtomicU64>,
}

impl TransferTask {
    fn snapshot(&self) -> TransferStatusRecord {
        TransferStatusRecord {
            id: self.id.to_string(),
            direction: self.direction.clone(),
            host_id: self.host_id.clone(),
            local_path: self.local_path.clone(),
            remote_path: self.remote_path.clone(),
            size: self.size,
            transferred: self.transferred.load(Ordering::Relaxed),
            status: *self.status.lock().unwrap(),
            error: self.error.lock().unwrap().clone(),
            version: self.version.load(Ordering::Relaxed),
        }
    }

    /// 递增版本号，在状态/进度/错误变更后调用。
    fn bump_version(&self) {
        self.version.fetch_add(1, Ordering::Relaxed);
    }
}

static TRANSFER_TASKS: OnceLock<Mutex<HashMap<Uuid, TransferTask>>> = OnceLock::new();
static TRANSFER_SEMAPHORE: OnceLock<tokio::sync::Semaphore> = OnceLock::new();

fn transfer_tasks() -> &'static Mutex<HashMap<Uuid, TransferTask>> {
    TRANSFER_TASKS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn transfer_semaphore() -> &'static tokio::sync::Semaphore {
    TRANSFER_SEMAPHORE.get_or_init(|| tokio::sync::Semaphore::new(TRANSFER_CONCURRENCY))
}

fn total_size(local: &std::path::Path) -> u64 {
    std::fs::metadata(local).map(|m| m.len()).unwrap_or(0)
}

/// Start an upload or download task and return its id immediately.
/// The task runs on the global tokio runtime; use `transfer_status` / `transfer_list`
/// to poll progress.
#[uniffi::export]
pub fn start_transfer(
    direction: TransferDirectionEnum,
    host_id: String,
    local_path: String,
    remote_path: String,
    size: u64,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<String, PandaError> {
    let cfg = load_host(&host_id)?;
    // 上传时若 Swift 未提供大小(传 0),则从本地文件系统计算;
    // 下载时使用 Swift 从 SFTP 列表中已获取的远端大小。
    let size = match direction {
        TransferDirectionEnum::Upload if size == 0 => total_size(PathBuf::from(&local_path).as_path()),
        _ => size,
    };
    let id = Uuid::new_v4();
    let task = TransferTask {
        id,
        direction,
        host_id,
        local_path,
        remote_path,
        password,
        passphrase,
        size,
        status: Arc::new(std::sync::Mutex::new(TransferStatusEnum::Queued)),
        transferred: Arc::new(AtomicU64::new(0)),
        error: Arc::new(std::sync::Mutex::new(None)),
        cancel: Arc::new(AtomicBool::new(false)),
        paused: Arc::new(AtomicBool::new(false)),
        resume_notify: Arc::new(tokio::sync::Notify::new()),
        version: Arc::new(AtomicU64::new(1)),
    };
    transfer_tasks()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, task.clone());

    runtime().spawn(async move {
        run_transfer_task(task, cfg).await;
    });
    Ok(id.to_string())
}

/// 当任务被暂停时阻塞，直到继续或被取消。
async fn wait_while_paused(task: &TransferTask) {
    loop {
        if task.cancel.load(Ordering::Relaxed) {
            return;
        }
        if !task.paused.load(Ordering::Relaxed) {
            return;
        }
        {
            let mut status = task.status.lock().unwrap();
            if *status == TransferStatusEnum::Cancelled {
                return;
            }
            *status = TransferStatusEnum::Paused;
        }
        // 先注册等待再检查,避免 resume 通知在 await 前丢失。
        let notified = task.resume_notify.notified();
        if !task.paused.load(Ordering::Relaxed) {
            return;
        }
        notified.await;
    }
}

async fn run_transfer_task(task: TransferTask, cfg: panda_core::HostConfig) {
    // 排队阶段若被暂停，则等待恢复后再竞争信号量。
    wait_while_paused(&task).await;
    if task.cancel.load(Ordering::Relaxed) {
        *task.status.lock().unwrap() = TransferStatusEnum::Cancelled;
        return;
    }

    // 先获取信号量许可证,获取成功前保持 Queued 状态,让 UI 正确显示排队中。
    let _permit = match transfer_semaphore().acquire().await {
        Ok(p) => p,
        Err(_) => {
            *task.status.lock().unwrap() = TransferStatusEnum::Failed;
            *task.error.lock().unwrap() = Some("semaphore closed".to_string());
            return;
        }
    };

    // 获取信号量后再次被暂停，则先进入 Paused，等恢复后再 Running。
    wait_while_paused(&task).await;

    {
        let mut status = task.status.lock().unwrap();
        if *status == TransferStatusEnum::Cancelled {
            return;
        }
        *status = TransferStatusEnum::Running;
    }
    task.bump_version();

    let result = match task.direction {
        TransferDirectionEnum::Upload => run_upload(&task, &cfg).await,
        TransferDirectionEnum::Download => run_download(&task, &cfg).await,
    };

    match result {
        Ok(()) => {
            *task.status.lock().unwrap_or_else(|e| e.into_inner()) = TransferStatusEnum::Completed;
            if matches!(task.direction, TransferDirectionEnum::Upload) {
                task.transferred.store(task.size, Ordering::Relaxed);
            }
            task.bump_version();
        }
        Err(e) => {
            if task.cancel.load(Ordering::Relaxed) {
                *task.status.lock().unwrap_or_else(|e| e.into_inner()) = TransferStatusEnum::Cancelled;
            } else {
                *task.status.lock().unwrap_or_else(|e| e.into_inner()) = TransferStatusEnum::Failed;
                *task.error.lock().unwrap_or_else(|e| e.into_inner()) = Some(e.to_string());
            }
            task.bump_version();
        }
    }
}

async fn run_upload(
    task: &TransferTask,
    cfg: &panda_core::HostConfig,
) -> Result<(), panda_core::Error> {
    let creds = credentials_for(cfg, task.password.clone(), task.passphrase.clone())
        .map_err(|e| panda_core::Error::Other(e.to_string()))?;
    let store_path = match stores() {
        Ok(s) => s.known_hosts.path().to_path_buf(),
        Err(e) => return Err(panda_core::Error::Other(e.to_string())),
    };
    let mut known_hosts = KnownHosts::new(store_path);
    let session = panda_core::connection_pool::global_pool()
        .get_or_create(
            task.host_id.clone(),
            cfg,
            creds,
            &mut known_hosts,
            UnknownHostKeyPolicy::AcceptAndStore,
        )
        .await?;
    let sftp = SftpClient::new(&session).await?;

    let local = PathBuf::from(&task.local_path);
    let transferred = task.transferred.clone();
    let version = task.version.clone();
    let progress = Arc::new(move |sent: u64, _total: u64| {
        transferred.store(sent, Ordering::Relaxed);
        version.fetch_add(1, Ordering::Relaxed);
    });
    let result = sftp
        .upload_with_pause(
            local.as_path(),
            &task.remote_path,
            Some(progress),
            Some(task.cancel.clone()),
            Some(task.paused.clone()),
            Some(task.resume_notify.clone()),
        )
        .await;
    let _ = sftp.close().await;
    result
}

async fn run_download(
    task: &TransferTask,
    cfg: &panda_core::HostConfig,
) -> Result<(), panda_core::Error> {
    let creds = credentials_for(cfg, task.password.clone(), task.passphrase.clone())
        .map_err(|e| panda_core::Error::Other(e.to_string()))?;
    let store_path = match stores() {
        Ok(s) => s.known_hosts.path().to_path_buf(),
        Err(e) => return Err(panda_core::Error::Other(e.to_string())),
    };
    let mut known_hosts = KnownHosts::new(store_path);
    let session = panda_core::connection_pool::global_pool()
        .get_or_create(
            task.host_id.clone(),
            cfg,
            creds,
            &mut known_hosts,
            UnknownHostKeyPolicy::AcceptAndStore,
        )
        .await?;
    let sftp = SftpClient::new(&session).await?;

    let local = PathBuf::from(&task.local_path);
    let transferred = task.transferred.clone();
    let version = task.version.clone();
    let progress = Arc::new(move |received: u64, _total: u64| {
        transferred.store(received, Ordering::Relaxed);
        version.fetch_add(1, Ordering::Relaxed);
    });
    let result = sftp
        .download_with_pause(
            &task.remote_path,
            local.as_path(),
            Some(progress),
            Some(task.cancel.clone()),
            Some(task.paused.clone()),
            Some(task.resume_notify.clone()),
        )
        .await;
    let _ = sftp.close().await;
    result
}

/// Get a single task's current status.
#[uniffi::export]
pub fn transfer_status(task_id: String) -> Result<TransferStatusRecord, PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let tasks = transfer_tasks().lock().unwrap();
    let task = tasks.get(&id).ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    Ok(task.snapshot())
}

/// List all tasks ordered by creation time (ids are UUID v4, which are roughly
/// time-ordered; we sort by id string for deterministic output).
#[uniffi::export]
pub fn transfer_list() -> Result<Vec<TransferStatusRecord>, PandaError> {
    let tasks = transfer_tasks().lock().unwrap();
    let mut records: Vec<_> = tasks.values().map(|t| t.snapshot()).collect();
    records.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(records)
}

/// Cancel a queued, paused or running task. Idempotent for already-terminal tasks.
#[uniffi::export]
pub fn transfer_cancel(task_id: String) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let mut tasks = transfer_tasks().lock().unwrap();
    let task = tasks.get_mut(&id).ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    task.cancel.store(true, Ordering::Relaxed);
    task.resume_notify.notify_waiters();
    let status = *task.status.lock().unwrap();
    if matches!(status, TransferStatusEnum::Queued | TransferStatusEnum::Paused) {
        *task.status.lock().unwrap() = TransferStatusEnum::Cancelled;
        task.bump_version();
    }
    Ok(())
}

/// Retry a failed or cancelled task, reusing the same task id.
/// 重置任务状态为 Queued 后重新调度,避免在队列中产生新任务条目。
#[uniffi::export]
pub fn transfer_retry(task_id: String) -> Result<String, PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let task = {
        let tasks = transfer_tasks().lock().unwrap();
        tasks
            .get(&id)
            .ok_or_else(|| PandaError::UnknownTransferTask(task_id.clone()))?
            .clone()
    };

    {
        let status = *task.status.lock().unwrap();
        if !matches!(
            status,
            TransferStatusEnum::Failed | TransferStatusEnum::Cancelled
        ) {
            return Err(PandaError::Core(
                "task is not in a retryable state".to_string(),
            ));
        }
    }

    let cfg = load_host(&task.host_id)?;

    // 重置共享状态,保留原 id、路径与大小。
    *task.status.lock().unwrap() = TransferStatusEnum::Queued;
    task.transferred.store(0, Ordering::Relaxed);
    *task.error.lock().unwrap() = None;
    task.cancel.store(false, Ordering::Relaxed);
    task.paused.store(false, Ordering::Relaxed);
    task.resume_notify.notify_waiters();
    task.bump_version();

    runtime().spawn(async move {
        run_transfer_task(task, cfg).await;
    });
    Ok(id.to_string())
}

/// Pause a queued or running task.
/// 非终态任务可被暂停；已终态或已暂停任务为 no-op。
#[uniffi::export]
pub fn transfer_pause(task_id: String) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let mut tasks = transfer_tasks().lock().unwrap();
    let task = tasks.get_mut(&id).ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    let status = *task.status.lock().unwrap();
    if matches!(
        status,
        TransferStatusEnum::Completed | TransferStatusEnum::Failed | TransferStatusEnum::Cancelled
    ) {
        return Err(PandaError::Core("task is already terminal".to_string()));
    }
    task.paused.store(true, Ordering::Relaxed);
    if matches!(status, TransferStatusEnum::Queued | TransferStatusEnum::Running) {
        *task.status.lock().unwrap() = TransferStatusEnum::Paused;
        task.bump_version();
    }
    Ok(())
}

/// Resume a paused task.
/// 继续后会由工作线程重新竞争信号量或恢复 Running；非暂停任务为 no-op。
#[uniffi::export]
pub fn transfer_resume(task_id: String) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let mut tasks = transfer_tasks().lock().unwrap();
    let task = tasks.get_mut(&id).ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    task.paused.store(false, Ordering::Relaxed);
    let status = *task.status.lock().unwrap();
    if status == TransferStatusEnum::Paused {
        *task.status.lock().unwrap() = TransferStatusEnum::Queued;
        task.bump_version();
    }
    task.resume_notify.notify_waiters();
    Ok(())
}

// ---------------------------------------------------------------------------
// Snippet API
// ---------------------------------------------------------------------------

/// Mirror of `panda_core::Snippet` for FFI.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SnippetRecord {
    pub name: String,
    pub title: String,
    pub tags: Vec<String>,
    pub body: String,
}

impl From<panda_core::Snippet> for SnippetRecord {
    fn from(s: panda_core::Snippet) -> Self {
        SnippetRecord {
            name: s.name,
            title: s.title,
            tags: s.tags,
            body: s.body,
        }
    }
}

impl From<SnippetRecord> for panda_core::Snippet {
    fn from(r: SnippetRecord) -> Self {
        panda_core::Snippet {
            name: r.name,
            title: r.title,
            tags: r.tags,
            body: r.body,
        }
    }
}

static SNIPPET_STORE: Mutex<Option<panda_core::SnippetStore>> = Mutex::new(None);

fn snippet_store() -> Result<panda_core::SnippetStore, PandaError> {
    SNIPPET_STORE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .ok_or(PandaError::NotInitialized)
}

/// Initialize the snippet store at `dir`. Subsequent calls switch to the new
/// directory (old references become invalid, as designed).
#[uniffi::export]
pub fn init_snippets(dir: String) -> Result<(), PandaError> {
    let path = PathBuf::from(dir);
    std::fs::create_dir_all(&path)?;
    *SNIPPET_STORE.lock().unwrap_or_else(|e| e.into_inner()) = Some(panda_core::SnippetStore::new(path));
    Ok(())
}

#[uniffi::export]
pub fn list_snippets() -> Result<Vec<SnippetRecord>, PandaError> {
    Ok(snippet_store()?
        .list()?
        .into_iter()
        .map(SnippetRecord::from)
        .collect())
}

#[uniffi::export]
pub fn save_snippet(snippet: SnippetRecord) -> Result<(), PandaError> {
    Ok(snippet_store()?.save(&snippet.into())?)
}

#[uniffi::export]
pub fn delete_snippet(name: String) -> Result<(), PandaError> {
    Ok(snippet_store()?.delete(&name)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_missing_private_key_passphrase_to_structured_ffi_error() {
        let error = PandaError::from(panda_core::Error::MissingPassphrase);
        assert!(matches!(error, PandaError::MissingPassphrase(_)));
    }

    #[test]
    fn missing_password_stays_distinct_from_authentication_failure() {
        let cfg = HostConfig {
            id: "id".into(),
            name: "host".into(),
            host: "example.com".into(),
            port: 22,
            username: "user".into(),
            auth: AuthMethod::Password { password_ref: None },
            notes: None,
            group_id: None,
        };
        assert!(matches!(credentials_for(&cfg, None, None), Err(PandaError::MissingPassword(_))));
        assert!(matches!(PandaError::from(panda_core::Error::AuthFailed), PandaError::AuthFailed));
    }
}

//! UniFFI bindings exposing panda-core to Swift.
//!
//! All exported functions are synchronous from the caller's perspective;
//! async work runs on a lazily created global tokio runtime.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use panda_core::{
    AuthMethod, ConfigStore, CredentialStore, Credentials, Group, GroupStore, HostConfig,
    KnownHosts, SftpClient, ShellSession, SshSession, TomlConfigStore, TomlGroupStore,
    TransferSpeedTracker, UnknownHostKeyPolicy,
};
use tokio::runtime::Runtime;
use tokio::sync::Mutex as AsyncMutex;
use uuid::Uuid;

uniffi::setup_scaffolding!();

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

mod batch_transfer;
pub use batch_transfer::{
    batch_transfer_cancel, batch_transfer_list, batch_transfer_resolve_conflict,
    batch_transfer_status, scan_local_batch, scan_remote_batch, start_batch_download,
    start_batch_upload, BatchConflictRecord, BatchItemRecord, BatchTransferDirectionEnum,
    BatchTransferStatusEnum, BatchTransferStatusRecord,
};

mod task_aggregation;
pub use task_aggregation::{
    aggregate_task_groups_ffi, AggregationResultRecord, TaskGroupRecord, TaskItemRecord,
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
    #[error("shell session closed")]
    ShellSessionClosed,
    #[error("shell input is temporarily backpressured")]
    ShellInputBackpressure,
    #[error("shell exited with status {0}")]
    ShellExitStatus(u32),
    #[error("unknown SFTP session handle {0}")]
    UnknownSftpHandle(u64),
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
    #[error("unknown connection {0}")]
    UnknownConnection(u64),
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
            panda_core::Error::ShellSessionClosed => PandaError::ShellSessionClosed,
            panda_core::Error::ShellInputBackpressure => PandaError::ShellInputBackpressure,
            panda_core::Error::ShellExitStatus(status) => PandaError::ShellExitStatus(status),
            panda_core::Error::CredentialProtectionKeyRequired => {
                PandaError::CredentialProtectionKeyRequired
            }
            panda_core::Error::CredentialUnlockFailed => PandaError::CredentialUnlockFailed,
            panda_core::Error::InvalidCredentialFile => PandaError::InvalidCredentialFile,
            panda_core::Error::UnknownConnection(id) => PandaError::UnknownConnection(id),
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
    Password {
        password_ref: Option<String>,
    },
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

/// 持久 SFTP 标签会话的稳定句柄与初始目录。
#[derive(Debug, Clone, uniffi::Record)]
pub struct SftpSessionRecord {
    pub handle: u64,
    pub connection_id: u64,
    pub home_dir: String,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionStateEnum {
    Connecting,
    Active,
    Idle,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SshConnectionStateEnum {
    Connecting,
    Authenticated,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HealthStateEnum {
    Unknown,
    Healthy,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChannelStateEnum {
    Open,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChannelKindEnum {
    Shell,
    Sftp,
    Exec,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ChannelTelemetryRecord {
    pub id: u64,
    pub kind: ChannelKindEnum,
    pub state: ChannelStateEnum,
    pub created_at_ms: u64,
    pub last_activity_at_ms: u64,
    pub received_bytes: u64,
    pub sent_bytes: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ConnectionTelemetryRecord {
    pub id: u64,
    pub host_id: String,
    pub address: String,
    pub owner_kind: String,
    pub owner_id: String,
    pub created_at_ms: u64,
    pub last_activity_at_ms: u64,
    pub transport_state: ConnectionStateEnum,
    pub ssh_state: SshConnectionStateEnum,
    pub health_state: HealthStateEnum,
    pub last_health_check_at_ms: Option<u64>,
    pub received_bytes: u64,
    pub sent_bytes: u64,
    pub receive_bytes_per_second: u64,
    pub send_bytes_per_second: u64,
    pub last_error: Option<String>,
    pub channels: Vec<ChannelTelemetryRecord>,
}

impl From<panda_core::telemetry::HealthState> for HealthStateEnum {
    fn from(value: panda_core::telemetry::HealthState) -> Self {
        match value {
            panda_core::telemetry::HealthState::Unknown => Self::Unknown,
            panda_core::telemetry::HealthState::Healthy => Self::Healthy,
            panda_core::telemetry::HealthState::Unavailable => Self::Unavailable,
        }
    }
}

impl From<panda_core::telemetry::ChannelSnapshot> for ChannelTelemetryRecord {
    fn from(value: panda_core::telemetry::ChannelSnapshot) -> Self {
        use panda_core::telemetry::{ChannelKind, ChannelState};
        Self {
            id: value.id,
            kind: match value.kind {
                ChannelKind::Shell => ChannelKindEnum::Shell,
                ChannelKind::Sftp => ChannelKindEnum::Sftp,
                ChannelKind::Exec => ChannelKindEnum::Exec,
            },
            state: match value.state {
                ChannelState::Open => ChannelStateEnum::Open,
                ChannelState::Closed => ChannelStateEnum::Closed,
                ChannelState::Failed => ChannelStateEnum::Failed,
            },
            created_at_ms: value.created_at_ms,
            last_activity_at_ms: value.last_activity_at_ms,
            received_bytes: value.received_bytes,
            sent_bytes: value.sent_bytes,
        }
    }
}

impl From<panda_core::telemetry::ConnectionSnapshot> for ConnectionTelemetryRecord {
    fn from(value: panda_core::telemetry::ConnectionSnapshot) -> Self {
        use panda_core::telemetry::{SshState, TransportState};
        Self {
            id: value.id,
            host_id: value.host_id,
            address: value.address,
            owner_kind: value.owner_kind,
            owner_id: value.owner_id,
            created_at_ms: value.created_at_ms,
            last_activity_at_ms: value.last_activity_at_ms,
            transport_state: match value.transport_state {
                TransportState::Connecting => ConnectionStateEnum::Connecting,
                TransportState::Active => ConnectionStateEnum::Active,
                TransportState::Idle => ConnectionStateEnum::Idle,
                TransportState::Closed => ConnectionStateEnum::Closed,
                TransportState::Failed => ConnectionStateEnum::Failed,
            },
            ssh_state: match value.ssh_state {
                SshState::Connecting => SshConnectionStateEnum::Connecting,
                SshState::Authenticated => SshConnectionStateEnum::Authenticated,
                SshState::Closed => SshConnectionStateEnum::Closed,
                SshState::Failed => SshConnectionStateEnum::Failed,
            },
            health_state: value.health_state.into(),
            last_health_check_at_ms: value.last_health_check_at_ms,
            received_bytes: value.received_bytes,
            sent_bytes: value.sent_bytes,
            receive_bytes_per_second: value.receive_bytes_per_second,
            send_bytes_per_second: value.send_bytes_per_second,
            last_error: value.last_error,
            channels: value
                .channels
                .into_iter()
                .map(ChannelTelemetryRecord::from)
                .collect(),
        }
    }
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
    Known {
        fingerprint: String,
        key_type: String,
    },
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
    STORES
        .lock()
        .unwrap()
        .clone()
        .ok_or(PandaError::NotInitialized)
}

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
// Store API
// ---------------------------------------------------------------------------

/// Initialize the config store and known_hosts under `config_dir`
/// (the app passes its App Group container path). 允许重新初始化,
/// 使 panda-ffi 的集成测试可以在同进程中切换临时目录;App 仍只调用一次。
#[uniffi::export]
pub fn init_store(config_dir: String) -> Result<(), PandaError> {
    let dir = PathBuf::from(config_dir);
    std::fs::create_dir_all(&dir)?;
    *STORES.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Arc::new(Stores {
        config: TomlConfigStore::new(dir.join("hosts.toml")),
        groups: TomlGroupStore::new(dir.join("groups.toml")),
        known_hosts: KnownHosts::new(dir.join("known_hosts")),
        credentials: CredentialStore::new(dir.join("credentials.toml")),
    }));
    panda_core::logger::configure_global_file_path(dir.join("logs").join("panda-ssh.log"))?;
    Ok(())
}

#[uniffi::export]
pub fn list_hosts() -> Result<Vec<HostConfigRecord>, PandaError> {
    let hosts = stores()?.config.list()?;
    Ok(hosts.into_iter().map(HostConfigRecord::from).collect())
}

/// 按关键字模糊搜索主机。匹配字段：名称、地址、用户名、分组路径。空查询返回全部。
#[uniffi::export]
pub fn search_hosts(query: String) -> Result<Vec<HostConfigRecord>, PandaError> {
    let s = stores()?;
    let hosts = s.config.list()?;
    let groups = s.groups.list()?;
    Ok(panda_core::search_hosts(&hosts, &groups, &query)
        .into_iter()
        .map(HostConfigRecord::from)
        .collect())
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

fn restore_credential(
    store: &CredentialStore,
    reference: &str,
    secret: Option<String>,
) -> Result<(), panda_core::Error> {
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
pub fn set_credential_protection_key(
    current_key: Option<String>,
    new_key: Option<String>,
) -> Result<(), PandaError> {
    Ok(stores()?
        .credentials
        .set_protection_key(current_key, new_key)?)
}

#[uniffi::export]
pub fn credential_protection_enabled() -> Result<bool, PandaError> {
    Ok(stores()?.credentials.is_protected()?)
}

/// 凭据解析结果（FFI 友好枚举）。
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ResolvedCredentialEnum {
    /// 凭据就绪，可直接连接。
    Available {
        password: Option<String>,
        passphrase: Option<String>,
    },
    /// 需要用户输入密码。
    NeedsPassword,
    /// 需要用户输入私钥口令。
    NeedsPassphrase,
}

/// 解析主机凭据状态：已保存 → Available；未保存 → NeedsPassword/NeedsPassphrase。
#[uniffi::export]
pub fn credential_resolve(host_id: String) -> Result<ResolvedCredentialEnum, PandaError> {
    let s = stores()?;
    let host = s.config.get(&host_id)?
        .ok_or_else(|| PandaError::Core(format!("host not found: {host_id}")))?;
    match panda_core::credential_resolve(&s.credentials, &host)? {
        panda_core::ResolvedCredential::Available { password, passphrase } => {
            Ok(ResolvedCredentialEnum::Available { password, passphrase })
        }
        panda_core::ResolvedCredential::NeedsPassword => Ok(ResolvedCredentialEnum::NeedsPassword),
        panda_core::ResolvedCredential::NeedsPassphrase => Ok(ResolvedCredentialEnum::NeedsPassphrase),
    }
}

/// 连接失败分类（FFI 友好枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FailureCategoryEnum {
    Timeout,
    AuthFailed,
    MissingCredential,
    HostKeyMismatch,
    Other,
}

/// 连接失败的结构化记录（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ConnectionFailureFFIRecord {
    pub category: FailureCategoryEnum,
    pub title: String,
    pub detail: String,
}

/// 将错误码分类为连接失败记录。
#[uniffi::export]
pub fn connection_failure_classify(error_code: String) -> ConnectionFailureFFIRecord {
    let error = match error_code.as_str() {
        "Timeout" => panda_core::Error::Timeout,
        "AuthFailed" => panda_core::Error::AuthFailed,
        "MissingPassphrase" => panda_core::Error::MissingPassphrase,
        "CredentialProtectionKeyRequired" => panda_core::Error::CredentialProtectionKeyRequired,
        "CredentialUnlockFailed" => panda_core::Error::CredentialUnlockFailed,
        "InvalidCredentialFile" => panda_core::Error::InvalidCredentialFile,
        "Cancelled" => panda_core::Error::Cancelled,
        "ShellSessionClosed" => panda_core::Error::ShellSessionClosed,
        other => panda_core::Error::Other(other.to_string()),
    };
    let record = panda_core::connection_failure_classify(&error);
    let category = match record.category {
        panda_core::FailureCategory::Timeout => FailureCategoryEnum::Timeout,
        panda_core::FailureCategory::AuthFailed => FailureCategoryEnum::AuthFailed,
        panda_core::FailureCategory::MissingCredential => FailureCategoryEnum::MissingCredential,
        panda_core::FailureCategory::HostKeyMismatch => FailureCategoryEnum::HostKeyMismatch,
        panda_core::FailureCategory::Other => FailureCategoryEnum::Other,
    };
    ConnectionFailureFFIRecord {
        category,
        title: record.title,
        detail: record.detail,
    }
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
// Preconnect API
// ---------------------------------------------------------------------------

/// 连接前评估结果（FFI 友好枚举）。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PreconnectActionEnum {
    /// 密钥已知且凭据就绪，可直接连接。
    Proceed,
    /// 未知主机，需用户确认密钥指纹（TOFU）。
    ConfirmTofu,
    /// 密钥与已知记录不匹配，应阻断连接并展示告警。
    KeyMismatch {
        stored_fingerprint: String,
        presented_fingerprint: String,
    },
    /// 需要用户输入密码。
    AskPassword,
    /// 需要用户输入私钥口令。
    AskPassphrase,
}

/// 连接前评估：综合主机密钥状态和凭据可用性，返回前端应执行的动作。
///
/// 评估顺序：先检查主机密钥状态，再检查凭据可用性。
#[uniffi::export]
pub fn preconnect_evaluate(host_id: String) -> Result<PreconnectActionEnum, PandaError> {
    let s = stores()?;
    let host = s.config.get(&host_id)?
        .ok_or_else(|| PandaError::Core(format!("host not found: {host_id}")))?;

    // 检查主机密钥状态
    let key_status = s.known_hosts.status(&host.host, host.port)?;

    // 检查凭据状态
    let cred_status = panda_core::credential_resolve(&s.credentials, &host)?;

    // 综合评估
    let action = panda_core::preconnect_evaluate(&host, &key_status, &cred_status);
    Ok(match action {
        panda_core::PreconnectAction::Proceed => PreconnectActionEnum::Proceed,
        panda_core::PreconnectAction::ConfirmTofu => PreconnectActionEnum::ConfirmTofu,
        panda_core::PreconnectAction::KeyMismatch {
            stored_fingerprint,
            presented_fingerprint,
        } => PreconnectActionEnum::KeyMismatch {
            stored_fingerprint,
            presented_fingerprint,
        },
        panda_core::PreconnectAction::AskPassword => PreconnectActionEnum::AskPassword,
        panda_core::PreconnectAction::AskPassphrase => PreconnectActionEnum::AskPassphrase,
    })
}

/// TOFU 并发序列化：注册等待者。
///
/// 返回 `true` 表示调用者是第一个请求，应执行探测并展示确认框。
/// 返回 `false` 表示已有探测在进行中，调用者应等待结果（通过轮询或回调）。
///
/// 该方法管理内部状态：第一个调用者标记为"探测中"，后续调用者只注册等待。
#[uniffi::export]
pub fn preconnect_tofu_register_waiter(host_id: String) -> bool {
    let mut state = workspace_state().lock().unwrap();
    if state.tofu_probing.contains(&host_id) {
        // 已有探测在进行中，调用者应等待
        false
    } else {
        // 第一个调用者，标记为探测中
        state.tofu_probing.insert(host_id);
        true
    }
}

/// TOFU 并发序列化：广播确认结果给所有等待者，并清理状态。
///
/// `trusted` 为 `true` 表示用户信任了该主机密钥，`false` 表示取消。
#[uniffi::export]
pub fn preconnect_tofu_resolve(host_id: String, trusted: bool) {
    let mut state = workspace_state().lock().unwrap();
    // 广播结果给所有等待者
    if let Some(waiters) = state.tofu_waiters.remove(&host_id) {
        for sender in waiters {
            let _ = sender.send(trusted);
        }
    }
    // 清理探测状态
    state.tofu_probing.remove(&host_id);
}

/// TOFU 并发序列化：重置所有状态（仅用于测试）。
#[uniffi::export]
pub fn preconnect_tofu_reset() {
    let mut state = workspace_state().lock().unwrap();
    state.tofu_waiters.clear();
    state.tofu_probing.clear();
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
    Ok(panda_core::delete_group_cascade(
        &stores.groups,
        &stores.config,
        &id,
    )?)
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

/// 返回分组的完整层级路径，如 "生产 / 华东 / 上海"。未知或空 id 返回 "根级"。
#[uniffi::export]
pub fn group_path(group_id: String) -> Result<String, PandaError> {
    let groups = stores()?.groups.list()?;
    Ok(panda_core::group_path(&groups, &group_id))
}

/// 侧栏树节点（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct SidebarNodeFFIRecord {
    pub id: String,
    pub is_group: bool,
    pub name: String,
    pub host: Option<HostConfigRecord>,
    pub group: Option<GroupRecord>,
    pub children: Option<Vec<SidebarNodeFFIRecord>>,
}

fn convert_sidebar_node(node: panda_core::SidebarNodeRecord) -> SidebarNodeFFIRecord {
    SidebarNodeFFIRecord {
        id: node.id,
        is_group: node.is_group,
        name: node.name,
        host: node.host.map(HostConfigRecord::from),
        group: node.group.map(GroupRecord::from),
        children: node.children.map(|cs| cs.into_iter().map(convert_sidebar_node).collect()),
    }
}

/// 返回已组装好的侧栏树。根级分组在前、根级主机在后；分组内先子分组后主机。
#[uniffi::export]
pub fn sidebar_tree() -> Result<Vec<SidebarNodeFFIRecord>, PandaError> {
    let s = stores()?;
    let hosts = s.config.list()?;
    let groups = s.groups.list()?;
    Ok(panda_core::sidebar_tree(&hosts, &groups)
        .into_iter()
        .map(convert_sidebar_node)
        .collect())
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

/// 返回当前进程内的连接监控快照；该查询不会建立网络连接。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ConnectionLifecycleRecord {
    pub connection_id: u64,
    pub address: String,
    pub owner_kind: String,
    pub owner_id: String,
    pub reason: String,
    pub is_error: bool,
}

impl From<panda_core::telemetry::LifecycleEvent> for ConnectionLifecycleRecord {
    fn from(event: panda_core::telemetry::LifecycleEvent) -> Self {
        Self {
            connection_id: event.connection_id,
            address: event.address,
            owner_kind: event.owner_kind,
            owner_id: event.owner_id,
            reason: event.kind.description().into(),
            is_error: event.kind.is_error(),
        }
    }
}

/// 由应用级日志桥接器消费；监控窗口不消费队列，避免窗口关闭丢失断线日志。
#[uniffi::export]
pub fn connection_lifecycle_drain() -> Vec<ConnectionLifecycleRecord> {
    panda_core::telemetry::global_registry()
        .drain_events()
        .into_iter()
        .map(Into::into)
        .collect()
}

#[uniffi::export]
pub fn connection_telemetry_list() -> Vec<ConnectionTelemetryRecord> {
    panda_core::connection_registry::global_registry().prune();
    panda_core::telemetry::global_registry()
        .snapshot()
        .into_iter()
        .map(ConnectionTelemetryRecord::from)
        .collect()
}

/// 对既有连接执行无命令的 SSH 通道探测；不会建立新连接或读取凭据。
#[uniffi::export]
pub fn connection_health_check(connection_id: u64) -> Result<HealthStateEnum, PandaError> {
    runtime().block_on(async {
        Ok(panda_core::connection_registry::global_registry()
            .check_health(connection_id)
            .await?
            .into())
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
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
    /// 实时传输速率（字节/秒），基于 2 秒滑动窗口。
    pub speed: f64,
    /// 从开始到现在的平均速率（字节/秒）。
    pub total_speed: f64,
    /// 预估剩余秒数；无法计算时为 None。
    pub eta_seconds: Option<f64>,
    /// 所属任务组 id；None 表示不属于任何组。
    pub group_id: Option<String>,
    /// 所属任务组名称。
    pub group_name: Option<String>,
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
    speed_tracker: Arc<Mutex<TransferSpeedTracker>>,
    group_id: Option<String>,
    group_name: Option<String>,
}

impl TransferTask {
    fn snapshot(&self) -> TransferStatusRecord {
        let tracker = self.speed_tracker.lock().unwrap();
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
            speed: tracker.live_speed(),
            total_speed: tracker.total_speed(),
            eta_seconds: tracker.eta_seconds(),
            group_id: self.group_id.clone(),
            group_name: self.group_name.clone(),
        }
    }

    /// 上传与下载共用进度通知，保证仅字节变化时也刷新 UI。
    fn progress_callback(&self) -> Arc<dyn Fn(u64, u64) + Send + Sync> {
        let task = self.clone();
        Arc::new(move |done, _total| {
            task.transferred.store(done, Ordering::Relaxed);
            task.speed_tracker.lock().unwrap().update(done);
            task.bump_version();
            notify_transfer_changed();
        })
    }

    /// 递增版本号，在状态/进度/错误变更后调用。
    fn bump_version(&self) {
        self.version.fetch_add(1, Ordering::Relaxed);
    }
}

static TRANSFER_TASKS: OnceLock<Mutex<HashMap<Uuid, TransferTask>>> = OnceLock::new();
static TRANSFER_SEMAPHORE: OnceLock<tokio::sync::Semaphore> = OnceLock::new();
/// 全局传输变更计数器；每次任务状态转换时递增。
/// Swift 侧可低频轮询此值，仅在变化时调用 `transfer_list()` 获取完整快照。
static TRANSFER_CHANGE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn transfer_tasks() -> &'static Mutex<HashMap<Uuid, TransferTask>> {
    TRANSFER_TASKS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn transfer_semaphore() -> &'static tokio::sync::Semaphore {
    TRANSFER_SEMAPHORE.get_or_init(|| tokio::sync::Semaphore::new(TRANSFER_CONCURRENCY))
}

/// 状态变更时调用：递增全局变更计数器。
fn notify_transfer_changed() {
    TRANSFER_CHANGE_COUNTER.fetch_add(1, Ordering::Relaxed);
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
    group_id: Option<String>,
    group_name: Option<String>,
) -> Result<String, PandaError> {
    let cfg = load_host(&host_id)?;
    // 上传时若 Swift 未提供大小(传 0),则从本地文件系统计算;
    // 下载时使用 Swift 从 SFTP 列表中已获取的远端大小。
    let size = match direction {
        TransferDirectionEnum::Upload if size == 0 => {
            total_size(PathBuf::from(&local_path).as_path())
        }
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
        speed_tracker: Arc::new(Mutex::new(TransferSpeedTracker::new(size))),
        group_id,
        group_name,
    };
    transfer_tasks()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, task.clone());
    notify_transfer_changed();

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
            drop(status);
            notify_transfer_changed();
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
        notify_transfer_changed();
        return;
    }

    // 先获取信号量许可证,获取成功前保持 Queued 状态,让 UI 正确显示排队中。
    let _permit = match transfer_semaphore().acquire().await {
        Ok(p) => p,
        Err(_) => {
            *task.status.lock().unwrap() = TransferStatusEnum::Failed;
            *task.error.lock().unwrap() = Some("semaphore closed".to_string());
            notify_transfer_changed();
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
    notify_transfer_changed();

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
            notify_transfer_changed();
        }
        Err(e) => {
            if task.cancel.load(Ordering::Relaxed) {
                *task.status.lock().unwrap_or_else(|e| e.into_inner()) =
                    TransferStatusEnum::Cancelled;
            } else {
                *task.status.lock().unwrap_or_else(|e| e.into_inner()) = TransferStatusEnum::Failed;
                *task.error.lock().unwrap_or_else(|e| e.into_inner()) = Some(e.to_string());
            }
            task.bump_version();
            notify_transfer_changed();
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
    let session = SshSession::connect_shared(
        cfg,
        creds,
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await?;
    session.set_owner("上传任务", task.id.to_string());
    let sftp = SftpClient::new(&session).await?;

    let local = PathBuf::from(&task.local_path);
    let progress = task.progress_callback();
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
    let session = SshSession::connect_shared(
        cfg,
        creds,
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await?;
    session.set_owner("下载任务", task.id.to_string());
    let sftp = SftpClient::new(&session).await?;

    let local = PathBuf::from(&task.local_path);
    let progress = task.progress_callback();
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
    let task = tasks
        .get(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
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

/// 聚合状态优先级：running > paused > queued > failed > cancelled > completed。
fn group_status_priority(statuses: &[TransferStatusEnum]) -> TransferStatusEnum {
    let set: std::collections::HashSet<_> = statuses.iter().copied().collect();
    if set.contains(&TransferStatusEnum::Running) {
        TransferStatusEnum::Running
    } else if set.contains(&TransferStatusEnum::Paused) {
        TransferStatusEnum::Paused
    } else if set.contains(&TransferStatusEnum::Queued) {
        TransferStatusEnum::Queued
    } else if set.contains(&TransferStatusEnum::Failed) {
        TransferStatusEnum::Failed
    } else if set.contains(&TransferStatusEnum::Cancelled) {
        TransferStatusEnum::Cancelled
    } else {
        TransferStatusEnum::Completed
    }
}

/// 任务组聚合记录。
#[derive(Debug, Clone, uniffi::Record)]
pub struct TransferGroupRecord {
    pub group_id: String,
    pub group_name: String,
    pub direction: TransferDirectionEnum,
    pub total_count: u32,
    pub completed_count: u32,
    pub total_bytes: u64,
    pub transferred_bytes: u64,
    pub status: TransferStatusEnum,
}

/// 返回按 group_id 聚合的任务组列表。无分组任务不出现在结果中。
#[uniffi::export]
pub fn transfer_groups() -> Result<Vec<TransferGroupRecord>, PandaError> {
    let tasks = transfer_tasks().lock().unwrap();
    let mut groups: std::collections::HashMap<
        String,
        (String, TransferDirectionEnum, Vec<TransferStatusEnum>, u64, u64, u32),
    > = std::collections::HashMap::new();

    for task in tasks.values() {
        if let (Some(gid), Some(gname)) = (&task.group_id, &task.group_name) {
            let entry = groups.entry(gid.clone()).or_insert_with(|| {
                (gname.clone(), task.direction, Vec::new(), 0, 0, 0)
            });
            let status = *task.status.lock().unwrap();
            entry.2.push(status);
            entry.3 += task.size;
            entry.4 += task.transferred.load(Ordering::Relaxed);
            entry.5 += 1;
            if matches!(
                status,
                TransferStatusEnum::Completed
                    | TransferStatusEnum::Failed
                    | TransferStatusEnum::Cancelled
            ) {
                // completed_count 在下方计算
            }
        }
    }

    let mut result: Vec<TransferGroupRecord> = groups
        .into_iter()
        .map(|(gid, (gname, dir, statuses, total_bytes, transferred_bytes, total_count))| {
            let completed_count = statuses
                .iter()
                .filter(|s| {
                    matches!(
                        s,
                        TransferStatusEnum::Completed
                            | TransferStatusEnum::Failed
                            | TransferStatusEnum::Cancelled
                    )
                })
                .count() as u32;
            TransferGroupRecord {
                group_id: gid,
                group_name: gname,
                direction: dir,
                total_count,
                completed_count,
                total_bytes,
                transferred_bytes,
                status: group_status_priority(&statuses),
            }
        })
        .collect();
    result.sort_by(|a, b| a.group_name.cmp(&b.group_name));
    Ok(result)
}

/// Cancel a queued, paused or running task. Idempotent for already-terminal tasks.
#[uniffi::export]
pub fn transfer_cancel(task_id: String) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let mut tasks = transfer_tasks().lock().unwrap();
    let task = tasks
        .get_mut(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    task.cancel.store(true, Ordering::Relaxed);
    task.resume_notify.notify_waiters();
    let status = *task.status.lock().unwrap();
    if matches!(
        status,
        TransferStatusEnum::Queued | TransferStatusEnum::Paused
    ) {
        *task.status.lock().unwrap() = TransferStatusEnum::Cancelled;
        task.bump_version();
        notify_transfer_changed();
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
    *task.speed_tracker.lock().unwrap() = TransferSpeedTracker::new(task.size);
    task.resume_notify.notify_waiters();
    task.bump_version();
    notify_transfer_changed();

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
    let task = tasks
        .get_mut(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    let status = *task.status.lock().unwrap();
    if matches!(
        status,
        TransferStatusEnum::Completed | TransferStatusEnum::Failed | TransferStatusEnum::Cancelled
    ) {
        return Err(PandaError::Core("task is already terminal".to_string()));
    }
    task.paused.store(true, Ordering::Relaxed);
    task.speed_tracker.lock().unwrap().on_pause();
    if matches!(
        status,
        TransferStatusEnum::Queued | TransferStatusEnum::Running
    ) {
        *task.status.lock().unwrap() = TransferStatusEnum::Paused;
        task.bump_version();
        notify_transfer_changed();
    }
    Ok(())
}

/// Resume a paused task.
/// 继续后会由工作线程重新竞争信号量或恢复 Running；非暂停任务为 no-op。
#[uniffi::export]
pub fn transfer_resume(task_id: String) -> Result<(), PandaError> {
    let id = Uuid::parse_str(&task_id).map_err(|e| PandaError::Core(e.to_string()))?;
    let mut tasks = transfer_tasks().lock().unwrap();
    let task = tasks
        .get_mut(&id)
        .ok_or_else(|| PandaError::UnknownTransferTask(task_id))?;
    task.paused.store(false, Ordering::Relaxed);
    task.speed_tracker.lock().unwrap().on_resume();
    let status = *task.status.lock().unwrap();
    if status == TransferStatusEnum::Paused {
        *task.status.lock().unwrap() = TransferStatusEnum::Queued;
        task.bump_version();
        notify_transfer_changed();
    }
    task.resume_notify.notify_waiters();
    Ok(())
}

/// 返回全局传输变更计数器。
/// Swift 侧低频轮询此值（如每 100ms），仅在返回值变化时调用 `transfer_list()` 获取完整快照，
/// 替代原先基于 Combine Timer 的无差别轮询。
#[uniffi::export]
pub fn transfer_change_counter() -> u64 {
    TRANSFER_CHANGE_COUNTER.load(Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// Config Archive API
// ---------------------------------------------------------------------------

/// 配置导出结果。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ExportManifestRecord {
    pub version: u32,
    pub timestamp: String,
    pub device_name: String,
    pub file_count: u32,
}

/// 配置导入结果。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ImportResultRecord {
    pub backup_files: Vec<String>,
    pub host_count: u32,
    pub group_count: u32,
    pub snippet_count: u32,
}

/// 将配置目录导出为 ZIP 归档。
#[uniffi::export]
pub fn config_export(output_path: String) -> Result<ExportManifestRecord, PandaError> {
    let config_dir = config_dir()?;
    let manifest = panda_core::config_archive::config_export(
        &config_dir,
        PathBuf::from(&output_path).as_path(),
    )
    .map_err(|e| PandaError::Core(e.to_string()))?;
    Ok(ExportManifestRecord {
        version: manifest.version,
        timestamp: manifest.timestamp,
        device_name: manifest.device_name,
        file_count: manifest.file_count,
    })
}

/// 从 ZIP 归档导入配置到配置目录。
#[uniffi::export]
pub fn config_import(archive_path: String) -> Result<ImportResultRecord, PandaError> {
    let config_dir = config_dir()?;
    let result = panda_core::config_archive::config_import(
        &config_dir,
        PathBuf::from(&archive_path).as_path(),
    )
    .map_err(|e| PandaError::Core(e.to_string()))?;
    Ok(ImportResultRecord {
        backup_files: result.backup_files,
        host_count: result.host_count,
        group_count: result.group_count,
        snippet_count: result.snippet_count,
    })
}

fn config_dir() -> Result<PathBuf, PandaError> {
    let s = stores()?;
    // stores 的 config 路径在 config_dir/hosts.toml，取父目录即为 config_dir
    Ok(s.config
        .path()
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."))
        .to_path_buf())
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
    *SNIPPET_STORE.lock().unwrap_or_else(|e| e.into_inner()) =
        Some(panda_core::SnippetStore::new(path));
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

// ---------------------------------------------------------------------------
// Logger API
// ---------------------------------------------------------------------------

/// 日志级别（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LogLevelEnum {
    Debug,
    Info,
    Warning,
    Error,
}

/// 日志条目（FFI 记录）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct LogEntryRecord {
    pub id: u64,
    pub timestamp: String,
    pub level: LogLevelEnum,
    pub module: String,
    pub message: String,
}

/// 写入一条日志。
#[uniffi::export]
pub fn log_write(level: LogLevelEnum, module: String, message: String) {
    let core_level = match level {
        LogLevelEnum::Debug => panda_core::logger::LogLevel::Debug,
        LogLevelEnum::Info => panda_core::logger::LogLevel::Info,
        LogLevelEnum::Warning => panda_core::logger::LogLevel::Warning,
        LogLevelEnum::Error => panda_core::logger::LogLevel::Error,
    };
    panda_core::logger::global_logger().log(core_level, &module, &message);
}

/// 获取最近的日志条目（按时间倒序）。
#[uniffi::export]
pub fn log_entries(limit: u32) -> Vec<LogEntryRecord> {
    panda_core::logger::global_logger()
        .entries(limit as usize)
        .into_iter()
        .map(|e| LogEntryRecord {
            id: e.id,
            timestamp: e.timestamp,
            level: match e.level {
                panda_core::logger::LogLevel::Debug => LogLevelEnum::Debug,
                panda_core::logger::LogLevel::Info => LogLevelEnum::Info,
                panda_core::logger::LogLevel::Warning => LogLevelEnum::Warning,
                panda_core::logger::LogLevel::Error => LogLevelEnum::Error,
            },
            module: e.module,
            message: e.message,
        })
        .collect()
}

/// 清空日志缓冲。
#[uniffi::export]
pub fn log_clear() {
    panda_core::logger::global_logger().clear();
}

// ---------------------------------------------------------------------------
// Workspace API
// ---------------------------------------------------------------------------

/// 标签页类型（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TabKindEnum {
    Terminal,
    Sftp,
}

impl From<TabKindEnum> for panda_core::TabKind {
    fn from(k: TabKindEnum) -> Self {
        match k {
            TabKindEnum::Terminal => panda_core::TabKind::Terminal,
            TabKindEnum::Sftp => panda_core::TabKind::Sftp,
        }
    }
}

impl From<panda_core::TabKind> for TabKindEnum {
    fn from(k: panda_core::TabKind) -> Self {
        match k {
            panda_core::TabKind::Terminal => TabKindEnum::Terminal,
            panda_core::TabKind::Sftp => TabKindEnum::Sftp,
        }
    }
}

/// 连接状态（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionStatusEnum {
    Inactive,
    Connecting,
    Connected,
    Failed,
}

impl From<ConnectionStatusEnum> for panda_core::ConnectionStatus {
    fn from(s: ConnectionStatusEnum) -> Self {
        match s {
            ConnectionStatusEnum::Inactive => panda_core::ConnectionStatus::Inactive,
            ConnectionStatusEnum::Connecting => panda_core::ConnectionStatus::Connecting,
            ConnectionStatusEnum::Connected => panda_core::ConnectionStatus::Connected,
            ConnectionStatusEnum::Failed => panda_core::ConnectionStatus::Failed,
        }
    }
}

impl From<panda_core::ConnectionStatus> for ConnectionStatusEnum {
    fn from(s: panda_core::ConnectionStatus) -> Self {
        match s {
            panda_core::ConnectionStatus::Inactive => ConnectionStatusEnum::Inactive,
            panda_core::ConnectionStatus::Connecting => ConnectionStatusEnum::Connecting,
            panda_core::ConnectionStatus::Connected => ConnectionStatusEnum::Connected,
            panda_core::ConnectionStatus::Failed => ConnectionStatusEnum::Failed,
        }
    }
}

/// 标签页记录（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct WorkspaceTabRecord {
    pub id: String,
    pub host_id: String,
    pub kind: TabKindEnum,
    pub title: String,
    pub connection_status: ConnectionStatusEnum,
}

/// 关闭确认记录（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct CloseConfirmationRecord {
    pub tab_ids: Vec<String>,
    pub connected_terminal_count: u32,
}

/// 终端会话阶段（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalPhaseEnum {
    Connecting,
    Shell,
    Failed,
}

impl From<TerminalPhaseEnum> for panda_core::TerminalPhase {
    fn from(p: TerminalPhaseEnum) -> Self {
        match p {
            TerminalPhaseEnum::Connecting => panda_core::TerminalPhase::Connecting,
            TerminalPhaseEnum::Shell => panda_core::TerminalPhase::Shell,
            TerminalPhaseEnum::Failed => panda_core::TerminalPhase::Failed,
        }
    }
}

impl From<panda_core::TerminalPhase> for TerminalPhaseEnum {
    fn from(p: panda_core::TerminalPhase) -> Self {
        match p {
            panda_core::TerminalPhase::Connecting => TerminalPhaseEnum::Connecting,
            panda_core::TerminalPhase::Shell => TerminalPhaseEnum::Shell,
            panda_core::TerminalPhase::Failed => TerminalPhaseEnum::Failed,
        }
    }
}

/// 终端会话失败分类（FFI 枚举）。
/// 复用已有的 FailureCategoryEnum 映射。
impl From<TerminalFailureCategoryEnum> for panda_core::TerminalFailureCategory {
    fn from(c: TerminalFailureCategoryEnum) -> Self {
        match c {
            TerminalFailureCategoryEnum::Timeout => panda_core::TerminalFailureCategory::Timeout,
            TerminalFailureCategoryEnum::AuthFailed => panda_core::TerminalFailureCategory::AuthFailed,
            TerminalFailureCategoryEnum::MissingCredential => panda_core::TerminalFailureCategory::MissingCredential,
            TerminalFailureCategoryEnum::HostKeyMismatch => panda_core::TerminalFailureCategory::HostKeyMismatch,
            TerminalFailureCategoryEnum::Other => panda_core::TerminalFailureCategory::Other,
        }
    }
}

impl From<panda_core::TerminalFailureCategory> for TerminalFailureCategoryEnum {
    fn from(c: panda_core::TerminalFailureCategory) -> Self {
        match c {
            panda_core::TerminalFailureCategory::Timeout => TerminalFailureCategoryEnum::Timeout,
            panda_core::TerminalFailureCategory::AuthFailed => TerminalFailureCategoryEnum::AuthFailed,
            panda_core::TerminalFailureCategory::MissingCredential => TerminalFailureCategoryEnum::MissingCredential,
            panda_core::TerminalFailureCategory::HostKeyMismatch => TerminalFailureCategoryEnum::HostKeyMismatch,
            panda_core::TerminalFailureCategory::Other => TerminalFailureCategoryEnum::Other,
        }
    }
}

/// 终端会话失败分类（FFI 枚举）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalFailureCategoryEnum {
    Timeout,
    AuthFailed,
    MissingCredential,
    HostKeyMismatch,
    Other,
}

/// 终端会话记录（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct TerminalSessionRecord {
    pub id: String,
    pub host_id: String,
    pub phase: TerminalPhaseEnum,
    pub failure_category: Option<TerminalFailureCategoryEnum>,
    pub failure_message: Option<String>,
    pub attempt: u32,
}

impl From<panda_core::TerminalSessionState> for TerminalSessionRecord {
    fn from(s: panda_core::TerminalSessionState) -> Self {
        TerminalSessionRecord {
            id: s.id,
            host_id: s.host_id,
            phase: s.phase.into(),
            failure_category: s.failure_category.map(|c| c.into()),
            failure_message: s.failure_message,
            attempt: s.attempt,
        }
    }
}

/// 工作区内部标签页状态。
#[derive(Debug, Clone)]
struct InternalTab {
    id: String,
    host_id: String,
    kind: panda_core::TabKind,
    connection_status: panda_core::ConnectionStatus,
    /// 终端标签页是否已连接（用于关闭确认判断）。
    terminal_connected: bool,
}

impl InternalTab {
    fn to_workspace_tab(&self, title: String) -> panda_core::WorkspaceTab {
        panda_core::WorkspaceTab {
            id: self.id.clone(),
            host_id: self.host_id.clone(),
            kind: self.kind,
            title,
            connection_status: self.connection_status,
        }
    }
}

/// 批量关闭待确认。
#[derive(Debug, Clone)]
enum PendingClose {
    /// 单标签关闭确认。
    Single(String),
    /// 批量关闭确认。
    Batch {
        scope: panda_core::workspace::BatchCloseScope,
        connected_terminal_count: u32,
    },
}

/// 工作区全局状态管理器。
struct WorkspaceState {
    tabs: Vec<InternalTab>,
    active_tab_id: Option<String>,
    pending_close: Option<PendingClose>,
    /// 主机名映射表：host_id -> name
    host_names: HashMap<String, String>,
    /// 终端会话状态机：tab_id -> TerminalSessionState
    terminal_sessions: HashMap<String, panda_core::TerminalSessionState>,
    /// TOFU 并发序列化：host_id → 等待该主机确认结果的 oneshot sender 列表。
    tofu_waiters: HashMap<String, Vec<tokio::sync::oneshot::Sender<bool>>>,
    /// TOFU 并发序列化：host_id → 是否已有探测在进行中。
    tofu_probing: HashSet<String>,
}

impl WorkspaceState {
    fn new() -> Self {
        Self {
            tabs: Vec::new(),
            active_tab_id: None,
            pending_close: None,
            host_names: HashMap::new(),
            terminal_sessions: HashMap::new(),
            tofu_waiters: HashMap::new(),
            tofu_probing: HashSet::new(),
        }
    }

    /// 增量更新主机名映射。
    fn update_host_names(&mut self, mappings: Vec<HostNameMapping>) {
        for mapping in mappings {
            self.host_names.insert(mapping.host_id, mapping.name);
        }
    }

    /// 计算当前标签页列表（含消歧标题）。
    fn tab_list(&self) -> Vec<panda_core::WorkspaceTab> {
        let workspace_tabs: Vec<panda_core::WorkspaceTab> = self
            .tabs
            .iter()
            .map(|t| t.to_workspace_tab(String::new()))
            .collect();
        let titles = panda_core::compute_disambiguated_titles(
            &workspace_tabs,
            &|host_id| self.host_names.get(host_id).cloned(),
        );
        self.tabs
            .iter()
            .zip(titles.into_iter())
            .map(|(t, title)| t.to_workspace_tab(title))
            .collect()
    }

    /// 打开新标签页，返回标签页 id。
    fn open_tab(&mut self, host_id: String, kind: panda_core::TabKind) -> String {
        let id = Uuid::new_v4().to_string();
        self.tabs.push(InternalTab {
            id: id.clone(),
            host_id,
            kind,
            connection_status: panda_core::ConnectionStatus::Connecting,
            terminal_connected: false,
        });
        self.active_tab_id = Some(id.clone());
        id
    }

    /// 更新标签页连接状态。
    fn report_connection_status(
        &mut self,
        tab_id: &str,
        status: panda_core::ConnectionStatus,
    ) {
        if let Some(tab) = self.tabs.iter_mut().find(|t| t.id == tab_id) {
            tab.connection_status = status;
            if tab.kind == panda_core::TabKind::Terminal {
                match status {
                    panda_core::ConnectionStatus::Connected => {
                        tab.terminal_connected = true;
                    }
                    panda_core::ConnectionStatus::Failed
                    | panda_core::ConnectionStatus::Inactive => {
                        tab.terminal_connected = false;
                    }
                    _ => {}
                }
            }
        }
    }

    /// 聚合同一主机的连接状态。
    fn host_connection_status(&self, host_id: &str) -> panda_core::ConnectionStatus {
        let statuses: Vec<_> = self
            .tabs
            .iter()
            .filter(|t| t.host_id == host_id)
            .map(|t| t.connection_status)
            .collect();
        panda_core::aggregate_connection_status(&statuses)
    }

    /// 内部关闭标签页（无确认检查）。
    fn close_tab_internal(&mut self, tab_id: &str) {
        if let Some(index) = self.tabs.iter().position(|t| t.id == tab_id) {
            self.tabs.remove(index);
            self.terminal_sessions.remove(tab_id);
            if self.active_tab_id.as_deref() == Some(tab_id) {
                let remaining_ids: Vec<String> = self.tabs.iter().map(|t| t.id.clone()).collect();
                self.active_tab_id =
                    panda_core::next_active_tab_after_close(&remaining_ids, index);
            }
        }
    }

    /// 请求关闭标签页。若为已连接终端标签页，设置待确认；否则直接关闭。
    /// 返回是否需要确认。
    fn request_close(&mut self, tab_id: &str) -> bool {
        let tab = match self.tabs.iter().find(|t| t.id == tab_id) {
            Some(t) => t,
            None => return false,
        };
        if tab.kind == panda_core::TabKind::Terminal && tab.terminal_connected {
            self.pending_close = Some(PendingClose::Single(tab_id.to_string()));
            true
        } else {
            self.close_tab_internal(tab_id);
            false
        }
    }

    /// 确认单标签关闭。
    fn confirm_close(&mut self) {
        if let Some(PendingClose::Single(tab_id)) = self.pending_close.take() {
            self.close_tab_internal(&tab_id);
        }
    }

    /// 取消关闭。
    fn cancel_close(&mut self) {
        self.pending_close = None;
    }

    /// 获取待确认信息。
    fn pending_close_info(&self) -> Option<CloseConfirmationRecord> {
        match &self.pending_close {
            Some(PendingClose::Single(tab_id)) => {
                let tab = self.tabs.iter().find(|t| &t.id == tab_id)?;
                Some(CloseConfirmationRecord {
                    tab_ids: vec![tab_id.clone()],
                    connected_terminal_count: if tab.terminal_connected { 1 } else { 0 },
                })
            }
            Some(PendingClose::Batch {
                scope,
                connected_terminal_count,
            }) => {
                let tab_ids = match scope {
                    panda_core::workspace::BatchCloseScope::Others { keeping } => self
                        .tabs
                        .iter()
                        .filter(|t| &t.id != keeping)
                        .map(|t| t.id.clone())
                        .collect(),
                    panda_core::workspace::BatchCloseScope::All => {
                        self.tabs.iter().map(|t| t.id.clone()).collect()
                    }
                };
                Some(CloseConfirmationRecord {
                    tab_ids,
                    connected_terminal_count: *connected_terminal_count,
                })
            }
            None => None,
        }
    }

    /// 请求关闭其他标签页。
    fn request_close_others(&mut self, keeping: &str) {
        let others: Vec<_> = self
            .tabs
            .iter()
            .filter(|t| t.id != keeping)
            .collect();
        let connected_count = others
            .iter()
            .filter(|t| t.kind == panda_core::TabKind::Terminal && t.terminal_connected)
            .count() as u32;
        if connected_count > 0 {
            self.pending_close = Some(PendingClose::Batch {
                scope: panda_core::workspace::BatchCloseScope::Others {
                    keeping: keeping.to_string(),
                },
                connected_terminal_count: connected_count,
            });
        } else {
            self.close_others_internal(keeping);
        }
    }

    /// 请求关闭全部标签页。
    fn request_close_all(&mut self) {
        let connected_count = self
            .tabs
            .iter()
            .filter(|t| t.kind == panda_core::TabKind::Terminal && t.terminal_connected)
            .count() as u32;
        if connected_count > 0 {
            self.pending_close = Some(PendingClose::Batch {
                scope: panda_core::workspace::BatchCloseScope::All,
                connected_terminal_count: connected_count,
            });
        } else {
            self.close_all_internal();
        }
    }

    /// 确认批量关闭。
    fn confirm_batch_close(&mut self) {
        if let Some(PendingClose::Batch { scope, .. }) = self.pending_close.take() {
            match scope {
                panda_core::workspace::BatchCloseScope::Others { keeping } => {
                    self.close_others_internal(&keeping);
                }
                panda_core::workspace::BatchCloseScope::All => {
                    self.close_all_internal();
                }
            }
        }
    }

    /// 内部关闭其他标签页。
    fn close_others_internal(&mut self, keeping: &str) {
        let to_remove: Vec<String> = self
            .tabs
            .iter()
            .filter(|t| t.id != keeping)
            .map(|t| t.id.clone())
            .collect();
        for id in to_remove {
            self.close_tab_internal(&id);
        }
        if self.tabs.iter().any(|t| t.id == keeping) {
            self.active_tab_id = Some(keeping.to_string());
        }
    }

    /// 内部关闭全部标签页。
    fn close_all_internal(&mut self) {
        let ids: Vec<String> = self.tabs.iter().map(|t| t.id.clone()).collect();
        for id in ids {
            self.close_tab_internal(&id);
        }
    }
}

static WORKSPACE_STATE: OnceLock<Mutex<WorkspaceState>> = OnceLock::new();

fn workspace_state() -> &'static Mutex<WorkspaceState> {
    WORKSPACE_STATE.get_or_init(|| Mutex::new(WorkspaceState::new()))
}

/// 设置主机名查询函数（由 Swift 侧在初始化时调用）。
/// 该函数接受一个闭包，将 host_id 映射为显示名称。
/// 注意：由于 FFI 限制，这里提供一个简化版本：直接传入 host_id -> name 的映射表。
#[uniffi::export]
pub fn workspace_set_host_names(host_names: Vec<HostNameMapping>) {
    let mut state = workspace_state().lock().unwrap();
    state.update_host_names(host_names);
}

/// 主机名映射记录。
#[derive(Debug, Clone, uniffi::Record)]
pub struct HostNameMapping {
    pub host_id: String,
    pub name: String,
}

/// 打开标签页。
#[uniffi::export]
pub fn workspace_open_tab(host_id: String, kind: TabKindEnum) -> WorkspaceTabRecord {
    let mut state = workspace_state().lock().unwrap();
    let tab_id = state.open_tab(host_id, kind.into());
    // 返回刚创建的标签页记录
    let tabs = state.tab_list();
    tabs.into_iter()
        .find(|t| t.id == tab_id)
        .map(|t| WorkspaceTabRecord {
            id: t.id,
            host_id: t.host_id,
            kind: t.kind.into(),
            title: t.title,
            connection_status: t.connection_status.into(),
        })
        .expect("just created tab should exist")
}

/// 关闭标签页（请求式，可能需要确认）。
#[uniffi::export]
pub fn workspace_close_tab(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.request_close(&tab_id);
}

/// 获取标签页列表（含消歧标题）。
#[uniffi::export]
pub fn workspace_tab_list() -> Vec<WorkspaceTabRecord> {
    let state = workspace_state().lock().unwrap();
    state
        .tab_list()
        .into_iter()
        .map(|t| WorkspaceTabRecord {
            id: t.id,
            host_id: t.host_id,
            kind: t.kind.into(),
            title: t.title,
            connection_status: t.connection_status.into(),
        })
        .collect()
}

/// 获取主机连接状态（聚合）。
#[uniffi::export]
pub fn workspace_host_connection_status(host_id: String) -> ConnectionStatusEnum {
    let state = workspace_state().lock().unwrap();
    state.host_connection_status(&host_id).into()
}

/// 更新标签页连接状态（由 Swift 侧在连接状态变化时调用）。
#[uniffi::export]
pub fn workspace_report_connection_status(tab_id: String, status: ConnectionStatusEnum) {
    let mut state = workspace_state().lock().unwrap();
    state.report_connection_status(&tab_id, status.into());
}

/// 关闭其他标签页（保留指定标签页）。
#[uniffi::export]
pub fn workspace_close_other_tabs(keeping_tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.request_close_others(&keeping_tab_id);
}

/// 关闭全部标签页。
#[uniffi::export]
pub fn workspace_close_all_tabs() {
    let mut state = workspace_state().lock().unwrap();
    state.request_close_all();
}

/// 确认关闭。
#[uniffi::export]
pub fn workspace_confirm_close() {
    let mut state = workspace_state().lock().unwrap();
    // 先检查是单标签还是批量
    let is_batch = matches!(&state.pending_close, Some(PendingClose::Batch { .. }));
    if is_batch {
        state.confirm_batch_close();
    } else {
        state.confirm_close();
    }
}

/// 取消关闭。
#[uniffi::export]
pub fn workspace_cancel_close() {
    let mut state = workspace_state().lock().unwrap();
    state.cancel_close();
}

/// 获取待关闭确认信息。
#[uniffi::export]
pub fn workspace_pending_close() -> Option<CloseConfirmationRecord> {
    let state = workspace_state().lock().unwrap();
    state.pending_close_info()
}

/// 选择标签页（设为活动标签）。
#[uniffi::export]
pub fn workspace_select_tab(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    if state.tabs.iter().any(|t| t.id == tab_id) {
        state.active_tab_id = Some(tab_id);
    }
}

/// 获取活动标签页 id。
#[uniffi::export]
pub fn workspace_active_tab_id() -> Option<String> {
    let state = workspace_state().lock().unwrap();
    state.active_tab_id.clone()
}

/// 重置工作区状态（用于测试）。
#[uniffi::export]
pub fn workspace_reset() {
    let mut state = workspace_state().lock().unwrap();
    state.tabs.clear();
    state.active_tab_id = None;
    state.pending_close = None;
    state.terminal_sessions.clear();
}

// ---------------------------------------------------------------------------
// 终端会话状态机 API
// ---------------------------------------------------------------------------

/// 注册/创建终端会话。
///
/// 为指定标签页创建新的终端会话状态，初始阶段为 `Connecting`，代次为 0。
/// 若该标签页已有会话，则覆盖之。
#[uniffi::export]
pub fn terminal_session_register(host_id: String, tab_id: String) -> TerminalSessionRecord {
    let mut state = workspace_state().lock().unwrap();
    let session = panda_core::TerminalSessionState::new(tab_id.clone(), host_id);
    state.terminal_sessions.insert(tab_id, session.clone());
    session.into()
}

/// 获取终端会话当前阶段。
///
/// 若标签页无会话记录，返回 `None`。
#[uniffi::export]
pub fn terminal_session_phase(tab_id: String) -> Option<TerminalPhaseEnum> {
    let state = workspace_state().lock().unwrap();
    state.terminal_sessions.get(&tab_id).map(|s| s.phase.into())
}

/// 状态转换：connecting → shell。
///
/// 握手成功，将会话推进到 shell 阶段。
/// 若当前阶段不是 `Connecting` 或标签页无会话，不做任何操作。
#[uniffi::export]
pub fn terminal_session_transition_to_shell(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    if let Some(session) = state.terminal_sessions.get(&tab_id).cloned() {
        if let Some(new_session) = panda_core::transition_to_shell(&session) {
            state.terminal_sessions.insert(tab_id, new_session);
        }
    }
}

/// 状态转换：任意阶段 → failed。
///
/// 连接失败或异常断开，将会话推进到失败阶段。
/// 若标签页无会话，不做任何操作。
#[uniffi::export]
pub fn terminal_session_transition_to_failed(
    tab_id: String,
    category: TerminalFailureCategoryEnum,
    message: String,
) {
    let mut state = workspace_state().lock().unwrap();
    if let Some(session) = state.terminal_sessions.get(&tab_id).cloned() {
        let new_session = panda_core::transition_to_failed(&session, category.into(), message);
        state.terminal_sessions.insert(tab_id, new_session);
    }
}

/// 重试：failed → connecting，代次递增。
///
/// 返回更新后的会话记录（包含新的代次）。
/// 若当前阶段不是 `Failed` 或标签页无会话，返回 `None`。
#[uniffi::export]
pub fn terminal_session_retry(tab_id: String) -> Option<TerminalSessionRecord> {
    let mut state = workspace_state().lock().unwrap();
    if let Some(session) = state.terminal_sessions.get(&tab_id).cloned() {
        if let Some(new_session) = panda_core::transition_to_connecting(&session) {
            state.terminal_sessions.insert(tab_id, new_session.clone());
            return Some(new_session.into());
        }
    }
    None
}

/// 关闭终端会话，从状态管理器中移除。
#[uniffi::export]
pub fn terminal_session_close(tab_id: String) {
    let mut state = workspace_state().lock().unwrap();
    state.terminal_sessions.remove(&tab_id);
}

/// 检测握手结果是否已过期。
///
/// 用发起握手时的代次 `request_generation` 与当前会话的代次比较。
/// 若不相等，说明在握手期间用户已重试或关闭，该结果应被丢弃。
/// 若标签页无会话，返回 `true`（视为过期）。
#[uniffi::export]
pub fn terminal_session_is_stale(tab_id: String, request_generation: u32) -> bool {
    let state = workspace_state().lock().unwrap();
    match state.terminal_sessions.get(&tab_id) {
        Some(session) => panda_core::is_stale(session, request_generation),
        None => true, // 无会话视为过期
    }
}

/// 获取终端会话当前状态记录。
///
/// 若标签页无会话，返回 `None`。
#[uniffi::export]
pub fn terminal_session_get(tab_id: String) -> Option<TerminalSessionRecord> {
    let state = workspace_state().lock().unwrap();
    state.terminal_sessions.get(&tab_id).map(|s| s.clone().into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normal_shell_end_has_a_structured_error() {
        assert!(matches!(
            PandaError::from(panda_core::Error::ShellSessionClosed),
            PandaError::ShellSessionClosed
        ));
    }

    #[test]
    fn shell_input_backpressure_has_a_structured_ffi_error() {
        assert!(matches!(
            PandaError::from(panda_core::Error::ShellInputBackpressure),
            PandaError::ShellInputBackpressure
        ));
    }

    #[test]
    fn shell_nonzero_exit_has_a_structured_ffi_error() {
        assert!(matches!(
            PandaError::from(panda_core::Error::ShellExitStatus(7)),
            PandaError::ShellExitStatus(7)
        ));
    }

    #[test]
    fn lifecycle_record_has_only_safe_identifiers_and_fixed_reason() {
        let event = ConnectionLifecycleRecord::from(panda_core::telemetry::LifecycleEvent {
            connection_id: 42,
            address: "example.test:22".into(),
            owner_kind: "终端标签".into(),
            owner_id: "7".into(),
            kind: panda_core::telemetry::LifecycleKind::KeepaliveFailed,
        });
        assert!(event.is_error);
        assert_eq!(event.reason, "SSH keepalive 失败");
        assert_eq!(event.connection_id, 42);
    }

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
        assert!(matches!(
            credentials_for(&cfg, None, None),
            Err(PandaError::MissingPassword(_))
        ));
        assert!(matches!(
            PandaError::from(panda_core::Error::AuthFailed),
            PandaError::AuthFailed
        ));
    }

    #[test]
    fn connection_snapshot_maps_all_structured_fields_without_sensitive_content() {
        use panda_core::telemetry::{
            ChannelKind, ChannelSnapshot, ChannelState, ConnectionSnapshot, HealthState, SshState,
            TransportState,
        };
        let record = ConnectionTelemetryRecord::from(ConnectionSnapshot {
            id: 7,
            host_id: "host-id".into(),
            address: "example.test:22".into(),
            owner_kind: "终端标签".into(),
            owner_id: "tab-7".into(),
            created_at_ms: 10,
            last_activity_at_ms: 20,
            transport_state: TransportState::Idle,
            ssh_state: SshState::Authenticated,
            health_state: HealthState::Healthy,
            last_health_check_at_ms: Some(19),
            received_bytes: u64::MAX,
            sent_bytes: u64::MAX - 1,
            receive_bytes_per_second: 123,
            send_bytes_per_second: 456,
            last_error: None,
            channels: vec![ChannelSnapshot {
                id: 8,
                kind: ChannelKind::Sftp,
                state: ChannelState::Open,
                created_at_ms: 11,
                last_activity_at_ms: 18,
                received_bytes: 99,
                sent_bytes: 100,
            }],
        });

        assert_eq!(record.transport_state, ConnectionStateEnum::Idle);
        assert_eq!(record.ssh_state, SshConnectionStateEnum::Authenticated);
        assert_eq!(record.health_state, HealthStateEnum::Healthy);
        assert_eq!(record.owner_kind, "终端标签");
        assert_eq!(record.owner_id, "tab-7");
        assert_eq!(record.received_bytes, u64::MAX);
        assert_eq!(record.channels.len(), 1);
        assert_eq!(record.channels[0].kind, ChannelKindEnum::Sftp);
        let exported = format!("{record:?}").to_lowercase();
        for forbidden in [
            "password",
            "credential",
            "command",
            "terminal_output",
            "file_content",
        ] {
            assert!(
                !exported.contains(forbidden),
                "导出记录包含敏感字段 {forbidden}"
            );
        }
    }

    #[test]
    fn telemetry_list_can_be_empty_and_unknown_health_id_is_structured() {
        assert!(connection_telemetry_list().is_empty());
        assert!(matches!(
            connection_health_check(u64::MAX),
            Err(PandaError::UnknownConnection(id)) if id == u64::MAX
        ));
        assert!(connection_telemetry_list().is_empty());
    }

    // -----------------------------------------------------------------------
    // Workspace API tests
    // -----------------------------------------------------------------------

    /// 辅助：创建带主机名映射的 WorkspaceState。
    fn make_state(names: &[(&str, &str)]) -> WorkspaceState {
        let mappings: Vec<HostNameMapping> = names
            .iter()
            .map(|(id, name)| HostNameMapping {
                host_id: id.to_string(),
                name: name.to_string(),
            })
            .collect();
        let mut state = WorkspaceState::new();
        state.update_host_names(mappings);
        state
    }

    #[test]
    fn workspace_open_tab_creates_tab_with_disambiguated_title() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Sftp);
        let id3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);

        let list = state.tab_list();
        assert_eq!(list.len(), 3);
        assert_eq!(list[0].title, "server");
        assert_eq!(list[1].title, "server (2)");
        assert_eq!(list[2].title, "server (3)");
        assert_eq!(list[0].id, id1);
        assert_eq!(list[1].id, id2);
        assert_eq!(list[2].id, id3);
        assert_eq!(list[0].kind, panda_core::TabKind::Terminal);
        assert_eq!(list[0].connection_status, panda_core::ConnectionStatus::Connecting);
    }

    #[test]
    fn workspace_close_tab_renumbers_remaining() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let _id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let id3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);

        // 关闭第一个标签页（非已连接终端，直接关闭）
        state.request_close(&id1);

        let list = state.tab_list();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].title, "server");
        assert_eq!(list[1].title, "server (2)");
        assert!(list.iter().any(|t| t.id == id3));
    }

    #[test]
    fn workspace_close_active_tab_selects_neighbor() {
        let mut state = make_state(&[("h1", "server")]);
        let _id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let id3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);

        // id3 是活动标签（最后打开的）
        assert_eq!(state.active_tab_id, Some(id3.clone()));

        // 关闭活动标签 id3
        state.request_close(&id3);
        // 应选左侧相邻 id2
        assert_eq!(state.active_tab_id, Some(id2.clone()));
    }

    #[test]
    fn workspace_host_connection_status_aggregates_with_priority() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);

        // 初始都是 Connecting
        assert_eq!(
            state.host_connection_status("h1"),
            panda_core::ConnectionStatus::Connecting
        );

        // id1 connected, id2 failed → Connected (优先级最高)
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);
        state.report_connection_status(&id2, panda_core::ConnectionStatus::Failed);
        assert_eq!(
            state.host_connection_status("h1"),
            panda_core::ConnectionStatus::Connected
        );

        // 两个都 failed → Failed
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Failed);
        assert_eq!(
            state.host_connection_status("h1"),
            panda_core::ConnectionStatus::Failed
        );

        // 无标签页 → Inactive
        state.close_tab_internal(&id1);
        state.close_tab_internal(&id2);
        assert_eq!(
            state.host_connection_status("h1"),
            panda_core::ConnectionStatus::Inactive
        );
    }

    #[test]
    fn workspace_close_connected_terminal_triggers_confirmation() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);

        // 请求关闭应触发确认
        state.request_close(&id1);

        // 标签页应该还在
        assert_eq!(state.tab_list().len(), 1);

        // 应有待确认
        let pending = state.pending_close_info();
        assert!(pending.is_some());
        let pending = pending.unwrap();
        assert_eq!(pending.tab_ids, vec![id1.clone()]);
        assert_eq!(pending.connected_terminal_count, 1);

        // 确认关闭
        state.confirm_close();
        assert!(state.tab_list().is_empty());
        assert!(state.pending_close_info().is_none());
    }

    #[test]
    fn workspace_cancel_close_preserves_tab() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);

        state.request_close(&id1);
        assert!(state.pending_close_info().is_some());

        state.cancel_close();
        assert!(state.pending_close_info().is_none());

        // 标签页应该还在
        assert_eq!(state.tab_list().len(), 1);
        assert_eq!(state.tab_list()[0].id, id1);
    }

    #[test]
    fn workspace_close_sftp_tab_does_not_require_confirmation() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Sftp);
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);

        // SFTP 标签页直接关闭，不需要确认
        state.request_close(&id1);
        assert!(state.pending_close_info().is_none());
        assert!(state.tab_list().is_empty());
    }

    #[test]
    fn workspace_close_all_with_connected_terminals_triggers_batch_confirmation() {
        let mut state = make_state(&[("h1", "server"), ("h2", "other")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let _id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let _id3 = state.open_tab("h2".into(), panda_core::TabKind::Sftp);

        // 标记 id1 为已连接终端
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);

        state.request_close_all();

        // 应有批量确认
        let pending = state.pending_close_info();
        assert!(pending.is_some());
        let pending = pending.unwrap();
        assert_eq!(pending.connected_terminal_count, 1);
        assert_eq!(pending.tab_ids.len(), 3);

        // 确认关闭
        state.confirm_batch_close();
        assert!(state.tab_list().is_empty());
    }

    #[test]
    fn workspace_close_all_without_connected_terminals_closes_immediately() {
        let mut state = make_state(&[("h1", "server")]);
        let _id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let _id2 = state.open_tab("h1".into(), panda_core::TabKind::Sftp);

        // 没有已连接的终端
        state.request_close_all();

        // 不应有待确认
        assert!(state.pending_close_info().is_none());
        assert!(state.tab_list().is_empty());
    }

    #[test]
    fn workspace_close_others_with_connected_terminals_triggers_confirmation() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let id3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);

        // 标记 id2 为已连接终端
        state.report_connection_status(&id2, panda_core::ConnectionStatus::Connected);

        // 关闭其他（保留 id1）
        state.request_close_others(&id1);

        // 应有确认
        let pending = state.pending_close_info();
        assert!(pending.is_some());
        let pending = pending.unwrap();
        assert_eq!(pending.connected_terminal_count, 1);
        assert!(pending.tab_ids.contains(&id2));
        assert!(pending.tab_ids.contains(&id3));
        assert!(!pending.tab_ids.contains(&id1));

        // 确认关闭
        state.confirm_batch_close();
        assert_eq!(state.tab_list().len(), 1);
        assert_eq!(state.tab_list()[0].id, id1);
    }

    #[test]
    fn workspace_close_others_without_connected_closes_immediately() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let _id2 = state.open_tab("h1".into(), panda_core::TabKind::Sftp);

        // 没有已连接的终端
        state.request_close_others(&id1);

        assert!(state.pending_close_info().is_none());
        assert_eq!(state.tab_list().len(), 1);
        assert_eq!(state.tab_list()[0].id, id1);
    }

    #[test]
    fn workspace_select_tab_updates_active() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);

        // id2 是活动标签
        assert_eq!(state.active_tab_id, Some(id2.clone()));

        state.active_tab_id = Some(id1.clone());
        assert_eq!(state.active_tab_id, Some(id1.clone()));
    }

    #[test]
    fn workspace_disconnected_terminal_closes_without_confirmation() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);
        state.report_connection_status(&id1, panda_core::ConnectionStatus::Failed);

        // 已断开的终端标签页不需要确认
        state.request_close(&id1);
        assert!(state.pending_close_info().is_none());
        assert!(state.tab_list().is_empty());
    }

    #[test]
    fn workspace_unknown_host_uses_host_id_as_title() {
        let mut state = make_state(&[]); // 不设置任何主机名
        let _id1 = state.open_tab("unknown-host-id".into(), panda_core::TabKind::Terminal);
        let list = state.tab_list();
        assert_eq!(list[0].title, "unknown-host-id");
    }

    #[test]
    fn workspace_close_first_tab_selects_right_neighbor() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let _id3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);

        // 活动标签是 id3，手动设为 id1
        state.active_tab_id = Some(id1.clone());
        // 关闭 id1（第一个标签）
        state.request_close(&id1);
        // 应选右侧邻居（索引 0 位置），即 id2
        assert_eq!(state.active_tab_id, Some(id2.clone()));
    }

    #[test]
    fn workspace_batch_close_confirmed_by_confirm_close() {
        let mut state = make_state(&[("h1", "server")]);
        let id1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let _id2 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);

        state.report_connection_status(&id1, panda_core::ConnectionStatus::Connected);

        state.request_close_all();
        assert!(state.pending_close_info().is_some());

        // workspace_confirm_close 应该也能处理批量关闭
        // 在 FFI 层通过 is_batch 判断
        let is_batch = matches!(&state.pending_close, Some(PendingClose::Batch { .. }));
        assert!(is_batch);

        if is_batch {
            state.confirm_batch_close();
        } else {
            state.confirm_close();
        }
        assert!(state.tab_list().is_empty());
    }

    #[test]
    fn workspace_multiple_hosts_independent_numbering() {
        let mut state = make_state(&[("h1", "alpha"), ("h2", "beta")]);
        let _t1 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);
        let _t2 = state.open_tab("h2".into(), panda_core::TabKind::Terminal);
        let _t3 = state.open_tab("h1".into(), panda_core::TabKind::Terminal);

        let list = state.tab_list();
        assert_eq!(list[0].title, "alpha");
        assert_eq!(list[1].title, "beta");
        assert_eq!(list[2].title, "alpha (2)");
    }

    // -----------------------------------------------------------------------
    // 终端会话状态机 FFI
    // -----------------------------------------------------------------------

    fn unique_tab_id(prefix: &str) -> String {
        format!("{}-{}", prefix, Uuid::new_v4())
    }

    #[test]
    fn terminal_session_register_creates_connecting_session() {
        let tab_id = unique_tab_id("register");
        let record = terminal_session_register("host-1".into(), tab_id.clone());
        assert_eq!(record.id, tab_id);
        assert_eq!(record.host_id, "host-1");
        assert_eq!(record.phase, TerminalPhaseEnum::Connecting);
        assert_eq!(record.attempt, 0);
        assert_eq!(record.failure_category, None);
        assert_eq!(record.failure_message, None);
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_phase_returns_current_phase() {
        let tab_id = unique_tab_id("phase");
        terminal_session_register("host-1".into(), tab_id.clone());
        assert_eq!(terminal_session_phase(tab_id.clone()), Some(TerminalPhaseEnum::Connecting));

        terminal_session_transition_to_shell(tab_id.clone());
        assert_eq!(terminal_session_phase(tab_id.clone()), Some(TerminalPhaseEnum::Shell));
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_phase_returns_none_for_unknown_tab() {
        assert_eq!(terminal_session_phase(unique_tab_id("nonexistent")), None);
    }

    #[test]
    fn terminal_session_transition_to_shell_from_connecting() {
        let tab_id = unique_tab_id("to-shell");
        terminal_session_register("host-1".into(), tab_id.clone());
        terminal_session_transition_to_shell(tab_id.clone());

        let record = terminal_session_get(tab_id.clone()).unwrap();
        assert_eq!(record.phase, TerminalPhaseEnum::Shell);
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_transition_to_shell_from_shell_is_noop() {
        let tab_id = unique_tab_id("noop-shell");
        terminal_session_register("host-1".into(), tab_id.clone());
        terminal_session_transition_to_shell(tab_id.clone());
        // 再次调用，应无效果
        terminal_session_transition_to_shell(tab_id.clone());

        let record = terminal_session_get(tab_id.clone()).unwrap();
        assert_eq!(record.phase, TerminalPhaseEnum::Shell);
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_transition_to_failed_records_error() {
        let tab_id = unique_tab_id("fail");
        terminal_session_register("host-1".into(), tab_id.clone());
        terminal_session_transition_to_failed(
            tab_id.clone(),
            TerminalFailureCategoryEnum::Timeout,
            "连接超时".into(),
        );

        let record = terminal_session_get(tab_id.clone()).unwrap();
        assert_eq!(record.phase, TerminalPhaseEnum::Failed);
        assert_eq!(record.failure_category, Some(TerminalFailureCategoryEnum::Timeout));
        assert_eq!(record.failure_message, Some("连接超时".into()));
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_retry_increments_attempt() {
        let tab_id = unique_tab_id("retry");
        terminal_session_register("host-1".into(), tab_id.clone());
        terminal_session_transition_to_failed(
            tab_id.clone(),
            TerminalFailureCategoryEnum::AuthFailed,
            "认证失败".into(),
        );

        let retry = terminal_session_retry(tab_id.clone()).unwrap();
        assert_eq!(retry.phase, TerminalPhaseEnum::Connecting);
        assert_eq!(retry.attempt, 1);
        assert_eq!(retry.failure_category, None);
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_retry_from_connecting_returns_none() {
        let tab_id = unique_tab_id("retry-connecting");
        terminal_session_register("host-1".into(), tab_id.clone());
        // 当前是 Connecting，重试应返回 None
        assert!(terminal_session_retry(tab_id.clone()).is_none());
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_close_removes_session() {
        let tab_id = unique_tab_id("close");
        terminal_session_register("host-1".into(), tab_id.clone());
        assert!(terminal_session_get(tab_id.clone()).is_some());

        terminal_session_close(tab_id.clone());
        assert!(terminal_session_get(tab_id.clone()).is_none());
    }

    #[test]
    fn terminal_session_is_stale_detects_outdated_generation() {
        let tab_id = unique_tab_id("stale");
        let record = terminal_session_register("host-1".into(), tab_id.clone());
        let gen0 = record.attempt;

        // 代次 0 有效
        assert!(!terminal_session_is_stale(tab_id.clone(), gen0));

        // 失败并重试后代次变为 1
        terminal_session_transition_to_failed(
            tab_id.clone(),
            TerminalFailureCategoryEnum::Timeout,
            "超时".into(),
        );
        terminal_session_retry(tab_id.clone());

        // 代次 0 现在已过期
        assert!(terminal_session_is_stale(tab_id.clone(), gen0));
        // 代次 1 有效
        assert!(!terminal_session_is_stale(tab_id.clone(), 1));
        terminal_session_close(tab_id);
    }

    #[test]
    fn terminal_session_is_stale_returns_true_for_unknown_tab() {
        assert!(terminal_session_is_stale(unique_tab_id("nonexistent-stale"), 0));
    }

    #[test]
    fn terminal_session_full_lifecycle_via_ffi() {
        let tab_id = unique_tab_id("lifecycle");

        // 注册
        let record = terminal_session_register("host-1".into(), tab_id.clone());
        assert_eq!(record.phase, TerminalPhaseEnum::Connecting);
        assert_eq!(record.attempt, 0);

        // 连接失败
        terminal_session_transition_to_failed(
            tab_id.clone(),
            TerminalFailureCategoryEnum::Timeout,
            "超时".into(),
        );
        let failed = terminal_session_get(tab_id.clone()).unwrap();
        assert_eq!(failed.phase, TerminalPhaseEnum::Failed);
        assert_eq!(failed.attempt, 0);

        // 重试
        let retry = terminal_session_retry(tab_id.clone()).unwrap();
        assert_eq!(retry.phase, TerminalPhaseEnum::Connecting);
        assert_eq!(retry.attempt, 1);

        // 旧代次过期
        assert!(terminal_session_is_stale(tab_id.clone(), 0));
        assert!(!terminal_session_is_stale(tab_id.clone(), 1));

        // 连接成功
        terminal_session_transition_to_shell(tab_id.clone());
        let shell = terminal_session_get(tab_id.clone()).unwrap();
        assert_eq!(shell.phase, TerminalPhaseEnum::Shell);
        assert_eq!(shell.attempt, 1);

        // 关闭
        terminal_session_close(tab_id.clone());
        assert!(terminal_session_get(tab_id.clone()).is_none());
    }

    #[test]
    fn terminal_session_close_via_tab_close() {
        let mut state = workspace_state().lock().unwrap();
        // 打开标签页
        let tab_id = state.open_tab("host-1".into(), panda_core::TabKind::Terminal);
        state.terminal_sessions.insert(
            tab_id.clone(),
            panda_core::TerminalSessionState::new(tab_id.clone(), "host-1".into()),
        );
        assert!(state.terminal_sessions.contains_key(&tab_id));

        // 关闭标签页应同时清理终端会话
        state.close_tab_internal(&tab_id);
        assert!(!state.terminal_sessions.contains_key(&tab_id));
    }

    // -----------------------------------------------------------------------
    // TOFU waiter management tests
    // -----------------------------------------------------------------------

    #[test]
    fn tofu_first_waiter_gets_probe_true() {
        preconnect_tofu_reset();
        assert!(preconnect_tofu_register_waiter("host-1".into()));
        preconnect_tofu_resolve("host-1".into(), true);
    }

    #[test]
    fn tofu_second_waiter_gets_probe_false() {
        preconnect_tofu_reset();
        assert!(preconnect_tofu_register_waiter("host-2".into()));
        // 第二个等待者应返回 false
        assert!(!preconnect_tofu_register_waiter("host-2".into()));
        preconnect_tofu_resolve("host-2".into(), true);
    }

    #[test]
    fn tofu_resolve_clears_probing_state() {
        preconnect_tofu_reset();
        assert!(preconnect_tofu_register_waiter("host-3".into()));
        preconnect_tofu_resolve("host-3".into(), true);
        // 清理后可以再次注册
        assert!(preconnect_tofu_register_waiter("host-3".into()));
        preconnect_tofu_resolve("host-3".into(), false);
    }

    #[test]
    fn tofu_different_hosts_are_independent() {
        preconnect_tofu_reset();
        assert!(preconnect_tofu_register_waiter("host-a".into()));
        assert!(preconnect_tofu_register_waiter("host-b".into()));
        // 不同主机互不影响
        assert!(!preconnect_tofu_register_waiter("host-a".into()));
        assert!(!preconnect_tofu_register_waiter("host-b".into()));
        preconnect_tofu_resolve("host-a".into(), true);
        preconnect_tofu_resolve("host-b".into(), false);
    }

    #[test]
    fn tofu_resolve_without_waiters_is_noop() {
        preconnect_tofu_reset();
        // 没有等待者时 resolve 不应 panic
        preconnect_tofu_resolve("nonexistent".into(), true);
    }

    // -----------------------------------------------------------------------
    // Transfer change counter tests
    // -----------------------------------------------------------------------

    /// 构造一个假的 TransferTask 用于测试（不启动异步工作线程）。
    fn make_test_task(id: Uuid) -> TransferTask {
        TransferTask {
            id,
            direction: TransferDirectionEnum::Upload,
            host_id: "test-host".into(),
            local_path: "/tmp/test".into(),
            remote_path: "/remote/test".into(),
            password: None,
            passphrase: None,
            size: 1024,
            status: Arc::new(std::sync::Mutex::new(TransferStatusEnum::Queued)),
            transferred: Arc::new(AtomicU64::new(0)),
            error: Arc::new(std::sync::Mutex::new(None)),
            cancel: Arc::new(AtomicBool::new(false)),
            paused: Arc::new(AtomicBool::new(false)),
            resume_notify: Arc::new(tokio::sync::Notify::new()),
            version: Arc::new(AtomicU64::new(1)),
            speed_tracker: Arc::new(Mutex::new(TransferSpeedTracker::new(1024))),
            group_id: None,
            group_name: None,
        }
    }

    /// 将测试任务插入全局注册表。
    fn insert_test_task(task: &TransferTask) {
        transfer_tasks()
            .lock()
            .unwrap()
            .insert(task.id, task.clone());
    }

    /// 从全局注册表移除测试任务。
    fn remove_test_task(id: &Uuid) {
        transfer_tasks().lock().unwrap().remove(id);
    }

    #[test]
    fn progress_alone_advances_revision_and_snapshot() {
        let task = make_test_task(Uuid::new_v4());
        let progress = task.progress_callback();
        for done in [1, 512, 1024] {
            let before = transfer_change_counter();
            progress(done, 1024);
            assert!(transfer_change_counter() > before, "仅字节进度也必须通知订阅方");
            assert_eq!(task.snapshot().transferred, done);
        }
    }

    #[test]
    fn change_counter_increments_on_notify() {
        let before = transfer_change_counter();
        notify_transfer_changed();
        let after = transfer_change_counter();
        assert_eq!(after, before + 1);
    }

    #[test]
    fn change_counter_does_not_increment_on_read() {
        // 读取计数器本身不改变它的值
        let v1 = transfer_change_counter();
        let v2 = transfer_change_counter();
        assert_eq!(v1, v2);
    }

    #[test]
    fn change_counter_increments_on_cancel() {
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);

        let before = transfer_change_counter();
        let _ = transfer_cancel(id.to_string());
        let after = transfer_change_counter();
        assert!(after > before, "cancel should bump change counter");

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_increments_on_pause() {
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);

        let before = transfer_change_counter();
        let _ = transfer_pause(id.to_string());
        let after = transfer_change_counter();
        assert!(after > before, "pause should bump change counter");

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_increments_on_resume() {
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        // 先暂停
        *task.status.lock().unwrap() = TransferStatusEnum::Paused;
        insert_test_task(&task);

        let before = transfer_change_counter();
        let _ = transfer_resume(id.to_string());
        let after = transfer_change_counter();
        assert!(after > before, "resume should bump change counter");

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_multiple_transitions_accumulate() {
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        insert_test_task(&task);

        let c0 = transfer_change_counter();

        // Queued → Paused
        let _ = transfer_pause(id.to_string());
        let c1 = transfer_change_counter();
        assert!(c1 >= c0 + 1, "pause should bump counter by at least 1");

        // Paused → Queued (resume)
        let _ = transfer_resume(id.to_string());
        let c2 = transfer_change_counter();
        assert!(c2 >= c1 + 1, "resume should bump counter by at least 1");

        // Queued → Cancelled
        let _ = transfer_cancel(id.to_string());
        let c3 = transfer_change_counter();
        assert!(c3 >= c2 + 1, "cancel should bump counter by at least 1");

        // 总共至少递增了 3 次
        assert!(c3 >= c0 + 3, "three transitions should bump counter by at least 3");

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_no_increment_for_noop_cancel() {
        // 已完成的任务 cancel 是 no-op，任务状态不应改变
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        *task.status.lock().unwrap() = TransferStatusEnum::Completed;
        insert_test_task(&task);

        let _ = transfer_cancel(id.to_string());
        // 状态应保持 Completed，不应被改为 Cancelled
        assert_eq!(
            *task.status.lock().unwrap(),
            TransferStatusEnum::Completed,
            "cancelling a completed task should not change its status"
        );

        remove_test_task(&id);
    }

    #[test]
    fn change_counter_no_increment_for_noop_pause() {
        // 已暂停的任务再次 pause 是 no-op，任务状态不应改变
        let id = Uuid::new_v4();
        let task = make_test_task(id);
        *task.status.lock().unwrap() = TransferStatusEnum::Paused;
        insert_test_task(&task);

        let _ = transfer_pause(id.to_string());
        // 状态应保持 Paused（不会重复触发 notify）
        assert_eq!(
            *task.status.lock().unwrap(),
            TransferStatusEnum::Paused,
            "pausing an already paused task should not change its status"
        );

        remove_test_task(&id);
    }
}

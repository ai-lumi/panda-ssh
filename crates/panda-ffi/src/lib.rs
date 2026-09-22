//! UniFFI bindings exposing panda-core to Swift.
//!
//! All exported functions are synchronous from the caller's perspective;
//! async work runs on a lazily created global tokio runtime.

use std::path::PathBuf;

use panda_core::{AuthMethod, HostConfig};

uniffi::setup_scaffolding!();

mod ffi_runtime;

#[cfg(test)]
mod test_support;

mod ffi_adapter;
pub use ffi_adapter::{sftp_child_path, sftp_directory_path};

mod ffi_workspace;
pub use ffi_workspace::{
    preconnect_tofu_register_waiter, preconnect_tofu_reset, preconnect_tofu_resolve,
    terminal_session_close, terminal_session_get, terminal_session_is_stale,
    terminal_session_phase, terminal_session_register, terminal_session_retry,
    terminal_session_transition_to_failed, terminal_session_transition_to_shell,
    workspace_active_tab_id, workspace_cancel_close, workspace_close_all_tabs,
    workspace_close_other_tabs, workspace_close_tab, workspace_confirm_close,
    workspace_host_connection_status, workspace_open_tab, workspace_pending_close,
    workspace_report_connection_status, workspace_reset, workspace_select_tab,
    workspace_set_host_names, workspace_tab_list, CloseConfirmationRecord, ConnectionStatusEnum,
    HostNameMapping, TabKindEnum, TerminalFailureCategoryEnum, TerminalPhaseEnum,
    TerminalSessionRecord, WorkspaceTabRecord,
};

mod ffi_telemetry;
pub use ffi_telemetry::{
    connection_failure_classify, connection_health_check, connection_lifecycle_drain,
    connection_telemetry_list, log_clear, log_entries, log_write, ChannelKindEnum,
    ChannelStateEnum, ChannelTelemetryRecord, ConnectionFailureFFIRecord,
    ConnectionLifecycleRecord, ConnectionStateEnum, ConnectionTelemetryRecord, FailureCategoryEnum,
    HealthStateEnum, LogEntryRecord, LogLevelEnum, SshConnectionStateEnum,
};

mod ffi_transfers;
pub use ffi_transfers::{
    aggregate_task_groups_ffi, batch_transfer_cancel, batch_transfer_list,
    batch_transfer_resolve_conflict, batch_transfer_status, scan_local_batch, scan_remote_batch,
    start_batch_download, start_batch_upload, start_transfer, transfer_cancel,
    transfer_change_counter, transfer_groups, transfer_list, transfer_pause, transfer_resume,
    transfer_retry, transfer_status, AggregationResultRecord, BatchConflictRecord, BatchItemRecord,
    BatchTransferDirectionEnum, BatchTransferStatusEnum, BatchTransferStatusRecord,
    TaskGroupRecord, TaskItemRecord, TransferDirectionEnum, TransferGroupRecord,
    TransferStatusEnum, TransferStatusRecord,
};

mod ffi_store;
pub use ffi_store::{
    accept_unknown_host_key, config_export, config_import, credential_protection_enabled,
    credential_protection_status, credential_resolve, credential_unlock_only,
    default_terminal_buffer_lines, delete_credential, delete_group, delete_host, delete_snippet,
    group_path, host_key_status, init_snippets, init_store, list_groups, list_hosts, list_snippets,
    move_group, preconnect_evaluate, read_credential, save_credential, save_group, save_host,
    save_snippet, search_hosts, set_credential_protection_key, sidebar_tree,
    validate_credential_protection_input, validate_terminal_buffer_lines, ExportManifestRecord,
    ImportResultRecord, PreconnectActionEnum, ProtectionActionEnum, ProtectionInputErrorEnum,
    ProtectionStatusEnum, ResolvedCredentialEnum, SidebarNodeFFIRecord, SnippetRecord,
    TerminalBufferErrorEnum,
};

mod ffi_sessions;
pub use ffi_sessions::{
    sftp_check_download_conflict, sftp_check_upload_conflict, sftp_create_dir, sftp_download,
    sftp_home_dir, sftp_list, sftp_remove_dir, sftp_remove_file,
    sftp_session_check_download_conflict, sftp_session_check_upload_conflict, sftp_session_close,
    sftp_session_create_dir, sftp_session_list, sftp_session_open, sftp_session_remove_dir,
    sftp_session_remove_file, sftp_upload, shell_close, shell_open, shell_read, shell_resize,
    shell_write, test_connection,
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

#[cfg(test)]
#[cfg(test)]
#[path = "tests/lib_tests.rs"]
mod tests;

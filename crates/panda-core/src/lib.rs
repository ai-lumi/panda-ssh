//! Core library for Panda SSH: host config, known-hosts, SSH and SFTP.

pub mod batch;
pub mod config;
pub mod config_archive;
pub mod connection_registry;
pub mod credentials;
pub mod delete_tasks;
pub mod groups;
pub mod hostkey;
pub mod logger;
pub mod sftp;
pub mod sftp_path;
pub mod snippets;
pub mod ssh;
pub mod telemetry;
pub mod transfer_speed;
pub mod task_aggregation;
pub mod preconnect;
pub mod workspace;

pub use batch::{
    execute_batch_download, execute_batch_upload, scan_local_sources, scan_remote_sources,
    BatchConflictCallback, BatchItem, BatchOutcome, BatchPlan, BatchProgressCallback,
    BatchTransferOptions, ConflictResolution, ScanOptions,
};
pub use config::{AuthMethod, ConfigStore, HostConfig, TomlConfigStore, search_hosts};
pub use credentials::{CredentialStore, ResolvedCredential, credential_resolve};
pub use groups::{
    delete_group_cascade, descendant_ids, group_path, move_group, sidebar_tree, Group,
    GroupStore, SidebarNodeRecord, TomlGroupStore, MAX_GROUP_DEPTH,
};
pub use hostkey::{fingerprint_sha256, HostKeyStatus, KnownHostStatus, KnownHosts};
pub use sftp::{FileConflictInfo, RemoteFile, SftpClient};
pub use snippets::{Snippet, SnippetStore};
pub use ssh::{Credentials, ExecOutput, FailureCategory, ShellSession, SshSession, UnknownHostKeyPolicy, connection_failure_classify};
pub use transfer_speed::TransferSpeedTracker;
pub use task_aggregation::{
    AggregationResult, TaskGroup, TaskItem, TaskStatus, TransferDirection,
    aggregate_task_groups, group_cancel_plan, group_retry_plan,
};
pub use workspace::{
    CloseConfirmation, ConnectionStatus, ShellExitClassification, TabKind, TerminalFailureCategory,
    TerminalPhase, TerminalSessionState, WorkspaceTab, aggregate_connection_status,
    classify_shell_exit, compute_disambiguated_titles, is_stale, next_active_tab_after_close,
    transition_to_connecting, transition_to_failed, transition_to_shell,
};
pub use preconnect::{PreconnectAction, PresentedKey, preconnect_evaluate};

/// Unified error type for the core crate.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("toml parse error: {0}")]
    TomlParse(#[from] toml::de::Error),

    #[error("toml serialize error: {0}")]
    TomlSerialize(#[from] toml::ser::Error),

    #[error("ssh error: {0}")]
    Ssh(#[from] russh::Error),

    #[error("key error: {0}")]
    Key(#[from] russh::keys::Error),

    #[error("sftp error: {0}")]
    Sftp(#[from] russh_sftp::client::error::Error),

    #[error("host key mismatch for {host}: stored {stored_fingerprint}, presented {presented_fingerprint}")]
    HostKeyMismatch {
        host: String,
        stored_fingerprint: String,
        presented_fingerprint: String,
    },

    #[error("unknown host key for {host}: fingerprint {fingerprint}")]
    UnknownHostKey {
        host: String,
        presented: String,
        fingerprint: String,
    },

    #[error("authentication failed")]
    AuthFailed,

    #[error("private key passphrase is required")]
    MissingPassphrase,

    #[error("operation timed out")]
    Timeout,

    #[error("shell session closed")]
    ShellSessionClosed,

    #[error("unknown connection telemetry id {0}")]
    UnknownConnection(u64),

    #[error("operation cancelled")]
    Cancelled,

    #[error("credential protection key is required")]
    CredentialProtectionKeyRequired,

    #[error("credential protection key cannot decrypt the credential file")]
    CredentialUnlockFailed,

    #[error("credential file is invalid")]
    InvalidCredentialFile,

    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, Error>;
pub mod task_summary;

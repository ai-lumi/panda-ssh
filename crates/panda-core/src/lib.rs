//! Core library for Panda SSH: host config, known-hosts, SSH and SFTP.

pub mod application;
pub mod batch;
pub mod config;
pub mod config_archive;
pub mod connection_registry;
pub mod credentials;
pub mod delete_service;
pub mod delete_tasks;
pub mod groups;
pub mod hostkey;
pub mod logger;
pub mod preconnect;
pub mod sftp;
pub mod sftp_path;
pub mod sftp_orchestration;
pub mod snippets;
pub mod ssh;
pub mod task_aggregation;
pub mod telemetry;
pub mod tofu;
pub mod transfer;
pub mod transfer_speed;
pub mod workspace;

pub use application::{
    ConnectionCredentialKind, ConnectionCredentialPreparation, ConnectionCredentialRequest,
    ConnectionCredentials, CredentialIntent, HostDeleteResult, HostSaveRequest, HostSaveResult,
    PandaCore, SessionKey, SftpDeleteFileSystem, StorageLocation,
};
pub use batch::{
    execute_batch_download, execute_batch_upload, scan_local_sources, scan_remote_sources,
    BatchConflictCallback, BatchConflictInfo, BatchConflictResolver, BatchContext, BatchDirection,
    BatchExecutor, BatchItem, BatchOutcome, BatchPlan, BatchProgressCallback, BatchServiceParams,
    BatchStatus, BatchTaskSnapshot, BatchTransferOptions, BatchTransferService, ConflictResolution,
    ScanOptions,
};
pub use config::{
    default_terminal_buffer_lines, search_hosts, validate_terminal_buffer_lines, AuthMethod,
    ConfigStore, HostConfig, TerminalBufferError, TomlConfigStore, DEFAULT_TERMINAL_BUFFER_LINES,
    MAX_TERMINAL_BUFFER_LINES, MIN_TERMINAL_BUFFER_LINES,
};
pub use credentials::{
    credential_resolve, validate_protection_input, CredentialStore, ProtectionAction,
    ProtectionInputError, ProtectionStatus, ResolvedCredential,
};
pub use delete_service::{DeleteService, DeleteServiceSnapshot};
pub use groups::{
    delete_group_cascade, descendant_ids, group_path, move_group, sidebar_tree, Group, GroupStore,
    SidebarNodeRecord, TomlGroupStore, MAX_GROUP_DEPTH,
};
pub use hostkey::{fingerprint_sha256, HostKeyStatus, KnownHostStatus, KnownHosts};
pub use preconnect::{preconnect_evaluate, PreconnectAction, PresentedKey};
pub use sftp::{FileConflictInfo, RemoteFile, SftpClient};
pub use sftp_orchestration::{
    plan_sftp_orchestration, PlannedBatch, PlannedTransfer, SftpOrchestrationDirection,
    SftpOrchestrationPlan,
};
pub use snippets::{Snippet, SnippetStore};
pub use ssh::{
    connection_failure_classify, Credentials, ExecOutput, FailureCategory, ShellSession,
    SshSession, UnknownHostKeyPolicy,
};
pub use task_aggregation::{
    aggregate_task_groups, group_cancel_plan, group_retry_plan, AggregationResult, TaskGroup,
    TaskItem, TaskStatus, TransferDirection,
};
pub use transfer_speed::TransferSpeedTracker;
pub use tofu::{PresentedKeyInfo, TofuCoordinator, TofuOutcome, TofuRegistration};
pub use workspace::{
    aggregate_connection_status, classify_shell_exit, compute_disambiguated_titles, is_stale,
    next_active_tab_after_close, transition_to_connecting, transition_to_failed,
    transition_to_shell, CloseConfirmation, CloseResult, ConnectionStatus, GroupSnapshot,
    ShellExitClassification, ShutdownSummary, TabGroup, TabKind, TerminalFailureCategory,
    TerminalPhase, TerminalSessionState, WorkspaceService, WorkspaceTab,
};

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

    #[error("host {0} uses password auth but no password was provided")]
    MissingPassword(String),

    #[error("private key passphrase is required")]
    MissingPassphrase,

    #[error("operation timed out")]
    Timeout,

    #[error("shell session closed")]
    ShellSessionClosed,

    #[error("unknown shell session handle {0}")]
    UnknownShellHandle(u64),

    #[error("unknown SFTP session handle {0}")]
    UnknownSftpHandle(u64),

    #[error("shell input is temporarily backpressured")]
    ShellInputBackpressure,

    #[error("shell exited with status {0}")]
    ShellExitStatus(u32),

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

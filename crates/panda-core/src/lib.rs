//! Core library for Panda SSH: host config, known-hosts, SSH and SFTP.

pub mod config;
pub mod groups;
pub mod hostkey;
pub mod sftp;
pub mod snippets;
pub mod ssh;

pub use config::{AuthMethod, ConfigStore, HostConfig, TomlConfigStore};
pub use groups::{
    delete_group_cascade, descendant_ids, move_group, Group, GroupStore, TomlGroupStore,
    MAX_GROUP_DEPTH,
};
pub use hostkey::{HostKeyStatus, KnownHostStatus, KnownHosts, fingerprint_sha256};
pub use sftp::{RemoteFile, SftpClient};
pub use snippets::{Snippet, SnippetStore};
pub use ssh::{Credentials, ExecOutput, ShellSession, SshSession, UnknownHostKeyPolicy};

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

    #[error("operation timed out")]
    Timeout,

    #[error("shell session closed")]
    ShellSessionClosed,

    #[error("operation cancelled")]
    Cancelled,

    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, Error>;

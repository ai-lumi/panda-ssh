//! SFTP client built on russh-sftp over an existing SSH session.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use russh_sftp::client::SftpSession;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::ssh::SshSession;
use crate::{Error, Result};

const COPY_BUF_SIZE: usize = 64 * 1024;

/// A remote directory entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteFile {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: Option<SystemTime>,
}

/// High-level SFTP operations over one SSH connection.
pub struct SftpClient {
    session: SftpSession,
}

impl SftpClient {
    /// Open a channel on `session` and start the SFTP subsystem.
    pub async fn new(session: &SshSession) -> Result<Self> {
        let channel = session.open_channel().await?;
        channel.request_subsystem(true, "sftp").await?;
        Ok(Self {
            session: SftpSession::new(channel.into_stream()).await?,
        })
    }

    /// List the entries of a remote directory.
    pub async fn list_dir(&self, path: &str) -> Result<Vec<RemoteFile>> {
        let entries = self
            .session
            .read_dir(path)
            .await?
            .map(|entry| {
                let meta = entry.metadata();
                RemoteFile {
                    name: entry.file_name(),
                    path: entry.path(),
                    is_dir: meta.is_dir(),
                    size: meta.size.unwrap_or(0),
                    modified: meta
                        .mtime
                        .map(|secs| UNIX_EPOCH + Duration::from_secs(u64::from(secs))),
                }
            })
            .collect();
        Ok(entries)
    }

    /// Upload a local file, invoking `progress(sent, total)` after each chunk.
    pub async fn upload(
        &self,
        local: &Path,
        remote: &str,
        progress: Option<&dyn Fn(u64, u64)>,
    ) -> Result<()> {
        let total = tokio::fs::metadata(local).await?.len();
        let mut src = tokio::fs::File::open(local).await?;
        let mut dst = self.session.create(remote).await?;

        let mut buf = vec![0u8; COPY_BUF_SIZE];
        let mut sent = 0u64;
        loop {
            let n = src.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            dst.write_all(&buf[..n]).await?;
            sent += n as u64;
            if let Some(cb) = progress {
                cb(sent, total);
            }
        }
        dst.close().await?;
        Ok(())
    }

    /// Upload a local file with optional cancellation flag.
    /// `cancel` 若置为 true，下一轮循环立即返回 `Error::Cancelled`。
    pub async fn upload_with_cancel(
        &self,
        local: &Path,
        remote: &str,
        progress: Option<Arc<dyn Fn(u64, u64) + Send + Sync>>,
        cancel: Option<Arc<AtomicBool>>,
    ) -> Result<()> {
        let total = tokio::fs::metadata(local).await?.len();
        let mut src = tokio::fs::File::open(local).await?;
        let mut dst = self.session.create(remote).await?;

        let mut buf = vec![0u8; COPY_BUF_SIZE];
        let mut sent = 0u64;
        loop {
            if cancel.as_ref().map(|c| c.load(Ordering::Relaxed)).unwrap_or(false) {
                return Err(Error::Cancelled);
            }
            let n = src.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            dst.write_all(&buf[..n]).await?;
            sent += n as u64;
            if let Some(ref cb) = progress {
                cb(sent, total);
            }
        }
        dst.close().await?;
        Ok(())
    }

    /// Download a remote file to a local path.
    pub async fn download(&self, remote: &str, local: &Path) -> Result<()> {
        let mut src = self.session.open(remote).await?;
        let mut dst = tokio::fs::File::create(local).await?;
        tokio::io::copy(&mut src, &mut dst).await?;
        dst.flush().await?;
        Ok(())
    }

    /// Download a remote file to a local path with progress and cancellation.
    /// `cancel` 若置为 true，下一轮循环立即返回 `Error::Cancelled`。
    pub async fn download_with_cancel(
        &self,
        remote: &str,
        local: &Path,
        progress: Option<Arc<dyn Fn(u64, u64) + Send + Sync>>,
        cancel: Option<Arc<AtomicBool>>,
    ) -> Result<()> {
        let total = self
            .session
            .metadata(remote)
            .await
            .ok()
            .and_then(|m| m.size)
            .unwrap_or(0);
        let mut src = self.session.open(remote).await?;
        let mut dst = tokio::fs::File::create(local).await?;

        let mut buf = vec![0u8; COPY_BUF_SIZE];
        let mut received = 0u64;
        loop {
            if cancel.as_ref().map(|c| c.load(Ordering::Relaxed)).unwrap_or(false) {
                return Err(Error::Cancelled);
            }
            let n = src.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            dst.write_all(&buf[..n]).await?;
            received += n as u64;
            if let Some(ref cb) = progress {
                cb(received, total);
            }
        }
        dst.flush().await?;
        Ok(())
    }

    pub async fn remove_file(&self, path: &str) -> Result<()> {
        Ok(self.session.remove_file(path).await?)
    }

    pub async fn remove_dir(&self, path: &str) -> Result<()> {
        Ok(self.session.remove_dir(path).await?)
    }

    pub async fn create_dir(&self, path: &str) -> Result<()> {
        Ok(self.session.create_dir(path).await?)
    }

    /// Resolve the user's home directory at session start.
    /// SFTP 会话初始工作目录通常是用户 home；`canonicalize(".")` 将其转为绝对路径。
    pub async fn home_dir(&self) -> Result<String> {
        Ok(self.session.canonicalize(".").await?)
    }

    /// Close the SFTP session and its channel.
    pub async fn close(&self) -> Result<()> {
        Ok(self.session.close().await?)
    }
}

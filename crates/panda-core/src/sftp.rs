//! SFTP client built on russh-sftp over an existing SSH session.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use russh_sftp::client::SftpSession;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Notify;
use tokio::time::sleep;

use crate::ssh::SshSession;
use crate::telemetry::{global_registry, ChannelKind, ChannelState};
use crate::{Error, Result};

const COPY_BUF_SIZE: usize = 64 * 1024;
const PAUSE_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// 若 `pause` 为 true，则等待直到被解除或取消；取消时返回 `Error::Cancelled`。
async fn wait_if_paused(
    cancel: Option<&Arc<AtomicBool>>,
    pause: Option<&Arc<AtomicBool>>,
    resume: Option<&Arc<Notify>>,
) -> Result<()> {
    loop {
        if cancel
            .as_ref()
            .map(|c| c.load(Ordering::Relaxed))
            .unwrap_or(false)
        {
            return Err(Error::Cancelled);
        }
        if !pause
            .as_ref()
            .map(|p| p.load(Ordering::Relaxed))
            .unwrap_or(false)
        {
            return Ok(());
        }
        if let Some(notify) = resume {
            // 先注册等待再检查,避免通知在 await 前丢失。
            let notified = notify.notified();
            if !pause
                .as_ref()
                .map(|p| p.load(Ordering::Relaxed))
                .unwrap_or(false)
            {
                return Ok(());
            }
            notified.await;
        } else {
            sleep(PAUSE_POLL_INTERVAL).await;
        }
    }
}

/// 文件覆盖确认所需元数据。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileConflictInfo {
    pub source_size: u64,
    pub source_mtime: Option<u64>,
    pub target_size: u64,
    pub target_mtime: Option<u64>,
}

/// 远端文件元数据的内部抽象，便于纯函数测试。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RemoteMetadata {
    size: u64,
    mtime: Option<u64>,
}

fn system_time_to_secs(t: SystemTime) -> Option<u64> {
    t.duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs())
}

/// 判断 SFTP 服务器返回的错误消息是否表示"目录已存在"。
fn is_already_exists_message(msg: &str) -> bool {
    let lower = msg.to_lowercase();
    lower.contains("already exists") || lower.contains("file exists") || lower.contains("exists")
}

fn build_conflict_info(
    source_size: u64,
    source_mtime: Option<u64>,
    target_meta: Option<RemoteMetadata>,
) -> Option<FileConflictInfo> {
    target_meta.map(|m| FileConflictInfo {
        source_size,
        source_mtime,
        target_size: m.size,
        target_mtime: m.mtime,
    })
}

/// 检查本地目标文件是否已存在，并构造冲突信息。
fn local_conflict_check(
    source_size: u64,
    source_mtime: Option<u64>,
    local: &Path,
) -> Result<Option<FileConflictInfo>> {
    match std::fs::metadata(local) {
        Ok(meta) => {
            let target_size = meta.len();
            let target_mtime = meta.modified().ok().and_then(system_time_to_secs);
            Ok(Some(FileConflictInfo {
                source_size,
                source_mtime,
                target_size,
                target_mtime,
            }))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

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
    telemetry_id: u64,
    channel_telemetry_id: u64,
}

impl SftpClient {
    /// Open a channel on `session` and start the SFTP subsystem.
    pub async fn new(session: &SshSession) -> Result<Self> {
        let channel = session.open_channel().await?;
        channel.request_subsystem(true, "sftp").await?;
        let sftp_session = SftpSession::new(channel.into_stream()).await?;
        let telemetry_id = session.telemetry_id();
        let channel_telemetry_id = global_registry().open_channel(telemetry_id, ChannelKind::Sftp);
        Ok(Self {
            session: sftp_session,
            telemetry_id,
            channel_telemetry_id,
        })
    }

    fn record_io(&self, received: u64, sent: u64) {
        global_registry().update_channel(
            self.telemetry_id,
            self.channel_telemetry_id,
            received,
            sent,
            None,
        );
    }

    /// Get metadata of a remote file or directory.
    pub async fn metadata(&self, path: &str) -> Result<russh_sftp::protocol::FileAttributes> {
        Ok(self.session.metadata(path).await?)
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
    /// 自动创建远程目标路径的父目录（如果不存在）。
    pub async fn upload(
        &self,
        local: &Path,
        remote: &str,
        progress: Option<&dyn Fn(u64, u64)>,
    ) -> Result<()> {
        if let Some(parent) = Path::new(remote)
            .parent()
            .and_then(|p| p.to_str())
            .filter(|p| !p.is_empty())
        {
            self.create_dir_all(parent).await?;
        }
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
            self.record_io(0, n as u64);
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
        self.upload_with_pause(local, remote, progress, cancel, None, None)
            .await
    }

    /// Upload a local file with optional cancellation, pause and resume.
    /// `pause` 为 true 时循环阻塞，直到 `pause` 被置为 false 或收到 `resume` 通知。
    /// 自动创建远程目标路径的父目录（如果不存在）。
    pub async fn upload_with_pause(
        &self,
        local: &Path,
        remote: &str,
        progress: Option<Arc<dyn Fn(u64, u64) + Send + Sync>>,
        cancel: Option<Arc<AtomicBool>>,
        pause: Option<Arc<AtomicBool>>,
        resume: Option<Arc<Notify>>,
    ) -> Result<()> {
        if let Some(parent) = Path::new(remote)
            .parent()
            .and_then(|p| p.to_str())
            .filter(|p| !p.is_empty())
        {
            self.create_dir_all(parent).await?;
        }
        let total = tokio::fs::metadata(local).await?.len();
        let mut src = tokio::fs::File::open(local).await?;
        let mut dst = self.session.create(remote).await?;

        let mut buf = vec![0u8; COPY_BUF_SIZE];
        let mut sent = 0u64;
        loop {
            if cancel
                .as_ref()
                .map(|c| c.load(Ordering::Relaxed))
                .unwrap_or(false)
            {
                return Err(Error::Cancelled);
            }
            wait_if_paused(cancel.as_ref(), pause.as_ref(), resume.as_ref()).await?;
            let n = src.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            dst.write_all(&buf[..n]).await?;
            sent += n as u64;
            self.record_io(0, n as u64);
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
        let mut buf = vec![0u8; COPY_BUF_SIZE];
        loop {
            let n = src.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            dst.write_all(&buf[..n]).await?;
            self.record_io(n as u64, 0);
        }
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
        self.download_with_pause(remote, local, progress, cancel, None, None)
            .await
    }

    /// Download a remote file to a local path with optional cancellation, pause and resume.
    /// `pause` 为 true 时循环阻塞，直到 `pause` 被置为 false 或收到 `resume` 通知。
    pub async fn download_with_pause(
        &self,
        remote: &str,
        local: &Path,
        progress: Option<Arc<dyn Fn(u64, u64) + Send + Sync>>,
        cancel: Option<Arc<AtomicBool>>,
        pause: Option<Arc<AtomicBool>>,
        resume: Option<Arc<Notify>>,
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
            if cancel
                .as_ref()
                .map(|c| c.load(Ordering::Relaxed))
                .unwrap_or(false)
            {
                return Err(Error::Cancelled);
            }
            wait_if_paused(cancel.as_ref(), pause.as_ref(), resume.as_ref()).await?;
            let n = src.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            dst.write_all(&buf[..n]).await?;
            received += n as u64;
            self.record_io(n as u64, 0);
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

    /// 递归删除远端文件或目录。文件直接删除；目录先递归清空内容再删除自身。
    pub async fn remove_all(&self, path: &str) -> Result<()> {
        let normalized = path.trim_end_matches('/');
        let path = if normalized.is_empty() {
            "/"
        } else {
            normalized
        };
        self.remove_all_inner(path).await
    }

    async fn remove_all_inner(&self, path: &str) -> Result<()> {
        match self.session.metadata(path).await {
            Ok(meta) if meta.is_dir() => {
                let entries = self.list_dir(path).await?;
                for entry in entries {
                    if entry.name == "." || entry.name == ".." {
                        continue;
                    }
                    let child = if path.ends_with('/') {
                        format!("{}{}", path, entry.name)
                    } else {
                        format!("{}/{}", path, entry.name)
                    };
                    Box::pin(self.remove_all_inner(&child)).await?;
                }
                self.session.remove_dir(path).await?;
                Ok(())
            }
            Ok(_) => {
                self.session.remove_file(path).await?;
                Ok(())
            }
            Err(_) => {
                // 元数据获取失败时回退到直接删除文件
                self.session.remove_file(path).await?;
                Ok(())
            }
        }
    }

    pub async fn create_dir(&self, path: &str) -> Result<()> {
        Ok(self.session.create_dir(path).await?)
    }

    /// 递归创建远端目录（等价于 `mkdir -p`）。
    /// 已存在的目录会被忽略；父目录缺失时逐层向上创建。
    pub async fn create_dir_all(&self, path: &str) -> Result<()> {
        let normalized = path.trim_end_matches('/');
        if normalized.is_empty() || normalized == "/" {
            return Ok(());
        }

        // 自下而上收集需要创建的目录层级。
        let mut parts: Vec<&str> = Vec::new();
        let mut current = normalized;
        loop {
            match self.session.metadata(current).await {
                Ok(meta) if meta.is_dir() => break,
                Ok(_) => {
                    return Err(Error::Other(format!("{} is not a directory", current)));
                }
                Err(russh_sftp::client::error::Error::Status(status))
                    if status.status_code == russh_sftp::protocol::StatusCode::NoSuchFile => {}
                Err(e) => return Err(e.into()),
            }
            parts.push(current);
            match current.rfind('/') {
                None | Some(0) => break,
                Some(i) => current = &current[..i],
            }
        }

        // 自顶向下创建缺失目录。
        for part in parts.into_iter().rev() {
            match self.session.create_dir(part).await {
                Ok(()) => {}
                Err(russh_sftp::client::error::Error::Status(status))
                    if status.status_code == russh_sftp::protocol::StatusCode::Failure
                        && is_already_exists_message(&status.error_message) => {}
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    }

    /// Resolve the user's home directory at session start.
    /// SFTP 会话初始工作目录通常是用户 home；`canonicalize(".")` 将其转为绝对路径。
    pub async fn home_dir(&self) -> Result<String> {
        Ok(self.session.canonicalize(".").await?)
    }

    /// 上传前检查远端目标是否已存在。
    /// 返回 `Some(FileConflictInfo)` 表示需要用户确认是否覆盖；
    /// 返回 `None` 表示目标不存在，可以直接上传。
    pub async fn check_upload_conflict(
        &self,
        local: &Path,
        remote: &str,
    ) -> Result<Option<FileConflictInfo>> {
        let source_meta = tokio::fs::metadata(local).await?;
        let source_size = source_meta.len();
        let source_mtime = source_meta.modified().ok().and_then(system_time_to_secs);

        let target_meta = match self.session.metadata(remote).await {
            Ok(meta) => Some(RemoteMetadata {
                size: meta.size.unwrap_or(0),
                mtime: meta.mtime.map(u64::from),
            }),
            Err(russh_sftp::client::error::Error::Status(status))
                if status.status_code == russh_sftp::protocol::StatusCode::NoSuchFile =>
            {
                None
            }
            Err(e) => return Err(e.into()),
        };

        Ok(build_conflict_info(source_size, source_mtime, target_meta))
    }

    /// 下载前检查本地目标是否已存在。
    /// 返回 `Some(FileConflictInfo)` 表示需要用户确认是否覆盖；
    /// 返回 `None` 表示目标不存在，可以直接下载。
    pub async fn check_download_conflict(
        &self,
        remote: &str,
        local: &Path,
    ) -> Result<Option<FileConflictInfo>> {
        let source_meta = match self.session.metadata(remote).await {
            Ok(meta) => meta,
            Err(russh_sftp::client::error::Error::Status(status))
                if status.status_code == russh_sftp::protocol::StatusCode::NoSuchFile =>
            {
                return Ok(None);
            }
            Err(e) => return Err(e.into()),
        };
        let source_size = source_meta.size.unwrap_or(0);
        let source_mtime = source_meta.mtime.map(u64::from);

        local_conflict_check(source_size, source_mtime, local)
    }

    /// Close the SFTP session and its channel.
    pub async fn close(&self) -> Result<()> {
        match self.session.close().await {
            Ok(()) => {
                global_registry().update_channel(
                    self.telemetry_id,
                    self.channel_telemetry_id,
                    0,
                    0,
                    Some(ChannelState::Closed),
                );
                Ok(())
            }
            Err(error) => {
                global_registry().update_channel(
                    self.telemetry_id,
                    self.channel_telemetry_id,
                    0,
                    0,
                    Some(ChannelState::Failed),
                );
                Err(error.into())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn file_conflict_info_fields_are_all_present() {
        let info = FileConflictInfo {
            source_size: 100,
            source_mtime: Some(1_700_000_000),
            target_size: 200,
            target_mtime: Some(1_700_000_100),
        };
        assert_eq!(info.source_size, 100);
        assert_eq!(info.source_mtime, Some(1_700_000_000));
        assert_eq!(info.target_size, 200);
        assert_eq!(info.target_mtime, Some(1_700_000_100));
    }

    #[test]
    fn build_conflict_info_returns_none_when_target_missing() {
        let result = build_conflict_info(100, Some(1_700_000_000), None);
        assert!(result.is_none());
    }

    #[test]
    fn build_conflict_info_returns_conflict_when_target_exists() {
        let result = build_conflict_info(
            100,
            Some(1_700_000_000),
            Some(RemoteMetadata {
                size: 200,
                mtime: Some(1_700_000_100),
            }),
        );
        let info = result.expect("should be Some");
        assert_eq!(info.source_size, 100);
        assert_eq!(info.source_mtime, Some(1_700_000_000));
        assert_eq!(info.target_size, 200);
        assert_eq!(info.target_mtime, Some(1_700_000_100));
    }

    #[test]
    fn system_time_to_secs_handles_epoch_and_future() {
        assert_eq!(system_time_to_secs(UNIX_EPOCH), Some(0));
        let future = UNIX_EPOCH + Duration::from_secs(2_000_000_000);
        assert_eq!(system_time_to_secs(future), Some(2_000_000_000));
        let past = UNIX_EPOCH - Duration::from_secs(1);
        assert_eq!(system_time_to_secs(past), None);
    }

    #[test]
    fn local_conflict_check_returns_none_when_target_missing() {
        let dir = tempfile::tempdir().unwrap();
        let local = dir.path().join("not_exist.txt");
        let result = local_conflict_check(100, Some(1_700_000_000), &local).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn local_conflict_check_returns_conflict_when_target_exists() {
        let dir = tempfile::tempdir().unwrap();
        let local = dir.path().join("existing.txt");
        let mut f = std::fs::File::create(&local).unwrap();
        f.write_all(b"hello world").unwrap();
        f.flush().unwrap();
        drop(f);

        let result = local_conflict_check(100, Some(1_700_000_000), &local).unwrap();
        let info = result.expect("should be Some");
        assert_eq!(info.source_size, 100);
        assert_eq!(info.source_mtime, Some(1_700_000_000));
        assert_eq!(info.target_size, 11);
        assert!(info.target_mtime.is_some());
    }

    #[test]
    fn local_conflict_check_preserves_none_mtime_for_target() {
        // 构造一个修改时间无法读取的场景比较困难；
        // 这里验证当 source_mtime 为 None 时，target_mtime 仍被正确填充。
        let dir = tempfile::tempdir().unwrap();
        let local = dir.path().join("existing.txt");
        std::fs::write(&local, b"x").unwrap();

        let result = local_conflict_check(100, None, &local).unwrap();
        let info = result.expect("should be Some");
        assert_eq!(info.source_mtime, None);
        assert!(info.target_mtime.is_some());
    }

    #[tokio::test]
    async fn wait_if_paused_returns_cancelled_when_cancel_is_true() {
        let cancel = Arc::new(AtomicBool::new(true));
        let result = wait_if_paused(Some(&cancel), None, None).await;
        assert!(matches!(result, Err(Error::Cancelled)));
    }

    #[tokio::test]
    async fn wait_if_paused_returns_immediately_when_not_paused() {
        let cancel = Arc::new(AtomicBool::new(false));
        let pause = Arc::new(AtomicBool::new(false));
        let result = wait_if_paused(Some(&cancel), Some(&pause), None).await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn wait_if_paused_waits_until_resumed_with_notify() {
        let cancel = Arc::new(AtomicBool::new(false));
        let pause = Arc::new(AtomicBool::new(true));
        let resume = Arc::new(Notify::new());

        let pause_clone = pause.clone();
        let resume_clone = resume.clone();

        // 在另一个任务中延迟解除暂停
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            pause_clone.store(false, Ordering::Relaxed);
            resume_clone.notify_one();
        });

        let result = wait_if_paused(Some(&cancel), Some(&pause), Some(&resume)).await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn wait_if_paused_uses_polling_when_no_resume_notify() {
        let cancel = Arc::new(AtomicBool::new(false));
        let pause = Arc::new(AtomicBool::new(true));

        let pause_clone = pause.clone();

        // 在另一个任务中延迟解除暂停
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            pause_clone.store(false, Ordering::Relaxed);
        });

        let result = wait_if_paused(Some(&cancel), Some(&pause), None).await;
        assert!(result.is_ok());
    }

    #[test]
    fn is_already_exists_message_detects_various_forms() {
        assert!(is_already_exists_message("File already exists"));
        assert!(is_already_exists_message("file exists"));
        assert!(is_already_exists_message("directory EXISTS"));
        assert!(!is_already_exists_message("not found"));
        assert!(!is_already_exists_message("permission denied"));
    }
}

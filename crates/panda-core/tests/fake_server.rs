//! In-process integration tests against a fake SSH/SFTP server built on
//! the russh server API. Covers connect, password auth (success/failure),
//! host-key policy behavior, exec, and basic SFTP operations.

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use panda_core::config::AuthMethod;
use panda_core::telemetry::{global_registry, ChannelKind, ChannelState, HealthState};
use panda_core::{
    execute_batch_download, execute_batch_upload, scan_remote_sources, BatchTransferOptions,
    ConflictResolution, Credentials, Error, HostConfig, KnownHostStatus, KnownHosts, ScanOptions,
    SftpClient, ShellSession, SshSession, UnknownHostKeyPolicy,
};
use russh::keys::{ssh_key::LineEnding, Algorithm, PrivateKey};
use russh::server::{Auth, ChannelOpenHandle, Msg, Server as _, Session};
use russh::{Channel, ChannelId, Pty};
use russh_sftp::protocol::{
    Attrs, Data, File, FileAttributes, Handle, Name, OpenFlags, Status, StatusCode, Version,
};
use tokio::net::TcpListener;
use tokio::sync::{Mutex, Notify};

const USERNAME: &str = "panda";
const PASSWORD: &str = "s3cret";

// ---------------------------------------------------------------------------
// Fake SSH server
// ---------------------------------------------------------------------------

/// Per-connection server state.
struct TestHandler {
    fs: MemFs,
    channels: HashMap<ChannelId, Channel<Msg>>,
    shell_channels: HashSet<ChannelId>,
    reject_sftp: bool,
}

#[derive(Clone, Default)]
struct TestServer {
    fs: MemFs,
    reject_sftp: bool,
}

impl russh::server::Server for TestServer {
    type Handler = TestHandler;

    fn new_client(&mut self, _: Option<SocketAddr>) -> TestHandler {
        TestHandler {
            fs: self.fs.clone(),
            channels: HashMap::new(),
            shell_channels: HashSet::new(),
            reject_sftp: self.reject_sftp,
        }
    }
}

impl russh::server::Handler for TestHandler {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user == USERNAME && password == PASSWORD {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
                partial_success: false,
            })
        }
    }

    async fn channel_open_session(
        &mut self,
        channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.channels.insert(channel.id(), channel);
        reply.accept().await;
        Ok(())
    }

    async fn exec_request(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let command = String::from_utf8_lossy(data);
        session.channel_success(channel)?;
        match command.trim() {
            // Writes both streams and exits non-zero.
            "hello" => {
                session.data(channel, b"hello stdout".to_vec())?;
                session.extended_data(channel, 1, b"hello stderr".to_vec())?;
                session.exit_status_request(channel, 42)?;
                session.close(channel)?;
            }
            // Never finishes: used to test the client-side exec timeout.
            "hang" => {}
            // Sends extended data with ext != 1, which the client should ignore.
            "ext" => {
                session.extended_data(channel, 0, b"ignored ext data".to_vec())?;
                session.data(channel, b"after ext".to_vec())?;
                session.exit_status_request(channel, 0)?;
                session.close(channel)?;
            }
            _ => {
                session.exit_status_request(channel, 0)?;
                session.close(channel)?;
            }
        }
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.shell_channels.insert(channel);
        session.channel_success(channel)?;
        session.data(channel, b"Panda fake shell\n".to_vec())?;
        Ok(())
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        _term: &str,
        _col_width: u32,
        _row_height: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        Ok(())
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if self.shell_channels.contains(&channel) {
            if data.trim_ascii() == b"disconnect" {
                session.disconnect(russh::Disconnect::ByApplication, "fixture disconnect", "")?;
                return Ok(());
            }
            if let Some(status) = data
                .trim_ascii()
                .strip_prefix(b"exit ")
                .and_then(|value| std::str::from_utf8(value).ok())
                .and_then(|value| value.parse::<u32>().ok())
            {
                session.exit_status_request(channel, status)?;
                session.close(channel)?;
                return Ok(());
            }
            if data.trim_ascii() == b"exit" {
                session.data(channel, b"logout\n".to_vec())?;
                session.exit_status_request(channel, 0)?;
                session.close(channel)?;
                return Ok(());
            }
            let echo = format!("echo: {}", String::from_utf8_lossy(data));
            session.data(channel, echo.into_bytes())?;
        }
        Ok(())
    }

    async fn subsystem_request(
        &mut self,
        channel: ChannelId,
        name: &str,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if name == "sftp" && !self.reject_sftp {
            let channel = self.channels.remove(&channel).expect("channel missing");
            session.channel_success(channel.id())?;
            russh_sftp::server::run(channel.into_stream(), self.fs.clone()).await;
        } else {
            // 拒绝方式：确认后先 EOF 再关闭通道。russh 的 ChannelRx 只在收到
            // Eof 时返回 EOF，否则 SftpSession::new 要等到 10s 请求超时。
            session.channel_success(channel)?;
            session.eof(channel)?;
            session.close(channel)?;
        }
        Ok(())
    }
}

/// Start the fake server on a random local port; returns the port.
async fn start_server() -> u16 {
    start_server_with(TestServer::default()).await
}

/// Start a fake server whose SFTP subsystem requests are always rejected.
async fn start_server_rejecting_sftp() -> u16 {
    start_server_with(TestServer {
        reject_sftp: true,
        ..Default::default()
    })
    .await
}

/// Start a fake server, returning the port and the shared in-memory
/// filesystem so tests can inject per-path failures.
async fn start_server_with_fs() -> (u16, MemFs) {
    let fs = MemFs::default();
    let port = start_server_with(TestServer {
        fs: fs.clone(),
        ..Default::default()
    })
    .await;
    (port, fs)
}

async fn start_server_with(server: TestServer) -> u16 {
    let config = Arc::new(russh::server::Config {
        auth_rejection_time: Duration::from_millis(10),
        auth_rejection_time_initial: Some(Duration::from_millis(10)),
        keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap()],
        ..Default::default()
    });
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let mut server = server;
    tokio::spawn(async move { server.run_on_socket(config, &listener).await });
    port
}

// ---------------------------------------------------------------------------
// In-memory SFTP filesystem
// ---------------------------------------------------------------------------

/// Per-path failure injection used to exercise the client's error paths.
#[derive(Clone, Default)]
struct FailRules {
    fail_write: HashSet<String>,
    fail_read: HashSet<String>,
    fail_close: HashSet<String>,
    fail_mkdir: HashSet<String>,
    fail_rmdir: HashSet<String>,
    fail_remove: HashSet<String>,
    no_mtime: HashSet<String>,
}

/// A tiny in-memory filesystem backing the SFTP subsystem: flat maps of
/// file contents and directory paths.
#[derive(Clone, Default)]
struct MemFs {
    files: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    dirs: Arc<Mutex<HashSet<String>>>,
    /// SFTP handle → path it was opened for.
    handles: Arc<Mutex<HashMap<String, String>>>,
    /// Directory handles whose listing was already sent.
    listed: Arc<Mutex<HashSet<String>>>,
    next_handle: Arc<Mutex<u64>>,
    fail: Arc<Mutex<FailRules>>,
}

impl MemFs {
    /// Register a path for which the given operation should fail.
    async fn fail(&self, mut f: impl FnMut(&mut FailRules)) {
        let mut rules = self.fail.lock().await;
        f(&mut rules);
    }
    async fn new_handle(&self, path: &str) -> String {
        let mut next = self.next_handle.lock().await;
        *next += 1;
        let handle = format!("h{}", *next);
        self.handles
            .lock()
            .await
            .insert(handle.clone(), path.to_string());
        handle
    }

    fn ok(id: u32) -> Status {
        Status {
            id,
            status_code: StatusCode::Ok,
            error_message: "Ok".to_string(),
            language_tag: "en-US".to_string(),
        }
    }
}

fn parent_of(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(0) | None => "/".to_string(),
        Some(i) => trimmed[..i].to_string(),
    }
}

fn basename(path: &str) -> String {
    path.trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or(path)
        .to_string()
}

fn attrs_for(size: u64, is_dir: bool) -> FileAttributes {
    attrs_for_with_mtime(size, is_dir, Some(1_700_000_000))
}

fn attrs_for_with_mtime(size: u64, is_dir: bool, mtime: Option<u32>) -> FileAttributes {
    let mut attrs = FileAttributes {
        size: Some(size),
        mtime,
        ..Default::default()
    };
    if is_dir {
        attrs.set_dir(true);
    } else {
        attrs.set_regular(true);
    }
    attrs
}

impl russh_sftp::server::Handler for MemFs {
    type Error = StatusCode;

    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }

    async fn init(
        &mut self,
        _version: u32,
        _extensions: HashMap<String, String>,
    ) -> Result<Version, Self::Error> {
        Ok(Version::new())
    }

    async fn open(
        &mut self,
        id: u32,
        filename: String,
        pflags: OpenFlags,
        _attrs: FileAttributes,
    ) -> Result<Handle, Self::Error> {
        let mut files = self.files.lock().await;
        if pflags.contains(OpenFlags::WRITE) {
            // create/truncate semantics, enough for the tests
            let parent = parent_of(&filename);
            if parent != "/" && !self.dirs.lock().await.contains(&parent) {
                return Err(StatusCode::NoSuchFile);
            }
            files.insert(filename.clone(), Vec::new());
        } else if !files.contains_key(&filename) {
            return Err(StatusCode::NoSuchFile);
        }
        let handle = self.new_handle(&filename).await;
        Ok(Handle { id, handle })
    }

    async fn read(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        len: u32,
    ) -> Result<Data, Self::Error> {
        let path = self
            .handles
            .lock()
            .await
            .get(&handle)
            .cloned()
            .ok_or(StatusCode::Failure)?;
        let files = self.files.lock().await;
        let content = files.get(&path).ok_or(StatusCode::NoSuchFile)?;
        if self.fail.lock().await.fail_read.contains(&path) {
            return Err(StatusCode::Failure);
        }
        let offset = offset as usize;
        if offset >= content.len() {
            return Err(StatusCode::Eof);
        }
        let end = (offset + len as usize).min(content.len());
        Ok(Data {
            id,
            data: content[offset..end].to_vec(),
        })
    }

    async fn write(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, Self::Error> {
        let path = self
            .handles
            .lock()
            .await
            .get(&handle)
            .cloned()
            .ok_or(StatusCode::Failure)?;
        let mut files = self.files.lock().await;
        let content = files.get_mut(&path).ok_or(StatusCode::NoSuchFile)?;
        if self.fail.lock().await.fail_write.contains(&path) {
            return Err(StatusCode::Failure);
        }
        let offset = offset as usize;
        if content.len() < offset + data.len() {
            content.resize(offset + data.len(), 0);
        }
        content[offset..offset + data.len()].copy_from_slice(&data);
        Ok(Self::ok(id))
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, Self::Error> {
        let path = self.handles.lock().await.get(&handle).cloned();
        if let Some(p) = &path {
            if self.fail.lock().await.fail_close.contains(p) {
                return Err(StatusCode::Failure);
            }
        }
        self.handles.lock().await.remove(&handle);
        self.listed.lock().await.remove(&handle);
        Ok(Self::ok(id))
    }

    async fn opendir(&mut self, id: u32, path: String) -> Result<Handle, Self::Error> {
        let normalized = if path.is_empty() {
            "/".to_string()
        } else {
            path
        };
        let is_root = normalized == "/";
        if !is_root && !self.dirs.lock().await.contains(&normalized) {
            return Err(StatusCode::NoSuchFile);
        }
        let handle = self.new_handle(&normalized).await;
        Ok(Handle { id, handle })
    }

    async fn readdir(&mut self, id: u32, handle: String) -> Result<Name, Self::Error> {
        let path = self
            .handles
            .lock()
            .await
            .get(&handle)
            .cloned()
            .ok_or(StatusCode::Failure)?;
        if !self.listed.lock().await.insert(handle.clone()) {
            return Err(StatusCode::Eof);
        }
        let mut entries = Vec::new();
        let fail = self.fail.lock().await;
        for (file, content) in self.files.lock().await.iter() {
            if parent_of(file) == path {
                let attrs = if fail.no_mtime.contains(file) {
                    attrs_for_with_mtime(content.len() as u64, false, None)
                } else {
                    attrs_for(content.len() as u64, false)
                };
                entries.push(File::new(basename(file), attrs));
            }
        }
        for dir in self.dirs.lock().await.iter() {
            if parent_of(dir) == path && *dir != path {
                entries.push(File::new(basename(dir), attrs_for(0, true)));
            }
        }
        Ok(Name { id, files: entries })
    }

    async fn remove(&mut self, id: u32, filename: String) -> Result<Status, Self::Error> {
        if self.fail.lock().await.fail_remove.contains(&filename) {
            return Err(StatusCode::Failure);
        }
        if self.files.lock().await.remove(&filename).is_some() {
            Ok(Self::ok(id))
        } else {
            Err(StatusCode::NoSuchFile)
        }
    }

    async fn mkdir(
        &mut self,
        id: u32,
        path: String,
        _attrs: FileAttributes,
    ) -> Result<Status, Self::Error> {
        if self.fail.lock().await.fail_mkdir.contains(&path) {
            return Err(StatusCode::Failure);
        }
        if self.dirs.lock().await.contains(&path) || path == "/" {
            return Ok(Status {
                id,
                status_code: StatusCode::Failure,
                error_message: "already exists".to_string(),
                language_tag: "en-US".to_string(),
            });
        }
        let parent = parent_of(&path);
        if parent != "/" && !self.dirs.lock().await.contains(&parent) {
            return Err(StatusCode::NoSuchFile);
        }
        self.dirs.lock().await.insert(path);
        Ok(Self::ok(id))
    }

    async fn rmdir(&mut self, id: u32, path: String) -> Result<Status, Self::Error> {
        if self.fail.lock().await.fail_rmdir.contains(&path) {
            return Err(StatusCode::Failure);
        }
        if self.dirs.lock().await.remove(&path) {
            Ok(Self::ok(id))
        } else {
            Err(StatusCode::NoSuchFile)
        }
    }

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        if let Some(content) = self.files.lock().await.get(&path) {
            return Ok(Attrs {
                id,
                attrs: attrs_for(content.len() as u64, false),
            });
        }
        if self.dirs.lock().await.contains(&path) || path == "/" {
            return Ok(Attrs {
                id,
                attrs: attrs_for(0, true),
            });
        }
        Err(StatusCode::NoSuchFile)
    }

    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        self.stat(id, path).await
    }

    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, Self::Error> {
        Ok(Name {
            id,
            files: vec![File::dummy(path)],
        })
    }
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn host_cfg(port: u16) -> HostConfig {
    HostConfig {
        id: "test".into(),
        name: "fake".into(),
        host: "127.0.0.1".into(),
        port,
        username: USERNAME.into(),
        auth: AuthMethod::Password { password_ref: None },
        notes: None,
        group_id: None,
    }
}

async fn connect(port: u16, known_hosts_dir: &Path, password: &str) -> Result<SshSession, Error> {
    let mut known_hosts = KnownHosts::new(known_hosts_dir.join("known_hosts"));
    SshSession::connect(
        &host_cfg(port),
        Credentials::Password(password.to_string()),
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn exec_collects_stdout_stderr_and_exit_status() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();

    let output = session.exec("hello").await.unwrap();
    assert_eq!(output.stdout, b"hello stdout");
    assert_eq!(output.stderr, b"hello stderr");
    assert_eq!(output.exit_status, Some(42));

    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn wrong_password_is_auth_failed() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut config = host_cfg(port);
    config.id = "wrong-password-telemetry-cleanup".into();
    let mut known_hosts = KnownHosts::new(dir.path().join("known_hosts"));
    let result = SshSession::connect(
        &config,
        Credentials::Password("wrong".into()),
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await;
    match result {
        Err(Error::AuthFailed) => {}
        other => panic!("expected AuthFailed, got {:?}", other.map(|_| "session")),
    }
    assert!(
        global_registry()
            .snapshot()
            .iter()
            .all(|record| record.host_id != config.id),
        "认证失败后不得遗留无所有者的遥测记录"
    );
}

#[tokio::test]
async fn reject_policy_reports_unknown_host_key_with_fingerprint() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut known_hosts = KnownHosts::new(dir.path().join("known_hosts"));
    let result = SshSession::connect(
        &host_cfg(port),
        Credentials::Password(PASSWORD.to_string()),
        &mut known_hosts,
        UnknownHostKeyPolicy::Reject,
    )
    .await;
    match result {
        Err(Error::UnknownHostKey {
            host,
            presented,
            fingerprint,
        }) => {
            assert_eq!(host, format!("127.0.0.1:{port}"));
            assert!(presented.starts_with("ssh-ed25519 "), "got: {presented}");
            assert!(fingerprint.starts_with("SHA256:"), "got: {fingerprint}");
        }
        other => panic!(
            "expected UnknownHostKey, got {:?}",
            other.map(|_| "session")
        ),
    }
}

#[tokio::test]
async fn reject_probe_then_accept_stores_presented_key() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut known_hosts = KnownHosts::new(dir.path().join("known_hosts"));

    // 1) Reject 探测未知主机:返回 UnknownHostKey,携带呈现密钥与冒号指纹,
    //    且 known_hosts 不落盘。
    let result = SshSession::connect(
        &host_cfg(port),
        Credentials::Password(PASSWORD.to_string()),
        &mut known_hosts,
        UnknownHostKeyPolicy::Reject,
    )
    .await;
    let (presented, fingerprint) = match result {
        Err(Error::UnknownHostKey {
            presented,
            fingerprint,
            ..
        }) => (presented, fingerprint),
        other => panic!(
            "expected UnknownHostKey, got {:?}",
            other.map(|_| "session")
        ),
    };
    assert!(
        !known_hosts.path().exists(),
        "Reject 探测不得写入 known_hosts"
    );
    assert_eq!(
        known_hosts.status("127.0.0.1", port).unwrap(),
        KnownHostStatus::Unknown
    );

    // 2) 用户确认信任:存储的是探测呈现的密钥(非二次握手获取),
    //    status 变为 Known 且指纹与探测一致。
    known_hosts.accept("127.0.0.1", port, &presented).unwrap();
    match known_hosts.status("127.0.0.1", port).unwrap() {
        KnownHostStatus::Known {
            fingerprint: stored_fp,
            key_type,
        } => {
            assert_eq!(stored_fp, fingerprint);
            assert_eq!(key_type, "ssh-ed25519");
        }
        other => panic!("expected Known, got {other:?}"),
    }

    // 3) 重连:即使仍用 Reject 策略也判定 Match 直接放行。
    let session = SshSession::connect(
        &host_cfg(port),
        Credentials::Password(PASSWORD.to_string()),
        &mut known_hosts,
        UnknownHostKeyPolicy::Reject,
    )
    .await
    .unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn exec_hanging_command_times_out() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();

    let result = session
        .exec_with_timeout("hang", Duration::from_millis(200))
        .await;
    assert!(matches!(result, Err(Error::Timeout)), "got {result:?}");

    // The connection is still usable after the timed-out command.
    let output = session.exec("hello").await.unwrap();
    assert_eq!(output.exit_status, Some(42));
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_list_upload_download_round_trip() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    // Upload a local file.
    let local = dir.path().join("local.txt");
    std::fs::write(&local, b"panda sftp payload").unwrap();
    sftp.upload(&local, "/upload.txt", None).await.unwrap();

    // It shows up in the directory listing.
    let entries = sftp.list_dir("/").await.unwrap();
    let uploaded = entries
        .iter()
        .find(|f| f.name == "upload.txt")
        .expect("uploaded file missing from listing");
    assert!(!uploaded.is_dir);
    assert_eq!(uploaded.size, b"panda sftp payload".len() as u64);

    // Download it back and compare contents.
    let back = dir.path().join("back.txt");
    sftp.download("/upload.txt", &back).await.unwrap();
    assert_eq!(std::fs::read(&back).unwrap(), b"panda sftp payload");

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_mkdir_remove_file_and_rmdir() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    // create_dir → the directory appears in the listing.
    sftp.create_dir("/sub").await.unwrap();
    let entries = sftp.list_dir("/").await.unwrap();
    let sub = entries
        .iter()
        .find(|f| f.name == "sub")
        .expect("created dir missing from listing");
    assert!(sub.is_dir);

    // Upload into it, then remove the file.
    let local = dir.path().join("f.txt");
    std::fs::write(&local, b"data").unwrap();
    sftp.upload(&local, "/sub/f.txt", None).await.unwrap();
    sftp.remove_file("/sub/f.txt").await.unwrap();
    assert!(sftp.list_dir("/sub").await.unwrap().is_empty());

    // remove_dir drops the directory itself.
    sftp.remove_dir("/sub").await.unwrap();
    let entries = sftp.list_dir("/").await.unwrap();
    assert!(entries.iter().all(|f| f.name != "sub"));

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn host_key_mismatch_is_reported() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut known_hosts = KnownHosts::new(dir.path().join("known_hosts"));
    std::fs::write(
        known_hosts.path(),
        format!("[127.0.0.1]:{port} ssh-ed25519 AAAABadKey\n"),
    )
    .unwrap();

    let result = SshSession::connect(
        &host_cfg(port),
        Credentials::Password(PASSWORD.to_string()),
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await;

    match result {
        Err(Error::HostKeyMismatch {
            stored_fingerprint,
            presented_fingerprint,
            ..
        }) => {
            // 存储记录是坏 base64 → 回退为原始字符串;呈现密钥 → 冒号指纹。
            assert!(
                stored_fingerprint.contains("AAAABadKey"),
                "{stored_fingerprint}"
            );
            assert!(
                presented_fingerprint.starts_with("SHA256:"),
                "{presented_fingerprint}"
            );
        }
        other => panic!(
            "expected HostKeyMismatch, got {:?}",
            other.map(|_| "session")
        ),
    }

    // Mismatch 不得覆盖 known_hosts。
    let raw = std::fs::read_to_string(known_hosts.path()).unwrap();
    assert!(raw.contains("AAAABadKey"), "known_hosts 被改动: {raw}");
}

#[tokio::test]
async fn malformed_known_hosts_returns_other_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut known_hosts = KnownHosts::new(dir.path().join("known_hosts"));
    std::fs::write(known_hosts.path(), [0xff, 0xfe, 0xfd]).unwrap();

    let result = SshSession::connect(
        &host_cfg(port),
        Credentials::Password(PASSWORD.to_string()),
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await;

    match result {
        Err(Error::Other(msg)) => assert!(msg.contains("host key check failed"), "{msg}"),
        other => panic!("expected Other, got {:?}", other.map(|_| "session")),
    }
}

#[tokio::test]
async fn accept_and_store_returns_error_when_known_hosts_parent_is_file() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let parent_file = dir.path().join("parent_file");
    std::fs::write(&parent_file, b"not a directory").unwrap();
    let mut known_hosts = KnownHosts::new(parent_file.join("known_hosts"));

    let result = SshSession::connect(
        &host_cfg(port),
        Credentials::Password(PASSWORD.to_string()),
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await;

    match result {
        Err(Error::Other(msg)) => assert!(msg.contains("host key check failed"), "{msg}"),
        other => panic!("expected Other, got {:?}", other.map(|_| "session")),
    }
}

#[tokio::test]
async fn keyfile_auth_with_missing_key_returns_key_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut known_hosts = KnownHosts::new(dir.path().join("known_hosts"));

    let result = SshSession::connect(
        &host_cfg(port),
        Credentials::KeyFile {
            path: dir.path().join("no-such-key"),
            passphrase: None,
        },
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await;

    match result {
        Err(Error::Key(_)) => {}
        other => panic!("expected Key error, got {:?}", other.map(|_| "session")),
    }
}

#[tokio::test]
async fn sftp_upload_progress_reaches_total() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("progress.bin");
    let payload = vec![7u8; 200_000];
    std::fs::write(&local, &payload).unwrap();

    let progress = std::sync::Mutex::new(Vec::<(u64, u64)>::new());
    let cb = |sent: u64, total: u64| {
        progress.lock().unwrap().push((sent, total));
    };

    sftp.upload(&local, "/progress.bin", Some(&cb))
        .await
        .unwrap();

    let events = progress.lock().unwrap();
    assert!(!events.is_empty());
    let (last_sent, last_total) = events[events.len() - 1];
    assert_eq!(last_total, payload.len() as u64);
    assert_eq!(last_sent, last_total);

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_download_missing_file_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("missing.txt");
    assert!(sftp.download("/not-found.txt", &local).await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_list_nonexistent_dir_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    assert!(sftp.list_dir("/no-such-dir").await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_upload_missing_local_file_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("no-such-local.bin");
    assert!(sftp.upload(&local, "/remote.bin", None).await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_upload_directory_as_source_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    // 元数据可读、打开成功，但读取目录内容会失败（EISDIR）。
    assert!(sftp.upload(dir.path(), "/remote.bin", None).await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_upload_creates_missing_parent_dirs() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("local.bin");
    std::fs::write(&local, b"x").unwrap();
    sftp.upload(&local, "/no/dir/f.bin", None).await.unwrap();

    let entries = sftp.list_dir("/no/dir").await.unwrap();
    let file = entries
        .iter()
        .find(|f| f.name == "f.bin")
        .expect("file missing");
    assert!(!file.is_dir);
    assert_eq!(file.size, 1);

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_upload_to_existing_parent_dir_still_works() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir_all("/existing/sub").await.unwrap();

    let local = dir.path().join("local.bin");
    std::fs::write(&local, b"y").unwrap();
    sftp.upload(&local, "/existing/sub/f.bin", None)
        .await
        .unwrap();

    let entries = sftp.list_dir("/existing/sub").await.unwrap();
    let file = entries
        .iter()
        .find(|f| f.name == "f.bin")
        .expect("file missing");
    assert!(!file.is_dir);
    assert_eq!(file.size, 1);

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_remove_file_missing_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    assert!(sftp.remove_file("/no-such-file").await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_remove_dir_missing_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    assert!(sftp.remove_dir("/no-such-dir").await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_download_to_nonexistent_local_dir_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("local.bin");
    std::fs::write(&local, b"payload").unwrap();
    sftp.upload(&local, "/exists.bin", None).await.unwrap();

    let target = dir.path().join("no-such-parent").join("back.bin");
    assert!(sftp.download("/exists.bin", &target).await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn store_failure_when_known_hosts_dir_is_readonly() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let kh_dir = dir.path().join("kh");
    std::fs::create_dir(&kh_dir).unwrap();
    let mut known_hosts = KnownHosts::new(kh_dir.join("known_hosts"));
    // 预置一个可读但未包含该密钥的 known_hosts，使 check() 返回 Unknown；
    // 再把目录设为只读，让 TOFU 的 store() 写入失败。
    std::fs::write(known_hosts.path(), "example.com ssh-ed25519 AAAAOther\n").unwrap();
    let mut perms = std::fs::metadata(&kh_dir).unwrap().permissions();
    perms.set_readonly(true);
    std::fs::set_permissions(&kh_dir, perms).unwrap();

    let result = SshSession::connect(
        &host_cfg(port),
        Credentials::Password(PASSWORD.to_string()),
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await;

    match result {
        Err(Error::Other(msg)) => assert!(msg.contains("host key check failed"), "{msg}"),
        other => panic!("expected Other, got {:?}", other.map(|_| "session")),
    }
}

#[tokio::test]
async fn keyfile_auth_rejected_by_server_returns_auth_failed() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut known_hosts = KnownHosts::new(dir.path().join("known_hosts"));

    // 生成一把真实密钥文件：加载成功、但服务器只允许密码认证，公钥被拒。
    let key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
    let key_path = dir.path().join("id_ed25519");
    key.write_openssh_file(&key_path, LineEnding::LF).unwrap();

    let result = SshSession::connect(
        &host_cfg(port),
        Credentials::KeyFile {
            path: key_path,
            passphrase: None,
        },
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await;

    match result {
        Err(Error::AuthFailed) => {}
        other => panic!("expected AuthFailed, got {:?}", other.map(|_| "session")),
    }
}

#[tokio::test]
async fn sftp_new_fails_when_subsystem_rejected() {
    let port = start_server_rejecting_sftp().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();

    assert!(SftpClient::new(&session).await.is_err());

    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_upload_unreadable_local_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("locked.bin");
    std::fs::write(&local, b"secret").unwrap();
    // 元数据可读，但 open 被拒绝（000 权限，非 root 打不开）。
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&local, std::fs::Permissions::from_mode(0o000)).unwrap();
    }

    assert!(sftp.upload(&local, "/remote.bin", None).await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_upload_write_failure_returns_error() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    fs.fail(|f| {
        f.fail_write.insert("/blocked.bin".into());
    })
    .await;
    let local = dir.path().join("local.bin");
    std::fs::write(&local, b"payload").unwrap();
    assert!(sftp.upload(&local, "/blocked.bin", None).await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_upload_close_failure_returns_error() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    fs.fail(|f| {
        f.fail_close.insert("/closed.bin".into());
    })
    .await;
    let local = dir.path().join("local.bin");
    std::fs::write(&local, b"x").unwrap();
    assert!(sftp.upload(&local, "/closed.bin", None).await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_upload_with_cancel_close_failure_returns_error() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    fs.fail(|f| {
        f.fail_close.insert("/cancel-closed.bin".into());
    })
    .await;
    let local = dir.path().join("local.bin");
    std::fs::write(&local, b"x").unwrap();
    assert!(sftp
        .upload_with_cancel(&local, "/cancel-closed.bin", None, None)
        .await
        .is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_download_read_failure_returns_error() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("local.bin");
    std::fs::write(&local, b"payload").unwrap();
    sftp.upload(&local, "/read-blocked.bin", None)
        .await
        .unwrap();
    fs.fail(|f| {
        f.fail_read.insert("/read-blocked.bin".into());
    })
    .await;

    let back = dir.path().join("back.bin");
    assert!(sftp.download("/read-blocked.bin", &back).await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_create_dir_failure_returns_error() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    fs.fail(|f| {
        f.fail_mkdir.insert("/blocked".into());
    })
    .await;
    assert!(sftp.create_dir("/blocked").await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_create_dir_all_creates_missing_parents() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    // 远端不存在 /remote，create_dir_all 应递归创建 /remote 与 /remote/nested。
    sftp.create_dir_all("/remote/nested").await.unwrap();
    let entries = sftp.list_dir("/remote").await.unwrap();
    assert!(entries.iter().any(|e| e.name == "nested" && e.is_dir));

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_create_dir_all_ignores_existing_directory() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/existing").await.unwrap();
    // 目录已存在时 create_dir_all 应视为成功。
    sftp.create_dir_all("/existing").await.unwrap();
    sftp.create_dir_all("/existing/sub").await.unwrap();
    let entries = sftp.list_dir("/existing").await.unwrap();
    assert!(entries.iter().any(|e| e.name == "sub" && e.is_dir));

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_create_dir_all_fails_when_permission_denied() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    fs.fail(|f| {
        f.fail_mkdir.insert("/blocked/sub".into());
    })
    .await;
    assert!(sftp.create_dir_all("/blocked/sub").await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_remove_file_failure_returns_error() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("f.txt");
    std::fs::write(&local, b"data").unwrap();
    sftp.upload(&local, "/remove-blocked.txt", None)
        .await
        .unwrap();
    fs.fail(|f| {
        f.fail_remove.insert("/remove-blocked.txt".into());
    })
    .await;

    assert!(sftp.remove_file("/remove-blocked.txt").await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_remove_dir_failure_returns_error() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/rmdir-blocked").await.unwrap();
    fs.fail(|f| {
        f.fail_rmdir.insert("/rmdir-blocked".into());
    })
    .await;

    assert!(sftp.remove_dir("/rmdir-blocked").await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn exec_ignores_extended_data_with_non_stderr_extension() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();

    let output = session.exec("ext").await.unwrap();
    assert_eq!(output.stdout, b"after ext");
    assert!(output.stderr.is_empty());
    assert_eq!(output.exit_status, Some(0));

    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn connect_to_refused_port_returns_ssh_error() {
    let dir = tempfile::tempdir().unwrap();
    let mut known_hosts = KnownHosts::new(dir.path().join("known_hosts"));
    // 找一个大概率未被占用的本地端口。
    let result = SshSession::connect(
        &HostConfig {
            id: "x".into(),
            name: "x".into(),
            host: "127.0.0.1".into(),
            port: 1,
            username: USERNAME.into(),
            auth: AuthMethod::Password { password_ref: None },
            notes: None,
            group_id: None,
        },
        Credentials::Password(PASSWORD.to_string()),
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await;
    assert!(
        matches!(result, Err(Error::Ssh(_))),
        "expected Ssh error, got {:?}",
        result.map(|_| "session")
    );
}

#[tokio::test]
async fn shell_session_writes_and_reads_output() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let mut shell = ShellSession::open(Arc::new(session)).await.unwrap();

    // 等待 banner 输出
    tokio::time::sleep(Duration::from_millis(100)).await;
    let banner = shell.read(1024).unwrap();
    assert!(String::from_utf8_lossy(&banner).contains("Panda fake shell"));

    shell.write(b"hello\n").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let out = shell.read(1024).unwrap();
    assert!(String::from_utf8_lossy(&out).contains("echo: hello"));
    shell.resize(120, 40).unwrap();

    shell.close().await.unwrap();
}

#[tokio::test]
async fn shell_close_twice_is_idempotent() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let mut shell = ShellSession::open(Arc::new(session)).await.unwrap();

    shell.close().await.unwrap();
    // 第二次 close:reader 已被 take，应走 else 分支且不 panic。
    let _ = shell.close().await;
}

#[tokio::test]
async fn shell_session_read_write_after_close_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let mut shell = ShellSession::open(Arc::new(session)).await.unwrap();

    shell.close().await.unwrap();
    assert!(matches!(shell.read(1024), Err(Error::ShellSessionClosed)));
    assert!(matches!(shell.write(b"x"), Err(Error::ShellSessionClosed)));
    assert!(matches!(
        shell.resize(80, 24),
        Err(Error::ShellSessionClosed)
    ));
}

#[tokio::test]
async fn shell_session_reports_remote_exit_after_draining_final_output() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let shell = ShellSession::open(Arc::new(session)).await.unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;
    let _ = shell.read(1024).unwrap();

    shell.write(b"exit\n").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;

    assert_eq!(shell.read(1024).unwrap(), b"logout\n");
    assert!(matches!(shell.read(1024), Err(Error::ShellSessionClosed)));
    assert!(matches!(shell.write(b"x"), Err(Error::ShellSessionClosed)));
}

#[tokio::test]
async fn shell_session_reports_nonzero_remote_exit_status() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let shell = ShellSession::open(Arc::new(session)).await.unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;
    let _ = shell.read(1024).unwrap();
    shell.write(b"exit 7\n").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;

    let result = shell.read(1024);
    assert!(matches!(result, Err(Error::ShellExitStatus(7))), "{result:?}");
}

#[tokio::test]
async fn releasing_transport_owner_closes_channels_even_if_client_survives() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();
    sftp.list_dir("/").await.unwrap();
    drop(session);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let result = tokio::time::timeout(Duration::from_secs(2), sftp.list_dir("/")).await;
    assert!(
        matches!(result, Ok(Err(_))),
        "Transport 所有者释放后不能由孤儿通道继续保活"
    );
}

#[tokio::test]
async fn shell_close_does_not_wait_for_space_in_full_input_queue() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let mut shell = ShellSession::open(Arc::new(session)).await.unwrap();
    // 当前线程不让出执行权，确定性填满 64 条输入队列。
    for _ in 0..64 {
        shell.write(b"x").unwrap();
    }
    let result = tokio::time::timeout(Duration::from_secs(1), shell.close()).await;
    assert!(result.is_ok(), "关闭不能依赖已满输入队列中的空消息");
    result.unwrap().unwrap();
}

#[tokio::test]
async fn empty_shell_input_is_not_a_close_signal() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let mut shell = ShellSession::open(Arc::new(session)).await.unwrap();
    shell.write(b"").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    shell.write(b"still-alive\n").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(String::from_utf8_lossy(&shell.read(4096).unwrap()).contains("still-alive"));
    shell.close().await.unwrap();
}

#[tokio::test]
async fn shell_full_queues_report_failure_without_hanging() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let mut shell = ShellSession::open(Arc::new(session)).await.unwrap();
    assert!(shell.read(0).unwrap().is_empty());
    for _ in 0..64 {
        shell.write(b"x").unwrap();
    }
    assert!(matches!(
        shell.write(b"overflow"),
        Err(Error::ShellInputBackpressure)
    ));
    for _ in 0..8 {
        shell.resize(80, 24).unwrap();
    }
    assert!(shell.resize(80, 24).is_err());
    shell.close().await.unwrap();
}

#[tokio::test]
async fn transport_disconnect_is_not_a_normal_shell_exit() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let shell = ShellSession::open(Arc::new(session)).await.unwrap();
    shell.write(b"disconnect\n").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let _ = shell.read(4096);
    assert!(
        matches!(shell.read(4096), Err(Error::Other(_))),
        "Socket 断开不能伪装成 exit"
    );
    assert!(matches!(shell.write(b"x"), Err(Error::Other(_))));
    assert!(matches!(shell.resize(80, 24), Err(Error::Other(_))));
}

#[tokio::test]
async fn independent_shells_survive_exit_retry_and_idle_past_thirty_seconds() {
    let port = start_server().await;
    let first_dir = tempfile::tempdir().unwrap();
    let second_dir = tempfile::tempdir().unwrap();
    let (first, second) = tokio::join!(
        connect(port, first_dir.path(), PASSWORD),
        connect(port, second_dir.path(), PASSWORD)
    );
    let first = Arc::new(first.unwrap());
    let second = Arc::new(second.unwrap());
    assert_ne!(first.telemetry_id(), second.telemetry_id());
    let mut a = ShellSession::open(first.clone()).await.unwrap();
    let mut b = ShellSession::open(second.clone()).await.unwrap();
    a.write(b"exit\n").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let _ = a.read(4096);
    assert!(matches!(a.read(4096), Err(Error::ShellSessionClosed)));
    a.close().await.unwrap();
    drop(a);
    let retry = Arc::new(connect(port, first_dir.path(), PASSWORD).await.unwrap());
    assert_ne!(retry.telemetry_id(), first.telemetry_id());
    let mut c = ShellSession::open(retry.clone()).await.unwrap();
    // 使用真实计时跨过旧 30 秒 inactivity timeout，不能仅验证配置值。
    tokio::time::sleep(Duration::from_secs(32)).await;
    b.write(b"second-alive\n").unwrap();
    c.write(b"retry-alive\n").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(String::from_utf8_lossy(&b.read(4096).unwrap()).contains("second-alive"));
    assert!(String::from_utf8_lossy(&c.read(4096).unwrap()).contains("retry-alive"));
    let snapshots = global_registry().snapshot();
    for id in [second.telemetry_id(), retry.telemetry_id()] {
        let record = snapshots.iter().find(|record| record.id == id).unwrap();
        assert_eq!(record.health_state, HealthState::Healthy);
    }
    b.close().await.unwrap();
    c.close().await.unwrap();
}

#[tokio::test]
async fn sftp_download_progress_reaches_total() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let remote = "/download-progress.bin";
    let payload = vec![9u8; 200_000];
    let local = dir.path().join("download-progress.bin");

    let upload_local = dir.path().join("upload-src.bin");
    std::fs::write(&upload_local, &payload).unwrap();
    sftp.upload(&upload_local, remote, None).await.unwrap();

    let progress = Arc::new(std::sync::Mutex::new(Vec::<u64>::new()));
    let progress_cb = progress.clone();
    let cb = Arc::new(move |received: u64, _total: u64| {
        progress_cb.lock().unwrap().push(received);
    });
    sftp.download_with_cancel(remote, &local, Some(cb), None)
        .await
        .unwrap();

    let events = progress.lock().unwrap();
    assert!(!events.is_empty());
    assert_eq!(events[events.len() - 1], payload.len() as u64);

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_upload_cancel_stops_midway() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("cancel.bin");
    let payload = vec![3u8; 5_000_000];
    std::fs::write(&local, &payload).unwrap();

    let cancel = Arc::new(AtomicBool::new(false));
    let progress = Arc::new(std::sync::Mutex::new(0u64));
    let progress_cb = progress.clone();
    let cb = Arc::new(move |sent: u64, _total: u64| {
        *progress_cb.lock().unwrap() = sent;
    });

    let cancel_clone = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(1)).await;
        cancel_clone.store(true, Ordering::Relaxed);
    });

    let result = sftp
        .upload_with_cancel(&local, "/cancel.bin", Some(cb), Some(cancel))
        .await;
    assert!(
        matches!(result, Err(Error::Cancelled)),
        "expected Cancelled, got {:?}",
        result
    );

    let sent = *progress.lock().unwrap();
    assert!(
        sent < payload.len() as u64,
        "expected partial upload, got {}",
        sent
    );

    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_home_dir_returns_canonicalized_dot() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let home = sftp.home_dir().await.unwrap();
    assert!(!home.is_empty(), "home_dir should return a non-empty path");

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_list_dir_handles_missing_mtime() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("no-mtime.bin");
    std::fs::write(&local, b"data").unwrap();
    sftp.upload(&local, "/no-mtime.bin", None).await.unwrap();
    fs.fail(|f| {
        f.no_mtime.insert("/no-mtime.bin".into());
    })
    .await;

    let entries = sftp.list_dir("/").await.unwrap();
    let entry = entries
        .iter()
        .find(|f| f.name == "no-mtime.bin")
        .expect("file missing from listing");
    assert_eq!(entry.modified, None);

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_download_cancel_stops_midway() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let remote = "/cancel-download.bin";
    let payload = vec![5u8; 5_000_000];
    let upload_local = dir.path().join("upload-src.bin");
    std::fs::write(&upload_local, &payload).unwrap();
    sftp.upload(&upload_local, remote, None).await.unwrap();

    let local = dir.path().join("cancel-download.bin");
    let cancel = Arc::new(AtomicBool::new(false));
    let progress = Arc::new(std::sync::Mutex::new(0u64));
    let progress_cb = progress.clone();
    let cb = Arc::new(move |received: u64, _total: u64| {
        *progress_cb.lock().unwrap() = received;
    });

    let cancel_clone = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(1)).await;
        cancel_clone.store(true, Ordering::Relaxed);
    });

    let result = sftp
        .download_with_cancel(remote, &local, Some(cb), Some(cancel))
        .await;
    assert!(
        matches!(result, Err(Error::Cancelled)),
        "expected Cancelled, got {:?}",
        result
    );

    let received = *progress.lock().unwrap();
    assert!(
        received < payload.len() as u64,
        "expected partial download, got {}",
        received
    );

    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_upload_pause_and_resume_completes() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("pause.bin");
    let payload = vec![7u8; 5_000_000];
    std::fs::write(&local, &payload).unwrap();

    let pause = Arc::new(AtomicBool::new(false));
    let resume = Arc::new(Notify::new());
    let progress = Arc::new(std::sync::Mutex::new(0u64));
    let progress_cb = progress.clone();
    let cb = Arc::new(move |sent: u64, _total: u64| {
        *progress_cb.lock().unwrap() = sent;
    });

    let pause_clone = pause.clone();
    let resume_clone = resume.clone();
    let progress_clone = progress.clone();
    tokio::spawn(async move {
        // 等待进度开始增长后暂停。
        for _ in 0..100 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            if *progress_clone.lock().unwrap() > 0 {
                break;
            }
        }
        pause_clone.store(true, Ordering::Relaxed);
        tokio::time::sleep(Duration::from_millis(200)).await;
        let frozen = *progress_clone.lock().unwrap();
        // 暂停期间进度不应继续增长。
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert_eq!(
            *progress_clone.lock().unwrap(),
            frozen,
            "进度在暂停期间应停止增长"
        );
        pause_clone.store(false, Ordering::Relaxed);
        resume_clone.notify_waiters();
    });

    sftp.upload_with_pause(
        &local,
        "/pause.bin",
        Some(cb),
        None,
        Some(pause),
        Some(resume),
    )
    .await
    .unwrap();

    assert_eq!(*progress.lock().unwrap(), payload.len() as u64);
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn sftp_download_pause_and_resume_completes() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let remote = "/pause-download.bin";
    let payload = vec![9u8; 5_000_000];
    let upload_local = dir.path().join("upload-src.bin");
    std::fs::write(&upload_local, &payload).unwrap();
    sftp.upload(&upload_local, remote, None).await.unwrap();

    let local = dir.path().join("pause-download.bin");
    let pause = Arc::new(AtomicBool::new(false));
    let resume = Arc::new(Notify::new());
    let progress = Arc::new(std::sync::Mutex::new(0u64));
    let progress_cb = progress.clone();
    let cb = Arc::new(move |received: u64, _total: u64| {
        *progress_cb.lock().unwrap() = received;
    });

    let pause_clone = pause.clone();
    let resume_clone = resume.clone();
    let progress_clone = progress.clone();
    tokio::spawn(async move {
        for _ in 0..100 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            if *progress_clone.lock().unwrap() > 0 {
                break;
            }
        }
        pause_clone.store(true, Ordering::Relaxed);
        tokio::time::sleep(Duration::from_millis(200)).await;
        let frozen = *progress_clone.lock().unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert_eq!(
            *progress_clone.lock().unwrap(),
            frozen,
            "进度在暂停期间应停止增长"
        );
        pause_clone.store(false, Ordering::Relaxed);
        resume_clone.notify_waiters();
    });

    sftp.download_with_pause(remote, &local, Some(cb), None, Some(pause), Some(resume))
        .await
        .unwrap();

    assert_eq!(*progress.lock().unwrap(), payload.len() as u64);
    session.disconnect().await.unwrap();
}

// ---------------------------------------------------------------------------
// Batch scan tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn batch_scan_remote_directory_recursively() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/project").await.unwrap();
    sftp.create_dir("/project/src").await.unwrap();
    let readme = dir.path().join("README.md");
    std::fs::write(&readme, b"readme").unwrap();
    let main_swift = dir.path().join("main.swift");
    std::fs::write(&main_swift, b"code").unwrap();
    sftp.upload(&readme, "/project/README.md", None)
        .await
        .unwrap();
    sftp.upload(&main_swift, "/project/src/main.swift", None)
        .await
        .unwrap();

    let plan = scan_remote_sources(
        &sftp,
        &["/project".to_string()],
        "/local",
        &ScanOptions::default(),
    )
    .await
    .unwrap();

    let destinations: Vec<_> = plan.items.iter().map(|i| i.destination.clone()).collect();
    assert!(destinations.contains(&"/local/project".to_string()));
    assert!(destinations.contains(&"/local/project/README.md".to_string()));
    assert!(destinations.contains(&"/local/project/src".to_string()));
    assert!(destinations.contains(&"/local/project/src/main.swift".to_string()));

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_scan_remote_multiple_sources() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let a = dir.path().join("a.txt");
    std::fs::write(&a, b"a").unwrap();
    sftp.upload(&a, "/a.txt", None).await.unwrap();

    sftp.create_dir("/folder").await.unwrap();
    let b = dir.path().join("b.txt");
    std::fs::write(&b, b"bb").unwrap();
    sftp.upload(&b, "/folder/b.txt", None).await.unwrap();

    let plan = scan_remote_sources(
        &sftp,
        &["/a.txt".to_string(), "/folder".to_string()],
        "/local",
        &ScanOptions::default(),
    )
    .await
    .unwrap();

    let destinations: Vec<_> = plan.items.iter().map(|i| i.destination.clone()).collect();
    assert!(destinations.contains(&"/local/a.txt".to_string()));
    assert!(destinations.contains(&"/local/folder".to_string()));
    assert!(destinations.contains(&"/local/folder/b.txt".to_string()));

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_scan_remote_empty_directory() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/empty").await.unwrap();
    let plan = scan_remote_sources(
        &sftp,
        &["/empty".to_string()],
        "/local",
        &ScanOptions::default(),
    )
    .await
    .unwrap();

    assert_eq!(plan.items.len(), 1);
    assert_eq!(plan.items[0].destination, "/local/empty");
    assert!(plan.items[0].is_dir);

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_scan_remote_respects_max_depth() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/d1").await.unwrap();
    sftp.create_dir("/d1/d2").await.unwrap();
    sftp.create_dir("/d1/d2/d3").await.unwrap();
    let deep = dir.path().join("deep.txt");
    std::fs::write(&deep, b"deep").unwrap();
    sftp.upload(&deep, "/d1/d2/d3/deep.txt", None)
        .await
        .unwrap();

    let opts = ScanOptions {
        max_depth: 2,
        ..Default::default()
    };
    let result = scan_remote_sources(&sftp, &["/d1".to_string()], "/local", &opts).await;
    assert!(result.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_upload_directory_recursively() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    // 预先创建目标父目录，保持该测试继续验证"目标父目录已存在"场景。
    sftp.create_dir("/remote").await.unwrap();

    let src = dir.path().join("project");
    tokio::fs::create_dir(&src).await.unwrap();
    tokio::fs::write(src.join("README.md"), b"readme")
        .await
        .unwrap();
    let sub = src.join("src");
    tokio::fs::create_dir(&sub).await.unwrap();
    tokio::fs::write(sub.join("main.swift"), b"code")
        .await
        .unwrap();

    let plan = panda_core::scan_local_sources(&[src.clone()], "/remote", &ScanOptions::default())
        .await
        .unwrap();
    let options = BatchTransferOptions::default();
    let outcome = execute_batch_upload(&sftp, &plan, &options, None, None, None)
        .await
        .unwrap();

    assert!(!outcome.cancelled);
    assert!(outcome.errors.is_empty());
    assert_eq!(outcome.completed.len(), 2);

    let entries = sftp.list_dir("/remote/project").await.unwrap();
    assert!(entries.iter().any(|e| e.name == "README.md"));
    let src_entries = sftp.list_dir("/remote/project/src").await.unwrap();
    assert!(src_entries.iter().any(|e| e.name == "main.swift"));

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_upload_skips_conflict_when_callback_returns_skip() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/remote").await.unwrap();
    let existing = dir.path().join("existing.txt");
    tokio::fs::write(&existing, b"old").await.unwrap();
    sftp.upload(&existing, "/remote/existing.txt", None)
        .await
        .unwrap();

    let local = dir.path().join("existing.txt");
    tokio::fs::write(&local, b"new").await.unwrap();

    let plan = panda_core::scan_local_sources(&[local.clone()], "/remote", &ScanOptions::default())
        .await
        .unwrap();
    let options = BatchTransferOptions::default();
    let conflict_cb = Arc::new(
        |_item: &panda_core::BatchItem, _info: &panda_core::FileConflictInfo| {
            ConflictResolution::Skip
        },
    );
    let outcome = execute_batch_upload(&sftp, &plan, &options, Some(conflict_cb), None, None)
        .await
        .unwrap();

    assert_eq!(outcome.skipped.len(), 1);
    assert!(outcome.completed.is_empty());

    // 远程内容应保持不变。
    let back = dir.path().join("back.txt");
    sftp.download("/remote/existing.txt", &back).await.unwrap();
    assert_eq!(std::fs::read(&back).unwrap(), b"old");

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_upload_error_isolation_continues_by_default() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/remote").await.unwrap();
    let a = dir.path().join("a.txt");
    let b = dir.path().join("b.txt");
    tokio::fs::write(&a, b"a").await.unwrap();
    tokio::fs::write(&b, b"bb").await.unwrap();

    let plan =
        panda_core::scan_local_sources(&[a.clone(), b.clone()], "/remote", &ScanOptions::default())
            .await
            .unwrap();

    // 让 b.txt 上传失败。
    fs.fail(|f| {
        f.fail_write.insert("/remote/b.txt".into());
    })
    .await;

    let options = BatchTransferOptions::default();
    let outcome = execute_batch_upload(&sftp, &plan, &options, None, None, None)
        .await
        .unwrap();

    assert_eq!(outcome.completed.len(), 1);
    assert_eq!(outcome.errors.len(), 1);
    assert!(outcome.errors[0].contains("b.txt"));

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_upload_stop_on_error_halts_on_first_failure() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/remote").await.unwrap();
    let a = dir.path().join("a.txt");
    let b = dir.path().join("b.txt");
    tokio::fs::write(&a, b"a").await.unwrap();
    tokio::fs::write(&b, b"bb").await.unwrap();

    let plan =
        panda_core::scan_local_sources(&[a.clone(), b.clone()], "/remote", &ScanOptions::default())
            .await
            .unwrap();

    fs.fail(|f| {
        f.fail_write.insert("/remote/a.txt".into());
    })
    .await;

    let options = BatchTransferOptions {
        stop_on_error: true,
    };
    let result = execute_batch_upload(&sftp, &plan, &options, None, None, None).await;
    assert!(result.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_upload_creates_missing_remote_parent() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let src = dir.path().join("project");
    tokio::fs::create_dir(&src).await.unwrap();
    tokio::fs::write(src.join("README.md"), b"readme")
        .await
        .unwrap();

    // 远端 /remote 不存在，execute_batch_upload 应递归创建并上传成功。
    let plan = panda_core::scan_local_sources(&[src.clone()], "/remote", &ScanOptions::default())
        .await
        .unwrap();
    let options = BatchTransferOptions::default();
    let outcome = execute_batch_upload(&sftp, &plan, &options, None, None, None)
        .await
        .unwrap();

    assert!(
        outcome.errors.is_empty(),
        "unexpected errors: {:?}",
        outcome.errors
    );
    assert_eq!(outcome.completed.len(), 1);
    let entries = sftp.list_dir("/remote/project").await.unwrap();
    assert!(entries.iter().any(|e| e.name == "README.md"));

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_upload_ignores_existing_remote_directory() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/remote").await.unwrap();
    sftp.create_dir("/remote/project").await.unwrap();

    let src = dir.path().join("project");
    tokio::fs::create_dir(&src).await.unwrap();
    tokio::fs::write(src.join("README.md"), b"readme")
        .await
        .unwrap();

    let plan = panda_core::scan_local_sources(&[src.clone()], "/remote", &ScanOptions::default())
        .await
        .unwrap();
    let options = BatchTransferOptions::default();
    let outcome = execute_batch_upload(&sftp, &plan, &options, None, None, None)
        .await
        .unwrap();

    assert!(
        outcome.errors.is_empty(),
        "unexpected errors: {:?}",
        outcome.errors
    );
    assert_eq!(outcome.completed.len(), 1);

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_upload_error_includes_source_and_destination() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    // 让远端目录创建失败，验证错误信息同时包含源路径与目标路径。
    fs.fail(|f| {
        f.fail_mkdir.insert("/remote/project".into());
    })
    .await;

    let src = dir.path().join("project");
    tokio::fs::create_dir(&src).await.unwrap();
    tokio::fs::write(src.join("README.md"), b"readme")
        .await
        .unwrap();

    let plan = panda_core::scan_local_sources(&[src.clone()], "/remote", &ScanOptions::default())
        .await
        .unwrap();
    let options = BatchTransferOptions::default();
    let outcome = execute_batch_upload(&sftp, &plan, &options, None, None, None)
        .await
        .unwrap();

    // 目录创建失败会导致其下文件上传也失败，因此错误数 >= 1。
    assert!(!outcome.errors.is_empty());
    let dir_error = outcome
        .errors
        .iter()
        .find(|e| e.contains("/remote/project") && !e.contains("README.md"))
        .expect("should have directory creation error");
    assert!(
        dir_error.contains(&src.to_string_lossy().to_string()),
        "error should contain source path: {}",
        dir_error
    );

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_download_directory_recursively() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/project").await.unwrap();
    sftp.create_dir("/project/src").await.unwrap();
    let readme = dir.path().join("README.md");
    std::fs::write(&readme, b"readme").unwrap();
    let main_swift = dir.path().join("main.swift");
    std::fs::write(&main_swift, b"code").unwrap();
    sftp.upload(&readme, "/project/README.md", None)
        .await
        .unwrap();
    sftp.upload(&main_swift, "/project/src/main.swift", None)
        .await
        .unwrap();

    let local_dest = dir.path().join("local");
    let plan = scan_remote_sources(
        &sftp,
        &["/project".to_string()],
        local_dest.to_str().unwrap(),
        &ScanOptions::default(),
    )
    .await
    .unwrap();
    let options = BatchTransferOptions::default();
    let outcome = execute_batch_download(&sftp, &plan, &options, None, None, None)
        .await
        .unwrap();

    assert!(!outcome.cancelled);
    assert!(
        outcome.errors.is_empty(),
        "unexpected errors: {:?}",
        outcome.errors
    );
    assert_eq!(outcome.completed.len(), 2);

    assert!(local_dest.join("project").is_dir());
    assert_eq!(
        std::fs::read(local_dest.join("project/README.md")).unwrap(),
        b"readme"
    );
    assert_eq!(
        std::fs::read(local_dest.join("project/src/main.swift")).unwrap(),
        b"code"
    );

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_download_skips_conflict_when_callback_returns_skip() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/remote").await.unwrap();
    let remote = dir.path().join("existing.txt");
    std::fs::write(&remote, b"remote").unwrap();
    sftp.upload(&remote, "/remote/existing.txt", None)
        .await
        .unwrap();

    let local = dir.path().join("existing.txt");
    std::fs::write(&local, b"local").unwrap();

    let plan = scan_remote_sources(
        &sftp,
        &["/remote/existing.txt".to_string()],
        dir.path().to_str().unwrap(),
        &ScanOptions::default(),
    )
    .await
    .unwrap();
    let options = BatchTransferOptions::default();
    let conflict_cb = Arc::new(
        |_item: &panda_core::BatchItem, _info: &panda_core::FileConflictInfo| {
            ConflictResolution::Skip
        },
    );
    let outcome = execute_batch_download(&sftp, &plan, &options, Some(conflict_cb), None, None)
        .await
        .unwrap();

    assert_eq!(outcome.skipped.len(), 1);
    assert!(outcome.completed.is_empty());
    assert_eq!(std::fs::read(&local).unwrap(), b"local");

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_download_error_includes_source_and_destination() {
    let (port, fs) = start_server_with_fs().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/remote").await.unwrap();
    let remote_file = dir.path().join("blocked.txt");
    std::fs::write(&remote_file, b"secret").unwrap();
    sftp.upload(&remote_file, "/remote/blocked.txt", None)
        .await
        .unwrap();

    fs.fail(|f| {
        f.fail_read.insert("/remote/blocked.txt".into());
    })
    .await;

    let plan = scan_remote_sources(
        &sftp,
        &["/remote/blocked.txt".to_string()],
        dir.path().to_str().unwrap(),
        &ScanOptions::default(),
    )
    .await
    .unwrap();
    let options = BatchTransferOptions::default();
    let outcome = execute_batch_download(&sftp, &plan, &options, None, None, None)
        .await
        .unwrap();

    assert_eq!(outcome.errors.len(), 1);
    let error = &outcome.errors[0];
    assert!(
        error.contains("/remote/blocked.txt"),
        "error should contain remote source path: {}",
        error
    );
    assert!(
        error.contains(&dir.path().join("blocked.txt").to_string_lossy().to_string()),
        "error should contain local destination path: {}",
        error
    );

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn batch_download_dir_creation_error_includes_paths() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    sftp.create_dir("/remote").await.unwrap();
    sftp.create_dir("/remote/project").await.unwrap();

    let plan = scan_remote_sources(
        &sftp,
        &["/remote/project".to_string()],
        dir.path().to_str().unwrap(),
        &ScanOptions::default(),
    )
    .await
    .unwrap();

    // 在本地目标路径上创建一个文件，使 create_dir_all 因"路径已存在且不是目录"失败。
    let blocking = dir.path().join("project");
    std::fs::write(&blocking, b"not a dir").unwrap();

    let options = BatchTransferOptions::default();
    let outcome = execute_batch_download(&sftp, &plan, &options, None, None, None)
        .await
        .unwrap();

    assert_eq!(outcome.errors.len(), 1);
    let error = &outcome.errors[0];
    assert!(
        error.contains("/remote/project"),
        "error should contain remote source path: {}",
        error
    );
    assert!(
        error.contains(&blocking.to_string_lossy().to_string()),
        "error should contain local destination path: {}",
        error
    );

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn telemetry_tracks_real_socket_exec_shell_and_sftp_traffic() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = Arc::new(connect(port, dir.path(), PASSWORD).await.unwrap());
    let telemetry_id = session.telemetry_id();

    session.exec("hello").await.unwrap();
    let mut shell = ShellSession::open(Arc::clone(&session)).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();
    let local = dir.path().join("telemetry.txt");
    std::fs::write(&local, b"telemetry payload").unwrap();
    sftp.upload(&local, "/telemetry.txt", None).await.unwrap();
    shell.write(b"hello\n").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;

    let snapshot = global_registry()
        .snapshot()
        .into_iter()
        .find(|record| record.id == telemetry_id)
        .unwrap();
    assert!(snapshot.received_bytes > 0);
    assert!(snapshot.sent_bytes > 0);
    assert!(snapshot.channels.iter().any(|channel| {
        channel.kind == ChannelKind::Exec
            && channel.state == ChannelState::Closed
            && channel.received_bytes > 0
    }));
    assert!(snapshot.channels.iter().any(|channel| {
        channel.kind == ChannelKind::Shell
            && channel.state == ChannelState::Open
            && channel.sent_bytes >= 6
    }));
    assert!(snapshot.channels.iter().any(|channel| {
        channel.kind == ChannelKind::Sftp
            && channel.state == ChannelState::Open
            && channel.sent_bytes == 17
    }));

    shell.close().await.unwrap();
    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn health_check_uses_existing_connection_is_throttled_and_never_reconnects() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let mut known_hosts = KnownHosts::new(dir.path().join("known_hosts"));
    let session = SshSession::connect_shared(
        &host_cfg(port),
        Credentials::Password(PASSWORD.to_string()),
        &mut known_hosts,
        UnknownHostKeyPolicy::AcceptAndStore,
    )
    .await
    .unwrap();
    let telemetry_id = session.telemetry_id();

    assert_eq!(
        panda_core::connection_registry::global_registry()
            .check_health(telemetry_id)
            .await
            .unwrap(),
        HealthState::Healthy
    );
    let first_checked_at = global_registry()
        .snapshot()
        .into_iter()
        .find(|record| record.id == telemetry_id)
        .unwrap()
        .last_health_check_at_ms;
    assert_eq!(
        panda_core::connection_registry::global_registry()
            .check_health(telemetry_id)
            .await
            .unwrap(),
        HealthState::Healthy
    );
    let second_checked_at = global_registry()
        .snapshot()
        .into_iter()
        .find(|record| record.id == telemetry_id)
        .unwrap()
        .last_health_check_at_ms;
    assert_eq!(first_checked_at, second_checked_at);
    let (concurrent_a, concurrent_b) = tokio::join!(
        panda_core::connection_registry::global_registry().check_health(telemetry_id),
        panda_core::connection_registry::global_registry().check_health(telemetry_id)
    );
    assert_eq!(concurrent_a.unwrap(), HealthState::Healthy);
    assert_eq!(concurrent_b.unwrap(), HealthState::Healthy);
    session.disconnect().await.unwrap();
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(
        panda_core::connection_registry::global_registry()
            .check_health(telemetry_id)
            .await
            .unwrap(),
        HealthState::Unavailable
    );
}

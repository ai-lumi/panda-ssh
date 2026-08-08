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
use panda_core::{
    Credentials, Error, HostConfig, KnownHostStatus, KnownHosts, SftpClient, ShellSession,
    SshSession, UnknownHostKeyPolicy,
};
use russh::keys::{Algorithm, PrivateKey, ssh_key::LineEnding};
use russh::server::{Auth, ChannelOpenHandle, Msg, Server as _, Session};
use russh::{Channel, ChannelId};
use russh_sftp::protocol::{
    Data, File, FileAttributes, Handle, Name, OpenFlags, Status, StatusCode, Version,
};
use tokio::net::TcpListener;
use tokio::sync::Mutex;

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

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if self.shell_channels.contains(&channel) {
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
    let mut attrs = FileAttributes {
        size: Some(size),
        mtime: Some(1_700_000_000),
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
        let normalized = if path.is_empty() { "/".to_string() } else { path };
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
        for (file, content) in self.files.lock().await.iter() {
            if parent_of(file) == path {
                entries.push(File::new(
                    basename(file),
                    attrs_for(content.len() as u64, false),
                ));
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
        self.dirs.lock().await.insert(path);
        Ok(Self::ok(id))
    }

    async fn rmdir(&mut self, id: u32, path: String) -> Result<Status, Self::Error> {
        if self.dirs.lock().await.remove(&path) {
            Ok(Self::ok(id))
        } else {
            Err(StatusCode::NoSuchFile)
        }
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
    let result = connect(port, dir.path(), "wrong").await;
    match result {
        Err(Error::AuthFailed) => {}
        other => panic!("expected AuthFailed, got {:?}", other.map(|_| "session")),
    }
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
        other => panic!("expected UnknownHostKey, got {:?}", other.map(|_| "session")),
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
    assert!(!known_hosts.path().exists(), "Reject 探测不得写入 known_hosts");
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
            assert!(stored_fingerprint.contains("AAAABadKey"), "{stored_fingerprint}");
            assert!(
                presented_fingerprint.starts_with("SHA256:"),
                "{presented_fingerprint}"
            );
        }
        other => panic!("expected HostKeyMismatch, got {:?}", other.map(|_| "session")),
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

    sftp.upload(&local, "/progress.bin", Some(&cb)).await.unwrap();

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
async fn sftp_upload_to_nonexistent_parent_dir_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let sftp = SftpClient::new(&session).await.unwrap();

    let local = dir.path().join("local.bin");
    std::fs::write(&local, b"x").unwrap();
    assert!(sftp.upload(&local, "/no/dir/f.bin", None).await.is_err());

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

    fs.fail(|f| { f.fail_write.insert("/blocked.bin".into()); })
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

    fs.fail(|f| { f.fail_close.insert("/closed.bin".into()); })
        .await;
    let local = dir.path().join("local.bin");
    std::fs::write(&local, b"x").unwrap();
    assert!(sftp.upload(&local, "/closed.bin", None).await.is_err());

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
    fs.fail(|f| { f.fail_read.insert("/read-blocked.bin".into()); })
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

    fs.fail(|f| { f.fail_mkdir.insert("/blocked".into()); }).await;
    assert!(sftp.create_dir("/blocked").await.is_err());

    sftp.close().await.unwrap();
    session.disconnect().await.unwrap();
}

#[tokio::test]
async fn shell_session_writes_and_reads_output() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let mut shell = ShellSession::open(session).await.unwrap();

    // 等待 banner 输出
    tokio::time::sleep(Duration::from_millis(100)).await;
    let banner = shell.read(1024).unwrap();
    assert!(String::from_utf8_lossy(&banner).contains("Panda fake shell"));

    shell.write(b"hello\n").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let out = shell.read(1024).unwrap();
    assert!(String::from_utf8_lossy(&out).contains("echo: hello"));

    shell.close().await.unwrap();
}

#[tokio::test]
async fn shell_session_read_write_after_close_returns_error() {
    let port = start_server().await;
    let dir = tempfile::tempdir().unwrap();
    let session = connect(port, dir.path(), PASSWORD).await.unwrap();
    let mut shell = ShellSession::open(session).await.unwrap();

    shell.close().await.unwrap();
    assert!(matches!(shell.read(1024), Err(Error::ShellSessionClosed)));
    assert!(matches!(shell.write(b"x"), Err(Error::ShellSessionClosed)));
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
    assert!(sent < payload.len() as u64, "expected partial upload, got {}", sent);

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

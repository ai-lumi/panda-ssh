use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use panda_ffi::{
    accept_unknown_host_key, delete_host, host_key_status, init_store, list_hosts, save_host,
    sftp_create_dir, sftp_download, sftp_list, sftp_remove_dir, sftp_remove_file, sftp_upload,
    shell_close, shell_open, shell_read, shell_write, start_transfer, test_connection,
    transfer_cancel, transfer_list, transfer_retry, transfer_status, AuthMethodEnum,
    HostConfigRecord, KnownHostStatusEnum, PandaError, TransferDirectionEnum, TransferStatusEnum,
};
use russh::keys::{Algorithm, PrivateKey};
use russh::server::{Auth, ChannelOpenHandle, Msg, Server as _, Session};
use russh::{Channel, ChannelId};
use russh_sftp::protocol::{
    Data, File, FileAttributes, Handle, Name, OpenFlags, Status, StatusCode, Version,
};
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use uuid::Uuid;

static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

const USERNAME: &str = "panda";
const PASSWORD: &str = "s3cret";

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
        _data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        session.exit_status_request(channel, 0)?;
        session.close(channel)?;
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
            session.channel_failure(channel)?;
        }
        Ok(())
    }
}

fn start_server() -> u16 {
    start_server_with(TestServer::default())
}

/// Start a server whose SFTP subsystem requests are always rejected.
fn start_server_rejecting_sftp() -> u16 {
    start_server_with(TestServer {
        reject_sftp: true,
        ..Default::default()
    })
}

fn start_server_with(server: TestServer) -> u16 {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async move {
            let config = Arc::new(russh::server::Config {
                auth_rejection_time: Duration::from_millis(10),
                auth_rejection_time_initial: Some(Duration::from_millis(10)),
                keys: vec![PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap()],
                ..Default::default()
            });
            let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
            let port = listener.local_addr().unwrap().port();
            tx.send(port).unwrap();
            let mut server = server;
            let _ = server.run_on_socket(config, &listener).await;
        });
    });
    rx.recv().unwrap()
}

fn ensure_store_and_clear_hosts() {
    let dir = std::env::temp_dir().join("panda-ffi-integration-store");
    // 每个测试从全新 store 目录开始,避免上次测试的 hosts/groups/known_hosts 残留。
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    init_store(dir.to_string_lossy().into_owned()).unwrap();
}

/// 测试结束后清理集成测试 store 目录,避免在 /tmp 留下 hosts.toml/groups.toml/known_hosts。
fn cleanup_store() {
    let dir = std::env::temp_dir().join("panda-ffi-integration-store");
    let _ = std::fs::remove_dir_all(&dir);
}

#[derive(Clone, Default)]
struct MemFs {
    files: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    dirs: Arc<Mutex<HashSet<String>>>,
    handles: Arc<Mutex<HashMap<String, String>>>,
    listed: Arc<Mutex<HashSet<String>>>,
    next_handle: Arc<Mutex<u64>>,
}

impl MemFs {
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
        let offset = offset as usize;
        if content.len() < offset + data.len() {
            content.resize(offset + data.len(), 0);
        }
        content[offset..offset + data.len()].copy_from_slice(&data);
        Ok(Self::ok(id))
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, Self::Error> {
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

/// 完整 TOFU 流程:未知主机 → Reject 探测取指纹(不落盘)→ 信任存储呈现密钥
/// → 状态变 Known → 重连直接放行;非法密钥的 accept 报错。
#[test]
fn ffi_tofu_probe_accept_and_reconnect() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let port = start_server();
    save_host(HostConfigRecord {
        id: String::new(),
        name: "tofu".into(),
        host: "127.0.0.1".into(),
        port,
        username: USERNAME.into(),
        auth: AuthMethodEnum::Password {
            password_ref: Some("kc://tofu".into()),
        },
        notes: None,
        group_id: None,
    })
    .unwrap();
    let host = list_hosts()
        .unwrap()
        .into_iter()
        .find(|h| h.name == "tofu")
        .unwrap();

    // 未知主机:status 为 Unknown。
    assert!(matches!(
        host_key_status("127.0.0.1".into(), port).unwrap(),
        KnownHostStatusEnum::Unknown
    ));

    // trust_on_first_use=false 探测:UnknownHostKey 携带呈现密钥与冒号指纹,
    // 且 known_hosts 不落盘。
    let err = test_connection(host.id.clone(), Some(PASSWORD.into()), None, false).unwrap_err();
    let (presented, fingerprint) = match err {
        PandaError::UnknownHostKey {
            presented,
            fingerprint,
            ..
        } => (presented, fingerprint),
        other => panic!("expected UnknownHostKey, got {other}"),
    };
    assert!(presented.starts_with("ssh-ed25519 "), "got: {presented}");
    assert!(fingerprint.starts_with("SHA256:"), "got: {fingerprint}");
    assert!(matches!(
        host_key_status("127.0.0.1".into(), port).unwrap(),
        KnownHostStatusEnum::Unknown
    ));

    // 非法密钥的 accept 报错且不落盘。
    assert!(accept_unknown_host_key("127.0.0.1".into(), port, "garbage".into()).is_err());
    assert!(matches!(
        host_key_status("127.0.0.1".into(), port).unwrap(),
        KnownHostStatusEnum::Unknown
    ));

    // 信任:存储探测呈现的密钥 → status 变为 Known,指纹与探测一致。
    accept_unknown_host_key("127.0.0.1".into(), port, presented).unwrap();
    match host_key_status("127.0.0.1".into(), port).unwrap() {
        KnownHostStatusEnum::Known {
            fingerprint: stored_fp,
            key_type,
        } => {
            assert_eq!(stored_fp, fingerprint);
            assert_eq!(key_type, "ssh-ed25519");
        }
        other => panic!("expected Known, got {other:?}"),
    }

    // 重连:即使 trust_on_first_use=false 也判定 Match 直接放行。
    let msg = test_connection(host.id.clone(), Some(PASSWORD.into()), None, false).unwrap();
    assert!(msg.contains("connected to"));

    delete_host(host.id).unwrap();
    cleanup_store();
}

/// 已记录主机密钥被替换:trust_on_first_use 无论真假都必须拒绝,
/// 错误携带已存储与呈现两个指纹,known_hosts 不被覆盖。
#[test]
fn ffi_host_key_mismatch_is_rejected_with_fingerprints() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let port = start_server();
    // 预置一条错误的密钥记录(合法 base64 但与服务器密钥不同;该端口专属
    // token,不干扰其它测试)。
    let wrong_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChanged";
    let known_hosts_path = std::env::temp_dir()
        .join("panda-ffi-integration-store")
        .join("known_hosts");
    let mut lines = std::fs::read_to_string(&known_hosts_path).unwrap_or_default();
    lines.push_str(&format!("[127.0.0.1]:{port} {wrong_key}\n"));
    std::fs::write(&known_hosts_path, &lines).unwrap();

    save_host(HostConfigRecord {
        id: String::new(),
        name: "mitm".into(),
        host: "127.0.0.1".into(),
        port,
        username: USERNAME.into(),
        auth: AuthMethodEnum::Password {
            password_ref: Some("kc://mitm".into()),
        },
        notes: None,
        group_id: None,
    })
    .unwrap();
    let host = list_hosts()
        .unwrap()
        .into_iter()
        .find(|h| h.name == "mitm")
        .unwrap();

    // 已记录(虽然密钥对不上):status 为 Known。
    assert!(matches!(
        host_key_status("127.0.0.1".into(), port).unwrap(),
        KnownHostStatusEnum::Known { .. }
    ));

    for trust in [false, true] {
        let err = test_connection(host.id.clone(), Some(PASSWORD.into()), None, trust)
            .unwrap_err();
        match err {
            PandaError::HostKeyMismatch {
                stored_fingerprint,
                presented_fingerprint,
            } => {
                assert!(
                    stored_fingerprint.starts_with("SHA256:"),
                    "{stored_fingerprint}"
                );
                assert!(
                    presented_fingerprint.starts_with("SHA256:"),
                    "{presented_fingerprint}"
                );
                assert_ne!(stored_fingerprint, presented_fingerprint);
            }
            other => panic!("expected HostKeyMismatch (trust={trust}), got {other}"),
        }
    }

    // known_hosts 未被覆盖。
    let raw = std::fs::read_to_string(&known_hosts_path).unwrap();
    assert!(raw.contains(wrong_key), "known_hosts 被改动: {raw}");

    delete_host(host.id).unwrap();
    cleanup_store();
}

#[test]
fn ffi_sftp_and_connection_success_paths() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let port = start_server();
    let dir = tempfile::tempdir().unwrap();

    save_host(HostConfigRecord {
        id: String::new(),
        name: "fake".into(),
        host: "127.0.0.1".into(),
        port,
        username: USERNAME.into(),
        auth: AuthMethodEnum::Password {
            password_ref: Some("kc://fake".into()),
        },
        notes: None,
            group_id: None,
    })
    .unwrap();

    let host = list_hosts()
        .unwrap()
        .into_iter()
        .find(|h| h.name == "fake")
        .unwrap();
    let msg = test_connection(host.id.clone(), Some(PASSWORD.into()), None, true).unwrap();
    assert!(msg.contains("connected to"));

    let local = dir.path().join("local.txt");
    std::fs::write(&local, b"ffi payload").unwrap();
    sftp_upload(
        host.id.clone(),
        local.to_string_lossy().into_owned(),
        "/upload.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let listing = sftp_list(host.id.clone(), "/".into(), Some(PASSWORD.into()), None, true).unwrap();
    assert!(listing.iter().any(|f| f.name == "upload.txt"));

    let back = dir.path().join("back.txt");
    sftp_download(
        host.id.clone(),
        "/upload.txt".into(),
        back.to_string_lossy().into_owned(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    assert_eq!(std::fs::read(&back).unwrap(), b"ffi payload");

    sftp_create_dir(
        host.id.clone(),
        "/sub".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_remove_file(
        host.id.clone(),
        "/upload.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_remove_dir(host.id.clone(), "/sub".into(), Some(PASSWORD.into()), None, true).unwrap();

    delete_host(host.id).unwrap();
    cleanup_store();
}

#[test]
fn ffi_error_and_conversion_paths() {
    let _guard = TEST_LOCK.lock().unwrap();

    assert!(matches!(
        PandaError::from(panda_core::Error::AuthFailed),
        PandaError::AuthFailed
    ));
    assert!(matches!(
        PandaError::from(panda_core::Error::Timeout),
        PandaError::Timeout
    ));

    let mismatch: PandaError = panda_core::Error::HostKeyMismatch {
        host: "h:22".into(),
        stored_fingerprint: "SHA256:old".into(),
        presented_fingerprint: "SHA256:new".into(),
    }
    .into();
    let (stored, presented) = match mismatch {
        PandaError::HostKeyMismatch {
            stored_fingerprint,
            presented_fingerprint,
        } => (stored_fingerprint, presented_fingerprint),
        _ => panic!("expected HostKeyMismatch"),
    };
    assert_eq!(stored, "SHA256:old");
    assert_eq!(presented, "SHA256:new");

    let unknown: PandaError = panda_core::Error::UnknownHostKey {
        host: "h:22".into(),
        presented: "ssh-ed25519 AAAA".into(),
        fingerprint: "SHA256:xyz".into(),
    }
    .into();
    let (host, presented_key, fp) = match unknown {
        PandaError::UnknownHostKey {
            host,
            presented,
            fingerprint,
        } => (host, presented, fingerprint),
        _ => panic!("expected UnknownHostKey"),
    };
    assert_eq!(host, "h:22");
    assert_eq!(presented_key, "ssh-ed25519 AAAA");
    assert_eq!(fp, "SHA256:xyz");

    let core: PandaError = panda_core::Error::Other("boom".into()).into();
    let msg = match core {
        PandaError::Core(msg) => msg,
        _ => panic!("expected Core"),
    };
    assert_eq!(msg, "boom");

    let a = AuthMethodEnum::PublicKey {
        key_path: "/tmp/id_ed25519".into(),
        passphrase_ref: Some("kc://p".into()),
    };
    let core_auth: panda_core::AuthMethod = a.into();
    let back: AuthMethodEnum = core_auth.into();
    let (key_path, passphrase_ref) = match back {
        AuthMethodEnum::PublicKey {
            key_path,
            passphrase_ref,
        } => (key_path, passphrase_ref),
        _ => panic!("expected PublicKey"),
    };
    assert_eq!(key_path, "/tmp/id_ed25519");
    assert_eq!(passphrase_ref.as_deref(), Some("kc://p"));

    let e: PandaError = std::io::Error::other("io boom").into();
    let msg = match e {
        PandaError::Core(msg) => msg,
        _ => panic!("expected Core from io error"),
    };
    assert!(msg.contains("io boom"));
}

#[test]
fn ffi_store_and_api_error_paths() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let dir = std::env::temp_dir().join(format!("panda-ffi-test-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    assert!(list_hosts().unwrap().is_empty());

    save_host(HostConfigRecord {
        id: String::new(),
        name: "box".into(),
        host: "example.com".into(),
        port: 22,
        username: "panda".into(),
        auth: AuthMethodEnum::Password { password_ref: None },
        notes: Some("note".into()),
        group_id: None,
    })
    .unwrap();

    let saved = list_hosts().unwrap().into_iter().next().unwrap();
    assert!(!saved.id.is_empty());

    assert!(matches!(
        test_connection("missing-id".into(), None, None, true),
        Err(PandaError::UnknownHost(_))
    ));
    assert!(matches!(
        sftp_list("missing-id".into(), "/".into(), None, None, true),
        Err(PandaError::UnknownHost(_))
    ));
    assert!(matches!(
        sftp_upload("missing-id".into(), "/a".into(), "/b".into(), None, None, true),
        Err(PandaError::UnknownHost(_))
    ));
    assert!(matches!(
        sftp_download("missing-id".into(), "/a".into(), "/b".into(), None, None, true),
        Err(PandaError::UnknownHost(_))
    ));
    assert!(matches!(
        sftp_remove_file("missing-id".into(), "/a".into(), None, None, true),
        Err(PandaError::UnknownHost(_))
    ));
    assert!(matches!(
        sftp_remove_dir("missing-id".into(), "/a".into(), None, None, true),
        Err(PandaError::UnknownHost(_))
    ));
    assert!(matches!(
        sftp_create_dir("missing-id".into(), "/a".into(), None, None, true),
        Err(PandaError::UnknownHost(_))
    ));
    assert!(matches!(
        test_connection(saved.id.clone(), None, None, true),
        Err(PandaError::MissingPassword(_))
    ));
    assert!(matches!(
        sftp_list(saved.id.clone(), "/".into(), None, None, true),
        Err(PandaError::MissingPassword(_))
    ));
    assert!(matches!(
        sftp_upload(
            saved.id.clone(),
            "/tmp/nope".into(),
            "/remote/nope".into(),
            None,
            None,
            true,
        ),
        Err(PandaError::MissingPassword(_))
    ));
    assert!(matches!(
        sftp_download(
            saved.id.clone(),
            "/remote/nope".into(),
            "/tmp/nope".into(),
            None,
            None,
            true,
        ),
        Err(PandaError::MissingPassword(_))
    ));
    assert!(matches!(
        sftp_remove_file(saved.id.clone(), "/remote/nope".into(), None, None, true),
        Err(PandaError::MissingPassword(_))
    ));
    assert!(matches!(
        sftp_remove_dir(saved.id.clone(), "/remote/nope".into(), None, None, true),
        Err(PandaError::MissingPassword(_))
    ));
    assert!(matches!(
        sftp_create_dir(saved.id.clone(), "/remote/nope".into(), None, None, true),
        Err(PandaError::MissingPassword(_))
    ));

    save_host(HostConfigRecord {
        id: String::new(),
        name: "key-box".into(),
        host: "127.0.0.1".into(),
        port: 22,
        username: "panda".into(),
        auth: AuthMethodEnum::PublicKey {
            key_path: "/tmp/does-not-exist".into(),
            passphrase_ref: Some("kc://passphrase".into()),
        },
        notes: None,
group_id: None,
    })
    .unwrap();
    let key_saved = list_hosts()
        .unwrap()
        .into_iter()
        .find(|h| h.name == "key-box")
        .unwrap();
    assert!(matches!(
        test_connection(key_saved.id.clone(), None, Some("p".into()), true),
        Err(PandaError::Core(_))
    ));

    delete_host(key_saved.id).unwrap();
    delete_host(saved.id).unwrap();
    assert!(list_hosts().unwrap().is_empty());

    let _ = std::fs::remove_dir_all(dir);
    cleanup_store();
}

#[test]
fn ffi_sftp_error_paths() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let port = start_server();
    let dir = tempfile::tempdir().unwrap();

    save_host(HostConfigRecord {
        id: String::new(),
        name: "fake".into(),
        host: "127.0.0.1".into(),
        port,
        username: USERNAME.into(),
        auth: AuthMethodEnum::Password {
            password_ref: Some("kc://fake".into()),
        },
        notes: None,
            group_id: None,
    })
    .unwrap();

    let host = list_hosts()
        .unwrap()
        .into_iter()
        .find(|h| h.name == "fake")
        .unwrap();
    let pw = Some(PASSWORD.into());

    assert!(matches!(
        sftp_list(host.id.clone(), "/no-such-dir".into(), pw.clone(), None, true),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        sftp_upload(
            host.id.clone(),
            "/tmp/does-not-exist".into(),
            "/remote.bin".into(),
            pw.clone(),
            None,
            true,
        ),
        Err(PandaError::Core(_))
    ));
    let back = dir.path().join("back.bin");
    assert!(matches!(
        sftp_download(
            host.id.clone(),
            "/missing.bin".into(),
            back.to_string_lossy().into_owned(),
            pw.clone(),
            None,
            true,
        ),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        sftp_remove_file(host.id.clone(), "/missing.bin".into(), pw.clone(), None, true),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        sftp_remove_dir(host.id.clone(), "/no-such-dir".into(), pw.clone(), None, true),
        Err(PandaError::Core(_))
    ));

    delete_host(host.id).unwrap();
    cleanup_store();
}

#[test]
fn ffi_save_host_with_explicit_id_replaces_in_place() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let fixed_id = Uuid::new_v4().to_string();
    let rec = || HostConfigRecord {
        id: fixed_id.clone(),
        name: "fixed".into(),
        host: "example.com".into(),
        port: 22,
        username: "panda".into(),
        auth: AuthMethodEnum::Password { password_ref: None },
        notes: None,
        group_id: None,
    };
    save_host(rec()).unwrap();
    save_host(rec()).unwrap();

    let hosts = list_hosts().unwrap();
    let matches = hosts.iter().filter(|h| h.name == "fixed").count();
    assert_eq!(matches, 1);
    assert_eq!(hosts[0].id, fixed_id);

    delete_host(fixed_id).unwrap();
    cleanup_store();
}

#[test]
fn ffi_shell_session_lifecycle() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let port = start_server();
    save_host(HostConfigRecord {
        id: String::new(),
        name: "shell".into(),
        host: "127.0.0.1".into(),
        port,
        username: USERNAME.into(),
        auth: AuthMethodEnum::Password {
            password_ref: Some("kc://shell".into()),
        },
        notes: None,
        group_id: None,
    })
    .unwrap();

    let host = list_hosts()
        .unwrap()
        .into_iter()
        .find(|h| h.name == "shell")
        .unwrap();

    let handle = shell_open(
        host.id.clone(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    std::thread::sleep(Duration::from_millis(150));
    let banner = shell_read(handle, 1024).unwrap();
    assert!(String::from_utf8_lossy(&banner).contains("Panda fake shell"));

    shell_write(handle, b"hello\n".to_vec()).unwrap();
    std::thread::sleep(Duration::from_millis(150));
    let out = shell_read(handle, 1024).unwrap();
    assert!(String::from_utf8_lossy(&out).contains("echo: hello"));

    shell_close(handle).unwrap();

    assert!(matches!(
        shell_read(handle, 1024),
        Err(PandaError::UnknownShellHandle(_))
    ));

    delete_host(host.id).unwrap();
    cleanup_store();
}

#[test]
fn ffi_shell_open_requires_store_initialization() {
    // 未初始化 store 时返回 NotInitialized。
    assert!(matches!(
        shell_open("any".into(), None, None, false),
        Err(PandaError::NotInitialized)
    ));
}

#[test]
fn ffi_sftp_new_fails_when_subsystem_rejected() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let port = start_server_rejecting_sftp();
    save_host(HostConfigRecord {
        id: String::new(),
        name: "fake".into(),
        host: "127.0.0.1".into(),
        port,
        username: USERNAME.into(),
        auth: AuthMethodEnum::Password {
            password_ref: Some("kc://fake".into()),
        },
        notes: None,
            group_id: None,
    })
    .unwrap();

    let host = list_hosts()
        .unwrap()
        .into_iter()
        .find(|h| h.name == "fake")
        .unwrap();
    let pw = Some(PASSWORD.into());

    // SFTP 子系统被拒时，共享的 SftpClient::new 失败，所有导出函数都必须报 Core 错误。
    // 只需调用一个即可覆盖共享站点。
    assert!(matches!(
        sftp_list(host.id.clone(), "/".into(), pw.clone(), None, true),
        Err(PandaError::Core(_))
    ));

    delete_host(host.id).unwrap();
    cleanup_store();
}

fn save_test_host(port: u16, name: &str) -> HostConfigRecord {
    save_host(HostConfigRecord {
        id: String::new(),
        name: name.into(),
        host: "127.0.0.1".into(),
        port,
        username: USERNAME.into(),
        auth: AuthMethodEnum::Password {
            password_ref: Some("kc://fake".into()),
        },
        notes: None,
        group_id: None,
    })
    .unwrap();
    list_hosts()
        .unwrap()
        .into_iter()
        .find(|h| h.name == name)
        .unwrap()
}

#[test]
fn ffi_transfer_upload_and_poll_completes() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "transfer-upload");
    let dir = std::env::temp_dir().join(format!("panda-ffi-transfer-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("upload.bin");
    std::fs::write(&local, vec![1u8; 100_000]).unwrap();

    let id = start_transfer(
        TransferDirectionEnum::Upload,
        host.id,
        local.to_string_lossy().into_owned(),
        "/upload.bin".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let mut status;
    for _ in 0..100 {
        std::thread::sleep(Duration::from_millis(50));
        status = transfer_status(id.clone()).unwrap();
        if matches!(status.status, TransferStatusEnum::Completed) {
            assert_eq!(status.transferred, 100_000);
            cleanup_store();
            return;
        }
    }
    panic!("upload did not complete");
}

#[test]
fn ffi_transfer_download_and_poll_completes() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "transfer-download");
    let dir = std::env::temp_dir().join(format!("panda-ffi-transfer-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    // 先上传一个文件供下载。
    let src = dir.join("src.bin");
    std::fs::write(&src, vec![2u8; 100_000]).unwrap();
    sftp_upload(
        host.id.clone(),
        src.to_string_lossy().into_owned(),
        "/download.bin".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let dst = dir.join("dst.bin");
    let id = start_transfer(
        TransferDirectionEnum::Download,
        host.id,
        dst.to_string_lossy().into_owned(),
        "/download.bin".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let mut status;
    for _ in 0..100 {
        std::thread::sleep(Duration::from_millis(50));
        status = transfer_status(id.clone()).unwrap();
        if matches!(status.status, TransferStatusEnum::Completed) {
            assert_eq!(status.transferred, 100_000);
            cleanup_store();
            return;
        }
    }
    panic!("download did not complete");
}

#[test]
fn ffi_transfer_cancel_running_task() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "transfer-cancel");
    let dir = std::env::temp_dir().join(format!("panda-ffi-transfer-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("big.bin");
    std::fs::write(&local, vec![7u8; 5_000_000]).unwrap();

    let id = start_transfer(
        TransferDirectionEnum::Upload,
        host.id,
        local.to_string_lossy().into_owned(),
        "/big.bin".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    // 等待任务进入 Running 状态后立即取消。
    loop {
        let status = transfer_status(id.clone()).unwrap();
        if matches!(status.status, TransferStatusEnum::Running) {
            transfer_cancel(id.clone()).unwrap();
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(50));
        let status = transfer_status(id.clone()).unwrap();
        if matches!(status.status, TransferStatusEnum::Cancelled) {
            assert!(status.transferred < 5_000_000);
            cleanup_store();
            return;
        }
    }
    panic!("task was not cancelled");
}

#[test]
fn ffi_transfer_cancel_queued_task() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "transfer-queue");
    let dir = std::env::temp_dir().join(format!("panda-ffi-transfer-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    // 启动 4 个大文件上传，并发上限为 3，最后一个在排队。
    let mut ids = Vec::new();
    for i in 0..4 {
        let local = dir.join(format!("big{}.bin", i));
        std::fs::write(&local, vec![i as u8; 5_000_000]).unwrap();
        let id = start_transfer(
            TransferDirectionEnum::Upload,
            host.id.clone(),
            local.to_string_lossy().into_owned(),
            format!("/big{}.bin", i),
            Some(PASSWORD.into()),
            None,
        )
        .unwrap();
        ids.push(id);
    }

    // 取消最后一个任务，它应当在排队中直接被置为 Cancelled。
    transfer_cancel(ids[3].clone()).unwrap();

    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(50));
        let status = transfer_status(ids[3].clone()).unwrap();
        if matches!(status.status, TransferStatusEnum::Cancelled) {
            cleanup_store();
            return;
        }
    }
    panic!("queued task was not cancelled");
}

#[test]
fn ffi_transfer_retry_failed_task() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "transfer-retry");
    let dir = std::env::temp_dir().join(format!("panda-ffi-transfer-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("retry.bin");
    std::fs::write(&local, b"retry payload").unwrap();

    // 下载不存在的文件使其失败。
    let id = start_transfer(
        TransferDirectionEnum::Download,
        host.id.clone(),
        local.to_string_lossy().into_owned(),
        "/does-not-exist.bin".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let mut failed = false;
    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(50));
        let status = transfer_status(id.clone()).unwrap();
        if matches!(status.status, TransferStatusEnum::Failed) {
            failed = true;
            break;
        }
    }
    assert!(failed, "task did not fail");

    // 上传一个存在的文件到同一远程路径，然后重试原任务（使用相同参数）。
    sftp_upload(
        host.id.clone(),
        local.to_string_lossy().into_owned(),
        "/does-not-exist.bin".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let new_id = transfer_retry(id).unwrap();
    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(50));
        let status = transfer_status(new_id.clone()).unwrap();
        if matches!(status.status, TransferStatusEnum::Completed) {
            cleanup_store();
            return;
        }
    }
    panic!("retried task did not complete");
}

#[test]
fn ffi_transfer_unknown_task_returns_error() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    assert!(matches!(
        transfer_status("00000000-0000-0000-0000-000000000000".into()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    assert!(matches!(
        transfer_cancel("00000000-0000-0000-0000-000000000000".into()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    assert!(matches!(
        transfer_retry("00000000-0000-0000-0000-000000000000".into()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    cleanup_store();
}

#[test]
fn ffi_transfer_list_includes_tasks() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "transfer-list");
    let dir = std::env::temp_dir().join(format!("panda-ffi-transfer-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("list.bin");
    std::fs::write(&local, b"list").unwrap();

    let id = start_transfer(
        TransferDirectionEnum::Upload,
        host.id,
        local.to_string_lossy().into_owned(),
        "/list.bin".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let list = transfer_list().unwrap();
    assert!(list.iter().any(|t| t.id == id));

    cleanup_store();
}

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use panda_ffi::{
    AuthMethodEnum, BatchTransferStatusEnum, HostConfigRecord, KnownHostStatusEnum, PandaError,
    TransferDirectionEnum, TransferStatusEnum, accept_unknown_host_key, batch_transfer_cancel,
    batch_transfer_list, batch_transfer_resolve_conflict, batch_transfer_status, delete_host,
    host_key_status, init_store, list_hosts, save_host, scan_local_batch, scan_remote_batch,
    sftp_check_download_conflict, sftp_check_upload_conflict, sftp_create_dir, sftp_download,
    sftp_home_dir, sftp_list, sftp_remove_dir, sftp_remove_file, sftp_upload, shell_close,
    shell_open, shell_read, shell_resize, shell_write, start_batch_download, start_batch_upload,
    start_transfer, test_connection, transfer_cancel, transfer_list, transfer_pause,
    transfer_resume, transfer_retry, transfer_status,
};
use russh::keys::{Algorithm, PrivateKey};
use russh::server::{Auth, ChannelOpenHandle, Msg, Server as _, Session};
use russh::{Channel, ChannelId};
use russh_sftp::protocol::{
    Attrs, Data, File, FileAttributes, Handle, Name, OpenFlags, Status, StatusCode, Version,
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
    // 先取消所有可能仍在运行的传输任务，避免占用并发槽位或污染后续测试。
    cancel_all_transfers();
    let dir = std::env::temp_dir().join("panda-ffi-integration-store");
    // 每个测试从全新 store 目录开始,避免上次测试的 hosts/groups/known_hosts 残留。
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    init_store(dir.to_string_lossy().into_owned()).unwrap();
}

/// 取消当前所有单文件与批量传输任务，并等待其进入终态，用于测试间清理。
fn cancel_all_transfers() {
    let _ = std::panic::catch_unwind(|| {
        for t in transfer_list().unwrap_or_default() {
            let _ = transfer_cancel(t.id);
        }
        for t in batch_transfer_list().unwrap_or_default() {
            let _ = batch_transfer_cancel(t.id);
        }
        for _ in 0..300 {
            std::thread::sleep(Duration::from_millis(20));
            let done = transfer_list().unwrap_or_default().iter().all(|t| {
                matches!(
                    t.status,
                    TransferStatusEnum::Completed
                        | TransferStatusEnum::Failed
                        | TransferStatusEnum::Cancelled
                )
            }) && batch_transfer_list().unwrap_or_default().iter().all(|t| {
                matches!(
                    t.status,
                    BatchTransferStatusEnum::Completed
                        | BatchTransferStatusEnum::Failed
                        | BatchTransferStatusEnum::Cancelled
                )
            });
            if done {
                break;
            }
        }
    });
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

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let files = self.files.lock().await;
        if let Some(content) = files.get(&path) {
            return Ok(Attrs {
                id,
                attrs: attrs_for(content.len() as u64, false),
            });
        }
        drop(files);
        let dirs = self.dirs.lock().await;
        if dirs.contains(&path) {
            return Ok(Attrs {
                id,
                attrs: attrs_for(0, true),
            });
        }
        Err(StatusCode::NoSuchFile)
    }

    async fn opendir(&mut self, id: u32, path: String) -> Result<Handle, Self::Error> {
        let normalized = if path.is_empty() || path == "/" {
            "/".to_string()
        } else {
            path.trim_end_matches('/').to_string()
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
        let err = test_connection(host.id.clone(), Some(PASSWORD.into()), None, trust).unwrap_err();
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

    let listing = sftp_list(
        host.id.clone(),
        "/".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
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
    sftp_remove_dir(
        host.id.clone(),
        "/sub".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    delete_host(host.id).unwrap();
    cleanup_store();
}

#[test]
fn ffi_sftp_remove_all_recursive() {
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

    // 创建嵌套目录结构 /nested/subdir
    sftp_create_dir(
        host.id.clone(),
        "/nested".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_create_dir(
        host.id.clone(),
        "/nested/subdir".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    // 在嵌套目录中上传文件
    let local = dir.path().join("nested.txt");
    std::fs::write(&local, b"nested payload").unwrap();
    sftp_upload(
        host.id.clone(),
        local.to_string_lossy().into_owned(),
        "/nested/file.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_upload(
        host.id.clone(),
        local.to_string_lossy().into_owned(),
        "/nested/subdir/inner.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    // 验证文件存在
    let listing = sftp_list(
        host.id.clone(),
        "/".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    assert!(listing.iter().any(|f| f.name == "nested" && f.is_dir));

    // 使用 sftp_remove_dir（内部调用 remove_all）递归删除非空目录
    sftp_remove_dir(
        host.id.clone(),
        "/nested".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    // 验证目录已被删除
    let listing = sftp_list(
        host.id.clone(),
        "/".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    assert!(!listing.iter().any(|f| f.name == "nested"));

    // 额外验证：remove_all 也能直接删除单个文件（metadata 判定为文件路径）
    sftp_upload(
        host.id.clone(),
        local.to_string_lossy().into_owned(),
        "/standalone.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_remove_dir(
        host.id.clone(),
        "/standalone.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    // 额外验证：remove_all 处理以斜杠结尾的目录路径
    sftp_create_dir(
        host.id.clone(),
        "/trailing".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_upload(
        host.id.clone(),
        local.to_string_lossy().into_owned(),
        "/trailing/inside.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_remove_dir(
        host.id.clone(),
        "/trailing/".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    let listing = sftp_list(
        host.id.clone(),
        "/".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    assert!(!listing.iter().any(|f| f.name == "trailing"));

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
    assert!(matches!(
        PandaError::from(panda_core::Error::Cancelled),
        PandaError::Cancelled
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

    // GroupRecord round-trip preserves parent_id.
    let g = panda_ffi::GroupRecord {
        id: "g1".into(),
        name: "group".into(),
        parent_id: Some("parent".into()),
    };
    let core: panda_core::Group = g.into();
    let back: panda_ffi::GroupRecord = core.into();
    assert_eq!(back.id, "g1");
    assert_eq!(back.parent_id, Some("parent".into()));

    // HostConfigRecord group_id round-trip.
    let h = HostConfigRecord {
        id: "h1".into(),
        name: "host".into(),
        host: "example.com".into(),
        port: 22,
        username: "u".into(),
        auth: AuthMethodEnum::Password {
            password_ref: Some("kc://p".into()),
        },
        notes: Some("note".into()),
        group_id: Some("g1".into()),
    };
    let core: panda_core::HostConfig = h.clone().into();
    let back: HostConfigRecord = core.into();
    assert_eq!(back.group_id, Some("g1".into()));
    assert_eq!(back.notes, Some("note".into()));
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
        sftp_upload(
            "missing-id".into(),
            "/a".into(),
            "/b".into(),
            None,
            None,
            true
        ),
        Err(PandaError::UnknownHost(_))
    ));
    assert!(matches!(
        sftp_download(
            "missing-id".into(),
            "/a".into(),
            "/b".into(),
            None,
            None,
            true
        ),
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
        sftp_list(
            host.id.clone(),
            "/no-such-dir".into(),
            pw.clone(),
            None,
            true
        ),
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
        sftp_remove_file(
            host.id.clone(),
            "/missing.bin".into(),
            pw.clone(),
            None,
            true
        ),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        sftp_remove_dir(
            host.id.clone(),
            "/no-such-dir".into(),
            pw.clone(),
            None,
            true
        ),
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

    let handle = shell_open(host.id.clone(), Some(PASSWORD.into()), None, true).unwrap();

    std::thread::sleep(Duration::from_millis(150));
    let banner = shell_read(handle, 1024).unwrap();
    assert!(String::from_utf8_lossy(&banner).contains("Panda fake shell"));

    shell_write(handle, b"hello\n".to_vec()).unwrap();
    std::thread::sleep(Duration::from_millis(150));
    let out = shell_read(handle, 1024).unwrap();
    assert!(String::from_utf8_lossy(&out).contains("echo: hello"));
    shell_resize(handle, 120, 40).unwrap();

    shell_close(handle).unwrap();

    assert!(matches!(
        shell_read(handle, 1024),
        Err(PandaError::UnknownShellHandle(_))
    ));

    delete_host(host.id).unwrap();
    cleanup_store();
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

fn unused_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.local_addr().unwrap().port()
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
        0,
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
        100_000,
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
        0,
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
            0,
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
        0,
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

    let retried_id = transfer_retry(id.clone()).unwrap();
    assert_eq!(retried_id, id, "重试失败任务应复用原任务 id,不应创建新任务");
    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(50));
        let status = transfer_status(id.clone()).unwrap();
        if matches!(status.status, TransferStatusEnum::Completed) {
            cleanup_store();
            return;
        }
    }
    panic!("retried task did not complete");
}

#[test]
fn ffi_transfer_retry_non_terminal_task_fails() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "transfer-retry-non-terminal");
    let dir = std::env::temp_dir().join(format!("panda-ffi-transfer-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("retry.bin");
    std::fs::write(&local, b"retry payload").unwrap();

    // 启动一个会成功的上传任务,立即重试应失败,因为任务尚未进入可重试状态。
    let id = start_transfer(
        TransferDirectionEnum::Upload,
        host.id,
        local.to_string_lossy().into_owned(),
        "/retry-non-terminal.bin".into(),
        0,
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    assert!(
        matches!(transfer_retry(id), Err(PandaError::Core(_))),
        "非终态任务不允许重试"
    );
    cleanup_store();
}

#[test]
fn ffi_transfer_pause_and_resume_running_task() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "transfer-pause");
    let dir = std::env::temp_dir().join(format!("panda-ffi-transfer-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("pause.bin");
    let payload = vec![1u8; 5_000_000];
    std::fs::write(&local, &payload).unwrap();

    let id = start_transfer(
        TransferDirectionEnum::Upload,
        host.id,
        local.to_string_lossy().into_owned(),
        "/pause-running.bin".into(),
        0,
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    // 等待任务进入 running。
    let mut running = false;
    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(50));
        let status = transfer_status(id.clone()).unwrap();
        if matches!(status.status, TransferStatusEnum::Running) {
            running = true;
            break;
        }
    }
    assert!(running, "任务应先进入 running");

    transfer_pause(id.clone()).unwrap();
    std::thread::sleep(Duration::from_millis(100));
    let paused = transfer_status(id.clone()).unwrap();
    assert!(
        matches!(paused.status, TransferStatusEnum::Paused),
        "暂停后状态应为 paused"
    );
    let frozen = paused.transferred;
    std::thread::sleep(Duration::from_millis(300));
    let still = transfer_status(id.clone()).unwrap();
    assert!(
        matches!(still.status, TransferStatusEnum::Paused),
        "继续前应保持 paused"
    );
    assert_eq!(still.transferred, frozen, "暂停期间已传输字节数应不变");

    transfer_resume(id.clone()).unwrap();
    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(50));
        let status = transfer_status(id.clone()).unwrap();
        if matches!(status.status, TransferStatusEnum::Completed) {
            cleanup_store();
            return;
        }
    }
    panic!("继续后任务未完成");
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
    assert!(matches!(
        transfer_pause("00000000-0000-0000-0000-000000000000".into()),
        Err(PandaError::UnknownTransferTask(_))
    ));
    assert!(matches!(
        transfer_resume("00000000-0000-0000-0000-000000000000".into()),
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
        0,
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let list = transfer_list().unwrap();
    assert!(list.iter().any(|t| t.id == id));

    cleanup_store();
}

#[test]
fn ffi_shell_unknown_handle_returns_error() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    assert!(matches!(
        shell_write(9999, b"x".to_vec()),
        Err(PandaError::UnknownShellHandle(9999))
    ));
    assert!(matches!(
        shell_read(9999, 1024),
        Err(PandaError::UnknownShellHandle(9999))
    ));
    assert!(matches!(
        shell_close(9999),
        Err(PandaError::UnknownShellHandle(9999))
    ));
    assert!(matches!(
        shell_resize(9999, 80, 24),
        Err(PandaError::UnknownShellHandle(9999))
    ));

    cleanup_store();
}

#[test]
fn ffi_start_transfer_unknown_host_returns_error() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    assert!(matches!(
        start_transfer(
            TransferDirectionEnum::Upload,
            "no-such-host".into(),
            "/tmp/x".into(),
            "/remote/x".into(),
            0,
            None,
            None,
        ),
        Err(PandaError::UnknownHost(_))
    ));

    cleanup_store();
}

#[test]
fn ffi_sftp_check_upload_conflict_no_target_returns_none() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "upload-conflict-none");
    let dir = std::env::temp_dir().join(format!("panda-ffi-upload-conflict-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("source.bin");
    std::fs::write(&local, b"hello").unwrap();

    let result = sftp_check_upload_conflict(
        host.id,
        local.to_string_lossy().into_owned(),
        "/not_yet_existing.bin".into(),
        Some(PASSWORD.into()),
        None,
        true,
    );
    assert!(result.unwrap().is_none());

    cleanup_store();
}

#[test]
fn ffi_sftp_check_upload_conflict_existing_target_returns_info() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "upload-conflict-exists");
    let dir = std::env::temp_dir().join(format!("panda-ffi-upload-conflict-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("source.bin");
    std::fs::write(&local, b"new content").unwrap();

    // 先在远端写入一个已存在的文件
    sftp_upload(
        host.id.clone(),
        local.to_string_lossy().into_owned(),
        "/existing.bin".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let info = sftp_check_upload_conflict(
        host.id,
        local.to_string_lossy().into_owned(),
        "/existing.bin".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap()
    .expect("should conflict");
    assert_eq!(info.source_size, 11);
    assert_eq!(info.target_size, 11);
    assert!(info.source_mtime.is_some());
    assert_eq!(info.target_mtime, Some(1_700_000_000));

    cleanup_store();
}

#[test]
fn ffi_sftp_check_download_conflict_no_target_returns_none() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "download-conflict-none");
    let dir = std::env::temp_dir().join(format!("panda-ffi-download-conflict-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("target.bin");

    // 远端文件存在，本地目标不存在
    let remote_local = dir.join("remote.bin");
    std::fs::write(&remote_local, b"remote").unwrap();
    sftp_upload(
        host.id.clone(),
        remote_local.to_string_lossy().into_owned(),
        "/remote_source.bin".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let result = sftp_check_download_conflict(
        host.id,
        "/remote_source.bin".into(),
        local.to_string_lossy().into_owned(),
        Some(PASSWORD.into()),
        None,
        true,
    );
    assert!(result.unwrap().is_none());

    cleanup_store();
}

#[test]
fn ffi_sftp_check_download_conflict_existing_target_returns_info() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "download-conflict-exists");
    let dir = std::env::temp_dir().join(format!("panda-ffi-download-conflict-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let local = dir.join("target.bin");
    std::fs::write(&local, b"old local").unwrap();

    let remote_local = dir.join("remote.bin");
    std::fs::write(&remote_local, b"remote content").unwrap();
    sftp_upload(
        host.id.clone(),
        remote_local.to_string_lossy().into_owned(),
        "/remote_source.bin".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let info = sftp_check_download_conflict(
        host.id,
        "/remote_source.bin".into(),
        local.to_string_lossy().into_owned(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap()
    .expect("should conflict");
    assert_eq!(info.source_size, 14);
    assert_eq!(info.target_size, 9);
    assert_eq!(info.source_mtime, Some(1_700_000_000));
    assert!(info.target_mtime.is_some());

    cleanup_store();
}

#[test]
fn ffi_batch_upload_directory_completes() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-upload");
    let dir = std::env::temp_dir().join(format!("panda-ffi-batch-upload-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    let src = dir.join("project");
    std::fs::create_dir(&src).unwrap();
    std::fs::write(src.join("README.md"), b"readme").unwrap();
    let sub = src.join("src");
    std::fs::create_dir(&sub).unwrap();
    std::fs::write(sub.join("main.swift"), b"code").unwrap();

    sftp_create_dir(
        host.id.clone(),
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let task_id = start_batch_upload(
        host.id.clone(),
        vec![src.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    // 轮询等待完成。
    let mut status = BatchTransferStatusEnum::Queued;
    for _ in 0..200 {
        let record = batch_transfer_status(task_id.clone()).unwrap();
        status = record.status;
        if matches!(
            status,
            BatchTransferStatusEnum::Completed
                | BatchTransferStatusEnum::Failed
                | BatchTransferStatusEnum::Cancelled
        ) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(status, BatchTransferStatusEnum::Completed);

    let list = sftp_list(
        host.id.clone(),
        "/remote/project".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    assert!(list.iter().any(|f| f.name == "README.md"));

    let src_list = sftp_list(
        host.id.clone(),
        "/remote/project/src".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    assert!(src_list.iter().any(|f| f.name == "main.swift"));

    cleanup_store();
}

#[test]
fn ffi_batch_upload_creates_missing_remote_parent() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-upload-missing-parent");
    let dir = std::env::temp_dir().join(format!(
        "panda-ffi-batch-upload-missing-parent-{}",
        Uuid::new_v4()
    ));
    std::fs::create_dir_all(&dir).unwrap();

    let src = dir.join("project");
    std::fs::create_dir(&src).unwrap();
    std::fs::write(src.join("README.md"), b"readme").unwrap();

    // 不预先创建 /remote，验证批量上传能递归创建父目录。
    let task_id = start_batch_upload(
        host.id.clone(),
        vec![src.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let mut status = BatchTransferStatusEnum::Queued;
    for _ in 0..200 {
        let record = batch_transfer_status(task_id.clone()).unwrap();
        status = record.status;
        if matches!(
            status,
            BatchTransferStatusEnum::Completed
                | BatchTransferStatusEnum::Failed
                | BatchTransferStatusEnum::Cancelled
        ) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(status, BatchTransferStatusEnum::Completed);

    let list = sftp_list(
        host.id.clone(),
        "/remote/project".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    assert!(list.iter().any(|f| f.name == "README.md"));

    cleanup_store();
}

#[test]
fn ffi_batch_upload_ignores_existing_remote_directory() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-upload-existing-dir");
    let dir = std::env::temp_dir().join(format!(
        "panda-ffi-batch-upload-existing-dir-{}",
        Uuid::new_v4()
    ));
    std::fs::create_dir_all(&dir).unwrap();

    // 远端目录已存在。
    sftp_create_dir(
        host.id.clone(),
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_create_dir(
        host.id.clone(),
        "/remote/project".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let src = dir.join("project");
    std::fs::create_dir(&src).unwrap();
    std::fs::write(src.join("README.md"), b"readme").unwrap();

    let task_id = start_batch_upload(
        host.id.clone(),
        vec![src.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let mut status = BatchTransferStatusEnum::Queued;
    for _ in 0..200 {
        let record = batch_transfer_status(task_id.clone()).unwrap();
        status = record.status;
        if matches!(
            status,
            BatchTransferStatusEnum::Completed
                | BatchTransferStatusEnum::Failed
                | BatchTransferStatusEnum::Cancelled
        ) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(status, BatchTransferStatusEnum::Completed);

    cleanup_store();
}

#[test]
fn ffi_batch_upload_multiple_files_completes() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-upload-files");
    let dir = std::env::temp_dir().join(format!("panda-ffi-batch-upload-files-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    let a = dir.join("a.txt");
    let b = dir.join("b.txt");
    std::fs::write(&a, b"aaa").unwrap();
    std::fs::write(&b, b"bbbb").unwrap();

    sftp_create_dir(
        host.id.clone(),
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let task_id = start_batch_upload(
        host.id.clone(),
        vec![
            a.to_string_lossy().into_owned(),
            b.to_string_lossy().into_owned(),
        ],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let mut status = BatchTransferStatusEnum::Queued;
    for _ in 0..200 {
        let record = batch_transfer_status(task_id.clone()).unwrap();
        status = record.status;
        if matches!(
            status,
            BatchTransferStatusEnum::Completed
                | BatchTransferStatusEnum::Failed
                | BatchTransferStatusEnum::Cancelled
        ) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(status, BatchTransferStatusEnum::Completed);

    let list = sftp_list(
        host.id.clone(),
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    assert!(list.iter().any(|f| f.name == "a.txt"));
    assert!(list.iter().any(|f| f.name == "b.txt"));

    cleanup_store();
}

#[test]
fn ffi_batch_download_directory_completes() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-download");
    let dir = std::env::temp_dir().join(format!("panda-ffi-batch-download-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    sftp_create_dir(
        host.id.clone(),
        "/project".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_create_dir(
        host.id.clone(),
        "/project/src".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    let readme = dir.join("README.md");
    std::fs::write(&readme, b"readme").unwrap();
    sftp_upload(
        host.id.clone(),
        readme.to_string_lossy().into_owned(),
        "/project/README.md".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let task_id = start_batch_download(
        host.id.clone(),
        vec!["/project".into()],
        dir.to_string_lossy().into_owned(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let mut status = BatchTransferStatusEnum::Queued;
    for _ in 0..200 {
        let record = batch_transfer_status(task_id.clone()).unwrap();
        status = record.status;
        if matches!(
            status,
            BatchTransferStatusEnum::Completed
                | BatchTransferStatusEnum::Failed
                | BatchTransferStatusEnum::Cancelled
        ) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(status, BatchTransferStatusEnum::Completed);

    assert!(dir.join("project/README.md").exists());
    assert_eq!(
        std::fs::read(dir.join("project/README.md")).unwrap(),
        b"readme"
    );

    cleanup_store();
}

#[test]
fn ffi_batch_transfer_cancel_running_task() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-cancel");
    let dir = std::env::temp_dir().join(format!("panda-ffi-batch-cancel-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    let src = dir.join("big.bin");
    std::fs::write(&src, vec![0u8; 5_000_000]).unwrap();
    sftp_create_dir(
        host.id.clone(),
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let task_id = start_batch_upload(
        host.id.clone(),
        vec![src.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    // 稍微等待任务进入 running 状态。
    std::thread::sleep(Duration::from_millis(50));
    batch_transfer_cancel(task_id.clone()).unwrap();

    let mut status = BatchTransferStatusEnum::Queued;
    for _ in 0..100 {
        let record = batch_transfer_status(task_id.clone()).unwrap();
        status = record.status;
        if matches!(
            status,
            BatchTransferStatusEnum::Cancelled
                | BatchTransferStatusEnum::Failed
                | BatchTransferStatusEnum::Completed
        ) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(status, BatchTransferStatusEnum::Cancelled);

    cleanup_store();
}

#[test]
fn ffi_batch_transfer_list_includes_tasks() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-list");
    let dir = std::env::temp_dir().join(format!("panda-ffi-batch-list-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    let id1 = start_batch_upload(
        host.id.clone(),
        vec![dir.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();
    let id2 = start_batch_download(
        host.id.clone(),
        vec!["/".into()],
        dir.to_string_lossy().into_owned(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let list = batch_transfer_list().unwrap();
    let ids: Vec<_> = list.iter().map(|r| r.id.clone()).collect();
    assert!(ids.contains(&id1));
    assert!(ids.contains(&id2));

    cleanup_store();
}

#[test]
fn ffi_batch_upload_unknown_host_returns_error() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let result = start_batch_upload(
        "no-such-host".into(),
        vec!["/tmp".into()],
        "/remote".into(),
        None,
        None,
    );

    assert!(
        matches!(result, Err(PandaError::UnknownHost(_))),
        "未知主机应返回 UnknownHost"
    );
    cleanup_store();
}

#[test]
fn ffi_batch_upload_nonexistent_source_fails() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-upload-missing");

    let task_id = start_batch_upload(
        host.id,
        vec!["/no/such/path".into()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(50));
        let record = batch_transfer_status(task_id.clone()).unwrap();
        if matches!(record.status, BatchTransferStatusEnum::Failed) {
            assert!(!record.error.as_deref().unwrap_or("").is_empty());
            cleanup_store();
            return;
        }
    }
    panic!("批量上传扫描不存在路径应失败");
}

#[test]
fn ffi_batch_download_nonexistent_source_fails() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-download-missing");
    let dir = std::env::temp_dir().join(format!("panda-ffi-batch-dl-missing-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    let task_id = start_batch_download(
        host.id,
        vec!["/no/such/path".into()],
        dir.to_string_lossy().into_owned(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(50));
        let record = batch_transfer_status(task_id.clone()).unwrap();
        if matches!(record.status, BatchTransferStatusEnum::Failed) {
            assert!(!record.error.as_deref().unwrap_or("").is_empty());
            cleanup_store();
            return;
        }
    }
    panic!("批量下载扫描不存在远程路径应失败");
}

#[test]
fn ffi_batch_transfer_status_unknown_task_returns_error() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let result = batch_transfer_status(Uuid::new_v4().to_string());
    assert!(matches!(result, Err(PandaError::UnknownTransferTask(_))));
    cleanup_store();
}

#[test]
fn ffi_scan_local_batch_empty_sources() {
    let items = scan_local_batch(vec![], "/dest".into()).unwrap();
    assert!(items.is_empty());
}

#[test]
fn ffi_scan_local_batch_file_and_directory() {
    let dir = std::env::temp_dir().join(format!("panda-ffi-scan-local-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.txt");
    std::fs::write(&file, b"hello").unwrap();
    let subdir = dir.join("sub");
    std::fs::create_dir(&subdir).unwrap();
    let subfile = subdir.join("b.txt");
    std::fs::write(&subfile, b"world").unwrap();

    let items =
        scan_local_batch(vec![dir.to_string_lossy().into_owned()], "/remote".into()).unwrap();
    let dir_name = dir.file_name().unwrap().to_string_lossy().into_owned();

    assert!(items.iter().any(|i| i.is_dir
        && i.source == dir.to_string_lossy().into_owned()
        && i.destination == format!("/remote/{}", dir_name)));
    assert!(items.iter().any(|i| !i.is_dir
        && i.source == file.to_string_lossy().into_owned()
        && i.destination == format!("/remote/{}/a.txt", dir_name)));
    assert!(items.iter().any(|i| !i.is_dir
        && i.source == subfile.to_string_lossy().into_owned()
        && i.destination == format!("/remote/{}/sub/b.txt", dir_name)));
}

#[test]
fn ffi_scan_remote_batch_directory() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "scan-remote");

    let dir = std::env::temp_dir().join(format!("panda-ffi-scan-remote-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let a = dir.join("a.txt");
    std::fs::write(&a, b"hello").unwrap();
    let sub = dir.join("sub");
    std::fs::create_dir(&sub).unwrap();
    let b = sub.join("b.txt");
    std::fs::write(&b, b"world").unwrap();

    sftp_create_dir(
        host.id.clone(),
        "/scan".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_upload(
        host.id.clone(),
        a.to_string_lossy().into_owned(),
        "/scan/a.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_create_dir(
        host.id.clone(),
        "/scan/sub".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_upload(
        host.id.clone(),
        b.to_string_lossy().into_owned(),
        "/scan/sub/b.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let items = scan_remote_batch(
        host.id,
        vec!["/scan".into()],
        "/local".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    assert!(items.iter().any(|i| i.is_dir && i.source == "/scan"));
    assert!(items.iter().any(|i| !i.is_dir && i.source == "/scan/a.txt"));
    assert!(
        items
            .iter()
            .any(|i| !i.is_dir && i.source == "/scan/sub/b.txt")
    );
    cleanup_store();
}

#[test]
fn ffi_scan_local_batch_missing_source_fails() {
    let result = scan_local_batch(vec!["/no/such/path/exists".into()], "/dest".into());
    assert!(result.is_err());
}

#[test]
fn ffi_scan_remote_batch_unknown_host_fails() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let result = scan_remote_batch(
        "no-such-host".into(),
        vec!["/scan".into()],
        "/local".into(),
        Some(PASSWORD.into()),
        None,
    );
    assert!(matches!(result, Err(PandaError::UnknownHost(_))));
    cleanup_store();
}

#[test]
fn ffi_sftp_home_dir_returns_path() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "home-dir");

    let home = sftp_home_dir(host.id, Some(PASSWORD.into()), None, true).unwrap();
    assert!(!home.is_empty());

    cleanup_store();
}

#[test]
fn ffi_scan_remote_batch_missing_password_fails() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "scan-remote-no-pw");

    let result = scan_remote_batch(host.id, vec!["/".into()], "/local".into(), None, None);
    // scan_remote_batch 将 credentials_for 的错误信息包装为 PandaError::Core。
    assert!(matches!(result, Err(PandaError::Core(_))));

    cleanup_store();
}

#[test]
fn ffi_scan_remote_batch_connection_refused_fails() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let host = save_test_host(unused_port(), "scan-remote-refused");

    let result = scan_remote_batch(
        host.id,
        vec!["/".into()],
        "/local".into(),
        Some(PASSWORD.into()),
        None,
    );
    assert!(matches!(result, Err(PandaError::Core(_))));

    cleanup_store();
}

#[test]
fn ffi_scan_remote_batch_subsystem_rejected_fails() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server_rejecting_sftp();
    let host = save_test_host(port, "scan-remote-no-sftp");

    let result = scan_remote_batch(
        host.id,
        vec!["/".into()],
        "/local".into(),
        Some(PASSWORD.into()),
        None,
    );
    assert!(matches!(result, Err(PandaError::Core(_))));

    cleanup_store();
}

#[test]
fn ffi_batch_upload_missing_password_fails() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-upload-no-pw");
    let dir = std::env::temp_dir().join(format!("panda-ffi-batch-upload-no-pw-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.txt");
    std::fs::write(&file, b"x").unwrap();

    let task_id = start_batch_upload(
        host.id,
        vec![file.to_string_lossy().into_owned()],
        "/remote".into(),
        None,
        None,
    )
    .unwrap();

    let mut status = BatchTransferStatusEnum::Queued;
    for _ in 0..100 {
        let record = batch_transfer_status(task_id.clone()).unwrap();
        status = record.status;
        if matches!(
            status,
            BatchTransferStatusEnum::Failed
                | BatchTransferStatusEnum::Cancelled
                | BatchTransferStatusEnum::Completed
        ) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(status, BatchTransferStatusEnum::Failed);

    cleanup_store();
}

#[test]
fn ffi_batch_upload_overwrites_existing_target() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-upload-overwrite");
    let dir = std::env::temp_dir().join(format!("panda-ffi-batch-overwrite-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.txt");
    std::fs::write(&file, b"first").unwrap();

    sftp_create_dir(
        host.id.clone(),
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let first_id = start_batch_upload(
        host.id.clone(),
        vec![file.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();
    wait_for_batch_status(&first_id, BatchTransferStatusEnum::Completed);

    std::fs::write(&file, b"second").unwrap();
    let second_id = start_batch_upload(
        host.id.clone(),
        vec![file.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();
    // 目标已存在 → 等待覆盖确认；决策覆盖后任务完成。
    wait_for_batch_conflict(&second_id);
    batch_transfer_resolve_conflict(second_id.clone(), true).unwrap();
    wait_for_batch_status(&second_id, BatchTransferStatusEnum::Completed);

    cleanup_store();
}

#[test]
fn ffi_batch_upload_cancel_before_running_covers_queued_branch() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-cancel-queued");
    let dir =
        std::env::temp_dir().join(format!("panda-ffi-batch-cancel-queued-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("big.bin");
    std::fs::write(&file, vec![0u8; 50_000_000]).unwrap();

    sftp_create_dir(
        host.id.clone(),
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let task_id = start_batch_upload(
        host.id,
        vec![file.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    batch_transfer_cancel(task_id.clone()).unwrap();

    let mut status = BatchTransferStatusEnum::Queued;
    for _ in 0..100 {
        let record = batch_transfer_status(task_id.clone()).unwrap();
        status = record.status;
        if matches!(
            status,
            BatchTransferStatusEnum::Cancelled
                | BatchTransferStatusEnum::Failed
                | BatchTransferStatusEnum::Completed
        ) {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(status, BatchTransferStatusEnum::Cancelled);

    cleanup_store();
}

#[test]
fn ffi_invalid_task_id_returns_core_error() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let invalid = "not-a-uuid".to_string();
    assert!(matches!(
        transfer_status(invalid.clone()),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        transfer_cancel(invalid.clone()),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        transfer_pause(invalid.clone()),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        transfer_resume(invalid.clone()),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        transfer_retry(invalid.clone()),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        batch_transfer_status(invalid.clone()),
        Err(PandaError::Core(_))
    ));
    assert!(matches!(
        batch_transfer_cancel(invalid.clone()),
        Err(PandaError::Core(_))
    ));

    cleanup_store();
}

#[test]
fn ffi_transfer_pause_terminal_task_returns_error() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "pause-terminal");
    let dir = std::env::temp_dir().join(format!("panda-ffi-pause-terminal-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("tiny.txt");
    std::fs::write(&file, b"x").unwrap();

    let id = start_transfer(
        TransferDirectionEnum::Upload,
        host.id,
        file.to_string_lossy().into_owned(),
        "/tiny.txt".into(),
        1,
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    wait_for_transfer_status(&id, TransferStatusEnum::Completed);
    assert!(matches!(transfer_pause(id), Err(PandaError::Core(_))));

    cleanup_store();
}

#[test]
fn ffi_transfer_resume_non_paused_task_is_noop() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "resume-non-paused");
    let dir = std::env::temp_dir().join(format!("panda-ffi-resume-non-paused-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("q.txt");
    std::fs::write(&file, b"x").unwrap();

    let id = start_transfer(
        TransferDirectionEnum::Upload,
        host.id,
        file.to_string_lossy().into_owned(),
        "/q.txt".into(),
        1,
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    transfer_resume(id.clone()).unwrap();
    wait_for_transfer_status(&id, TransferStatusEnum::Completed);

    cleanup_store();
}

#[test]
fn ffi_batch_transfer_cancel_unknown_task_returns_error() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    let result = batch_transfer_cancel(Uuid::new_v4().to_string());
    assert!(matches!(result, Err(PandaError::UnknownTransferTask(_))));

    cleanup_store();
}

fn wait_for_transfer_status(task_id: &str, expected: TransferStatusEnum) {
    for _ in 0..200 {
        let record = transfer_status(task_id.to_string()).unwrap();
        if record.status == expected {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("task did not reach expected status");
}

fn wait_for_batch_status(task_id: &str, expected: BatchTransferStatusEnum) {
    for _ in 0..200 {
        let record = batch_transfer_status(task_id.to_string()).unwrap();
        if record.status == expected {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("batch task did not reach expected status");
}

/// 等待批量任务进入 WaitingForConflict 并返回其快照。
fn wait_for_batch_conflict(task_id: &str) -> panda_ffi::BatchTransferStatusRecord {
    for _ in 0..200 {
        let record = batch_transfer_status(task_id.to_string()).unwrap();
        if matches!(record.status, BatchTransferStatusEnum::WaitingForConflict) {
            return record;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("batch task did not reach WaitingForConflict");
}

/// 批量上传目标已存在 → 任务进入 WaitingForConflict 且携带完整冲突元数据；
/// 决策覆盖后目标内容被替换。
#[test]
fn ffi_batch_upload_conflict_waits_and_overwrites() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-conflict-overwrite");
    let dir = std::env::temp_dir().join(format!(
        "panda-ffi-batch-conflict-overwrite-{}",
        Uuid::new_v4()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.txt");
    std::fs::write(&file, b"new content").unwrap();

    sftp_create_dir(
        host.id.clone(),
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    // 远端目标已存在。
    sftp_upload(
        host.id.clone(),
        file.to_string_lossy().into_owned(),
        "/remote/a.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    std::fs::write(&file, b"new content").unwrap();

    let task_id = start_batch_upload(
        host.id.clone(),
        vec![file.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let record = wait_for_batch_conflict(&task_id);
    let conflict = record.pending_conflict.expect("应携带冲突信息");
    assert_eq!(conflict.item_source, file.to_string_lossy().into_owned());
    assert_eq!(conflict.item_destination, "/remote/a.txt");
    assert_eq!(conflict.source_size, 11, "b\"new content\" 长度应为 11");
    assert_eq!(conflict.target_size, 11);
    assert!(conflict.source_mtime.is_some());
    assert!(conflict.target_mtime.is_some());

    // 决策覆盖 → 任务完成，目标内容被替换。
    batch_transfer_resolve_conflict(task_id.clone(), true).unwrap();
    wait_for_batch_status(&task_id, BatchTransferStatusEnum::Completed);

    let back = dir.join("back.txt");
    sftp_download(
        host.id.clone(),
        "/remote/a.txt".into(),
        back.to_string_lossy().into_owned(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    assert_eq!(std::fs::read(&back).unwrap(), b"new content");

    cleanup_store();
}

/// 批量上传目标已存在，决策跳过 → 任务完成且目标内容保持不变。
#[test]
fn ffi_batch_upload_conflict_skip_keeps_target() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-conflict-skip");
    let dir =
        std::env::temp_dir().join(format!("panda-ffi-batch-conflict-skip-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.txt");
    std::fs::write(&file, b"new content").unwrap();

    sftp_create_dir(
        host.id.clone(),
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    // 远端目标已存在（旧内容）。
    let existing = dir.join("existing.txt");
    std::fs::write(&existing, b"old content").unwrap();
    sftp_upload(
        host.id.clone(),
        existing.to_string_lossy().into_owned(),
        "/remote/a.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let task_id = start_batch_upload(
        host.id.clone(),
        vec![file.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    let record = wait_for_batch_conflict(&task_id);
    assert!(record.pending_conflict.is_some());

    // 决策跳过 → 任务完成，目标内容保持旧值。
    batch_transfer_resolve_conflict(task_id.clone(), false).unwrap();
    wait_for_batch_status(&task_id, BatchTransferStatusEnum::Completed);

    let back = dir.join("back.txt");
    sftp_download(
        host.id.clone(),
        "/remote/a.txt".into(),
        back.to_string_lossy().into_owned(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    assert_eq!(std::fs::read(&back).unwrap(), b"old content");

    cleanup_store();
}

/// 取消等待确认中的批量任务 → 状态最终为 Cancelled，无悬空等待；
/// 随后 resolve 应报错而非悬挂或改变状态。
#[test]
fn ffi_batch_transfer_cancel_while_waiting_conflict() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server();
    let host = save_test_host(port, "batch-conflict-cancel");
    let dir = std::env::temp_dir().join(format!(
        "panda-ffi-batch-conflict-cancel-{}",
        Uuid::new_v4()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.txt");
    std::fs::write(&file, b"new content").unwrap();

    sftp_create_dir(
        host.id.clone(),
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();
    sftp_upload(
        host.id.clone(),
        file.to_string_lossy().into_owned(),
        "/remote/a.txt".into(),
        Some(PASSWORD.into()),
        None,
        true,
    )
    .unwrap();

    let task_id = start_batch_upload(
        host.id.clone(),
        vec![file.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    wait_for_batch_conflict(&task_id);

    batch_transfer_cancel(task_id.clone()).unwrap();
    wait_for_batch_status(&task_id, BatchTransferStatusEnum::Cancelled);

    // 无悬空等待：决策通道已被取消消费，resolve 报错且状态不变。
    assert!(matches!(
        batch_transfer_resolve_conflict(task_id.clone(), true),
        Err(PandaError::Core(_))
    ));
    assert_eq!(
        batch_transfer_status(task_id.clone()).unwrap().status,
        BatchTransferStatusEnum::Cancelled
    );

    cleanup_store();
}

/// 对未知任务 resolve 报 UnknownTransferTask。
#[test]
fn ffi_batch_transfer_resolve_unknown_task_returns_error() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();

    assert!(matches!(
        batch_transfer_resolve_conflict(Uuid::new_v4().to_string(), true),
        Err(PandaError::UnknownTransferTask(_))
    ));

    cleanup_store();
}

/// 批量上传连接被拒 → 任务 Failed 且携带错误信息。
#[test]
fn ffi_batch_upload_connection_refused_fails() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let host = save_test_host(unused_port(), "batch-upload-refused");
    let dir =
        std::env::temp_dir().join(format!("panda-ffi-batch-upload-refused-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.txt");
    std::fs::write(&file, b"x").unwrap();

    let task_id = start_batch_upload(
        host.id,
        vec![file.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    for _ in 0..50 {
        std::thread::sleep(Duration::from_millis(50));
        let record = batch_transfer_status(task_id.clone()).unwrap();
        if matches!(record.status, BatchTransferStatusEnum::Failed) {
            assert!(!record.error.as_deref().unwrap_or("").is_empty());
            cleanup_store();
            return;
        }
    }
    panic!("批量上传连接被拒应失败");
}

/// 批量上传 SFTP 子系统被拒 → 任务 Failed。
#[test]
fn ffi_batch_upload_subsystem_rejected_fails() {
    let _guard = TEST_LOCK.lock().unwrap();
    ensure_store_and_clear_hosts();
    let port = start_server_rejecting_sftp();
    let host = save_test_host(port, "batch-upload-no-sftp");
    let dir =
        std::env::temp_dir().join(format!("panda-ffi-batch-upload-no-sftp-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.txt");
    std::fs::write(&file, b"x").unwrap();

    let task_id = start_batch_upload(
        host.id,
        vec![file.to_string_lossy().into_owned()],
        "/remote".into(),
        Some(PASSWORD.into()),
        None,
    )
    .unwrap();

    for _ in 0..400 {
        std::thread::sleep(Duration::from_millis(50));
        let record = batch_transfer_status(task_id.clone()).unwrap();
        if matches!(record.status, BatchTransferStatusEnum::Failed) {
            cleanup_store();
            return;
        }
    }
    panic!("批量上传 SFTP 子系统被拒应失败");
}

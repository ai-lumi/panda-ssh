//! SSH session handling built on russh.

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use russh::client::{self, AuthResult, Handle};
use russh::keys::{load_secret_key, PrivateKeyWithHashAlg};
use russh::{ChannelMsg, Disconnect, Pty};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{mpsc, oneshot};

use crate::config::HostConfig;
use crate::hostkey::{fingerprint_sha256, HostKeyStatus, KnownHosts};
use crate::telemetry::{global_registry, LifecycleKind};
use crate::{Error, Result};

/// Default timeout for connect + auth, and interval for SSH keepalive.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

/// Default timeout for one `exec` call; a command that never finishes must
/// not block the caller forever.
const EXEC_TIMEOUT: Duration = Duration::from_secs(60);

/// Terminal type advertised to the remote shell.
const TERM_TYPE: &str = "xterm-256color";

/// Default PTY window size (columns × rows).
const DEFAULT_COLS: u32 = 80;
const DEFAULT_ROWS: u32 = 24;

/// Standard terminal modes for interactive PTY sessions.
///
/// Enables: signal generation, canonical (line-buffered) input, character
/// echo, erase/kill echoing, extended functions, output processing,
/// newline-to-CRLF conversion and 8-bit data.
///
/// Note: TTY_OP_END is NOT included — russh automatically appends it
/// when encoding the SSH packet, and including it here would cause the
/// declared length to mismatch the actual encoded bytes.
static STANDARD_TERMINAL_MODES: &[(Pty, u32)] = &[
    (Pty::ISIG, 1),   // enable signal generation (Ctrl-C → SIGINT)
    (Pty::ICANON, 1), // canonical / line-buffered mode
    (Pty::ECHO, 1),   // echo input characters
    (Pty::ECHOE, 1),  // echo erase character
    (Pty::ECHOK, 1),  // echo kill character
    (Pty::IEXTEN, 1), // extended functions
    (Pty::OPOST, 1),  // output processing
    (Pty::ONLCR, 1),  // NL → CR+NL
    (Pty::CS8, 1),    // 8-bit data
];

/// Secret material for one connection attempt.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Credentials {
    Password(String),
    KeyFile {
        path: PathBuf,
        passphrase: Option<String>,
    },
}

/// What to do when the server's host key is not in known_hosts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnknownHostKeyPolicy {
    /// Refuse to connect (the UI should prompt and retry with TOFU).
    Reject,
    /// Trust on first use: store the key and connect.
    AcceptAndStore,
}

/// Output of a remotely executed command.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ExecOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit_status: Option<u32>,
}

/// Why a host-key check failed, captured inside the russh handler and
/// read back after `client::connect` returns its (generic) error.
#[derive(Debug, Default)]
struct KeyCheckFailure {
    /// Stored and presented key fingerprints (SHA256 colon-separated).
    mismatch: Option<(String, String)>,
    /// Presented OpenSSH key string and its SHA256 fingerprint.
    unknown: Option<(String, String)>,
    io_error: Option<String>,
}

struct ClientHandler {
    host: String,
    port: u16,
    known_hosts_path: PathBuf,
    policy: UnknownHostKeyPolicy,
    failure: Arc<Mutex<KeyCheckFailure>>,
    telemetry_id: u64,
}

/// 已认证连接允许长期无业务流量；存活性只由真实 I/O 与 SSH keepalive 判断。
fn client_config() -> client::Config {
    client::Config {
        inactivity_timeout: None,
        keepalive_interval: Some(DEFAULT_TIMEOUT),
        nodelay: true,
        ..Default::default()
    }
}

impl ClientHandler {
    fn record(&self, f: impl FnOnce(&mut KeyCheckFailure)) {
        if let Ok(mut guard) = self.failure.lock() {
            f(&mut guard);
        }
    }
}

impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn disconnected(
        &mut self,
        reason: client::DisconnectReason<Self::Error>,
    ) -> std::result::Result<(), Self::Error> {
        match reason {
            client::DisconnectReason::Error(error) => {
                let kind = if matches!(error, russh::Error::KeepaliveTimeout) {
                    LifecycleKind::KeepaliveFailed
                } else {
                    LifecycleKind::TransportError
                };
                global_registry().fail_with_event(self.telemetry_id, kind);
                Err(error)
            }
            client::DisconnectReason::ReceivedDisconnect(_) => {
                global_registry().fail_with_event(self.telemetry_id, LifecycleKind::TransportError);
                Ok(())
            }
        }
    }

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> std::result::Result<bool, Self::Error> {
        let key_str = match server_public_key.to_openssh() {
            Ok(s) => s,
            Err(e) => {
                self.record(|f| f.io_error = Some(e.to_string()));
                return Ok(false);
            }
        };
        // KnownHosts re-reads its file on every call, so a separate
        // instance over the same path stays consistent with the caller's.
        let known_hosts = KnownHosts::new(self.known_hosts_path.clone());
        match known_hosts.check(&self.host, self.port, &key_str) {
            Ok(HostKeyStatus::Match) => Ok(true),
            Ok(HostKeyStatus::Mismatch { stored }) => {
                // 上报指纹而非完整密钥,UI 直接展示;坏记录回退为原始字符串。
                let stored_fp = fingerprint_sha256(&stored).unwrap_or(stored);
                let presented_fp = fingerprint_sha256(&key_str).unwrap_or_else(|_| key_str.clone());
                self.record(|f| f.mismatch = Some((stored_fp, presented_fp)));
                Ok(false)
            }
            Ok(HostKeyStatus::Unknown) => match self.policy {
                UnknownHostKeyPolicy::AcceptAndStore => {
                    match known_hosts.store(&self.host, self.port, &key_str) {
                        Ok(()) => Ok(true),
                        Err(e) => {
                            self.record(|f| f.io_error = Some(e.to_string()));
                            Ok(false)
                        }
                    }
                }
                UnknownHostKeyPolicy::Reject => {
                    let fingerprint =
                        fingerprint_sha256(&key_str).unwrap_or_else(|_| key_str.clone());
                    self.record(|f| f.unknown = Some((key_str.clone(), fingerprint)));
                    Ok(false)
                }
            },
            Err(e) => {
                self.record(|f| f.io_error = Some(e.to_string()));
                Ok(false)
            }
        }
    }
}

/// An authenticated SSH connection.
pub struct SshSession {
    handle: Handle<ClientHandler>,
    telemetry_id: u64,
    /// 所有者释放时唤醒传输读端，即使孤儿 Channel 仍持有 russh sender 也必须结束。
    _lifetime: oneshot::Sender<()>,
}

/// 建连成功前临时拥有遥测记录；任一提前返回都会自动移除无会话所有者的记录。
struct PendingConnectionTelemetry(Option<u64>);

impl PendingConnectionTelemetry {
    fn new(telemetry_id: u64) -> Self {
        Self(Some(telemetry_id))
    }

    fn commit(mut self) -> u64 {
        self.0.take().expect("pending telemetry id")
    }
}

impl Drop for PendingConnectionTelemetry {
    fn drop(&mut self) {
        if let Some(telemetry_id) = self.0.take() {
            global_registry().unregister_connection(telemetry_id);
        }
    }
}

/// 计量交给 russh 的加密传输字节；不包含 TCP/IP 头或内核重传。
struct CountingStream {
    inner: tokio::net::TcpStream,
    telemetry_id: u64,
    lifetime: oneshot::Receiver<()>,
}

impl AsyncRead for CountingStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        if Pin::new(&mut self.lifetime).poll(cx).is_ready() {
            return Poll::Ready(Ok(()));
        }
        let before = buf.filled().len();
        match Pin::new(&mut self.inner).poll_read(cx, buf) {
            Poll::Ready(Ok(())) => {
                let received = (buf.filled().len() - before) as u64;
                if received == 0 {
                    global_registry().fail(self.telemetry_id, "Socket EOF".into());
                    global_registry().record_event(self.telemetry_id, LifecycleKind::SocketEof);
                } else {
                    global_registry().record_io(self.telemetry_id, received, 0);
                }
                Poll::Ready(Ok(()))
            }
            Poll::Ready(Err(error)) => {
                global_registry().fail(self.telemetry_id, error.to_string());
                global_registry().record_event(self.telemetry_id, LifecycleKind::ReadError);
                Poll::Ready(Err(error))
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

impl AsyncWrite for CountingStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        match Pin::new(&mut self.inner).poll_write(cx, buf) {
            Poll::Ready(Ok(count)) => {
                global_registry().record_io(self.telemetry_id, 0, count as u64);
                Poll::Ready(Ok(count))
            }
            Poll::Ready(Err(error)) => {
                global_registry().fail(self.telemetry_id, error.to_string());
                global_registry().record_event(self.telemetry_id, LifecycleKind::WriteError);
                Poll::Ready(Err(error))
            }
            Poll::Pending => Poll::Pending,
        }
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

impl SshSession {
    /// 建立由调用方显式拥有的独立连接，并注册弱引用供健康检查使用。
    pub async fn connect_shared(
        cfg: &HostConfig,
        creds: Credentials,
        known_hosts: &mut KnownHosts,
        unknown_policy: UnknownHostKeyPolicy,
    ) -> Result<Arc<Self>> {
        let session = Arc::new(Self::connect(cfg, creds, known_hosts, unknown_policy).await?);
        crate::connection_registry::global_registry().register(&session);
        Ok(session)
    }

    /// Connect, verify the host key and authenticate.
    pub async fn connect(
        cfg: &HostConfig,
        creds: Credentials,
        known_hosts: &mut KnownHosts,
        unknown_policy: UnknownHostKeyPolicy,
    ) -> Result<Self> {
        let config = Arc::new(client_config());

        let telemetry_id = global_registry()
            .register_connection(cfg.id.clone(), format!("{}:{}", cfg.host, cfg.port));
        let pending_telemetry = PendingConnectionTelemetry::new(telemetry_id);

        let failure = Arc::new(Mutex::new(KeyCheckFailure::default()));
        let handler = ClientHandler {
            host: cfg.host.clone(),
            port: cfg.port,
            known_hosts_path: known_hosts.path().to_path_buf(),
            policy: unknown_policy,
            failure: failure.clone(),
            telemetry_id,
        };

        let addr = (cfg.host.as_str(), cfg.port);
        let socket =
            match tokio::time::timeout(DEFAULT_TIMEOUT, tokio::net::TcpStream::connect(addr)).await
            {
                Ok(Ok(socket)) => socket,
                Ok(Err(error)) => {
                    global_registry().fail_with_event(telemetry_id, LifecycleKind::TransportError);
                    return Err(Error::Ssh(russh::Error::IO(error)));
                }
                Err(_) => {
                    global_registry().fail_with_event(telemetry_id, LifecycleKind::ConnectionTimeout);
                    return Err(Error::Timeout);
                }
            };
        if config.nodelay {
            let _ = socket.set_nodelay(true);
        }
        let (lifetime, lifetime_rx) = oneshot::channel();
        let mut handle = match tokio::time::timeout(
            DEFAULT_TIMEOUT,
            client::connect_stream(
                config,
                CountingStream {
                    inner: socket,
                    telemetry_id,
                    lifetime: lifetime_rx,
                },
                handler,
            ),
        )
        .await
        {
            Ok(Ok(handle)) => handle,
            Ok(Err(e)) => {
                global_registry().fail_with_event(telemetry_id, LifecycleKind::TransportError);
                return Err(Self::map_connect_error(e, cfg, &failure));
            }
            Err(_) => {
                global_registry().fail_with_event(telemetry_id, LifecycleKind::ConnectionTimeout);
                return Err(Error::Timeout);
            }
        };

        match tokio::time::timeout(DEFAULT_TIMEOUT, Self::authenticate(&mut handle, cfg, creds))
            .await
        {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                global_registry().fail_with_event(telemetry_id, LifecycleKind::AuthenticationFailed);
                return Err(error);
            }
            Err(_) => {
                global_registry().fail_with_event(telemetry_id, LifecycleKind::ConnectionTimeout);
                return Err(Error::Timeout);
            }
        }
        global_registry().set_authenticated(telemetry_id);
        let telemetry_id = pending_telemetry.commit();

        Ok(Self {
            handle,
            telemetry_id,
            _lifetime: lifetime,
        })
    }

    async fn authenticate(
        handle: &mut Handle<ClientHandler>,
        cfg: &HostConfig,
        creds: Credentials,
    ) -> Result<()> {
        let result = match creds {
            Credentials::Password(password) => {
                handle
                    .authenticate_password(cfg.username.clone(), password)
                    .await?
            }
            Credentials::KeyFile { path, passphrase } => {
                let key = load_secret_key(&path, passphrase.as_deref())
                    .map_err(|error| Self::map_private_key_error(error, passphrase.is_some()))?;
                let key = PrivateKeyWithHashAlg::new(Arc::new(key), None);
                handle
                    .authenticate_publickey(cfg.username.clone(), key)
                    .await?
            }
        };
        match result {
            AuthResult::Success => Ok(()),
            AuthResult::Failure { .. } => Err(Error::AuthFailed),
        }
    }

    fn map_private_key_error(error: russh::keys::Error, has_passphrase: bool) -> Error {
        if matches!(error, russh::keys::Error::KeyIsEncrypted) && !has_passphrase {
            Error::MissingPassphrase
        } else {
            Error::Key(error)
        }
    }

    /// Turn a generic connect failure into a precise host-key error when
    /// the handler recorded one.
    fn map_connect_error(
        error: russh::Error,
        cfg: &HostConfig,
        failure: &Arc<Mutex<KeyCheckFailure>>,
    ) -> Error {
        if let Ok(guard) = failure.lock() {
            if let Some((stored_fingerprint, presented_fingerprint)) = &guard.mismatch {
                return Error::HostKeyMismatch {
                    host: format!("{}:{}", cfg.host, cfg.port),
                    stored_fingerprint: stored_fingerprint.clone(),
                    presented_fingerprint: presented_fingerprint.clone(),
                };
            }
            if let Some((presented, fingerprint)) = &guard.unknown {
                return Error::UnknownHostKey {
                    host: format!("{}:{}", cfg.host, cfg.port),
                    presented: presented.clone(),
                    fingerprint: fingerprint.clone(),
                };
            }
            if let Some(io) = &guard.io_error {
                return Error::Other(format!("host key check failed: {io}"));
            }
        }
        Error::Ssh(error)
    }

    /// Run `command` on a fresh session channel and collect its output.
    /// Times out after 60 seconds (`Error::Timeout`).
    pub async fn exec(&self, command: &str) -> Result<ExecOutput> {
        self.exec_with_timeout(command, EXEC_TIMEOUT).await
    }

    /// Like [`exec`](Self::exec) with an explicit timeout. On timeout the
    /// channel is dropped and `Error::Timeout` returned.
    pub async fn exec_with_timeout(&self, command: &str, timeout: Duration) -> Result<ExecOutput> {
        tokio::time::timeout(timeout, self.exec_inner(command))
            .await
            .map_err(|_| Error::Timeout)?
    }

    async fn exec_inner(&self, command: &str) -> Result<ExecOutput> {
        let mut channel = match self.handle.channel_open_session().await {
            Ok(channel) => channel,
            Err(error) => {
                global_registry().fail_with_event(self.telemetry_id, LifecycleKind::TransportError);
                return Err(error.into());
            }
        };
        let channel_id =
            global_registry().open_channel(self.telemetry_id, crate::telemetry::ChannelKind::Exec);
        if let Err(error) = channel.exec(true, command).await {
            global_registry().fail_with_event(self.telemetry_id, LifecycleKind::TransportError);
            global_registry().update_channel(
                self.telemetry_id,
                channel_id,
                0,
                0,
                Some(crate::telemetry::ChannelState::Failed),
            );
            return Err(error.into());
        }

        let mut output = ExecOutput::default();
        loop {
            match channel.wait().await {
                Some(ChannelMsg::Data { data }) => {
                    global_registry().update_channel(
                        self.telemetry_id,
                        channel_id,
                        data.len() as u64,
                        0,
                        None,
                    );
                    output.stdout.extend_from_slice(&data)
                }
                Some(ChannelMsg::ExtendedData { data, ext: 1 }) => {
                    global_registry().update_channel(
                        self.telemetry_id,
                        channel_id,
                        data.len() as u64,
                        0,
                        None,
                    );
                    output.stderr.extend_from_slice(&data)
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    output.exit_status = Some(exit_status)
                }
                Some(ChannelMsg::Close) => {
                    global_registry().update_channel(
                        self.telemetry_id,
                        channel_id,
                        0,
                        0,
                        Some(crate::telemetry::ChannelState::Closed),
                    );
                    break;
                }
                None => {
                    global_registry().fail_with_event(self.telemetry_id, LifecycleKind::TransportError);
                    global_registry().update_channel(
                        self.telemetry_id,
                        channel_id,
                        0,
                        0,
                        Some(crate::telemetry::ChannelState::Failed),
                    );
                    return Err(Error::ShellSessionClosed);
                }
                Some(_) => {}
            }
        }
        Ok(output)
    }

    /// Open a raw session channel (used by the SFTP layer).
    pub(crate) async fn open_channel(&self) -> Result<russh::Channel<client::Msg>> {
        Ok(self.handle.channel_open_session().await?)
    }

    pub fn telemetry_id(&self) -> u64 {
        self.telemetry_id
    }

    /// 关联不含敏感内容的 UI 标签或后台任务所有者。
    pub fn set_owner(&self, owner_kind: impl Into<String>, owner_id: impl Into<String>) {
        global_registry().set_owner(self.telemetry_id, owner_kind, owner_id);
    }

    pub async fn check_health(&self) -> crate::telemetry::HealthState {
        if let Some(state) =
            global_registry().recent_health(self.telemetry_id, Duration::from_secs(1))
        {
            return state;
        }
        match self.handle.channel_open_session().await {
            Ok(channel) => {
                let _ = channel.close().await;
                global_registry().set_health(
                    self.telemetry_id,
                    crate::telemetry::HealthState::Healthy,
                    None,
                );
                crate::telemetry::HealthState::Healthy
            }
            Err(error) => {
                global_registry().set_health(
                    self.telemetry_id,
                    crate::telemetry::HealthState::Unavailable,
                    Some(error.to_string()),
                );
                crate::telemetry::HealthState::Unavailable
            }
        }
    }

    /// Politely close the connection.
    pub async fn disconnect(&self) -> Result<()> {
        if self.handle.is_closed() {
            return Ok(());
        }
        global_registry().record_event(self.telemetry_id, LifecycleKind::ExplicitClose);
        global_registry().mark_explicit_close(self.telemetry_id);
        global_registry().close_connection(self.telemetry_id);
        let result = self
            .handle
            .disconnect(Disconnect::ByApplication, "", "")
            .await;
        result.map_err(Error::from)
    }

    /// Open a raw session channel for interactive shell use.
    pub(crate) async fn open_session_channel(&self) -> Result<russh::Channel<client::Msg>> {
        Ok(self.handle.channel_open_session().await?)
    }
}

impl Drop for SshSession {
    fn drop(&mut self) {
        global_registry().unregister_connection(self.telemetry_id);
    }
}

/// An interactive shell session over an already authenticated SSH connection.
///
/// Bytes written with [`write`](Self::write) are sent to the remote shell,
/// and bytes emitted by the remote side are buffered and can be polled with
/// [`read`](Self::read). The shell channel is closed when [`close`](Self::close)
/// is called. A shell owner receives a dedicated `SshSession`, so releasing
/// this object also releases only that shell's transport.
pub struct ShellSession {
    /// 持有 Arc 以延长 SSH 连接生命周期，直到 ShellSession 被 drop。
    #[allow(dead_code)]
    session: Arc<SshSession>,
    writer: mpsc::Sender<Vec<u8>>,
    /// Resize 命令发送端，由 resize() 方法使用。
    resize_tx: mpsc::Sender<(u32, u32)>,
    reader: Option<tokio::task::JoinHandle<()>>,
    output: Arc<Mutex<Vec<u8>>>,
    /// 本地关闭或远端 shell 关闭后设为 true。读取接口会先排空已有输出，
    /// 随后才报告会话关闭，避免吞掉远端退出前的最后一批字节。
    closed: Arc<AtomicBool>,
    failed: Arc<AtomicBool>,
    /// 远端 `exit-status`；`u32::MAX` 表示服务端未提供该字段。
    exit_status: Arc<std::sync::atomic::AtomicU32>,
    telemetry_id: u64,
    channel_telemetry_id: u64,
}

impl ShellSession {
    /// Open a shell channel on `session` and start the background reader.
    ///
    /// Requests a PTY (pseudo-terminal) from the server with standard
    /// terminal modes and the `TERM` environment variable before starting
    /// the remote shell, so the shell runs with full terminal semantics
    /// (ANSI escape codes, line editing, job control).
    pub async fn open(session: Arc<SshSession>) -> Result<Self> {
        let mut channel = session.open_session_channel().await?;

        // 1. Allocate a pseudo-terminal on the server.
        channel
            .request_pty(
                false,
                TERM_TYPE,
                DEFAULT_COLS,
                DEFAULT_ROWS,
                0,
                0,
                STANDARD_TERMINAL_MODES,
            )
            .await?;

        // 2. Advertise the terminal type via the `TERM` env var.
        //    set-env is a best-effort request; servers that do not support
        //    it will silently ignore the failure.
        if channel.set_env(false, "TERM", TERM_TYPE).await.is_err() {
            crate::logger::global_logger().warning("SSH", "终端 TERM 环境变量未被远端接受");
        }

        // 3. Start the remote shell process.
        channel.request_shell(true).await?;

        let telemetry_id = session.telemetry_id();
        let channel_telemetry_id =
            global_registry().open_channel(telemetry_id, crate::telemetry::ChannelKind::Shell);

        let output = Arc::new(Mutex::new(Vec::new()));
        let (writer, mut rx) = mpsc::channel::<Vec<u8>>(64);
        let (resize_tx, mut resize_rx) = mpsc::channel::<(u32, u32)>(8);
        let output_reader = output.clone();
        let closed = Arc::new(AtomicBool::new(false));
        let reader_closed = Arc::clone(&closed);
        let failed = Arc::new(AtomicBool::new(false));
        let reader_failed = Arc::clone(&failed);
        let exit_status = Arc::new(std::sync::atomic::AtomicU32::new(u32::MAX));
        let reader_exit_status = Arc::clone(&exit_status);
        let reader_telemetry_id = telemetry_id;
        let reader_channel_telemetry_id = channel_telemetry_id;
        let reader = tokio::spawn(async move {
            let mut saw_close = false;
            loop {
                tokio::select! {
                    Some(data) = rx.recv() => {
                        if let Err(error) = channel.data(&data[..]).await {
                            reader_failed.store(true, Ordering::SeqCst);
                            global_registry().fail(reader_telemetry_id, error.to_string());
                            global_registry().record_event(reader_telemetry_id, LifecycleKind::WriteError);
                            global_registry().update_channel(reader_telemetry_id, reader_channel_telemetry_id, 0, 0, Some(crate::telemetry::ChannelState::Failed));
                            break;
                        }
                        global_registry().update_channel(reader_telemetry_id, reader_channel_telemetry_id, 0, data.len() as u64, None);
                    }
                    Some((cols, rows)) = resize_rx.recv() => {
                        if channel.window_change(cols, rows, 0, 0).await.is_err() {
                            crate::logger::global_logger().warning("SSH", "终端尺寸同步失败");
                        }
                    }
                    msg = channel.wait() => {
                        match msg {
                            Some(ChannelMsg::Data { data }) => {
                                global_registry().update_channel(reader_telemetry_id, reader_channel_telemetry_id, data.len() as u64, 0, None);
                                output_reader
                                    .lock()
                                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                                    .extend_from_slice(&data);
                            }
                            Some(ChannelMsg::ExtendedData { data, .. }) => {
                                global_registry().update_channel(reader_telemetry_id, reader_channel_telemetry_id, data.len() as u64, 0, None);
                                output_reader
                                    .lock()
                                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                                    .extend_from_slice(&data);
                            }
                            Some(ChannelMsg::Close) => {
                                saw_close = true;
                            }
                            Some(ChannelMsg::ExitStatus { exit_status }) => {
                                reader_exit_status.store(exit_status, Ordering::SeqCst);
                            }
                            None => {
                                if saw_close {
                                    let status = reader_exit_status.load(Ordering::SeqCst);
                                    if status != u32::MAX && status != 0 {
                                        reader_failed.store(true, Ordering::SeqCst);
                                        global_registry().fail(reader_telemetry_id, "远端 shell 以非零退出码结束".into());
                                        global_registry().record_event(reader_telemetry_id, LifecycleKind::TransportError);
                                    } else {
                                        global_registry().record_event(reader_telemetry_id, LifecycleKind::ShellExit);
                                    }
                                } else {
                                    reader_failed.store(true, Ordering::SeqCst);
                                    global_registry().fail(reader_telemetry_id, "SSH 通道在未收到关闭通知前结束".into());
                                    global_registry().record_event(reader_telemetry_id, LifecycleKind::TransportError);
                                }
                                break;
                            }
                            Some(_) => {}
                        }
                    }
                }
            }
            reader_closed.store(true, Ordering::SeqCst);
            global_registry().update_channel(
                reader_telemetry_id,
                reader_channel_telemetry_id,
                0,
                0,
                Some(if reader_failed.load(Ordering::SeqCst) {
                    crate::telemetry::ChannelState::Failed
                } else {
                    crate::telemetry::ChannelState::Closed
                }),
            );
            if channel.close().await.is_err() {
                crate::logger::global_logger().warning("SSH", "终端通道关闭请求失败");
            }
        });

        Ok(Self {
            session,
            writer,
            resize_tx,
            reader: Some(reader),
            output,
            closed,
            failed,
            exit_status,
            telemetry_id,
            channel_telemetry_id,
        })
    }

    /// Send input bytes to the remote shell.
    pub fn write(&self, data: &[u8]) -> Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        if self.closed.load(Ordering::SeqCst) {
            global_registry().update_channel(
                self.telemetry_id,
                self.channel_telemetry_id,
                0,
                0,
                Some(crate::telemetry::ChannelState::Failed),
            );
            return Err(self.closed_error());
        }
        match self.writer.try_send(data.to_vec()) {
            Ok(()) => Ok(()),
            Err(mpsc::error::TrySendError::Full(_)) => Err(Error::ShellInputBackpressure),
            Err(mpsc::error::TrySendError::Closed(_)) => {
                self.failed.store(true, Ordering::SeqCst);
                global_registry().update_channel(
                    self.telemetry_id,
                    self.channel_telemetry_id,
                    0,
                    0,
                    Some(crate::telemetry::ChannelState::Failed),
                );
                Err(Error::Other("shell 输入通道已意外关闭".into()))
            }
        }
    }

    /// Notify the server that the PTY window has been resized to
    /// `cols` × `rows` characters.
    ///
    /// The actual SSH channel request is sent asynchronously by the
    /// background reader task; failures are ignored (the shell keeps
    /// working even if the server does not support window-change).
    pub fn resize(&self, cols: u32, rows: u32) -> Result<()> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(self.closed_error());
        }
        self.resize_tx
            .try_send((cols, rows))
            .map_err(|_| Error::Other("failed to send resize notification".into()))
    }

    /// Read up to `max` bytes that the remote shell has produced.
    pub fn read(&self, max: usize) -> Result<Vec<u8>> {
        let mut buf = self
            .output
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let take = max.min(buf.len());
        if take > 0 {
            return Ok(buf.drain(..take).collect());
        }
        if self.closed.load(Ordering::SeqCst) {
            return Err(self.closed_error());
        }
        Ok(Vec::new())
    }

    fn closed_error(&self) -> Error {
        let status = self.exit_status.load(Ordering::SeqCst);
        if status != u32::MAX && status != 0 {
            Error::ShellExitStatus(status)
        } else if self.failed.load(Ordering::SeqCst) {
            Error::Other("SSH 连接异常".into())
        } else {
            Error::ShellSessionClosed
        }
    }

    /// Close the shell channel and wait for the reader to finish.
    /// 底层 Transport 由本 ShellSession 独占，并随本对象释放。
    pub async fn close(&mut self) -> Result<()> {
        self.closed.store(true, Ordering::SeqCst);
        let mut reader_error = None;
        if let Some(reader) = self.reader.take() {
            // 不经过输入队列；即使队列满或远端窗口不再消费也能精确释放。
            reader.abort();
            if let Err(error) = reader.await {
                if error.is_panic() {
                    self.failed.store(true, Ordering::SeqCst);
                    global_registry().fail(self.telemetry_id, "终端后台任务异常结束".into());
                    reader_error = Some(Error::Other("终端后台任务异常结束".into()));
                }
            }
        }
        global_registry().update_channel(
            self.telemetry_id,
            self.channel_telemetry_id,
            0,
            0,
            Some(crate::telemetry::ChannelState::Closed),
        );
        match tokio::time::timeout(Duration::from_secs(1), self.session.disconnect()).await {
            Ok(Ok(())) => reader_error.map_or(Ok(()), Err),
            Ok(Err(error)) => Err(error),
            Err(_) => Err(Error::Timeout),
        }
    }
}

impl Drop for ShellSession {
    fn drop(&mut self) {
        // 任务句柄默认 Drop 会脱离任务；必须显式取消，防止孤儿读循环继续持有 Channel。
        if let Some(reader) = self.reader.take() {
            reader.abort();
        }
    }
}

/// 连接失败的分类。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FailureCategory {
    /// 连接超时
    Timeout,
    /// 认证失败
    AuthFailed,
    /// 缺少凭据(密码或口令未保存)
    MissingCredential,
    /// 主机密钥不匹配
    HostKeyMismatch,
    /// 其他错误
    Other,
}

/// 连接失败的分类记录,包含分类、标题和详情。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionFailureRecord {
    pub category: FailureCategory,
    pub title: String,
    pub detail: String,
}

/// 将 `Error` 分类为连接失败记录。
pub fn connection_failure_classify(error: &Error) -> ConnectionFailureRecord {
    match error {
        Error::Timeout => ConnectionFailureRecord {
            category: FailureCategory::Timeout,
            title: "连接超时".into(),
            detail: "服务器在规定时间内未响应,请检查网络连接或服务器状态。".into(),
        },
        Error::AuthFailed => ConnectionFailureRecord {
            category: FailureCategory::AuthFailed,
            title: "认证失败".into(),
            detail: "用户名或密码不正确,请检查凭据。".into(),
        },
        Error::MissingPassphrase
        | Error::CredentialProtectionKeyRequired
        | Error::CredentialUnlockFailed
        | Error::InvalidCredentialFile => ConnectionFailureRecord {
            category: FailureCategory::MissingCredential,
            title: "缺少凭据".into(),
            detail: format!("{error}"),
        },
        Error::HostKeyMismatch {
            host,
            stored_fingerprint,
            presented_fingerprint,
        } => ConnectionFailureRecord {
            category: FailureCategory::HostKeyMismatch,
            title: "主机密钥变更".into(),
            detail: format!(
                "主机 {host} 的密钥与已存储的不匹配。\n\
                 已存储: {stored_fingerprint}\n\
                 当前: {presented_fingerprint}\n\
                 这可能是中间人攻击,也可能是服务器重装。"
            ),
        },
        Error::UnknownHostKey { .. } => ConnectionFailureRecord {
            category: FailureCategory::Other,
            title: "未知主机密钥".into(),
            detail: format!("{error}"),
        },
        other => ConnectionFailureRecord {
            category: FailureCategory::Other,
            title: "连接失败".into(),
            detail: format!("{other}"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::AuthMethod;

    #[tokio::test]
    async fn keepalive_failure_is_recorded_without_remote_payload() {
        use russh::client::Handler;
        let telemetry_id =
            global_registry().register_connection("fixture".into(), "example.test:22".into());
        let mut handler = ClientHandler {
            host: "example.test".into(),
            port: 22,
            known_hosts_path: PathBuf::new(),
            policy: UnknownHostKeyPolicy::Reject,
            failure: Arc::new(Mutex::new(KeyCheckFailure::default())),
            telemetry_id,
        };
        assert!(handler
            .disconnected(client::DisconnectReason::Error(
                russh::Error::KeepaliveTimeout
            ))
            .await
            .is_err());
        let snapshot = global_registry()
            .snapshot()
            .into_iter()
            .find(|s| s.id == telemetry_id)
            .unwrap();
        assert_eq!(
            snapshot.health_state,
            crate::telemetry::HealthState::Unavailable
        );
        assert_eq!(snapshot.last_error.as_deref(), Some("SSH keepalive 失败"));
        global_registry().unregister_connection(telemetry_id);
    }

    fn test_cfg() -> HostConfig {
        HostConfig {
            id: "id".into(),
            name: "box".into(),
            host: "example.com".into(),
            port: 22,
            username: "panda".into(),
            auth: AuthMethod::Password { password_ref: None },
            notes: None,
            group_id: None,
        }
    }

    #[test]
    fn authenticated_connection_has_keepalive_without_inactivity_timeout() {
        let config = client_config();
        assert_eq!(config.inactivity_timeout, None);
        assert_eq!(config.keepalive_interval, Some(DEFAULT_TIMEOUT));
        assert!(config.keepalive_max > 0);
    }

    #[test]
    fn unknown_host_key_error_carries_presented_key_and_fingerprint() {
        let failure = Arc::new(Mutex::new(KeyCheckFailure {
            unknown: Some(("ssh-ed25519 AAAAexample".into(), "SHA256:abc123".into())),
            ..Default::default()
        }));
        let err = SshSession::map_connect_error(russh::Error::Disconnect, &test_cfg(), &failure);
        let msg = err.to_string();
        assert!(msg.contains("unknown host key"), "got: {msg}");
        assert!(msg.contains("example.com:22"), "got: {msg}");
        assert!(msg.contains("SHA256:abc123"), "got: {msg}");
    }

    #[test]
    fn host_key_mismatch_error_carries_both_fingerprints() {
        let failure = Arc::new(Mutex::new(KeyCheckFailure {
            mismatch: Some(("SHA256:aa:bb".into(), "SHA256:cc:dd".into())),
            ..Default::default()
        }));
        let err = SshSession::map_connect_error(russh::Error::Disconnect, &test_cfg(), &failure);
        let msg = err.to_string();
        assert!(msg.contains("host key mismatch"), "got: {msg}");
        assert!(msg.contains("example.com:22"), "got: {msg}");
        assert!(msg.contains("SHA256:aa:bb"), "got: {msg}");
        assert!(msg.contains("SHA256:cc:dd"), "got: {msg}");
    }

    #[test]
    fn io_error_in_host_key_check_maps_to_other() {
        let failure = Arc::new(Mutex::new(KeyCheckFailure {
            io_error: Some("disk failure".into()),
            ..Default::default()
        }));
        let err = SshSession::map_connect_error(russh::Error::Disconnect, &test_cfg(), &failure);
        assert!(err.to_string().contains("disk failure"), "got: {err}");
    }

    #[test]
    fn map_connect_error_falls_back_to_raw_ssh_error() {
        let failure = Arc::new(Mutex::new(KeyCheckFailure::default()));
        let err = SshSession::map_connect_error(russh::Error::Disconnect, &test_cfg(), &failure);
        assert!(err.to_string().contains("ssh error"), "got: {err}");
    }

    #[test]
    fn encrypted_private_key_without_passphrase_is_recoverable() {
        let error = SshSession::map_private_key_error(russh::keys::Error::KeyIsEncrypted, false);
        assert!(matches!(error, Error::MissingPassphrase));
    }

    #[test]
    fn encrypted_private_key_with_passphrase_keeps_key_error() {
        let error = SshSession::map_private_key_error(russh::keys::Error::KeyIsEncrypted, true);
        assert!(matches!(
            error,
            Error::Key(russh::keys::Error::KeyIsEncrypted)
        ));
    }

    #[test]
    fn record_silently_ignores_poisoned_lock() {
        let failure = Arc::new(Mutex::new(KeyCheckFailure::default()));
        let cloned = failure.clone();
        // 让一个线程在持锁时 panic，把互斥锁毒化。
        let handle = std::thread::spawn(move || {
            let _guard = cloned.lock().unwrap();
            panic!("poison the mutex");
        });
        assert!(handle.join().is_err());

        let handler = ClientHandler {
            host: "h".into(),
            port: 22,
            known_hosts_path: PathBuf::from("/tmp/kh"),
            policy: UnknownHostKeyPolicy::AcceptAndStore,
            failure,
            telemetry_id: 0,
        };
        // 锁已毒化：record() 必须静默跳过，不 panic。
        handler.record(|_| {});
    }

    #[test]
    fn record_applies_update_when_lock_is_healthy() {
        let failure = Arc::new(Mutex::new(KeyCheckFailure::default()));
        let handler = ClientHandler {
            host: "h".into(),
            port: 22,
            known_hosts_path: PathBuf::from("/tmp/kh"),
            policy: UnknownHostKeyPolicy::AcceptAndStore,
            failure: failure.clone(),
            telemetry_id: 0,
        };
        handler.record(|f| f.io_error = Some("healthy".into()));
        let guard = failure.lock().unwrap();
        assert_eq!(guard.io_error.as_deref(), Some("healthy"));
    }

    // --- connection_failure_classify ---

    #[test]
    fn timeout_error_classifies_as_timeout() {
        let record = connection_failure_classify(&Error::Timeout);
        assert_eq!(record.category, FailureCategory::Timeout);
        assert!(!record.title.is_empty());
    }

    #[test]
    fn auth_failed_classifies_as_auth_failed() {
        let record = connection_failure_classify(&Error::AuthFailed);
        assert_eq!(record.category, FailureCategory::AuthFailed);
    }

    #[test]
    fn missing_passphrase_classifies_as_missing_credential() {
        let record = connection_failure_classify(&Error::MissingPassphrase);
        assert_eq!(record.category, FailureCategory::MissingCredential);
    }

    #[test]
    fn credential_protection_key_required_classifies_as_missing_credential() {
        let record = connection_failure_classify(&Error::CredentialProtectionKeyRequired);
        assert_eq!(record.category, FailureCategory::MissingCredential);
    }

    #[test]
    fn credential_unlock_failed_classifies_as_missing_credential() {
        let record = connection_failure_classify(&Error::CredentialUnlockFailed);
        assert_eq!(record.category, FailureCategory::MissingCredential);
    }

    #[test]
    fn invalid_credential_file_classifies_as_missing_credential() {
        let record = connection_failure_classify(&Error::InvalidCredentialFile);
        assert_eq!(record.category, FailureCategory::MissingCredential);
    }

    #[test]
    fn host_key_mismatch_classifies_as_host_key_mismatch() {
        let error = Error::HostKeyMismatch {
            host: "example.com:22".into(),
            stored_fingerprint: "SHA256:aaa".into(),
            presented_fingerprint: "SHA256:bbb".into(),
        };
        let record = connection_failure_classify(&error);
        assert_eq!(record.category, FailureCategory::HostKeyMismatch);
        assert!(record.detail.contains("example.com"));
        assert!(record.detail.contains("SHA256:aaa"));
        assert!(record.detail.contains("SHA256:bbb"));
    }

    #[test]
    fn other_error_classifies_as_other() {
        let error = Error::Other("something went wrong".into());
        let record = connection_failure_classify(&error);
        assert_eq!(record.category, FailureCategory::Other);
        assert!(record.detail.contains("something went wrong"));
    }

    #[test]
    fn io_error_classifies_as_other() {
        let error = Error::Io(std::io::Error::new(std::io::ErrorKind::Other, "disk fail"));
        let record = connection_failure_classify(&error);
        assert_eq!(record.category, FailureCategory::Other);
    }

    #[test]
    fn shell_session_closed_classifies_as_other() {
        let record = connection_failure_classify(&Error::ShellSessionClosed);
        assert_eq!(record.category, FailureCategory::Other);
    }

    #[test]
    fn cancelled_classifies_as_other() {
        let record = connection_failure_classify(&Error::Cancelled);
        assert_eq!(record.category, FailureCategory::Other);
    }

    #[test]
    fn unknown_host_key_classifies_as_other() {
        let error = Error::UnknownHostKey {
            host: "example.com".into(),
            presented: "ssh-ed25519 AAAA".into(),
            fingerprint: "SHA256:abc".into(),
        };
        let record = connection_failure_classify(&error);
        assert_eq!(record.category, FailureCategory::Other);
        assert!(record.title.contains("未知主机密钥"));
    }
}

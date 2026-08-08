//! SSH session handling built on russh.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::client::{self, AuthResult, Handle};
use russh::keys::{PrivateKeyWithHashAlg, load_secret_key};
use russh::{ChannelMsg, Disconnect};
use tokio::sync::mpsc;

use crate::config::HostConfig;
use crate::hostkey::{HostKeyStatus, KnownHosts, fingerprint_sha256};
use crate::{Error, Result};

/// Default timeout for connect + auth, and for connection inactivity.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

/// Default timeout for one `exec` call; a command that never finishes must
/// not block the caller forever.
const EXEC_TIMEOUT: Duration = Duration::from_secs(60);

/// Secret material for one connection attempt.
#[derive(Debug, Clone)]
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
                    let fingerprint = fingerprint_sha256(&key_str)
                        .unwrap_or_else(|_| key_str.clone());
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
}

impl SshSession {
    /// Connect, verify the host key and authenticate.
    pub async fn connect(
        cfg: &HostConfig,
        creds: Credentials,
        known_hosts: &mut KnownHosts,
        unknown_policy: UnknownHostKeyPolicy,
    ) -> Result<Self> {
        let config = Arc::new(client::Config {
            inactivity_timeout: Some(DEFAULT_TIMEOUT),
            keepalive_interval: Some(DEFAULT_TIMEOUT),
            nodelay: true,
            ..Default::default()
        });

        let failure = Arc::new(Mutex::new(KeyCheckFailure::default()));
        let handler = ClientHandler {
            host: cfg.host.clone(),
            port: cfg.port,
            known_hosts_path: known_hosts.path().to_path_buf(),
            policy: unknown_policy,
            failure: failure.clone(),
        };

        let addr = (cfg.host.as_str(), cfg.port);
        let mut handle = match tokio::time::timeout(
            DEFAULT_TIMEOUT,
            client::connect(config, addr, handler),
        )
        .await
        {
            Ok(Ok(handle)) => handle,
            Ok(Err(e)) => return Err(Self::map_connect_error(e, cfg, &failure)),
            Err(_) => return Err(Error::Timeout),
        };

        tokio::time::timeout(DEFAULT_TIMEOUT, Self::authenticate(&mut handle, cfg, creds))
            .await
            .map_err(|_| Error::Timeout)??;

        Ok(Self { handle })
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
                let key = load_secret_key(&path, passphrase.as_deref())?;
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
        let mut channel = self.handle.channel_open_session().await?;
        channel.exec(true, command).await?;

        let mut output = ExecOutput::default();
        loop {
            match channel.wait().await {
                Some(ChannelMsg::Data { data }) => output.stdout.extend_from_slice(&data),
                Some(ChannelMsg::ExtendedData { data, ext: 1 }) => {
                    output.stderr.extend_from_slice(&data)
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    output.exit_status = Some(exit_status)
                }
                Some(ChannelMsg::Close) | None => break,
                Some(_) => {}
            }
        }
        Ok(output)
    }

    /// Open a raw session channel (used by the SFTP layer).
    pub(crate) async fn open_channel(&self) -> Result<russh::Channel<client::Msg>> {
        Ok(self.handle.channel_open_session().await?)
    }

    /// Politely close the connection.
    pub async fn disconnect(&self) -> Result<()> {
        self.handle
            .disconnect(Disconnect::ByApplication, "", "")
            .await?;
        Ok(())
    }

    /// Open a raw session channel for interactive shell use.
    pub(crate) async fn open_session_channel(&self) -> Result<russh::Channel<client::Msg>> {
        Ok(self.handle.channel_open_session().await?)
    }
}

/// An interactive shell session over an already authenticated SSH connection.
///
/// Bytes written with [`write`](Self::write) are sent to the remote shell,
/// and bytes emitted by the remote side are buffered and can be polled with
/// [`read`](Self::read). The session is closed and the SSH connection is
/// disconnected when [`close`](Self::close) is called.
pub struct ShellSession {
    session: SshSession,
    writer: mpsc::Sender<Vec<u8>>,
    reader: Option<tokio::task::JoinHandle<()>>,
    output: Arc<Mutex<Vec<u8>>>,
    closed: AtomicBool,
}

impl ShellSession {
    /// Open a shell channel on `session` and start the background reader.
    pub async fn open(session: SshSession) -> Result<Self> {
        let mut channel = session.open_session_channel().await?;
        channel.request_shell(true).await?;

        let output = Arc::new(Mutex::new(Vec::new()));
        let (writer, mut rx) = mpsc::channel::<Vec<u8>>(64);
        let output_reader = output.clone();
        let reader = tokio::spawn(async move {
            loop {
                tokio::select! {
                    Some(data) = rx.recv() => {
                        // 空消息作为关闭信号
                        if data.is_empty() {
                            break;
                        }
                        if channel.data(&data[..]).await.is_err() {
                            break;
                        }
                    }
                    msg = channel.wait() => {
                        match msg {
                            Some(ChannelMsg::Data { data }) => {
                                output_reader.lock().unwrap().extend_from_slice(&data);
                            }
                            Some(ChannelMsg::ExtendedData { data, .. }) => {
                                output_reader.lock().unwrap().extend_from_slice(&data);
                            }
                            Some(ChannelMsg::Close) | None => break,
                            Some(_) => {}
                        }
                    }
                }
            }
            let _ = channel.close().await;
        });

        Ok(Self {
            session,
            writer,
            reader: Some(reader),
            output,
            closed: AtomicBool::new(false),
        })
    }

    /// Send input bytes to the remote shell.
    pub fn write(&self, data: &[u8]) -> Result<()> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(Error::ShellSessionClosed);
        }
        self.writer
            .try_send(data.to_vec())
            .map_err(|_| Error::Other("failed to send data to shell".into()))
    }

    /// Read up to `max` bytes that the remote shell has produced.
    pub fn read(&self, max: usize) -> Result<Vec<u8>> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(Error::ShellSessionClosed);
        }
        let mut buf = self.output.lock().unwrap();
        let take = max.min(buf.len());
        Ok(buf.drain(..take).collect())
    }

    /// Close the shell channel, wait for the reader to finish and disconnect.
    pub async fn close(&mut self) -> Result<()> {
        self.closed.store(true, Ordering::SeqCst);
        let _ = self.writer.try_send(Vec::new());
        if let Some(reader) = self.reader.take() {
            let _ = reader.await;
        }
        self.session.disconnect().await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::AuthMethod;

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
        };
        handler.record(|f| f.io_error = Some("healthy".into()));
        let guard = failure.lock().unwrap();
        assert_eq!(guard.io_error.as_deref(), Some("healthy"));
    }
}

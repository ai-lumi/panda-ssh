//! 可由任意宿主直接构造的 Panda SSH 应用上下文。
//!
//! 此模块只负责组合既有核心领域存储。FFI 可以持有 `PandaCore` 的引用，
//! 但不得重新装配或拥有这些存储的业务状态。

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
};

use uuid::Uuid;

use crate::{
    credential_resolve, AuthMethod, ConfigStore, CredentialStore, GroupStore, HostConfig,
    KnownHosts, FileConflictInfo, RemoteFile, ResolvedCredential, Result, SftpClient, ShellSession,
    SidebarNodeRecord, Snippet, SnippetStore, SshSession, TerminalBufferError,
    TomlConfigStore, TomlGroupStore, UnknownHostKeyPolicy,
};
use crate::config_archive::{ExportManifest, ImportError, ImportResult};
use crate::delete_tasks::{DeleteError, DeleteFileSystem, NodeKind};
use crate::tofu::{TofuCoordinator, TofuRegistration};

/// 调用方对某个凭据槽位的明确编辑意图。
///
/// `Preserve` 与空字符串不同：前者保留已有引用，后者不是可保存的秘密；这样
/// 未编辑的表单不会被误解为删除已保存凭据。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialIntent {
    Preserve,
    Set(String),
    Remove,
}

/// 保存主机及其瞬态凭据输入的完整用例。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostSaveRequest {
    pub host: HostConfig,
    pub password: CredentialIntent,
    pub passphrase: CredentialIntent,
}

/// 联合保存成功后的权威配置快照。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostSaveResult {
    pub host: HostConfig,
}

/// 删除主机后的结果；未知 id 是显式无操作，避免适配器猜测删除范围。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostDeleteResult {
    pub deleted: bool,
}

/// 连接用例解析后的瞬态凭据；绝不写入配置快照或日志。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionCredentials {
    Available {
        password: Option<String>,
        passphrase: Option<String>,
    },
    NeedsPassword,
    NeedsPassphrase,
}

/// 等待用户输入的凭据类型。秘密本身不进入请求或快照。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionCredentialKind {
    Password,
    Passphrase,
}

/// 由核心创建、必须原样回传的连接凭据输入请求。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionCredentialRequest {
    pub id: String,
    pub session_id: String,
    pub host_id: String,
    pub kind: ConnectionCredentialKind,
}

/// 连接前凭据检查的权威结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionCredentialPreparation {
    Ready(ConnectionCredentials),
    NeedsInput(ConnectionCredentialRequest),
}

#[derive(Default)]
struct ConnectionInteractions {
    pending: HashMap<String, ConnectionCredentialRequest>,
}

struct OwnedSftpSession {
    session: Arc<SshSession>,
    client: SftpClient,
}

/// 会话注册时用于代次校验的复合键。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SessionKey {
    pub session_id: String,
    pub generation: u32,
}

#[derive(Clone)]
struct TestShellSession;

#[derive(Clone)]
struct TestSftpSession;

#[derive(Clone)]
enum ShellSessionEntry {
    Real(Arc<Mutex<ShellSession>>),
    Test(TestShellSession),
}

#[derive(Clone)]
enum SftpSessionEntry {
    Real(Arc<tokio::sync::Mutex<OwnedSftpSession>>),
    Test(TestSftpSession),
}

/// 基于 SFTP 会话的删除文件系统适配；每次操作独立获取互斥锁。
pub struct SftpDeleteFileSystem {
    session: Arc<tokio::sync::Mutex<OwnedSftpSession>>,
}

impl DeleteFileSystem for SftpDeleteFileSystem {
    async fn inspect(&self, path: &str) -> std::result::Result<NodeKind, DeleteError> {
        let attrs = self
            .session
            .lock()
            .await
            .client
            .metadata(path)
            .await
            .map_err(|e| DeleteError::new(e.to_string(), false))?;
        Ok(if attrs.is_dir() {
            NodeKind::Directory
        } else {
            NodeKind::File
        })
    }

    async fn children(&self, path: &str) -> std::result::Result<Vec<String>, DeleteError> {
        let files = self
            .session
            .lock()
            .await
            .client
            .list_dir(path)
            .await
            .map_err(|e| DeleteError::new(e.to_string(), false))?;
        Ok(files
            .into_iter()
            .filter(|f| f.name != "." && f.name != "..")
            .map(|f| f.name)
            .collect())
    }

    async fn remove(&self, path: &str, kind: NodeKind) -> std::result::Result<(), DeleteError> {
        let guard = self.session.lock().await;
        let result = match kind {
            NodeKind::Directory => guard.client.remove_dir(path).await,
            NodeKind::File | NodeKind::Symlink => guard.client.remove_file(path).await,
        };
        result.map_err(|e| DeleteError::new(e.to_string(), false))
    }
}

/// 配置根目录的权限所有权。
///
/// 平台适配器只提供这一事实；凭据文件校验和业务存储策略仍由核心执行。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageLocation {
    /// Panda SSH 独占的常规配置目录，核心负责收紧目录权限。
    PrivateConfig,
    /// 由平台（例如 App Group）管理目录权限的容器。
    PlatformContainer,
}

/// 一个应用实例使用的、由宿主提供的配置根目录。
///
/// 不同实例不共享存储对象或缓存。调用方若要替换其默认实例，已有操作应继续
/// 保留创建时获得的 `Arc<PandaCore>`，而不是在执行中回查另一个全局实例。
pub struct PandaCore {
    config_root: PathBuf,
    config: TomlConfigStore,
    #[allow(dead_code)] // 后续领域服务会使用；上下文现在即固定其作用域。
    groups: TomlGroupStore,
    #[allow(dead_code)] // 后续连接/信任服务会使用；上下文现在即固定其作用域。
    known_hosts: KnownHosts,
    #[allow(dead_code)] // 后续凭据用例会使用；上下文现在即固定其作用域。
    credentials: CredentialStore,
    interactions: Mutex<ConnectionInteractions>,
    shell_sessions: Mutex<HashMap<u64, ShellSessionEntry>>,
    sftp_sessions: tokio::sync::Mutex<HashMap<u64, SftpSessionEntry>>,
    next_shell_handle: AtomicU64,
    next_sftp_handle: AtomicU64,
    /// 会话代次跟踪：session_id → 当前代次。
    session_generations: Mutex<HashMap<String, u32>>,
    /// 句柄到会话标识的反向映射，用于精确释放。
    handle_to_session: Mutex<HashMap<u64, String>>,
    /// TOFU 并发协调器：管理未知主机密钥的首次信任确认。
    tofu: TofuCoordinator,
    /// 片段存储：管理代码片段。
    snippets: SnippetStore,
}

impl PandaCore {
    /// 在 `config_root` 下构造应用上下文。
    ///
    /// 目录创建失败（例如给出常规文件）会原样返回 I/O 错误；具体权限收紧与
    /// 存储位置类别将在存储保护领域统一处理。
    pub fn new(config_root: impl AsRef<Path>) -> Result<Self> {
        Self::new_with_storage_location(config_root, StorageLocation::PrivateConfig)
    }

    /// 在指定的存储位置类别中构造应用上下文。
    pub fn new_with_storage_location(
        config_root: impl AsRef<Path>,
        storage_location: StorageLocation,
    ) -> Result<Self> {
        let config_root = config_root.as_ref().to_path_buf();
        std::fs::create_dir_all(&config_root)?;
        fix_storage_permissions(&config_root, storage_location)?;

        Ok(Self {
            config: TomlConfigStore::new(config_root.join("hosts.toml")),
            groups: TomlGroupStore::new(config_root.join("groups.toml")),
            known_hosts: KnownHosts::new(config_root.join("known_hosts")),
            credentials: CredentialStore::new(config_root.join("credentials.toml")),
            interactions: Mutex::new(ConnectionInteractions::default()),
            shell_sessions: Mutex::new(HashMap::new()),
            sftp_sessions: tokio::sync::Mutex::new(HashMap::new()),
            next_shell_handle: AtomicU64::new(1),
            next_sftp_handle: AtomicU64::new(1),
            session_generations: Mutex::new(HashMap::new()),
            handle_to_session: Mutex::new(HashMap::new()),
            tofu: TofuCoordinator::new(),
            snippets: SnippetStore::new(config_root.join("snippets")),
            config_root,
        })
    }

    /// 返回此上下文固定使用的配置根目录。
    pub fn config_root(&self) -> &Path {
        &self.config_root
    }

    /// 保存主机配置。凭据联合写入将在后续应用用例中收敛到这里。
    pub fn save_host(&self, host: HostConfig) -> Result<()> {
        self.config.upsert(host)
    }

    /// 保存主机与凭据，并在失败时尽力恢复此前的配置和凭据。
    ///
    /// 配置与凭据位于两个原子文件中，不能承诺跨文件崩溃原子性；但本进程内的
    /// 任一写入或清理失败都不会被报告为成功，且会保留最初失败原因。
    pub fn save_host_with_credentials(&self, request: HostSaveRequest) -> Result<HostSaveResult> {
        let HostSaveRequest {
            mut host,
            password,
            passphrase,
        } = request;
        if host.id.is_empty() {
            return Err(crate::Error::Other("主机 id 不能为空".into()));
        }

        let existing = self.config.get(&host.id)?;
        let old_password_ref = existing.as_ref().and_then(password_reference);
        let old_passphrase_ref = existing.as_ref().and_then(passphrase_reference);
        let password_ref = format!("host.{}.password", host.id);
        let passphrase_ref = format!("host.{}.passphrase", host.id);

        let desired_password = match host.auth {
            AuthMethod::Password { .. } => {
                resolve_credential_intent(password, old_password_ref.as_deref(), &password_ref)?
            }
            AuthMethod::PublicKey { .. } => None,
        };
        let desired_passphrase = match host.auth {
            AuthMethod::PublicKey { .. } => resolve_credential_intent(
                passphrase,
                old_passphrase_ref.as_deref(),
                &passphrase_ref,
            )?,
            AuthMethod::Password { .. } => None,
        };

        host.auth = match host.auth {
            AuthMethod::Password { .. } => AuthMethod::Password {
                password_ref: desired_password
                    .as_ref()
                    .map(|entry| entry.reference.clone()),
            },
            AuthMethod::PublicKey { key_path, .. } => AuthMethod::PublicKey {
                key_path,
                passphrase_ref: desired_passphrase
                    .as_ref()
                    .map(|entry| entry.reference.clone()),
            },
        };

        let mut affected_references = vec![password_ref, passphrase_ref];
        affected_references.extend(old_password_ref);
        affected_references.extend(old_passphrase_ref);
        affected_references.sort();
        affected_references.dedup();
        let credential_snapshot = affected_references
            .iter()
            .map(|reference| Ok((reference.clone(), self.credentials.get(reference)?)))
            .collect::<Result<Vec<_>>>()?;

        let result = (|| {
            if let Some(entry) = desired_password.as_ref().or(desired_passphrase.as_ref()) {
                if let Some(secret) = &entry.secret {
                    self.credentials
                        .save(entry.reference.clone(), secret.clone())?;
                }
            }
            self.config.upsert(host.clone())?;
            let retained = [
                desired_password
                    .as_ref()
                    .map(|entry| entry.reference.as_str()),
                desired_passphrase
                    .as_ref()
                    .map(|entry| entry.reference.as_str()),
            ];
            for reference in &affected_references {
                if !retained.contains(&Some(reference.as_str())) {
                    self.credentials.delete(reference)?;
                }
            }
            Ok(())
        })();

        if let Err(original_error) = result {
            // 配置回滚优先，随后按读取前快照恢复每个受影响的秘密。补偿失败不能
            // 覆盖原始失败事实。
            let _ = match existing {
                Some(previous) => self.config.upsert(previous),
                None => self.config.delete(&host.id),
            };
            for (reference, previous) in credential_snapshot {
                let _ = match previous {
                    Some(secret) => self.credentials.save(reference, secret),
                    None => self.credentials.delete(&reference),
                };
            }
            return Err(original_error);
        }
        Ok(HostSaveResult { host })
    }

    /// 删除主机及该主机配置实际引用的凭据，并在配置删除失败时恢复秘密。
    pub fn delete_host_with_credentials(&self, id: &str) -> Result<HostDeleteResult> {
        let Some(host) = self.config.get(id)? else {
            return Ok(HostDeleteResult { deleted: false });
        };
        let mut references = [password_reference(&host), passphrase_reference(&host)]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
        // 兼容既有固定命名引用：认证方式切换中断后可能留下未被当前配置引用的
        // 同主机凭据，删除该主机时一并清理，但绝不触及其他主机的引用。
        references.push(format!("host.{id}.password"));
        references.push(format!("host.{id}.passphrase"));
        references.sort();
        references.dedup();
        let snapshot = references
            .iter()
            .map(|reference| Ok((reference.clone(), self.credentials.get(reference)?)))
            .collect::<Result<Vec<_>>>()?;

        let result = (|| {
            for reference in &references {
                self.credentials.delete(reference)?;
            }
            self.config.delete(id)
        })();
        if let Err(original_error) = result {
            for (reference, secret) in snapshot {
                let _ = match secret {
                    Some(secret) => self.credentials.save(reference, secret),
                    None => self.credentials.delete(&reference),
                };
            }
            return Err(original_error);
        }
        Ok(HostDeleteResult { deleted: true })
    }

    /// 复制非敏感主机配置，复制项永不复用源主机的凭据引用或秘密。
    pub fn copy_host(&self, id: &str) -> Result<HostConfig> {
        let mut copy = self
            .config
            .get(id)?
            .ok_or_else(|| crate::Error::Other(format!("未知主机: {id}")))?;
        copy.id = Uuid::new_v4().to_string();
        copy.auth = match copy.auth {
            AuthMethod::Password { .. } => AuthMethod::Password { password_ref: None },
            AuthMethod::PublicKey { key_path, .. } => AuthMethod::PublicKey {
                key_path,
                passphrase_ref: None,
            },
        };
        self.config.upsert(copy.clone())?;
        Ok(copy)
    }

    /// 读取此上下文中的全部主机配置。
    pub fn list_hosts(&self) -> Result<Vec<HostConfig>> {
        self.config.list()
    }

    /// 按当前会话的手动输入优先、再回退到已保存凭据的规则解析连接凭据。
    pub fn resolve_connection_credentials(
        &self,
        host_id: &str,
        manual_secret: Option<&str>,
    ) -> Result<ConnectionCredentials> {
        let host = self
            .config
            .get(host_id)?
            .ok_or_else(|| crate::Error::Other(format!("未知主机: {host_id}")))?;
        if let Some(secret) = manual_secret.filter(|secret| !secret.is_empty()) {
            return Ok(match host.auth {
                AuthMethod::Password { .. } => ConnectionCredentials::Available {
                    password: Some(secret.into()),
                    passphrase: None,
                },
                AuthMethod::PublicKey { .. } => ConnectionCredentials::Available {
                    password: None,
                    passphrase: Some(secret.into()),
                },
            });
        }
        Ok(match credential_resolve(&self.credentials, &host)? {
            ResolvedCredential::Available {
                password,
                passphrase,
            } => ConnectionCredentials::Available {
                password,
                passphrase,
            },
            ResolvedCredential::NeedsPassword => ConnectionCredentials::NeedsPassword,
            ResolvedCredential::NeedsPassphrase => ConnectionCredentials::NeedsPassphrase,
        })
    }

    /// 将已验证的连接凭据映射为 SSH 层输入；缺失凭据保持为结构化核心错误。
    pub fn ssh_credentials_for_connection(
        &self,
        host_id: &str,
        manual_secret: Option<&str>,
    ) -> Result<crate::Credentials> {
        let host = self
            .config
            .get(host_id)?
            .ok_or_else(|| crate::Error::Other(format!("未知主机: {host_id}")))?;
        match (
            host.auth,
            self.resolve_connection_credentials(host_id, manual_secret)?,
        ) {
            (
                AuthMethod::Password { .. },
                ConnectionCredentials::Available {
                    password: Some(password),
                    ..
                },
            ) => Ok(crate::Credentials::Password(password)),
            (
                AuthMethod::PublicKey { key_path, .. },
                ConnectionCredentials::Available { passphrase, .. },
            ) => Ok(crate::Credentials::KeyFile {
                path: key_path,
                passphrase,
            }),
            (AuthMethod::Password { .. }, ConnectionCredentials::NeedsPassword) => {
                Err(crate::Error::MissingPassword(host_id.into()))
            }
            (AuthMethod::PublicKey { .. }, ConnectionCredentials::NeedsPassphrase) => {
                Err(crate::Error::MissingPassphrase)
            }
            (_, other) => Err(crate::Error::Other(format!("凭据状态不匹配: {other:?}"))),
        }
    }

    /// 为某会话准备连接凭据。缺失时由核心生成关联请求，UI 只能呈现该请求。
    pub fn prepare_connection_credentials(
        &self,
        session_id: &str,
        host_id: &str,
        manual_secret: Option<&str>,
    ) -> Result<ConnectionCredentialPreparation> {
        match self.resolve_connection_credentials(host_id, manual_secret)? {
            available @ ConnectionCredentials::Available { .. } => {
                Ok(ConnectionCredentialPreparation::Ready(available))
            }
            ConnectionCredentials::NeedsPassword => {
                Ok(ConnectionCredentialPreparation::NeedsInput(
                    self.create_connection_credential_request(
                        session_id,
                        host_id,
                        ConnectionCredentialKind::Password,
                    )?,
                ))
            }
            ConnectionCredentials::NeedsPassphrase => {
                Ok(ConnectionCredentialPreparation::NeedsInput(
                    self.create_connection_credential_request(
                        session_id,
                        host_id,
                        ConnectionCredentialKind::Passphrase,
                    )?,
                ))
            }
        }
    }

    /// 响应一个仍有效的输入请求。空输入不消耗请求，以便 UI 保留草稿后重试。
    pub fn respond_connection_credential(
        &self,
        request_id: &str,
        secret: &str,
    ) -> Result<ConnectionCredentialPreparation> {
        if secret.is_empty() {
            return Err(crate::Error::Other("凭据不能为空".into()));
        }
        let request = self
            .interactions
            .lock()
            .map_err(|_| crate::Error::Other("连接交互状态已损坏".into()))?
            .pending
            .get(request_id)
            .cloned()
            .ok_or_else(|| crate::Error::Other(format!("未知或已失效的交互请求: {request_id}")))?;
        let result = self.resolve_connection_credentials(&request.host_id, Some(secret))?;
        let ConnectionCredentials::Available { .. } = result else {
            return Err(crate::Error::Other("输入未能满足连接凭据请求".into()));
        };
        self.interactions
            .lock()
            .map_err(|_| crate::Error::Other("连接交互状态已损坏".into()))?
            .pending
            .remove(request_id);
        Ok(ConnectionCredentialPreparation::Ready(result))
    }

    /// 关闭或重试会话时废弃其全部待输入请求；之后的迟到响应不会复活该会话。
    pub fn cancel_connection_interactions(&self, session_id: &str) {
        if let Ok(mut interactions) = self.interactions.lock() {
            interactions
                .pending
                .retain(|_, request| request.session_id != session_id);
        }
    }

    /// 建立并注册一个由调用方独占的交互式 Shell 会话。
    ///
    /// `session_id` 与 `generation` 用于代次校验：重试时 `generation` 递增，
    /// 核心在连接前拒绝过期代次以避免浪费 SSH 握手。传 `None` 则跳过代次跟踪。
    pub async fn open_shell_session(
        &self,
        host_id: &str,
        manual_secret: Option<&str>,
        trust_on_first_use: bool,
        session_id: Option<&str>,
        generation: Option<u32>,
    ) -> Result<u64> {
        if let (Some(id), Some(gen)) = (session_id, generation) {
            self.validate_session_registration(id, gen)?;
        }
        let (host, session) = self
            .connect_for_session(host_id, manual_secret, trust_on_first_use)
            .await?;
        let shell = ShellSession::open(Arc::clone(&session)).await?;
        let handle = self.next_shell_handle.fetch_add(1, Ordering::SeqCst);
        session.set_owner("终端标签", handle.to_string());
        self.shell_sessions
            .lock()
            .map_err(|_| crate::Error::Other("Shell 会话表已损坏".into()))?
            .insert(handle, ShellSessionEntry::Real(Arc::new(Mutex::new(shell))));
        if let (Some(id), Some(gen)) = (session_id, generation) {
            self.register_session(id, gen, handle, true);
        }
        let _ = host;
        Ok(handle)
    }

    /// 建立并注册一个由调用方独占的 SFTP 会话。
    pub async fn open_sftp_session(
        &self,
        host_id: &str,
        manual_secret: Option<&str>,
        trust_on_first_use: bool,
        session_id: Option<&str>,
        generation: Option<u32>,
    ) -> Result<u64> {
        if let (Some(id), Some(gen)) = (session_id, generation) {
            self.validate_session_registration(id, gen)?;
        }
        let (_, session) = self
            .connect_for_session(host_id, manual_secret, trust_on_first_use)
            .await?;
        let client = SftpClient::new(&session).await?;
        let handle = self.next_sftp_handle.fetch_add(1, Ordering::SeqCst);
        session.set_owner("SFTP 标签", handle.to_string());
        if let (Some(id), Some(gen)) = (session_id, generation) {
            self.register_session(id, gen, handle, false);
            let owned = Arc::new(tokio::sync::Mutex::new(OwnedSftpSession {
                session,
                client,
            }));
            self.sftp_sessions
                .lock()
                .await
                .insert(handle, SftpSessionEntry::Real(owned));
        } else {
            self.sftp_sessions.lock().await.insert(
                handle,
                SftpSessionEntry::Real(Arc::new(tokio::sync::Mutex::new(OwnedSftpSession {
                    session,
                    client,
                }))),
            );
        }
        Ok(handle)
    }

    /// 注册测试用 Shell 会话，不建立 SSH 连接。
    pub fn register_test_shell(
        &self,
        session_id: &str,
        generation: u32,
    ) -> Result<u64> {
        self.validate_session_registration(session_id, generation)?;
        let handle = self.next_shell_handle.fetch_add(1, Ordering::SeqCst);
        self.register_session(session_id, generation, handle, true);
        self.shell_sessions
            .lock()
            .map_err(|_| crate::Error::Other("Shell 会话表已损坏".into()))?
            .insert(handle, ShellSessionEntry::Test(TestShellSession));
        Ok(handle)
    }

    /// 注册测试用 SFTP 会话，不建立 SSH 连接。
    pub async fn register_test_sftp(
        &self,
        session_id: &str,
        generation: u32,
    ) -> Result<u64> {
        self.validate_session_registration(session_id, generation)?;
        let handle = self.next_sftp_handle.fetch_add(1, Ordering::SeqCst);
        self.register_session(session_id, generation, handle, false);
        self.sftp_sessions
            .lock()
            .await
            .insert(handle, SftpSessionEntry::Test(TestSftpSession));
        Ok(handle)
    }

    /// 取消某会话的所有活跃句柄，递增代次使迟到结果失效。
    pub fn cancel_session(&self, session_id: &str) {
        let mut generations = match self.session_generations.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        let gen = generations.entry(session_id.to_string()).or_insert(0);
        *gen += 1;
        drop(generations);
        self.invalidate_session_handles(session_id);
    }

    /// 检查指定代次是否为当前活跃代次。
    pub fn is_session_stale(&self, session_id: &str, generation: u32) -> bool {
        match self.session_generations.lock() {
            Ok(generations) => generations.get(session_id).copied().unwrap_or(0) != generation,
            Err(_) => true,
        }
    }

    /// 查询指定代次的会话是否仍有活跃句柄。
    pub fn has_active_session(&self, session_id: &str, generation: u32) -> bool {
        if self.is_session_stale(session_id, generation) {
            return false;
        }
        let has_shell = self
            .shell_sessions
            .lock()
            .ok()
            .map(|shells| {
                shells.keys().any(|handle| {
                    self.handle_to_session
                        .lock()
                        .map(|m| m.get(handle).map(|s| s == session_id).unwrap_or(false))
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false);
        if has_shell {
            return true;
        }
        self.sftp_sessions
            .try_lock()
            .map(|sftps| {
                sftps.keys().any(|handle| {
                    self.handle_to_session
                        .lock()
                        .map(|m| m.get(handle).map(|s| s == session_id).unwrap_or(false))
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false)
    }

    fn validate_session_registration(&self, session_id: &str, generation: u32) -> Result<()> {
        let mut generations = self
            .session_generations
            .lock()
            .map_err(|_| crate::Error::Other("会话代次状态已损坏".into()))?;
        let current = generations.get(session_id).copied();
        match current {
            Some(current) if current == generation => Ok(()),
            Some(_) => Err(crate::Error::Cancelled),
            None => {
                generations.insert(session_id.to_string(), generation);
                Ok(())
            }
        }
    }

    fn register_session(
        &self,
        session_id: &str,
        generation: u32,
        handle: u64,
        is_shell: bool,
    ) {
        let _ = is_shell;
        if let Ok(mut handle_map) = self.handle_to_session.lock() {
            handle_map.insert(handle, session_id.to_string());
        }
        if let Ok(mut generations) = self.session_generations.lock() {
            generations.insert(session_id.to_string(), generation);
        }
    }

    fn invalidate_session_handles(&self, session_id: &str) {
        let handles_to_remove: Vec<u64> = {
            let mut handle_map = match self.handle_to_session.lock() {
                Ok(m) => m,
                Err(_) => return,
            };
            let removed: Vec<u64> = handle_map
                .iter()
                .filter(|(_, sid)| *sid == session_id)
                .map(|(handle, _)| *handle)
                .collect();
            for handle in &removed {
                handle_map.remove(handle);
            }
            removed
        };
        if let Ok(mut shells) = self.shell_sessions.lock() {
            for handle in &handles_to_remove {
                shells.remove(handle);
            }
        }
        if let Ok(mut sftps) = self.sftp_sessions.try_lock() {
            for handle in &handles_to_remove {
                sftps.remove(handle);
            }
        }
    }

    pub fn shell_write(&self, handle: u64, data: &[u8]) -> Result<()> {
        match self.shell_session(handle)? {
            ShellSessionEntry::Real(session) => session
                .lock()
                .map_err(|_| crate::Error::Other("Shell 会话已损坏".into()))?
                .write(data),
            ShellSessionEntry::Test(_) => Ok(()),
        }
    }

    pub fn shell_read(&self, handle: u64, max: usize) -> Result<Vec<u8>> {
        match self.shell_session(handle)? {
            ShellSessionEntry::Real(session) => session
                .lock()
                .map_err(|_| crate::Error::Other("Shell 会话已损坏".into()))?
                .read(max),
            ShellSessionEntry::Test(_) => Ok(Vec::new()),
        }
    }

    pub fn shell_resize(&self, handle: u64, cols: u32, rows: u32) -> Result<()> {
        match self.shell_session(handle)? {
            ShellSessionEntry::Real(session) => session
                .lock()
                .map_err(|_| crate::Error::Other("Shell 会话已损坏".into()))?
                .resize(cols, rows),
            ShellSessionEntry::Test(_) => Ok(()),
        }
    }

    pub async fn close_shell_session(&self, handle: u64) -> Result<()> {
        let removed = self
            .shell_sessions
            .lock()
            .map_err(|_| crate::Error::Other("Shell 会话表已损坏".into()))?
            .remove(&handle);
        match removed {
            Some(ShellSessionEntry::Real(session)) => {
                session
                    .lock()
                    .map_err(|_| crate::Error::Other("Shell 会话已损坏".into()))?
                    .close()
                    .await
            }
            Some(ShellSessionEntry::Test(_)) => Ok(()),
            None if handle > 0 && handle < self.next_shell_handle.load(Ordering::SeqCst) => Ok(()),
            None => Err(crate::Error::UnknownShellHandle(handle)),
        }
    }

    pub async fn sftp_session_home_dir(&self, handle: u64) -> Result<String> {
        let owned = self.sftp_session(handle).await?;
        match owned {
            SftpSessionEntry::Real(owned) => {
                let guard = owned.lock().await;
                guard.client.home_dir().await
            }
            SftpSessionEntry::Test(_) => Ok(String::new()),
        }
    }

    pub async fn sftp_session_list(&self, handle: u64, path: &str) -> Result<Vec<RemoteFile>> {
        let owned = self.sftp_session(handle).await?;
        match owned {
            SftpSessionEntry::Real(owned) => {
                let guard = owned.lock().await;
                guard.client.list_dir(path).await
            }
            SftpSessionEntry::Test(_) => Ok(Vec::new()),
        }
    }

    pub async fn sftp_session_check_upload_conflict(
        &self,
        handle: u64,
        local_path: &Path,
        remote_path: &str,
    ) -> Result<Option<FileConflictInfo>> {
        let owned = self.sftp_session(handle).await?;
        match owned {
            SftpSessionEntry::Real(owned) => {
                let guard = owned.lock().await;
                guard.client.check_upload_conflict(local_path, remote_path).await
            }
            SftpSessionEntry::Test(_) => Ok(None),
        }
    }

    pub async fn sftp_session_check_download_conflict(
        &self,
        handle: u64,
        remote_path: &str,
        local_path: &Path,
    ) -> Result<Option<FileConflictInfo>> {
        let owned = self.sftp_session(handle).await?;
        match owned {
            SftpSessionEntry::Real(owned) => {
                let guard = owned.lock().await;
                guard.client.check_download_conflict(remote_path, local_path).await
            }
            SftpSessionEntry::Test(_) => Ok(None),
        }
    }

    pub async fn sftp_session_remove_file(&self, handle: u64, remote_path: &str) -> Result<()> {
        let owned = self.sftp_session(handle).await?;
        match owned {
            SftpSessionEntry::Real(owned) => {
                let guard = owned.lock().await;
                guard.client.remove_file(remote_path).await
            }
            SftpSessionEntry::Test(_) => Ok(()),
        }
    }

    pub async fn sftp_session_remove_dir(&self, handle: u64, remote_path: &str) -> Result<()> {
        let owned = self.sftp_session(handle).await?;
        match owned {
            SftpSessionEntry::Real(owned) => {
                let guard = owned.lock().await;
                guard.client.remove_all(remote_path).await
            }
            SftpSessionEntry::Test(_) => Ok(()),
        }
    }

    pub async fn sftp_session_create_dir(&self, handle: u64, remote_path: &str) -> Result<()> {
        let owned = self.sftp_session(handle).await?;
        match owned {
            SftpSessionEntry::Real(owned) => {
                let guard = owned.lock().await;
                guard.client.create_dir(remote_path).await
            }
            SftpSessionEntry::Test(_) => Ok(()),
        }
    }

    pub async fn sftp_session_upload(
        &self,
        handle: u64,
        local: &std::path::Path,
        remote: &str,
    ) -> Result<()> {
        let owned = self.sftp_session(handle).await?;
        match owned {
            SftpSessionEntry::Real(owned) => {
                let guard = owned.lock().await;
                guard.client.upload(local, remote, None).await
            }
            SftpSessionEntry::Test(_) => Ok(()),
        }
    }

    pub async fn sftp_session_download(
        &self,
        handle: u64,
        remote: &str,
        local: &std::path::Path,
    ) -> Result<()> {
        let owned = self.sftp_session(handle).await?;
        match owned {
            SftpSessionEntry::Real(owned) => {
                let guard = owned.lock().await;
                guard.client.download(remote, local).await
            }
            SftpSessionEntry::Test(_) => Ok(()),
        }
    }

    pub async fn close_sftp_session(&self, handle: u64) -> Result<()> {
        let removed = self.sftp_sessions.lock().await.remove(&handle);
        match removed {
            Some(SftpSessionEntry::Real(owned)) => {
                let guard = owned.lock().await;
                guard.client.close().await?;
                guard.session.disconnect().await
            }
            Some(SftpSessionEntry::Test(_)) => Ok(()),
            None if handle > 0 && handle < self.next_sftp_handle.load(Ordering::SeqCst) => Ok(()),
            None => Err(crate::Error::UnknownSftpHandle(handle)),
        }
    }

    /// 返回 SFTP 会话底层 SSH Transport 的遥测标识，用于连接健康检查。
    pub async fn sftp_session_connection_id(&self, handle: u64) -> Result<u64> {
        let owned = self.sftp_session(handle).await?;
        match owned {
            SftpSessionEntry::Real(owned) => {
                let guard = owned.lock().await;
                Ok(guard.session.telemetry_id())
            }
            SftpSessionEntry::Test(_) => Ok(0),
        }
    }

    /// 为指定 SFTP 句柄创建删除文件系统适配，用于远端删除任务。
    pub async fn create_sftp_delete_fs(
        &self,
        handle: u64,
    ) -> Result<SftpDeleteFileSystem> {
        let entry = self.sftp_session(handle).await?;
        match entry {
            SftpSessionEntry::Real(session) => Ok(SftpDeleteFileSystem { session }),
            SftpSessionEntry::Test(_) => {
                Err(crate::Error::Other("测试会话不支持删除文件系统".into()))
            }
        }
    }

    /// 连接并执行 `true` 以验证认证，返回人类可读的连接摘要后断开。
    pub async fn test_connection(
        &self,
        host_id: &str,
        manual_secret: Option<&str>,
        trust_on_first_use: bool,
    ) -> Result<String> {
        let (host, session) = self
            .connect_for_session(host_id, manual_secret, trust_on_first_use)
            .await?;
        session.set_owner("连接探测", host_id.to_string());
        let output = session.exec("true").await?;
        session.disconnect().await?;
        Ok(format!(
            "connected to {}@{}:{} (exit status: {:?})",
            host.username, host.host, host.port, output.exit_status
        ))
    }

    fn shell_session(&self, handle: u64) -> Result<ShellSessionEntry> {
        self.shell_sessions
            .lock()
            .map_err(|_| crate::Error::Other("Shell 会话表已损坏".into()))?
            .get(&handle)
            .cloned()
            .ok_or(crate::Error::UnknownShellHandle(handle))
    }

    async fn sftp_session(&self, handle: u64) -> Result<SftpSessionEntry> {
        self.sftp_sessions
            .lock()
            .await
            .get(&handle)
            .cloned()
            .ok_or(crate::Error::UnknownSftpHandle(handle))
    }

    async fn connect_for_session(
        &self,
        host_id: &str,
        manual_secret: Option<&str>,
        trust_on_first_use: bool,
    ) -> Result<(HostConfig, Arc<SshSession>)> {
        let host = self
            .config
            .get(host_id)?
            .ok_or_else(|| crate::Error::Other(format!("未知主机: {host_id}")))?;
        let credentials = self.ssh_credentials_for_connection(host_id, manual_secret)?;
        let mut known_hosts = KnownHosts::new(self.known_hosts.path().to_path_buf());
        let policy = if trust_on_first_use {
            UnknownHostKeyPolicy::AcceptAndStore
        } else {
            UnknownHostKeyPolicy::Reject
        };
        let session =
            SshSession::connect_shared(&host, credentials, &mut known_hosts, policy).await?;
        Ok((host, session))
    }

    fn create_connection_credential_request(
        &self,
        session_id: &str,
        host_id: &str,
        kind: ConnectionCredentialKind,
    ) -> Result<ConnectionCredentialRequest> {
        if session_id.is_empty() {
            return Err(crate::Error::Other("会话 id 不能为空".into()));
        }
        let request = ConnectionCredentialRequest {
            id: Uuid::new_v4().to_string(),
            session_id: session_id.into(),
            host_id: host_id.into(),
            kind,
        };
        self.interactions
            .lock()
            .map_err(|_| crate::Error::Other("连接交互状态已损坏".into()))?
            .pending
            .insert(request.id.clone(), request.clone());
        Ok(request)
    }

    /// 为迁移中的适配器提供既有主机存储访问；新的完整用例不得在桥层组合它。
    #[doc(hidden)]
    pub fn config_store(&self) -> &TomlConfigStore {
        &self.config
    }

    /// 为迁移中的适配器提供既有分组存储访问；新的完整用例不得在桥层组合它。
    #[doc(hidden)]
    pub fn group_store(&self) -> &TomlGroupStore {
        &self.groups
    }

    /// 为迁移中的适配器提供既有 known_hosts 访问；信任协调将在核心用例中收敛。
    #[doc(hidden)]
    pub fn known_hosts_store(&self) -> &KnownHosts {
        &self.known_hosts
    }

    /// 为迁移中的适配器提供既有凭据存储访问；凭据编排将在核心用例中收敛。
    #[doc(hidden)]
    pub fn credential_store(&self) -> &CredentialStore {
        &self.credentials
    }

    /// TOFU 协调器访问：管理未知主机密钥的首次信任确认。
    pub fn tofu_coordinator(&self) -> &TofuCoordinator {
        &self.tofu
    }

    /// 注册 TOFU 确认请求并等待结果（阻塞）。
    ///
    /// 返回 `(request_id, is_presenter, presented_key_info)`。
    /// `is_presenter` 为 true 时调用方应展示确认 UI；
    /// 为 false 时调用方是等待者，结果已通过 `waiter_result` 返回。
    pub fn tofu_register(
        &self,
        host: String,
        port: u16,
        key: String,
        fingerprint: String,
    ) -> TofuRegistration {
        self.tofu.register(host, port, key, fingerprint)
    }

    /// 确认信任：写入 known_hosts 并通知所有等待者。
    pub fn tofu_confirm(&self, request_id: &str) -> Result<()> {
        self.tofu.confirm(request_id, &self.known_hosts)
    }

    /// 拒绝信任：通知所有等待者。
    pub fn tofu_reject(&self, request_id: &str) {
        self.tofu.reject(request_id)
    }

    /// 取消请求（呈现者关闭等场景）。
    pub fn tofu_cancel(&self, request_id: &str) {
        self.tofu.cancel(request_id)
    }

    // -----------------------------------------------------------------------
    // 13.1 统一入口：搜索、分组级联、片段、导入导出、设置校验
    // -----------------------------------------------------------------------

    /// 按关键字搜索主机（名称、地址、用户名、分组路径）。空查询返回全部。
    pub fn search_hosts(&self, query: &str) -> Result<Vec<HostConfig>> {
        let hosts = self.config.list()?;
        let groups = self.groups.list()?;
        Ok(crate::config::search_hosts(&hosts, &groups, query))
    }

    /// 删除分组并级联处理子分组和主机归属。
    pub fn delete_group_cascade(&self, id: &str) -> Result<()> {
        crate::groups::delete_group_cascade(&self.groups, &self.config, id)
    }

    /// 移动分组到新的父分组下。
    pub fn move_group(&self, id: &str, new_parent: Option<&str>) -> Result<()> {
        crate::groups::move_group(&self.groups, id, new_parent)
    }

    /// 返回分组的层级路径。
    pub fn group_path(&self, id: &str) -> Result<String> {
        let groups = self.groups.list()?;
        Ok(crate::groups::group_path(&groups, id))
    }

    /// 返回侧边栏树快照。
    pub fn sidebar_tree(&self) -> Result<Vec<SidebarNodeRecord>> {
        let hosts = self.config.list()?;
        let groups = self.groups.list()?;
        Ok(crate::groups::sidebar_tree(&hosts, &groups))
    }

    /// 列出所有片段。
    pub fn snippet_list(&self) -> Result<Vec<Snippet>> {
        Ok(self.snippets.list()?)
    }

    /// 保存片段。
    pub fn snippet_save(&self, snippet: &Snippet) -> Result<()> {
        Ok(self.snippets.save(snippet)?)
    }

    /// 删除片段。
    pub fn snippet_delete(&self, name: &str) -> Result<()> {
        Ok(self.snippets.delete(name)?)
    }

    /// 导出配置归档。
    pub fn config_export(&self, output_path: &std::path::Path) -> std::result::Result<ExportManifest, ImportError> {
        crate::config_archive::config_export(&self.config_root, output_path)
    }

    /// 导入配置归档。
    pub fn config_import(&self, archive_path: &std::path::Path) -> std::result::Result<ImportResult, ImportError> {
        crate::config_archive::config_import(&self.config_root, archive_path)
    }

    /// 校验终端缓冲区行数设置。
    pub fn validate_terminal_buffer(&self, raw: &str) -> std::result::Result<u32, TerminalBufferError> {
        crate::config::validate_terminal_buffer_lines(raw)
    }
}

#[derive(Debug, Clone)]
struct DesiredCredential {
    reference: String,
    secret: Option<String>,
}

fn resolve_credential_intent(
    intent: CredentialIntent,
    previous_reference: Option<&str>,
    canonical_reference: &str,
) -> Result<Option<DesiredCredential>> {
    match intent {
        CredentialIntent::Preserve => Ok(previous_reference.map(|reference| DesiredCredential {
            reference: reference.into(),
            secret: None,
        })),
        CredentialIntent::Set(secret) if secret.is_empty() => {
            Err(crate::Error::Other("凭据不能为空".into()))
        }
        CredentialIntent::Set(secret) => Ok(Some(DesiredCredential {
            reference: canonical_reference.into(),
            secret: Some(secret),
        })),
        CredentialIntent::Remove => Ok(None),
    }
}

fn password_reference(host: &HostConfig) -> Option<String> {
    match &host.auth {
        AuthMethod::Password { password_ref } => password_ref.clone(),
        AuthMethod::PublicKey { .. } => None,
    }
}

fn passphrase_reference(host: &HostConfig) -> Option<String> {
    match &host.auth {
        AuthMethod::Password { .. } => None,
        AuthMethod::PublicKey { passphrase_ref, .. } => passphrase_ref.clone(),
    }
}

fn fix_storage_permissions(root: &Path, storage_location: StorageLocation) -> Result<()> {
    fix_storage_permissions_with(root, storage_location, &OsPermissionSetter)
}

trait PermissionSetter {
    fn set_private_directory_permissions(&self, root: &Path) -> Result<()>;
    fn set_credential_permissions(&self, credential_path: &Path) -> Result<()>;
}

struct OsPermissionSetter;

impl PermissionSetter for OsPermissionSetter {
    fn set_private_directory_permissions(&self, root: &Path) -> Result<()> {
        set_private_directory_permissions(root)
    }

    fn set_credential_permissions(&self, credential_path: &Path) -> Result<()> {
        set_credential_permissions(credential_path)
    }
}

fn fix_storage_permissions_with(
    root: &Path,
    storage_location: StorageLocation,
    permission_setter: &impl PermissionSetter,
) -> Result<()> {
    let credential_path = root.join("credentials.toml");
    let credential_metadata = std::fs::symlink_metadata(&credential_path);
    match credential_metadata {
        Ok(metadata) if metadata.file_type().is_file() => {
            permission_setter.set_credential_permissions(&credential_path)?;
        }
        Ok(_) => {
            return Err(crate::Error::Other(
                "credentials.toml 必须是常规文件".into(),
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }

    // 旧版本使用固定临时文件名。仅收紧常规遗留文件，绝不跟随符号链接。
    let legacy_temporary_path = root.join("credentials.tmp");
    if matches!(
        std::fs::symlink_metadata(&legacy_temporary_path),
        Ok(metadata) if metadata.file_type().is_file()
    ) {
        permission_setter.set_credential_permissions(&legacy_temporary_path)?;
    }

    if storage_location == StorageLocation::PrivateConfig {
        permission_setter.set_private_directory_permissions(root)?;
    }
    Ok(())
}

#[cfg(unix)]
fn set_private_directory_permissions(root: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_private_directory_permissions(_root: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn set_credential_permissions(credential_path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    std::fs::set_permissions(credential_path, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_credential_permissions(_credential_path: &Path) -> Result<()> {
    Ok(())
}

impl std::fmt::Debug for PandaCore {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PandaCore")
            .field("config_root", &self.config_root)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::{fix_storage_permissions_with, PandaCore, PermissionSetter, StorageLocation};

    fn test_core() -> (PandaCore, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let core = PandaCore::new(dir.path()).unwrap();
        (core, dir)
    }

    #[test]
    fn error_type_remains_the_core_error() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("file");
        std::fs::write(&file, "x").unwrap();

        assert!(matches!(PandaCore::new(file), Err(crate::Error::Io(_))));
    }

    struct FailingPermissionSetter;

    impl PermissionSetter for FailingPermissionSetter {
        fn set_private_directory_permissions(&self, _root: &std::path::Path) -> crate::Result<()> {
            Err(crate::Error::Other("无法修改目录权限".into()))
        }

        fn set_credential_permissions(
            &self,
            _credential_path: &std::path::Path,
        ) -> crate::Result<()> {
            Err(crate::Error::Other("无法修改凭据权限".into()))
        }
    }

    #[test]
    fn permission_adapter_failure_is_reported() {
        let directory = tempfile::tempdir().unwrap();

        assert!(matches!(
            fix_storage_permissions_with(
                directory.path(),
                StorageLocation::PrivateConfig,
                &FailingPermissionSetter,
            ),
            Err(crate::Error::Other(message)) if message == "无法修改目录权限"
        ));
    }

    // --- 5.1 会话资源与连接状态机 ---

    #[test]
    fn same_host_independent_shell_sessions_get_distinct_handles() {
        let (core, _dir) = test_core();
        let h1 = core.register_test_shell("s1", 1).unwrap();
        let h2 = core.register_test_shell("s1", 1).unwrap();
        assert_ne!(h1, h2);
        assert!(core.shell_write(h1, b"hello").is_ok());
        assert!(core.shell_write(h2, b"world").is_ok());
        assert_eq!(core.shell_read(h1, 64).unwrap(), Vec::<u8>::new());
        assert!(core.shell_resize(h1, 80, 24).is_ok());
    }

    #[test]
    fn unknown_shell_handle_is_rejected_for_all_operations() {
        let (core, _dir) = test_core();
        let bad = u64::MAX;
        assert!(matches!(
            core.shell_write(bad, b"x"),
            Err(crate::Error::UnknownShellHandle(h)) if h == bad
        ));
        assert!(matches!(
            core.shell_read(bad, 64),
            Err(crate::Error::UnknownShellHandle(h)) if h == bad
        ));
        assert!(matches!(
            core.shell_resize(bad, 80, 24),
            Err(crate::Error::UnknownShellHandle(h)) if h == bad
        ));
    }

    #[test]
    fn close_shell_session_is_idempotent_for_issued_handles() {
        let (core, _dir) = test_core();
        let handle = core.register_test_shell("s1", 1).unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        assert!(rt.block_on(core.close_shell_session(handle)).is_ok());
        assert!(rt.block_on(core.close_shell_session(handle)).is_ok());
    }

    #[test]
    fn close_shell_session_rejects_never_issued_handle() {
        let (core, _dir) = test_core();
        let rt = tokio::runtime::Runtime::new().unwrap();
        assert!(matches!(
            rt.block_on(core.close_shell_session(u64::MAX)),
            Err(crate::Error::UnknownShellHandle(h)) if h == u64::MAX
        ));
    }

    #[test]
    fn cancel_session_invalidates_handles_and_increments_generation() {
        let (core, _dir) = test_core();
        let handle = core.register_test_shell("s1", 1).unwrap();
        assert!(core.has_active_session("s1", 1));
        core.cancel_session("s1");
        assert!(!core.has_active_session("s1", 1));
        assert!(core.is_session_stale("s1", 1));
        assert!(matches!(
            core.shell_write(handle, b"x"),
            Err(crate::Error::UnknownShellHandle(h)) if h == handle
        ));
    }

    #[test]
    fn stale_generation_is_rejected_on_registration() {
        let (core, _dir) = test_core();
        let _h1 = core.register_test_shell("s1", 1).unwrap();
        core.cancel_session("s1");
        assert!(matches!(
            core.register_test_shell("s1", 1),
            Err(crate::Error::Cancelled)
        ));
    }

    #[test]
    fn retry_with_new_generation_succeeds_after_cancel() {
        let (core, _dir) = test_core();
        let _h1 = core.register_test_shell("s1", 1).unwrap();
        core.cancel_session("s1");
        let h2 = core.register_test_shell("s1", 2).unwrap();
        assert!(core.has_active_session("s1", 2));
        assert!(!core.has_active_session("s1", 1));
        assert!(core.shell_write(h2, b"data").is_ok());
    }

    #[tokio::test]
    async fn same_host_independent_sftp_session_gets_distinct_handle() {
        let (core, _dir) = test_core();
        let h = core.register_test_sftp("s1", 1).await.unwrap();
        assert_eq!(core.sftp_session_home_dir(h).await.unwrap(), String::new());
        assert_eq!(core.sftp_session_list(h, "/").await.unwrap(), Vec::<crate::RemoteFile>::new());
    }

    #[tokio::test]
    async fn unknown_sftp_handle_is_rejected_for_all_operations() {
        let (core, _dir) = test_core();
        let bad = u64::MAX;
        assert!(matches!(
            core.sftp_session_home_dir(bad).await,
            Err(crate::Error::UnknownSftpHandle(h)) if h == bad
        ));
        assert!(matches!(
            core.sftp_session_list(bad, "/").await,
            Err(crate::Error::UnknownSftpHandle(h)) if h == bad
        ));
        assert!(matches!(
            core.sftp_session_remove_file(bad, "/f").await,
            Err(crate::Error::UnknownSftpHandle(h)) if h == bad
        ));
        assert!(matches!(
            core.sftp_session_remove_dir(bad, "/d").await,
            Err(crate::Error::UnknownSftpHandle(h)) if h == bad
        ));
        assert!(matches!(
            core.sftp_session_create_dir(bad, "/d").await,
            Err(crate::Error::UnknownSftpHandle(h)) if h == bad
        ));
    }

    #[tokio::test]
    async fn close_sftp_session_is_idempotent_for_issued_handles() {
        let (core, _dir) = test_core();
        let handle = core.register_test_sftp("s1", 1).await.unwrap();
        assert!(core.close_sftp_session(handle).await.is_ok());
        assert!(core.close_sftp_session(handle).await.is_ok());
    }

    #[tokio::test]
    async fn cancel_session_invalidates_sftp_handles() {
        let (core, _dir) = test_core();
        let handle = core.register_test_sftp("s1", 1).await.unwrap();
        assert!(core.has_active_session("s1", 1));
        core.cancel_session("s1");
        assert!(!core.has_active_session("s1", 1));
        assert!(matches!(
            core.sftp_session_home_dir(handle).await,
            Err(crate::Error::UnknownSftpHandle(h)) if h == handle
        ));
    }

    #[test]
    fn is_session_stale_returns_true_for_unknown_session() {
        let (core, _dir) = test_core();
        assert!(core.is_session_stale("never-registered", 1));
    }

    #[test]
    fn has_active_session_returns_false_for_unknown_session() {
        let (core, _dir) = test_core();
        assert!(!core.has_active_session("never-registered", 0));
    }

    // --- 13.3 日志/遥测/健康检查三类测试 ---

    /// 正常：当前活跃代次的 shell 会话被正确识别。
    #[test]
    fn has_active_session_true_for_current_generation_with_shell() {
        let (core, _dir) = test_core();
        let _h = core.register_test_shell("s1", 0).unwrap();
        assert!(core.has_active_session("s1", 0));
        assert!(!core.is_session_stale("s1", 0));
    }

    /// 边界：所有 shell 句柄关闭后 has_active_session 返回 false。
    #[test]
    fn has_active_session_false_after_all_shell_handles_closed() {
        let (core, _dir) = test_core();
        let h1 = core.register_test_shell("s1", 0).unwrap();
        let h2 = core.register_test_shell("s1", 0).unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(core.close_shell_session(h1)).unwrap();
        assert!(core.has_active_session("s1", 0), "仍有一个活跃句柄");
        rt.block_on(core.close_shell_session(h2)).unwrap();
        assert!(!core.has_active_session("s1", 0), "所有句柄已关闭");
    }

    /// 边界：所有 SFTP 句柄关闭后 has_active_session 返回 false。
    #[tokio::test]
    async fn has_active_session_false_after_all_sftp_handles_closed() {
        let (core, _dir) = test_core();
        let h1 = core.register_test_sftp("s1", 0).await.unwrap();
        let h2 = core.register_test_sftp("s1", 0).await.unwrap();
        core.close_sftp_session(h1).await.unwrap();
        assert!(core.has_active_session("s1", 0), "仍有一个活跃句柄");
        core.close_sftp_session(h2).await.unwrap();
        assert!(!core.has_active_session("s1", 0), "所有句柄已关闭");
    }

    /// 意外：cancel 后旧代次立即失效且无活跃句柄。
    #[test]
    fn cancel_session_makes_both_stale_and_inactive_for_old_generation() {
        let (core, _dir) = test_core();
        let _h = core.register_test_shell("s1", 0).unwrap();
        core.cancel_session("s1");
        assert!(core.is_session_stale("s1", 0));
        assert!(!core.has_active_session("s1", 0));
    }

    /// 边界：未知会话在代次 0 时不视为过期（与默认值一致），非零代次则过期；始终不活跃。
    #[test]
    fn unknown_session_stale_depends_on_generation_and_never_active() {
        let (core, _dir) = test_core();
        assert!(!core.is_session_stale("nonexistent", 0));
        assert!(core.is_session_stale("nonexistent", u32::MAX));
        assert!(!core.has_active_session("nonexistent", 0));
        assert!(!core.has_active_session("nonexistent", u32::MAX));
    }

    // --- 13.1 统一入口测试 ---

    use crate::config::AuthMethod;
    use crate::config_archive::ImportError;
    use crate::groups::{Group, GroupStore};
    use crate::{HostConfig, Snippet, TerminalBufferError};

    fn password_host(id: &str, name: &str, host: &str, group_id: Option<&str>) -> HostConfig {
        HostConfig {
            id: id.into(),
            name: name.into(),
            host: host.into(),
            port: 22,
            username: "deploy".into(),
            auth: AuthMethod::Password { password_ref: None },
            notes: None,
            group_id: group_id.map(str::to_string),
        }
    }

    // -- search_hosts --

    #[test]
    fn search_hosts_normal_matches_name_and_username() {
        let (core, _dir) = test_core();
        core.save_host(password_host("h1", "数据库", "db.example.com", None)).unwrap();
        core.save_host(password_host("h2", "Web", "web.example.com", None)).unwrap();

        assert_eq!(core.search_hosts("数据").unwrap().len(), 1);
        assert_eq!(core.search_hosts("deploy").unwrap().len(), 2);
    }

    #[test]
    fn search_hosts_edge_empty_query_returns_all() {
        let (core, _dir) = test_core();
        core.save_host(password_host("h1", "A", "a.com", None)).unwrap();
        core.save_host(password_host("h2", "B", "b.com", None)).unwrap();
        assert_eq!(core.search_hosts("").unwrap().len(), 2);
    }

    #[test]
    fn search_hosts_edge_no_match_returns_empty() {
        let (core, _dir) = test_core();
        core.save_host(password_host("h1", "A", "a.com", None)).unwrap();
        assert!(core.search_hosts("不存在").unwrap().is_empty());
    }

    #[test]
    fn search_hosts_normal_matches_group_path() {
        let (core, _dir) = test_core();
        core.group_store().upsert(Group { id: "g1".into(), name: "生产".into(), parent_id: None }).unwrap();
        core.save_host(password_host("h1", "Web", "web.com", Some("g1"))).unwrap();
        assert_eq!(core.search_hosts("生产").unwrap().len(), 1);
    }

    #[test]
    fn search_hosts_edge_unicode_query() {
        let (core, _dir) = test_core();
        core.save_host(password_host("h1", "東京サーバー", "tokyo.com", None)).unwrap();
        assert_eq!(core.search_hosts("東京").unwrap().len(), 1);
    }

    // -- delete_group_cascade --

    #[test]
    fn delete_group_cascade_normal_removes_children() {
        let (core, _dir) = test_core();
        core.group_store().upsert(Group { id: "parent".into(), name: "P".into(), parent_id: None }).unwrap();
        core.group_store().upsert(Group { id: "child".into(), name: "C".into(), parent_id: Some("parent".into()) }).unwrap();
        core.save_host(password_host("h1", "H", "h.com", Some("child"))).unwrap();

        core.delete_group_cascade("parent").unwrap();

        assert!(core.group_store().get("parent").unwrap().is_none());
        assert!(core.group_store().get("child").unwrap().is_none());
    }

    #[test]
    fn delete_group_cascade_edge_nonexistent_id_is_noop() {
        let (core, _dir) = test_core();
        assert!(core.delete_group_cascade("no-such-group").is_ok());
    }

    // -- move_group --

    #[test]
    fn move_group_normal_reparents() {
        let (core, _dir) = test_core();
        core.group_store().upsert(Group { id: "a".into(), name: "A".into(), parent_id: None }).unwrap();
        core.group_store().upsert(Group { id: "b".into(), name: "B".into(), parent_id: None }).unwrap();

        core.move_group("b", Some("a")).unwrap();
        assert_eq!(core.group_store().get("b").unwrap().unwrap().parent_id.as_deref(), Some("a"));
    }

    #[test]
    fn move_group_unexpected_circular_move_is_rejected() {
        let (core, _dir) = test_core();
        core.group_store().upsert(Group { id: "a".into(), name: "A".into(), parent_id: None }).unwrap();
        core.group_store().upsert(Group { id: "b".into(), name: "B".into(), parent_id: Some("a".into()) }).unwrap();

        assert!(core.move_group("a", Some("b")).is_err());
    }

    #[test]
    fn move_group_edge_move_to_root() {
        let (core, _dir) = test_core();
        core.group_store().upsert(Group { id: "a".into(), name: "A".into(), parent_id: None }).unwrap();
        core.group_store().upsert(Group { id: "b".into(), name: "B".into(), parent_id: Some("a".into()) }).unwrap();

        core.move_group("b", None).unwrap();
        assert!(core.group_store().get("b").unwrap().unwrap().parent_id.is_none());
    }

    // -- group_path --

    #[test]
    fn group_path_normal_nested() {
        let (core, _dir) = test_core();
        core.group_store().upsert(Group { id: "a".into(), name: "A".into(), parent_id: None }).unwrap();
        core.group_store().upsert(Group { id: "b".into(), name: "B".into(), parent_id: Some("a".into()) }).unwrap();

        let path = core.group_path("b").unwrap();
        assert!(path.contains("A"));
        assert!(path.contains("B"));
    }

    #[test]
    fn group_path_edge_unknown_id_returns_fallback() {
        let (core, _dir) = test_core();
        let path = core.group_path("unknown").unwrap();
        assert!(!path.is_empty());
    }

    // -- sidebar_tree --

    #[test]
    fn sidebar_tree_normal_returns_groups_and_hosts() {
        let (core, _dir) = test_core();
        core.group_store().upsert(Group { id: "g1".into(), name: "G".into(), parent_id: None }).unwrap();
        core.save_host(password_host("h1", "H", "h.com", Some("g1"))).unwrap();

        let tree = core.sidebar_tree().unwrap();
        assert!(!tree.is_empty());
    }

    #[test]
    fn sidebar_tree_edge_empty_store() {
        let (core, _dir) = test_core();
        assert!(core.sidebar_tree().unwrap().is_empty());
    }

    // -- snippet CRUD --

    #[test]
    fn snippet_lifecycle_normal_save_list_delete() {
        let (core, _dir) = test_core();
        let s = Snippet {
            name: "test".into(),
            title: "Test".into(),
            tags: vec!["tag1".into()],
            body: "hello".into(),
        };
        core.snippet_save(&s).unwrap();
        assert_eq!(core.snippet_list().unwrap().len(), 1);

        core.snippet_delete("test").unwrap();
        assert!(core.snippet_list().unwrap().is_empty());
    }

    #[test]
    fn snippet_delete_unexpected_nonexistent_is_noop() {
        let (core, _dir) = test_core();
        assert!(core.snippet_delete("no-such-snippet").is_ok());
    }

    #[test]
    fn snippet_lifecycle_edge_unicode_name() {
        let (core, _dir) = test_core();
        let s = Snippet {
            name: "中文片段".into(),
            title: "测试".into(),
            tags: vec![],
            body: "内容".into(),
        };
        core.snippet_save(&s).unwrap();
        let list = core.snippet_list().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "中文片段");
    }

    // -- config_export / config_import --

    #[test]
    fn config_export_import_normal_roundtrip() {
        let (core, _dir) = test_core();
        core.save_host(password_host("h1", "H", "h.com", None)).unwrap();
        core.group_store().upsert(Group { id: "g1".into(), name: "G".into(), parent_id: None }).unwrap();

        let dir = tempfile::tempdir().unwrap();
        let archive = dir.path().join("backup.zip");
        let manifest = core.config_export(&archive).unwrap();
        assert!(manifest.file_count > 0);

        let core2_dir = tempfile::tempdir().unwrap();
        let core2 = PandaCore::new(core2_dir.path()).unwrap();
        let result = core2.config_import(&archive).unwrap();
        assert!(result.host_count > 0 || result.group_count > 0);
    }

    #[test]
    fn config_import_unexpected_corrupted_archive() {
        let (core, _dir) = test_core();
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("corrupt.zip");
        std::fs::write(&fake, b"not a zip file").unwrap();

        let err = core.config_import(&fake).unwrap_err();
        assert!(matches!(err, ImportError::Zip(_)));
    }

    #[test]
    fn config_export_edge_empty_store_succeeds() {
        let (core, _dir) = test_core();
        let dir = tempfile::tempdir().unwrap();
        let archive = dir.path().join("empty.zip");
        let manifest = core.config_export(&archive).unwrap();
        assert_eq!(manifest.file_count, 0);
    }

    #[test]
    fn config_import_unexpected_nonexistent_path() {
        let (core, _dir) = test_core();
        let err = core.config_import(std::path::Path::new("/no/such/file.zip")).unwrap_err();
        assert!(matches!(err, ImportError::Io(_)));
    }

    // -- validate_terminal_buffer --

    #[test]
    fn validate_terminal_buffer_normal_valid_value() {
        let (core, _dir) = test_core();
        assert_eq!(core.validate_terminal_buffer("5000").unwrap(), 5000);
    }

    #[test]
    fn validate_terminal_buffer_normal_empty_returns_default() {
        let (core, _dir) = test_core();
        assert_eq!(core.validate_terminal_buffer("").unwrap(), 10_000);
    }

    #[test]
    fn validate_terminal_buffer_unexpected_not_a_number() {
        let (core, _dir) = test_core();
        let err = core.validate_terminal_buffer("abc").unwrap_err();
        assert_eq!(err, TerminalBufferError::NotANumber);
    }

    #[test]
    fn validate_terminal_buffer_unexpected_out_of_range() {
        let (core, _dir) = test_core();
        let err = core.validate_terminal_buffer("500").unwrap_err();
        assert_eq!(err, TerminalBufferError::OutOfRange);
    }

    #[test]
    fn validate_terminal_buffer_edge_min_boundary() {
        let (core, _dir) = test_core();
        assert_eq!(core.validate_terminal_buffer("1000").unwrap(), 1000);
    }

    #[test]
    fn validate_terminal_buffer_edge_max_boundary() {
        let (core, _dir) = test_core();
        assert_eq!(core.validate_terminal_buffer("100000").unwrap(), 100_000);
    }

    #[test]
    fn validate_terminal_buffer_edge_just_over_max() {
        let (core, _dir) = test_core();
        let err = core.validate_terminal_buffer("100001").unwrap_err();
        assert_eq!(err, TerminalBufferError::OutOfRange);
    }
}

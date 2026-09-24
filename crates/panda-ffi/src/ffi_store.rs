//! 配置、凭据、分组、片段与导入导出的 FFI 导出。

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use panda_core::{
    ConfigStore, Credentials, Group, GroupStore, HostConfig, HostSaveRequest, PandaCore,
    StorageLocation,
};
use uuid::Uuid;

use crate::{CredentialIntentEnum, GroupRecord, HostConfigRecord, KnownHostStatusEnum, PandaError};

impl From<GroupRecord> for Group {
    fn from(r: GroupRecord) -> Self {
        Group {
            id: r.id,
            name: r.name,
            parent_id: r.parent_id,
        }
    }
}

impl From<Group> for GroupRecord {
    fn from(g: Group) -> Self {
        GroupRecord {
            id: g.id,
            name: g.name,
            parent_id: g.parent_id,
        }
    }
}

// ---------------------------------------------------------------------------
// Store state
// ---------------------------------------------------------------------------

/// Stores rooted at the app-provided config directory.
pub(crate) struct Stores {
    pub core: PandaCore,
}

static STORES: Mutex<Option<Arc<Stores>>> = Mutex::new(None);

pub(crate) fn stores() -> Result<Arc<Stores>, PandaError> {
    STORES
        .lock()
        .unwrap()
        .clone()
        .ok_or(PandaError::NotInitialized)
}

/// 根据主机 id 读取主机配置；未知主机返回 UnknownHost 错误。
pub(crate) fn load_host(host_id: &str) -> Result<HostConfig, PandaError> {
    stores()?
        .core
        .config_store()
        .get(host_id)?
        .ok_or_else(|| PandaError::UnknownHost(host_id.to_string()))
}

/// Build credentials from the host's auth method; secrets are supplied by
/// the caller from the local credential store or the current session.
pub(crate) fn credentials_for(
    cfg: &HostConfig,
    password: Option<String>,
    passphrase: Option<String>,
) -> Result<Credentials, PandaError> {
    let manual_secret = match cfg.auth {
        panda_core::AuthMethod::Password { .. } => password,
        panda_core::AuthMethod::PublicKey { .. } => passphrase,
    };
    Ok(stores()?
        .core
        .ssh_credentials_for_connection(&cfg.id, manual_secret.as_deref())?)
}

// ---------------------------------------------------------------------------
// Config API
// ---------------------------------------------------------------------------

/// Initialize the config store and known_hosts under `config_dir`
/// (the app passes its App Group container path). 允许重新初始化,
/// 使 panda-ffi 的集成测试可以在同进程中切换临时目录;App 仍只调用一次。
#[uniffi::export]
pub fn init_store(config_dir: String) -> Result<(), PandaError> {
    let dir = PathBuf::from(config_dir);
    let core = PandaCore::new_with_storage_location(&dir, ffi_storage_location())?;
    *STORES
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Arc::new(Stores { core }));
    panda_core::logger::configure_global_file_path(dir.join("logs").join("panda-ssh.log"))?;
    Ok(())
}

/// 重置全局 store 为 None（仅测试用），使 `stores()` 返回 `NotInitialized`。
#[cfg(test)]
pub(crate) fn reset_store_for_test() {
    *STORES
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
}

#[cfg(target_os = "ios")]
fn ffi_storage_location() -> StorageLocation {
    StorageLocation::PlatformContainer
}

#[cfg(not(target_os = "ios"))]
fn ffi_storage_location() -> StorageLocation {
    StorageLocation::PrivateConfig
}

#[uniffi::export]
pub fn list_hosts() -> Result<Vec<HostConfigRecord>, PandaError> {
    let hosts = stores()?.core.list_hosts()?;
    Ok(hosts.into_iter().map(HostConfigRecord::from).collect())
}

/// 按关键字模糊搜索主机。匹配字段：名称、地址、用户名、分组路径。空查询返回全部。
#[uniffi::export]
pub fn search_hosts(query: String) -> Result<Vec<HostConfigRecord>, PandaError> {
    let s = stores()?;
    let hosts = s.core.list_hosts()?;
    let groups = s.core.group_store().list()?;
    Ok(panda_core::search_hosts(&hosts, &groups, &query)
        .into_iter()
        .map(HostConfigRecord::from)
        .collect())
}

/// Insert or update a host. An empty `id` generates a fresh UUID.
#[uniffi::export]
pub fn save_host(host: HostConfigRecord) -> Result<(), PandaError> {
    let mut config: HostConfig = host.into();
    if config.id.is_empty() {
        config.id = Uuid::new_v4().to_string();
    }
    Ok(stores()?.core.save_host(config)?)
}

/// 保存主机与凭据的完整用例。桥只转换值类型；写入顺序、引用与补偿由核心决定。
#[uniffi::export]
pub fn save_host_with_credentials(
    host: HostConfigRecord,
    password: CredentialIntentEnum,
    passphrase: CredentialIntentEnum,
) -> Result<HostConfigRecord, PandaError> {
    let config: HostConfig = host.into();
    let result = stores()?.core.save_host_with_credentials(HostSaveRequest {
        host: config,
        password: password.into(),
        passphrase: passphrase.into(),
    })?;
    Ok(result.host.into())
}

#[uniffi::export]
pub fn delete_host(id: String) -> Result<(), PandaError> {
    stores()?.core.delete_host_with_credentials(&id)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Credential API
// ---------------------------------------------------------------------------

/// 保存本地凭据；秘密仅写入配置目录的 credentials.toml。
#[uniffi::export]
pub fn save_credential(reference: String, secret: String) -> Result<(), PandaError> {
    Ok(stores()?.core.credential_store().save(reference, secret)?)
}

#[uniffi::export]
pub fn read_credential(reference: String) -> Result<Option<String>, PandaError> {
    Ok(stores()?.core.credential_store().get(&reference)?)
}

#[uniffi::export]
pub fn delete_credential(reference: String) -> Result<(), PandaError> {
    Ok(stores()?.core.credential_store().delete(&reference)?)
}

/// 用当前保护密钥解锁凭据文件，并用新密钥重写；新密钥为空时迁回明文格式。
#[uniffi::export]
pub fn set_credential_protection_key(
    current_key: Option<String>,
    new_key: Option<String>,
) -> Result<(), PandaError> {
    Ok(stores()?
        .core
        .credential_store()
        .set_protection_key(current_key, new_key)?)
}

#[uniffi::export]
pub fn credential_protection_enabled() -> Result<bool, PandaError> {
    Ok(stores()?.core.credential_store().is_protected()?)
}

/// 凭据保护的可信状态（FFI 友好枚举）。
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ProtectionStatusEnum {
    /// 凭据文件为明文格式或不存在。
    Unprotected,
    /// 凭据文件已加密，当前进程尚未解锁。
    ProtectedLocked,
    /// 凭据文件已加密且当前进程已解锁。
    ProtectedUnlocked,
}

/// 查询凭据保护的可信状态。
#[uniffi::export]
pub fn credential_protection_status() -> Result<ProtectionStatusEnum, PandaError> {
    Ok(
        match stores()?.core.credential_store().protection_status()? {
            panda_core::ProtectionStatus::Unprotected => ProtectionStatusEnum::Unprotected,
            panda_core::ProtectionStatus::ProtectedLocked => ProtectionStatusEnum::ProtectedLocked,
            panda_core::ProtectionStatus::ProtectedUnlocked => {
                ProtectionStatusEnum::ProtectedUnlocked
            }
        },
    )
}

/// 只解锁：验证候选密钥但不改写凭据文件。
#[uniffi::export]
pub fn credential_unlock_only(candidate_key: String) -> Result<ProtectionStatusEnum, PandaError> {
    Ok(
        match stores()?
            .core
            .credential_store()
            .unlock_only(&candidate_key)?
        {
            panda_core::ProtectionStatus::Unprotected => ProtectionStatusEnum::Unprotected,
            panda_core::ProtectionStatus::ProtectedLocked => ProtectionStatusEnum::ProtectedLocked,
            panda_core::ProtectionStatus::ProtectedUnlocked => {
                ProtectionStatusEnum::ProtectedUnlocked
            }
        },
    )
}

/// 保护动作输入验证结果（FFI 友好枚举）。
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ProtectionActionEnum {
    /// 启用保护。
    Enable,
    /// 更换密钥。
    ChangeKey,
    /// 移除保护。
    Remove,
}

/// 保护动作输入验证错误（FFI 友好枚举）。
#[derive(Debug, Clone, uniffi::Error)]
pub enum ProtectionInputErrorEnum {
    /// 新密码与确认密码不一致。
    ConfirmMismatch,
    /// 更换或移除操作需要提供当前密码。
    CurrentKeyRequired,
    /// 凭据未受保护且未提供新密钥。
    AlreadyUnprotected,
}

impl std::fmt::Display for ProtectionInputErrorEnum {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ConfirmMismatch => write!(f, "新密码与确认密码不一致"),
            Self::CurrentKeyRequired => write!(f, "需要提供当前密码"),
            Self::AlreadyUnprotected => write!(f, "凭据未受保护"),
        }
    }
}

/// 验证保护动作的输入参数。
#[uniffi::export]
pub fn validate_credential_protection_input(
    current_key: Option<String>,
    new_key: Option<String>,
    confirm_key: Option<String>,
    is_protected: bool,
) -> Result<ProtectionActionEnum, ProtectionInputErrorEnum> {
    panda_core::validate_protection_input(
        current_key.as_deref(),
        new_key.as_deref(),
        confirm_key.as_deref(),
        is_protected,
    )
    .map(|action| match action {
        panda_core::ProtectionAction::Enable => ProtectionActionEnum::Enable,
        panda_core::ProtectionAction::ChangeKey => ProtectionActionEnum::ChangeKey,
        panda_core::ProtectionAction::Remove => ProtectionActionEnum::Remove,
    })
    .map_err(|error| match error {
        panda_core::ProtectionInputError::ConfirmMismatch => {
            ProtectionInputErrorEnum::ConfirmMismatch
        }
        panda_core::ProtectionInputError::CurrentKeyRequired => {
            ProtectionInputErrorEnum::CurrentKeyRequired
        }
        panda_core::ProtectionInputError::AlreadyUnprotected => {
            ProtectionInputErrorEnum::AlreadyUnprotected
        }
    })
}

/// 返回终端缓冲区行数的默认值。
#[uniffi::export]
pub fn default_terminal_buffer_lines() -> u32 {
    panda_core::default_terminal_buffer_lines()
}

/// 终端缓冲区行数校验错误（FFI 友好枚举）。
#[derive(Debug, Clone, uniffi::Error)]
pub enum TerminalBufferErrorEnum {
    /// 输入不是有效整数。
    NotANumber,
    /// 输入超出允许范围。
    OutOfRange,
}

impl std::fmt::Display for TerminalBufferErrorEnum {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotANumber => write!(f, "输入不是有效整数"),
            Self::OutOfRange => write!(f, "输入超出允许范围 1000–100000"),
        }
    }
}

/// 校验并规范化终端缓冲区行数的原始文本输入。
#[uniffi::export]
pub fn validate_terminal_buffer_lines(raw: String) -> Result<u32, TerminalBufferErrorEnum> {
    panda_core::validate_terminal_buffer_lines(&raw).map_err(|error| match error {
        panda_core::TerminalBufferError::NotANumber => TerminalBufferErrorEnum::NotANumber,
        panda_core::TerminalBufferError::OutOfRange => TerminalBufferErrorEnum::OutOfRange,
    })
}

/// 凭据解析结果（FFI 友好枚举）。
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ResolvedCredentialEnum {
    /// 凭据就绪，可直接连接。
    Available {
        password: Option<String>,
        passphrase: Option<String>,
    },
    /// 需要用户输入密码。
    NeedsPassword,
    /// 需要用户输入私钥口令。
    NeedsPassphrase,
}

/// 连接凭据输入种类；仅用于原生界面选择文案，秘密不会进入该值。
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum ConnectionCredentialKindEnum {
    Password,
    Passphrase,
}

/// 核心创建的待输入请求。响应必须携带 `id`，不能由界面猜测会话状态。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ConnectionCredentialRequestRecord {
    pub id: String,
    pub session_id: String,
    pub host_id: String,
    pub kind: ConnectionCredentialKindEnum,
}

/// 连接前凭据检查的简单值结果。
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ConnectionCredentialPreparationEnum {
    Ready {
        password: Option<String>,
        passphrase: Option<String>,
    },
    NeedsInput {
        request: ConnectionCredentialRequestRecord,
    },
}

/// 解析主机凭据状态：已保存 → Available；未保存 → NeedsPassword/NeedsPassphrase。
#[uniffi::export]
pub fn credential_resolve(host_id: String) -> Result<ResolvedCredentialEnum, PandaError> {
    let s = stores()?;
    let host = s
        .core
        .config_store()
        .get(&host_id)?
        .ok_or_else(|| PandaError::Core(format!("host not found: {host_id}")))?;
    match panda_core::credential_resolve(s.core.credential_store(), &host)? {
        panda_core::ResolvedCredential::Available {
            password,
            passphrase,
        } => Ok(ResolvedCredentialEnum::Available {
            password,
            passphrase,
        }),
        panda_core::ResolvedCredential::NeedsPassword => Ok(ResolvedCredentialEnum::NeedsPassword),
        panda_core::ResolvedCredential::NeedsPassphrase => {
            Ok(ResolvedCredentialEnum::NeedsPassphrase)
        }
    }
}

/// 解析一个连接用例的瞬态凭据；手动输入优先级由核心统一决定。
#[uniffi::export]
pub fn connection_credentials(
    host_id: String,
    manual_secret: Option<String>,
) -> Result<ResolvedCredentialEnum, PandaError> {
    match stores()?
        .core
        .resolve_connection_credentials(&host_id, manual_secret.as_deref())?
    {
        panda_core::ConnectionCredentials::Available {
            password,
            passphrase,
        } => Ok(ResolvedCredentialEnum::Available {
            password,
            passphrase,
        }),
        panda_core::ConnectionCredentials::NeedsPassword => {
            Ok(ResolvedCredentialEnum::NeedsPassword)
        }
        panda_core::ConnectionCredentials::NeedsPassphrase => {
            Ok(ResolvedCredentialEnum::NeedsPassphrase)
        }
    }
}

/// 开始一个连接前凭据检查；缺失凭据由核心生成关联输入请求。
#[uniffi::export]
pub fn connection_credential_prepare(
    session_id: String,
    host_id: String,
    manual_secret: Option<String>,
) -> Result<ConnectionCredentialPreparationEnum, PandaError> {
    connection_credential_preparation_from_core(stores()?.core.prepare_connection_credentials(
        &session_id,
        &host_id,
        manual_secret.as_deref(),
    )?)
}

/// 提交仍有效输入请求的秘密；核心验证请求 id 后才产生可用凭据结果。
#[uniffi::export]
pub fn connection_credential_respond(
    request_id: String,
    secret: String,
) -> Result<ConnectionCredentialPreparationEnum, PandaError> {
    connection_credential_preparation_from_core(
        stores()?
            .core
            .respond_connection_credential(&request_id, &secret)?,
    )
}

/// 关闭或重试会话时废弃该会话的待输入请求，迟到响应将被核心拒绝。
#[uniffi::export]
pub fn connection_credential_cancel(session_id: String) -> Result<(), PandaError> {
    stores()?.core.cancel_connection_interactions(&session_id);
    Ok(())
}

fn connection_credential_preparation_from_core(
    preparation: panda_core::ConnectionCredentialPreparation,
) -> Result<ConnectionCredentialPreparationEnum, PandaError> {
    Ok(match preparation {
        panda_core::ConnectionCredentialPreparation::Ready(
            panda_core::ConnectionCredentials::Available {
                password,
                passphrase,
            },
        ) => ConnectionCredentialPreparationEnum::Ready {
            password,
            passphrase,
        },
        panda_core::ConnectionCredentialPreparation::Ready(other) => {
            return Err(PandaError::Core(format!(
                "核心返回了未就绪的凭据: {other:?}"
            )));
        }
        panda_core::ConnectionCredentialPreparation::NeedsInput(request) => {
            ConnectionCredentialPreparationEnum::NeedsInput {
                request: ConnectionCredentialRequestRecord {
                    id: request.id,
                    session_id: request.session_id,
                    host_id: request.host_id,
                    kind: match request.kind {
                        panda_core::ConnectionCredentialKind::Password => {
                            ConnectionCredentialKindEnum::Password
                        }
                        panda_core::ConnectionCredentialKind::Passphrase => {
                            ConnectionCredentialKindEnum::Passphrase
                        }
                    },
                },
            }
        }
    })
}

// ---------------------------------------------------------------------------
// Host key API
// ---------------------------------------------------------------------------

/// File-level host key status for `host:port` (no connection is made):
/// `Unknown` when no known_hosts record exists, otherwise `Known` with the
/// recorded fingerprint and key type. The UI uses this before connecting to
/// decide between connecting directly and prompting for TOFU confirmation.
#[uniffi::export]
pub fn host_key_status(host: String, port: u16) -> Result<KnownHostStatusEnum, PandaError> {
    match stores()?.core.known_hosts_store().status(&host, port)? {
        panda_core::KnownHostStatus::Unknown => Ok(KnownHostStatusEnum::Unknown),
        panda_core::KnownHostStatus::Known {
            fingerprint,
            key_type,
        } => Ok(KnownHostStatusEnum::Known {
            fingerprint,
            key_type,
        }),
    }
}

/// Store a presented host key after the user confirmed its fingerprint.
/// `key` MUST be the `presented` key captured from a `Reject`-policy probe
/// (`UnknownHostKey` error), not a key from a fresh handshake — storing the
/// probed key closes the TOCTOU window between probe and reconnect.
#[uniffi::export]
pub fn accept_unknown_host_key(host: String, port: u16, key: String) -> Result<(), PandaError> {
    Ok(stores()?
        .core
        .known_hosts_store()
        .accept(&host, port, &key)?)
}

// ---------------------------------------------------------------------------
// Preconnect API
// ---------------------------------------------------------------------------

/// 连接前评估结果（FFI 友好枚举）。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PreconnectActionEnum {
    /// 密钥已知且凭据就绪，可直接连接。
    Proceed,
    /// 未知主机，需用户确认密钥指纹（TOFU）。
    ConfirmTofu,
    /// 密钥与已知记录不匹配，应阻断连接并展示告警。
    KeyMismatch {
        stored_fingerprint: String,
        presented_fingerprint: String,
    },
    /// 需要用户输入密码。
    AskPassword,
    /// 需要用户输入私钥口令。
    AskPassphrase,
}

/// 将 core 的连接前评估动作映射为 FFI 枚举。
/// 评估与映射分离：映射臂（含经导出函数不可达的 KeyMismatch）可被直接单测。
fn map_preconnect_action(action: panda_core::PreconnectAction) -> PreconnectActionEnum {
    match action {
        panda_core::PreconnectAction::Proceed => PreconnectActionEnum::Proceed,
        panda_core::PreconnectAction::ConfirmTofu => PreconnectActionEnum::ConfirmTofu,
        panda_core::PreconnectAction::KeyMismatch {
            stored_fingerprint,
            presented_fingerprint,
        } => PreconnectActionEnum::KeyMismatch {
            stored_fingerprint,
            presented_fingerprint,
        },
        panda_core::PreconnectAction::AskPassword => PreconnectActionEnum::AskPassword,
        panda_core::PreconnectAction::AskPassphrase => PreconnectActionEnum::AskPassphrase,
    }
}

/// 连接前评估：综合主机密钥状态和凭据可用性，返回前端应执行的动作。
///
/// 评估顺序：先检查主机密钥状态，再检查凭据可用性。
#[uniffi::export]
pub fn preconnect_evaluate(host_id: String) -> Result<PreconnectActionEnum, PandaError> {
    let s = stores()?;
    let host = s
        .core
        .config_store()
        .get(&host_id)?
        .ok_or_else(|| PandaError::Core(format!("host not found: {host_id}")))?;

    // 检查主机密钥状态
    let key_status = s.core.known_hosts_store().status(&host.host, host.port)?;

    // 检查凭据状态
    let cred_status = panda_core::credential_resolve(s.core.credential_store(), &host)?;

    // 综合评估
    let action = panda_core::preconnect_evaluate(&host, &key_status, &cred_status);
    Ok(map_preconnect_action(action))
}

// ---------------------------------------------------------------------------
// Group API
// ---------------------------------------------------------------------------

#[uniffi::export]
pub fn list_groups() -> Result<Vec<GroupRecord>, PandaError> {
    let groups = stores()?.core.group_store().list()?;
    Ok(groups.into_iter().map(GroupRecord::from).collect())
}

/// Insert or update a group. An empty `id` generates a fresh UUID.
#[uniffi::export]
pub fn save_group(group: GroupRecord) -> Result<(), PandaError> {
    let mut g: Group = group.into();
    if g.id.is_empty() {
        g.id = Uuid::new_v4().to_string();
    }
    Ok(stores()?.core.group_store().upsert(g)?)
}

/// Delete a group: hosts under it (including hosts of subgroups) move back
/// to root level with their data intact; subgroups are deleted too.
#[uniffi::export]
pub fn delete_group(id: String) -> Result<(), PandaError> {
    let stores = stores()?;
    Ok(panda_core::delete_group_cascade(
        stores.core.group_store(),
        stores.core.config_store(),
        &id,
    )?)
}

/// Change a group's parent (`None` moves it to root level). Refuses moves
/// that would create a cycle (into itself or a descendant).
#[uniffi::export]
pub fn move_group(id: String, new_parent_id: Option<String>) -> Result<(), PandaError> {
    Ok(panda_core::move_group(
        stores()?.core.group_store(),
        &id,
        new_parent_id.as_deref(),
    )?)
}

/// 返回分组的完整层级路径，如 "生产 / 华东 / 上海"。未知或空 id 返回 "根级"。
#[uniffi::export]
pub fn group_path(group_id: String) -> Result<String, PandaError> {
    let groups = stores()?.core.group_store().list()?;
    Ok(panda_core::group_path(&groups, &group_id))
}

/// 侧栏树节点（FFI 友好版本）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct SidebarNodeFFIRecord {
    pub id: String,
    pub is_group: bool,
    pub name: String,
    pub host: Option<HostConfigRecord>,
    pub group: Option<GroupRecord>,
    pub children: Option<Vec<SidebarNodeFFIRecord>>,
}

fn convert_sidebar_node(node: panda_core::SidebarNodeRecord) -> SidebarNodeFFIRecord {
    SidebarNodeFFIRecord {
        id: node.id,
        is_group: node.is_group,
        name: node.name,
        host: node.host.map(HostConfigRecord::from),
        group: node.group.map(GroupRecord::from),
        children: node
            .children
            .map(|cs| cs.into_iter().map(convert_sidebar_node).collect()),
    }
}

/// 返回已组装好的侧栏树。根级分组在前、根级主机在后；分组内先子分组后主机。
#[uniffi::export]
pub fn sidebar_tree() -> Result<Vec<SidebarNodeFFIRecord>, PandaError> {
    let s = stores()?;
    let hosts = s.core.list_hosts()?;
    let groups = s.core.group_store().list()?;
    Ok(panda_core::sidebar_tree(&hosts, &groups)
        .into_iter()
        .map(convert_sidebar_node)
        .collect())
}

// ---------------------------------------------------------------------------
// Config Archive API
// ---------------------------------------------------------------------------

/// 配置导出结果。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ExportManifestRecord {
    pub version: u32,
    pub timestamp: String,
    pub device_name: String,
    pub file_count: u32,
}

/// 配置导入结果。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ImportResultRecord {
    pub backup_files: Vec<String>,
    pub host_count: u32,
    pub group_count: u32,
    pub snippet_count: u32,
}

/// 将配置目录导出为 ZIP 归档。
#[uniffi::export]
pub fn config_export(output_path: String) -> Result<ExportManifestRecord, PandaError> {
    let config_dir = config_dir()?;
    let manifest = panda_core::config_archive::config_export(
        &config_dir,
        PathBuf::from(&output_path).as_path(),
    )
    .map_err(|e| PandaError::Core(e.to_string()))?;
    Ok(ExportManifestRecord {
        version: manifest.version,
        timestamp: manifest.timestamp,
        device_name: manifest.device_name,
        file_count: manifest.file_count,
    })
}

/// 从 ZIP 归档导入配置到配置目录。
#[uniffi::export]
pub fn config_import(archive_path: String) -> Result<ImportResultRecord, PandaError> {
    let config_dir = config_dir()?;
    let result = panda_core::config_archive::config_import(
        &config_dir,
        PathBuf::from(&archive_path).as_path(),
    )
    .map_err(|e| PandaError::Core(e.to_string()))?;
    Ok(ImportResultRecord {
        backup_files: result.backup_files,
        host_count: result.host_count,
        group_count: result.group_count,
        snippet_count: result.snippet_count,
    })
}

fn config_dir() -> Result<PathBuf, PandaError> {
    let s = stores()?;
    Ok(s.core.config_root().to_path_buf())
}

// ---------------------------------------------------------------------------
// Snippet API
// ---------------------------------------------------------------------------

/// Mirror of `panda_core::Snippet` for FFI.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SnippetRecord {
    pub name: String,
    pub title: String,
    pub tags: Vec<String>,
    pub body: String,
}

impl From<panda_core::Snippet> for SnippetRecord {
    fn from(s: panda_core::Snippet) -> Self {
        SnippetRecord {
            name: s.name,
            title: s.title,
            tags: s.tags,
            body: s.body,
        }
    }
}

impl From<SnippetRecord> for panda_core::Snippet {
    fn from(r: SnippetRecord) -> Self {
        panda_core::Snippet {
            name: r.name,
            title: r.title,
            tags: r.tags,
            body: r.body,
        }
    }
}

#[uniffi::export]
pub fn list_snippets() -> Result<Vec<SnippetRecord>, PandaError> {
    Ok(stores()?
        .core
        .snippet_list()?
        .into_iter()
        .map(SnippetRecord::from)
        .collect())
}

#[uniffi::export]
pub fn save_snippet(snippet: SnippetRecord) -> Result<(), PandaError> {
    Ok(stores()?.core.snippet_save(&snippet.into())?)
}

#[uniffi::export]
pub fn delete_snippet(name: String) -> Result<(), PandaError> {
    Ok(stores()?.core.snippet_delete(&name)?)
}

// ---------------------------------------------------------------------------
// Tests
#[cfg(test)]
#[path = "tests/ffi_store_tests.rs"]
pub(crate) mod tests;

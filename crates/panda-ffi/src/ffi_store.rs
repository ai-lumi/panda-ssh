//! 配置、凭据、分组、片段与导入导出的 FFI 导出。

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use panda_core::{
    ConfigStore, CredentialStore, Credentials, Group, GroupStore, HostConfig, KnownHosts,
    TomlConfigStore, TomlGroupStore,
};
use uuid::Uuid;

use crate::{GroupRecord, HostConfigRecord, KnownHostStatusEnum, PandaError};

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
    pub config: TomlConfigStore,
    pub groups: TomlGroupStore,
    pub known_hosts: KnownHosts,
    pub credentials: CredentialStore,
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
        .config
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
    match &cfg.auth {
        panda_core::AuthMethod::Password { .. } => password
            .map(Credentials::Password)
            .ok_or_else(|| PandaError::MissingPassword(cfg.name.clone())),
        panda_core::AuthMethod::PublicKey { key_path, .. } => Ok(Credentials::KeyFile {
            path: key_path.clone(),
            passphrase: passphrase.filter(|value| !value.is_empty()),
        }),
    }
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
    std::fs::create_dir_all(&dir)?;
    *STORES.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Arc::new(Stores {
        config: TomlConfigStore::new(dir.join("hosts.toml")),
        groups: TomlGroupStore::new(dir.join("groups.toml")),
        known_hosts: KnownHosts::new(dir.join("known_hosts")),
        credentials: CredentialStore::new(dir.join("credentials.toml")),
    }));
    panda_core::logger::configure_global_file_path(dir.join("logs").join("panda-ssh.log"))?;
    Ok(())
}

#[uniffi::export]
pub fn list_hosts() -> Result<Vec<HostConfigRecord>, PandaError> {
    let hosts = stores()?.config.list()?;
    Ok(hosts.into_iter().map(HostConfigRecord::from).collect())
}

/// 按关键字模糊搜索主机。匹配字段：名称、地址、用户名、分组路径。空查询返回全部。
#[uniffi::export]
pub fn search_hosts(query: String) -> Result<Vec<HostConfigRecord>, PandaError> {
    let s = stores()?;
    let hosts = s.config.list()?;
    let groups = s.groups.list()?;
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
    Ok(stores()?.config.upsert(config)?)
}

#[uniffi::export]
pub fn delete_host(id: String) -> Result<(), PandaError> {
    let stores = stores()?;
    let password_ref = format!("host.{id}.password");
    let passphrase_ref = format!("host.{id}.passphrase");
    let previous_password = stores.credentials.get(&password_ref)?;
    let previous_passphrase = stores.credentials.get(&passphrase_ref)?;

    // 先验证并删除凭据；若任一步失败，恢复已经删除的条目且不修改 hosts.toml。
    stores.credentials.delete(&password_ref)?;
    if let Err(error) = stores.credentials.delete(&passphrase_ref) {
        restore_credential(&stores.credentials, &password_ref, previous_password)?;
        return Err(error.into());
    }
    if let Err(error) = stores.config.delete(&id) {
        restore_credential(&stores.credentials, &password_ref, previous_password)?;
        restore_credential(&stores.credentials, &passphrase_ref, previous_passphrase)?;
        return Err(error.into());
    }
    Ok(())
}

fn restore_credential(
    store: &CredentialStore,
    reference: &str,
    secret: Option<String>,
) -> Result<(), panda_core::Error> {
    match secret {
        Some(secret) => store.save(reference.to_owned(), secret),
        None => store.delete(reference),
    }
}

// ---------------------------------------------------------------------------
// Credential API
// ---------------------------------------------------------------------------

/// 保存本地凭据；秘密仅写入配置目录的 credentials.toml。
#[uniffi::export]
pub fn save_credential(reference: String, secret: String) -> Result<(), PandaError> {
    Ok(stores()?.credentials.save(reference, secret)?)
}

#[uniffi::export]
pub fn read_credential(reference: String) -> Result<Option<String>, PandaError> {
    Ok(stores()?.credentials.get(&reference)?)
}

#[uniffi::export]
pub fn delete_credential(reference: String) -> Result<(), PandaError> {
    Ok(stores()?.credentials.delete(&reference)?)
}

/// 用当前保护密钥解锁凭据文件，并用新密钥重写；新密钥为空时迁回明文格式。
#[uniffi::export]
pub fn set_credential_protection_key(
    current_key: Option<String>,
    new_key: Option<String>,
) -> Result<(), PandaError> {
    Ok(stores()?
        .credentials
        .set_protection_key(current_key, new_key)?)
}

#[uniffi::export]
pub fn credential_protection_enabled() -> Result<bool, PandaError> {
    Ok(stores()?.credentials.is_protected()?)
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

/// 解析主机凭据状态：已保存 → Available；未保存 → NeedsPassword/NeedsPassphrase。
#[uniffi::export]
pub fn credential_resolve(host_id: String) -> Result<ResolvedCredentialEnum, PandaError> {
    let s = stores()?;
    let host = s.config.get(&host_id)?
        .ok_or_else(|| PandaError::Core(format!("host not found: {host_id}")))?;
    match panda_core::credential_resolve(&s.credentials, &host)? {
        panda_core::ResolvedCredential::Available { password, passphrase } => {
            Ok(ResolvedCredentialEnum::Available { password, passphrase })
        }
        panda_core::ResolvedCredential::NeedsPassword => Ok(ResolvedCredentialEnum::NeedsPassword),
        panda_core::ResolvedCredential::NeedsPassphrase => Ok(ResolvedCredentialEnum::NeedsPassphrase),
    }
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
    match stores()?.known_hosts.status(&host, port)? {
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
    Ok(stores()?.known_hosts.accept(&host, port, &key)?)
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
    let host = s.config.get(&host_id)?
        .ok_or_else(|| PandaError::Core(format!("host not found: {host_id}")))?;

    // 检查主机密钥状态
    let key_status = s.known_hosts.status(&host.host, host.port)?;

    // 检查凭据状态
    let cred_status = panda_core::credential_resolve(&s.credentials, &host)?;

    // 综合评估
    let action = panda_core::preconnect_evaluate(&host, &key_status, &cred_status);
    Ok(map_preconnect_action(action))
}

// ---------------------------------------------------------------------------
// Group API
// ---------------------------------------------------------------------------

#[uniffi::export]
pub fn list_groups() -> Result<Vec<GroupRecord>, PandaError> {
    let groups = stores()?.groups.list()?;
    Ok(groups.into_iter().map(GroupRecord::from).collect())
}

/// Insert or update a group. An empty `id` generates a fresh UUID.
#[uniffi::export]
pub fn save_group(group: GroupRecord) -> Result<(), PandaError> {
    let mut g: Group = group.into();
    if g.id.is_empty() {
        g.id = Uuid::new_v4().to_string();
    }
    Ok(stores()?.groups.upsert(g)?)
}

/// Delete a group: hosts under it (including hosts of subgroups) move back
/// to root level with their data intact; subgroups are deleted too.
#[uniffi::export]
pub fn delete_group(id: String) -> Result<(), PandaError> {
    let stores = stores()?;
    Ok(panda_core::delete_group_cascade(
        &stores.groups,
        &stores.config,
        &id,
    )?)
}

/// Change a group's parent (`None` moves it to root level). Refuses moves
/// that would create a cycle (into itself or a descendant).
#[uniffi::export]
pub fn move_group(id: String, new_parent_id: Option<String>) -> Result<(), PandaError> {
    Ok(panda_core::move_group(
        &stores()?.groups,
        &id,
        new_parent_id.as_deref(),
    )?)
}

/// 返回分组的完整层级路径，如 "生产 / 华东 / 上海"。未知或空 id 返回 "根级"。
#[uniffi::export]
pub fn group_path(group_id: String) -> Result<String, PandaError> {
    let groups = stores()?.groups.list()?;
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
        children: node.children.map(|cs| cs.into_iter().map(convert_sidebar_node).collect()),
    }
}

/// 返回已组装好的侧栏树。根级分组在前、根级主机在后；分组内先子分组后主机。
#[uniffi::export]
pub fn sidebar_tree() -> Result<Vec<SidebarNodeFFIRecord>, PandaError> {
    let s = stores()?;
    let hosts = s.config.list()?;
    let groups = s.groups.list()?;
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
    // stores 的 config 路径在 config_dir/hosts.toml，取父目录即为 config_dir
    Ok(s.config
        .path()
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."))
        .to_path_buf())
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

static SNIPPET_STORE: Mutex<Option<panda_core::SnippetStore>> = Mutex::new(None);

fn snippet_store() -> Result<panda_core::SnippetStore, PandaError> {
    SNIPPET_STORE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .ok_or(PandaError::NotInitialized)
}

/// Initialize the snippet store at `dir`. Subsequent calls switch to the new
/// directory (old references become invalid, as designed).
#[uniffi::export]
pub fn init_snippets(dir: String) -> Result<(), PandaError> {
    let path = PathBuf::from(dir);
    std::fs::create_dir_all(&path)?;
    *SNIPPET_STORE.lock().unwrap_or_else(|e| e.into_inner()) =
        Some(panda_core::SnippetStore::new(path));
    Ok(())
}

#[uniffi::export]
pub fn list_snippets() -> Result<Vec<SnippetRecord>, PandaError> {
    Ok(snippet_store()?
        .list()?
        .into_iter()
        .map(SnippetRecord::from)
        .collect())
}

#[uniffi::export]
pub fn save_snippet(snippet: SnippetRecord) -> Result<(), PandaError> {
    Ok(snippet_store()?.save(&snippet.into())?)
}

#[uniffi::export]
pub fn delete_snippet(name: String) -> Result<(), PandaError> {
    Ok(snippet_store()?.delete(&name)?)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::test_support::global_test_lock;
    use crate::test_support::GlobalTestGuard;
    use crate::AuthMethodEnum;

    /// 合法 `<keytype> <base64>` 格式的测试公钥；指纹计算只解码不校验密钥内容。
    const TEST_KEY: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

    /// 在独立临时目录中初始化 store；返回的锁保证串行，tempdir 由调用方持有。
    fn init_test_store() -> (GlobalTestGuard, tempfile::TempDir) {
        let lock = global_test_lock();
        let dir = tempfile::tempdir().unwrap();
        init_store(dir.path().to_string_lossy().into_owned()).unwrap();
        (lock, dir)
    }

    fn password_host(id: &str, name: &str, addr: &str) -> HostConfigRecord {
        HostConfigRecord {
            id: id.into(),
            name: name.into(),
            host: addr.into(),
            port: 22,
            username: "deploy".into(),
            auth: AuthMethodEnum::Password {
                password_ref: Some(format!("host.{id}.password")),
            },
            notes: None,
            group_id: None,
        }
    }

    fn key_host(id: &str, name: &str, passphrase_ref: Option<String>) -> HostConfigRecord {
        HostConfigRecord {
            id: id.into(),
            name: name.into(),
            host: format!("{id}.example.com"),
            port: 22,
            username: "deploy".into(),
            auth: AuthMethodEnum::PublicKey {
                key_path: "/tmp/id_ed25519".into(),
                passphrase_ref,
            },
            notes: None,
            group_id: None,
        }
    }

    fn new_group(name: &str, parent: Option<&str>) -> GroupRecord {
        GroupRecord {
            id: String::new(),
            name: name.into(),
            parent_id: parent.map(str::to_string),
        }
    }

    /// 创建分组并从列表取回带生成 id 的记录（save_group 不返回保存结果）。
    fn create_group(name: &str, parent: Option<&str>) -> GroupRecord {
        save_group(new_group(name, parent)).unwrap();
        list_groups()
            .unwrap()
            .into_iter()
            .find(|g| g.name == name)
            .unwrap()
    }

    #[test]
    fn search_hosts_matches_name_username_group_path_and_empty_query() {
        let (_lock, _dir) = init_test_store();
        let prod = create_group("生产", None);
        save_host(password_host("db", "数据库", "db.prod.example.com")).unwrap();
        let mut web = password_host("web", "Web", "web.example.com");
        web.group_id = Some(prod.id.clone());
        save_host(web).unwrap();

        // 名称命中
        assert_eq!(search_hosts("数据".into()).unwrap().len(), 1);
        // 用户名命中（两台同名用户）
        assert_eq!(search_hosts("deploy".into()).unwrap().len(), 2);
        // 分组路径命中
        assert_eq!(search_hosts("生产".into()).unwrap().len(), 1);
        // 空查询返回全部
        assert_eq!(search_hosts("".into()).unwrap().len(), 2);
        // 无命中
        assert!(search_hosts("不存在".into()).unwrap().is_empty());
    }

    #[test]
    fn credential_resolve_maps_available_needs_password_and_passphrase() {
        let (_lock, _dir) = init_test_store();

        // 已保存密码 → Available
        save_host(password_host("with-pw", "带密码", "a.example.com")).unwrap();
        save_credential("host.with-pw.password".into(), "secret".into()).unwrap();
        match credential_resolve("with-pw".into()).unwrap() {
            ResolvedCredentialEnum::Available { password, passphrase } => {
                assert_eq!(password.as_deref(), Some("secret"));
                assert_eq!(passphrase, None);
            }
            other => panic!("期望 Available，实际 {other:?}"),
        }

        // 密码认证但未保存 → NeedsPassword
        save_host(password_host("no-pw", "无密码", "b.example.com")).unwrap();
        assert!(matches!(
            credential_resolve("no-pw".into()).unwrap(),
            ResolvedCredentialEnum::NeedsPassword
        ));

        // 公钥认证带加密私钥但口令未保存 → NeedsPassphrase
        save_host(key_host("locked-key", "加密私钥", Some("host.locked-key.passphrase".into()))).unwrap();
        assert!(matches!(
            credential_resolve("locked-key".into()).unwrap(),
            ResolvedCredentialEnum::NeedsPassphrase
        ));

        // 公钥认证无加密私钥 → Available(None, None)
        save_host(key_host("plain-key", "明文私钥", None)).unwrap();
        match credential_resolve("plain-key".into()).unwrap() {
            ResolvedCredentialEnum::Available { password, passphrase } => {
                assert_eq!(password, None);
                assert_eq!(passphrase, None);
            }
            other => panic!("期望 Available，实际 {other:?}"),
        }

        // 未知主机 → 结构化错误
        assert!(credential_resolve("ghost".into()).is_err());
    }

    #[test]
    fn host_key_status_reports_unknown_then_known_after_accept() {
        let (_lock, _dir) = init_test_store();

        assert!(matches!(
            host_key_status("tofu.example.com".into(), 22).unwrap(),
            KnownHostStatusEnum::Unknown
        ));

        accept_unknown_host_key("tofu.example.com".into(), 22, TEST_KEY.into()).unwrap();
        match host_key_status("tofu.example.com".into(), 22).unwrap() {
            KnownHostStatusEnum::Known { fingerprint, key_type } => {
                assert!(fingerprint.starts_with("SHA256:"), "指纹应为 SHA256 冒号格式");
                assert_eq!(key_type, "ssh-ed25519");
            }
            other => panic!("期望 Known，实际 {other:?}"),
        }

        // 格式非法的密钥被拒绝
        assert!(accept_unknown_host_key("tofu.example.com".into(), 22, "not-a-key".into()).is_err());
    }

    #[test]
    fn preconnect_evaluate_maps_every_reachable_action() {
        let (_lock, _dir) = init_test_store();

        // 未知主机：无论凭据如何，先要求 TOFU 确认
        save_host(password_host("tofu-host", "TOFU", "tofu.example.com")).unwrap();
        assert!(matches!(
            preconnect_evaluate("tofu-host".into()).unwrap(),
            PreconnectActionEnum::ConfirmTofu
        ));

        // 密钥已知 + 密码已保存 → Proceed
        accept_unknown_host_key("tofu.example.com".into(), 22, TEST_KEY.into()).unwrap();
        save_credential("host.tofu-host.password".into(), "secret".into()).unwrap();
        assert!(matches!(
            preconnect_evaluate("tofu-host".into()).unwrap(),
            PreconnectActionEnum::Proceed
        ));

        // 密钥已知 + 密码未保存 → AskPassword
        save_host(password_host("ask-pw", "要密码", "ask.example.com")).unwrap();
        accept_unknown_host_key("ask.example.com".into(), 22, TEST_KEY.into()).unwrap();
        assert!(matches!(
            preconnect_evaluate("ask-pw".into()).unwrap(),
            PreconnectActionEnum::AskPassword
        ));

        // 密钥已知 + 加密私钥无口令 → AskPassphrase
        save_host(key_host("ask-pp", "要口令", Some("host.ask-pp.passphrase".into()))).unwrap();
        accept_unknown_host_key("ask-pp.example.com".into(), 22, TEST_KEY.into()).unwrap();
        assert!(matches!(
            preconnect_evaluate("ask-pp".into()).unwrap(),
            PreconnectActionEnum::AskPassphrase
        ));

        // 未知主机 id → 结构化错误
        assert!(preconnect_evaluate("ghost".into()).is_err());
    }

    #[test]
    fn map_preconnect_action_converts_core_variants_including_key_mismatch() {
        // KeyMismatch 在文件级评估中不可达（KnownHostStatus 无 Mismatch 变体），
        // 但映射必须保持完整，直接对映射函数验证。
        match map_preconnect_action(panda_core::PreconnectAction::KeyMismatch {
            stored_fingerprint: "SHA256:stored".into(),
            presented_fingerprint: "SHA256:presented".into(),
        }) {
            PreconnectActionEnum::KeyMismatch {
                stored_fingerprint,
                presented_fingerprint,
            } => {
                assert_eq!(stored_fingerprint, "SHA256:stored");
                assert_eq!(presented_fingerprint, "SHA256:presented");
            }
            other => panic!("期望 KeyMismatch，实际 {other:?}"),
        }
        assert_eq!(
            map_preconnect_action(panda_core::PreconnectAction::Proceed),
            PreconnectActionEnum::Proceed
        );
        assert_eq!(
            map_preconnect_action(panda_core::PreconnectAction::ConfirmTofu),
            PreconnectActionEnum::ConfirmTofu
        );
        assert!(matches!(
            map_preconnect_action(panda_core::PreconnectAction::AskPassword),
            PreconnectActionEnum::AskPassword
        ));
        assert!(matches!(
            map_preconnect_action(panda_core::PreconnectAction::AskPassphrase),
            PreconnectActionEnum::AskPassphrase
        ));
    }

    #[test]
    fn credential_protection_roundtrip_rewrites_file_with_new_key() {
        let (_lock, _dir) = init_test_store();

        save_credential("host.protected.password".into(), "secret".into()).unwrap();
        assert!(!credential_protection_enabled().unwrap());

        // 明文 → 加密
        set_credential_protection_key(None, Some("key1".into())).unwrap();
        assert!(credential_protection_enabled().unwrap());
        assert_eq!(
            read_credential("host.protected.password".into()).unwrap().as_deref(),
            Some("secret")
        );

        // 旧密钥解锁后以新密钥重写
        set_credential_protection_key(Some("key1".into()), Some("key2".into())).unwrap();
        assert_eq!(
            read_credential("host.protected.password".into()).unwrap().as_deref(),
            Some("secret")
        );

        // 迁回明文
        set_credential_protection_key(Some("key2".into()), None).unwrap();
        assert!(!credential_protection_enabled().unwrap());
        assert_eq!(
            read_credential("host.protected.password".into()).unwrap().as_deref(),
            Some("secret")
        );
    }

    #[test]
    fn group_path_reports_hierarchy_and_unknown_ids() {
        let (_lock, _dir) = init_test_store();
        let prod = create_group("生产", None);
        let east = create_group("华东", Some(&prod.id));

        assert_eq!(group_path(east.id.clone()).unwrap(), "生产 / 华东");
        assert_eq!(group_path(prod.id.clone()).unwrap(), "生产");
        assert_eq!(group_path("nope".into()).unwrap(), "根级");
        assert_eq!(group_path(String::new()).unwrap(), "根级");
    }

    #[test]
    fn move_group_refuses_cycles_and_allows_root_move() {
        let (_lock, _dir) = init_test_store();
        let prod = create_group("生产", None);
        let east = create_group("华东", Some(&prod.id));

        // 把祖先移到自己的后代下 → 拒绝
        assert!(move_group(prod.id.clone(), Some(east.id.clone())).is_err());
        // 移到自己下 → 拒绝
        assert!(move_group(east.id.clone(), Some(east.id.clone())).is_err());
        // 移到不存在的父下 → 拒绝
        assert!(move_group(east.id.clone(), Some("nope".into())).is_err());
        // 正常移回根级
        assert!(move_group(east.id.clone(), None).is_ok());
    }

    #[test]
    fn delete_group_cascade_moves_hosts_to_root_and_drops_subgroups() {
        let (_lock, _dir) = init_test_store();
        let prod = create_group("生产", None);
        let east = create_group("华东", Some(&prod.id));
        let mut db = password_host("db", "数据库", "db.example.com");
        db.group_id = Some(east.id.clone());
        save_host(db).unwrap();

        delete_group(prod.id.clone()).unwrap();

        assert!(list_groups().unwrap().is_empty(), "子分组应被级联删除");
        let hosts = list_hosts().unwrap();
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].group_id, None, "主机数据应保留并回到根级");
    }

    #[test]
    fn sidebar_tree_orders_groups_first_and_recurses_children() {
        let (_lock, _dir) = init_test_store();
        let prod = create_group("生产", None);
        let east = create_group("华东", Some(&prod.id));

        save_host(password_host("root-host", "根主机", "root.example.com")).unwrap();
        let mut prod_host = password_host("prod-host", "生产主机", "prod.example.com");
        prod_host.group_id = Some(prod.id.clone());
        save_host(prod_host).unwrap();
        let mut east_host = password_host("east-host", "华东主机", "east.example.com");
        east_host.group_id = Some(east.id.clone());
        save_host(east_host).unwrap();

        let tree = sidebar_tree().unwrap();
        // 根级：分组在前、主机在后
        assert_eq!(tree.len(), 2);
        assert!(tree[0].is_group);
        assert_eq!(tree[0].name, "生产");
        assert!(!tree[1].is_group);
        assert_eq!(tree[1].host.as_ref().unwrap().name, "根主机");
        assert!(tree[1].group.is_none());

        // 生产组：子分组在前、直属主机在后
        let children = tree[0].children.as_ref().unwrap();
        assert_eq!(children.len(), 2);
        assert_eq!(children[0].group.as_ref().unwrap().name, "华东");
        assert_eq!(children[1].host.as_ref().unwrap().name, "生产主机");

        // 华东组递归
        let east_children = children[0].children.as_ref().unwrap();
        assert_eq!(east_children.len(), 1);
        assert_eq!(east_children[0].host.as_ref().unwrap().name, "华东主机");
    }

    #[test]
    fn config_export_then_import_roundtrip_restores_hosts() {
        let (lock, _dir) = init_test_store();
        save_group(new_group("导出组", None)).unwrap();
        save_host(password_host("h1", "主机一", "one.example.com")).unwrap();
        save_host(password_host("h2", "主机二", "two.example.com")).unwrap();
        let archive_dir = tempfile::tempdir().unwrap();
        let archive_path = archive_dir.path().join("backup.zip");

        let manifest = config_export(archive_path.to_string_lossy().into_owned()).unwrap();
        assert!(manifest.file_count >= 2, "至少导出 hosts.toml 与 groups.toml");
        assert_eq!(manifest.version, 1);

        // 切换到全新空目录后导入（复用已持有的锁，验证 init_store 可重新初始化）
        let fresh_dir = tempfile::tempdir().unwrap();
        init_store(fresh_dir.path().to_string_lossy().into_owned()).unwrap();
        assert!(list_hosts().unwrap().is_empty());

        let result = config_import(archive_path.to_string_lossy().into_owned()).unwrap();
        assert_eq!(result.host_count, 2);
        // config_import 绕过 store 实例直写磁盘，而 store 带内存缓存：
        // 导入后必须重新 init_store 重建实例才能读到导入结果（App 侧同样如此）。
        init_store(fresh_dir.path().to_string_lossy().into_owned()).unwrap();
        let hosts = list_hosts().unwrap();
        assert_eq!(hosts.len(), 2);
        assert!(hosts.iter().any(|h| h.name == "主机一"));
        drop(lock);
    }

    #[test]
    fn snippet_crud_roundtrip() {
        let (_lock, dir) = init_test_store();
        init_snippets(dir.path().join("snippets").to_string_lossy().into_owned()).unwrap();

        let snippet = SnippetRecord {
            name: "重启服务".into(),
            title: "systemctl 重启".into(),
            tags: vec!["systemd".into()],
            body: "sudo systemctl restart app".into(),
        };
        save_snippet(snippet.clone()).unwrap();
        assert_eq!(list_snippets().unwrap(), vec![snippet]);

        delete_snippet("重启服务".into()).unwrap();
        assert!(list_snippets().unwrap().is_empty());
    }

    #[test]
    fn delete_host_clears_credential_entries_and_tolerates_unknown_id() {
        let (_lock, _dir) = init_test_store();
        save_host(password_host("victim", "待删", "victim.example.com")).unwrap();
        save_credential("host.victim.password".into(), "secret".into()).unwrap();
        save_credential("host.victim.passphrase".into(), "phrase".into()).unwrap();

        delete_host("victim".into()).unwrap();
        assert!(list_hosts().unwrap().iter().all(|h| h.id != "victim"));
        assert_eq!(read_credential("host.victim.password".into()).unwrap(), None);
        assert_eq!(read_credential("host.victim.passphrase".into()).unwrap(), None);

        // 未知 id 也为可删除的 no-op（config.delete 对不存在条目不报错）
        delete_host("ghost".into()).unwrap();
    }
}

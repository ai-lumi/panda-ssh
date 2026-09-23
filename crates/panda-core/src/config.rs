//! Host configuration model and TOML-backed persistence.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::groups::{group_path, Group};
use crate::Error;

/// How to authenticate against a host.
///
/// Secret material is never stored here: `*_ref` fields only hold the key
/// used to look the secret up in the local credential store.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AuthMethod {
    Password {
        password_ref: Option<String>,
    },
    PublicKey {
        key_path: PathBuf,
        passphrase_ref: Option<String>,
    },
}

/// A single saved SSH host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostConfig {
    pub id: String,
    pub name: String,
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    pub username: String,
    pub auth: AuthMethod,
    pub notes: Option<String>,
    /// 所属分组 id;`None` 表示根级。旧版配置文件缺该字段时按根级处理。
    #[serde(default)]
    pub group_id: Option<String>,
}

fn default_port() -> u16 {
    22
}

/// 终端缓冲区行数的默认值。
pub const DEFAULT_TERMINAL_BUFFER_LINES: u32 = 10_000;
/// 终端缓冲区行数的最小允许值。
pub const MIN_TERMINAL_BUFFER_LINES: u32 = 1_000;
/// 终端缓冲区行数的最大允许值。
pub const MAX_TERMINAL_BUFFER_LINES: u32 = 100_000;

/// 终端缓冲区行数校验错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalBufferError {
    /// 输入不是有效整数。
    NotANumber,
    /// 输入超出允许范围。
    OutOfRange,
}

/// 返回终端缓冲区行数的默认值（10000）。
pub fn default_terminal_buffer_lines() -> u32 {
    DEFAULT_TERMINAL_BUFFER_LINES
}

/// 校验并规范化终端缓冲区行数的原始文本输入。
///
/// 成功返回范围内的 `u32`；失败返回可区分的错误类型。
/// Swift 侧 MUST 将未解析的表单文本和 UserDefaults 原始值交给此函数，
/// 不在 Swift 侧重复解析或夹限。
pub fn validate_terminal_buffer_lines(raw: &str) -> std::result::Result<u32, TerminalBufferError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(DEFAULT_TERMINAL_BUFFER_LINES);
    }
    let value: u32 = trimmed
        .parse()
        .map_err(|_| TerminalBufferError::NotANumber)?;
    if value < MIN_TERMINAL_BUFFER_LINES || value > MAX_TERMINAL_BUFFER_LINES {
        return Err(TerminalBufferError::OutOfRange);
    }
    Ok(value)
}

impl HostConfig {
    /// Build a config with a fresh random UUID.
    pub fn new(
        name: impl Into<String>,
        host: impl Into<String>,
        username: impl Into<String>,
        auth: AuthMethod,
    ) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name: name.into(),
            host: host.into(),
            port: default_port(),
            username: username.into(),
            auth,
            notes: None,
            group_id: None,
        }
    }
}

/// Storage backend for host configurations.
pub trait ConfigStore {
    fn list(&self) -> Result<Vec<HostConfig>, Error>;
    fn get(&self, id: &str) -> Result<Option<HostConfig>, Error>;
    fn upsert(&self, config: HostConfig) -> Result<(), Error>;
    fn delete(&self, id: &str) -> Result<(), Error>;
}

/// On-disk layout of the host list file.
#[derive(Debug, Default, Serialize, Deserialize)]
struct HostsFile {
    #[serde(default, rename = "host")]
    hosts: Vec<HostConfig>,
}

/// Persists all hosts in a single TOML file.
///
/// The path is injected by the caller (the app points it at its App Group
/// container); writes are atomic (temp file + rename).
pub struct TomlConfigStore {
    path: PathBuf,
    /// 内存缓存，避免同一实例内重复解析 TOML。
    cache: std::sync::Mutex<Option<Vec<HostConfig>>>,
}

impl TomlConfigStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            cache: std::sync::Mutex::new(None),
        }
    }

    /// 返回存储文件的路径。
    pub fn path(&self) -> &Path {
        &self.path
    }

    fn read(&self) -> Result<Vec<HostConfig>, Error> {
        {
            let guard = self.cache.lock().unwrap();
            if let Some(ref cached) = *guard {
                return Ok(cached.clone());
            }
        }
        let hosts = match std::fs::read_to_string(&self.path) {
            Ok(text) => {
                let file: HostsFile = toml::from_str(&text)?;
                file.hosts
            }
            // A missing file just means "no hosts saved yet".
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e.into()),
        };
        *self.cache.lock().unwrap() = Some(hosts.clone());
        Ok(hosts)
    }

    fn write(&self, hosts: &[HostConfig]) -> Result<(), Error> {
        let file = HostsFile {
            hosts: hosts.to_vec(),
        };
        let text = toml::to_string_pretty(&file)?;
        write_atomic(&self.path, text.as_bytes())?;
        *self.cache.lock().unwrap() = Some(hosts.to_vec());
        Ok(())
    }
}

impl ConfigStore for TomlConfigStore {
    fn list(&self) -> Result<Vec<HostConfig>, Error> {
        self.read()
    }

    fn get(&self, id: &str) -> Result<Option<HostConfig>, Error> {
        Ok(self.read()?.into_iter().find(|h| h.id == id))
    }

    fn upsert(&self, config: HostConfig) -> Result<(), Error> {
        let mut hosts = self.read()?;
        match hosts.iter_mut().find(|h| h.id == config.id) {
            Some(existing) => *existing = config,
            None => hosts.push(config),
        }
        self.write(&hosts)
    }

    fn delete(&self, id: &str) -> Result<(), Error> {
        let mut hosts = self.read()?;
        hosts.retain(|h| h.id != id);
        self.write(&hosts)
    }
}

/// Write `bytes` to `path` atomically via a temp file + rename.
/// 文件写盘走 `spawn_blocking`，避免在 tokio worker 线程上阻塞。
pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), Error> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// 异步版本的 `write_atomic`，内部使用 `spawn_blocking`。
#[allow(dead_code)]
pub(crate) async fn write_atomic_async(path: &Path, bytes: &[u8]) -> Result<(), Error> {
    let path = path.to_path_buf();
    let bytes = bytes.to_vec();
    tokio::task::spawn_blocking(move || {
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, &bytes)?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    })
    .await
    .map_err(|e| Error::Other(format!("spawn_blocking failed: {e}")))?
}

/// 在主机列表中按关键字做大小写不敏感的模糊搜索。
///
/// 匹配字段:name、host(地址)、username、分组路径。
/// 空查询返回全部主机。
pub fn search_hosts(hosts: &[HostConfig], groups: &[Group], query: &str) -> Vec<HostConfig> {
    let query = query.trim();
    if query.is_empty() {
        return hosts.to_vec();
    }
    let q = query.to_lowercase();
    hosts
        .iter()
        .filter(|h| {
            h.name.to_lowercase().contains(&q)
                || h.host.to_lowercase().contains(&q)
                || h.username.to_lowercase().contains(&q)
                || h.group_id
                    .as_deref()
                    .map(|gid| group_path(groups, gid).to_lowercase().contains(&q))
                    .unwrap_or(false)
        })
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn password_host() -> HostConfig {
        HostConfig {
            id: "11111111-2222-3333-4444-555555555555".into(),
            name: "box".into(),
            host: "example.com".into(),
            port: 22,
            username: "panda".into(),
            auth: AuthMethod::Password {
                password_ref: Some("local/box".into()),
            },
            notes: None,
            group_id: None,
        }
    }

    fn key_host() -> HostConfig {
        HostConfig {
            id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".into(),
            name: "deploy".into(),
            host: "10.0.0.2".into(),
            port: 2222,
            username: "root".into(),
            auth: AuthMethod::PublicKey {
                key_path: PathBuf::from("/keys/id_ed25519"),
                passphrase_ref: None,
            },
            notes: Some("prod".into()),
            group_id: None,
        }
    }

    #[test]
    fn host_config_toml_round_trip_password() {
        let host = password_host();
        let text = toml::to_string_pretty(&host).unwrap();
        let back: HostConfig = toml::from_str(&text).unwrap();
        assert_eq!(host, back);
    }

    #[test]
    fn host_config_toml_round_trip_public_key() {
        let host = key_host();
        let text = toml::to_string_pretty(&host).unwrap();
        let back: HostConfig = toml::from_str(&text).unwrap();
        assert_eq!(host, back);
    }

    #[test]
    fn default_port_applies_when_missing() {
        let mut host = password_host();
        // Serialize, strip the port line, deserialize again.
        let text = toml::to_string_pretty(&host).unwrap();
        let text: String = text
            .lines()
            .filter(|l| !l.starts_with("port"))
            .collect::<Vec<_>>()
            .join("\n");
        let back: HostConfig = toml::from_str(&text).unwrap();
        assert_eq!(back.port, 22);
        host.port = 22;
    }

    #[test]
    fn store_upsert_list_delete_persists() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hosts.toml");
        let store = TomlConfigStore::new(path.clone());

        assert!(store.list().unwrap().is_empty());
        assert!(store.get("nope").unwrap().is_none());

        let h1 = password_host();
        let h2 = key_host();
        store.upsert(h1.clone()).unwrap();
        store.upsert(h2.clone()).unwrap();

        let listed = store.list().unwrap();
        assert_eq!(listed, vec![h1.clone(), h2.clone()]);
        assert_eq!(store.get(&h2.id).unwrap(), Some(h2.clone()));

        // Upsert with same id replaces in place.
        let mut h1b = h1.clone();
        h1b.notes = Some("updated".into());
        store.upsert(h1b.clone()).unwrap();
        assert_eq!(store.get(&h1.id).unwrap(), Some(h1b));
        assert_eq!(store.list().unwrap().len(), 2);

        // Reopen the file: data survived on disk.
        let store2 = TomlConfigStore::new(path.clone());
        assert_eq!(store2.list().unwrap().len(), 2);

        store2.delete(&h1.id).unwrap();
        let remaining = store2.list().unwrap();
        assert_eq!(remaining, vec![h2.clone()]);
        assert!(store2.get(&h1.id).unwrap().is_none());

        // Deleting a missing id is a no-op, not an error.
        store2.delete("missing").unwrap();
        assert_eq!(store2.list().unwrap().len(), 1);
    }

    #[test]
    fn missing_file_yields_empty_list() {
        let dir = tempfile::tempdir().unwrap();
        let store = TomlConfigStore::new(dir.path().join("absent.toml"));
        assert_eq!(store.list().unwrap(), Vec::<HostConfig>::new());
    }

    #[test]
    fn host_config_new_sets_defaults() {
        let host = HostConfig::new(
            "name",
            "example.com",
            "user",
            AuthMethod::Password { password_ref: None },
        );
        assert_eq!(host.name, "name");
        assert_eq!(host.host, "example.com");
        assert_eq!(host.username, "user");
        assert_eq!(host.port, 22);
        assert!(host.notes.is_none());
        assert!(!host.id.is_empty());
    }

    #[test]
    fn list_returns_error_for_non_file_path() {
        let dir = tempfile::tempdir().unwrap();
        let store = TomlConfigStore::new(dir.path().to_path_buf());
        assert!(store.list().is_err());
    }

    #[test]
    fn upsert_returns_error_when_parent_directory_is_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing").join("hosts.toml");
        let store = TomlConfigStore::new(path);
        assert!(store.upsert(password_host()).is_err());
    }

    #[test]
    fn invalid_toml_returns_parse_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hosts.toml");
        std::fs::write(&path, "not [valid toml").unwrap();
        let store = TomlConfigStore::new(path);
        assert!(store.list().is_err());
    }

    #[test]
    fn store_operating_on_directory_returns_errors() {
        let dir = tempfile::tempdir().unwrap();
        let store = TomlConfigStore::new(dir.path().to_path_buf());
        assert!(store.list().is_err());
        assert!(store.get("x").is_err());
        assert!(store.upsert(password_host()).is_err());
        assert!(store.delete("x").is_err());
    }

    #[tokio::test]
    async fn atomic_async_write_replaces_file_contents() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        write_atomic_async(&path, b"before").await.unwrap();
        write_atomic_async(&path, b"after").await.unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"after");

        let blocked = dir.path().join("not-a-directory");
        std::fs::write(&blocked, b"x").unwrap();
        assert!(write_atomic_async(&blocked.join("config.toml"), b"x")
            .await
            .is_err());
    }

    #[test]
    fn group_id_none_is_omitted_from_toml_output() {
        let host = password_host();
        assert!(host.group_id.is_none());
        let text = toml::to_string_pretty(&host).unwrap();
        // group_id 为 None 时 serde 序列化为空值或缺省;
        // 无论哪种方式,反序列化后必须恢复为 None。
        assert!(!text.contains("group_id = \""));
        let back: HostConfig = toml::from_str(&text).unwrap();
        assert_eq!(back.group_id, None);
    }

    #[test]
    fn empty_file_yields_empty_list_not_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hosts.toml");
        std::fs::write(&path, "").unwrap();
        let store = TomlConfigStore::new(path);
        // 空文件 serde 反序列化 HostsFile 默认字段 → 空列表
        assert_eq!(store.list().unwrap(), Vec::<HostConfig>::new());
    }

    #[test]
    fn corrupted_toml_returns_error_not_panic() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hosts.toml");
        std::fs::write(&path, "[[host\nbroken").unwrap();
        let store = TomlConfigStore::new(path);
        assert!(store.list().is_err());
    }

    #[test]
    fn write_atomic_does_not_leave_temp_file_on_success() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hosts.toml");
        write_atomic(&path, b"data").unwrap();
        assert!(path.exists());
        assert!(!dir.path().join("hosts.tmp").exists());
    }

    // --- search_hosts ---

    fn make_host(
        id: &str,
        name: &str,
        host: &str,
        user: &str,
        group_id: Option<&str>,
    ) -> HostConfig {
        let mut h = HostConfig::new(
            name,
            host,
            user,
            AuthMethod::Password { password_ref: None },
        );
        h.id = id.into();
        h.group_id = group_id.map(str::to_string);
        h
    }

    fn test_groups() -> Vec<crate::groups::Group> {
        vec![
            crate::groups::Group {
                id: "g1".into(),
                name: "生产环境".into(),
                parent_id: None,
            },
            crate::groups::Group {
                id: "g2".into(),
                name: "华东".into(),
                parent_id: Some("g1".into()),
            },
        ]
    }

    #[test]
    fn search_hosts_matches_name() {
        let hosts = vec![
            make_host("h1", "web-server", "10.0.0.1", "root", None),
            make_host("h2", "db-server", "10.0.0.2", "admin", None),
        ];
        let result = search_hosts(&hosts, &[], "web");
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "h1");
    }

    #[test]
    fn search_hosts_matches_address() {
        let hosts = vec![
            make_host("h1", "server", "10.0.0.1", "root", None),
            make_host("h2", "server", "192.168.1.1", "root", None),
        ];
        let result = search_hosts(&hosts, &[], "192.168");
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "h2");
    }

    #[test]
    fn search_hosts_matches_username() {
        let hosts = vec![
            make_host("h1", "server", "10.0.0.1", "deploy", None),
            make_host("h2", "server", "10.0.0.2", "admin", None),
        ];
        let result = search_hosts(&hosts, &[], "deploy");
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "h1");
    }

    #[test]
    fn search_hosts_matches_group_path() {
        let groups = test_groups();
        let hosts = vec![
            make_host("h1", "server", "10.0.0.1", "root", Some("g2")),
            make_host("h2", "server", "10.0.0.2", "root", None),
        ];
        let result = search_hosts(&hosts, &groups, "华东");
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "h1");
    }

    #[test]
    fn search_hosts_empty_query_returns_all() {
        let hosts = vec![
            make_host("h1", "a", "1.1.1.1", "u", None),
            make_host("h2", "b", "2.2.2.2", "u", None),
        ];
        let result = search_hosts(&hosts, &[], "");
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn search_hosts_case_insensitive() {
        let hosts = vec![make_host("h1", "WebServer", "10.0.0.1", "Root", None)];
        let result = search_hosts(&hosts, &[], "webserver");
        assert_eq!(result.len(), 1);
        let result2 = search_hosts(&hosts, &[], "ROOT");
        assert_eq!(result2.len(), 1);
    }

    #[test]
    fn search_hosts_no_match_returns_empty() {
        let hosts = vec![make_host("h1", "server", "10.0.0.1", "root", None)];
        let result = search_hosts(&hosts, &[], "nonexistent");
        assert!(result.is_empty());
    }

    // --- 终端缓冲区行数配置测试 ---

    #[test]
    fn terminal_buffer_default_is_10000() {
        assert_eq!(default_terminal_buffer_lines(), 10_000);
    }

    #[test]
    fn terminal_buffer_valid_input_returns_normalized_integer() {
        assert_eq!(validate_terminal_buffer_lines("1000").unwrap(), 1000);
        assert_eq!(validate_terminal_buffer_lines("10000").unwrap(), 10000);
        assert_eq!(validate_terminal_buffer_lines("100000").unwrap(), 100000);
        assert_eq!(validate_terminal_buffer_lines("50000").unwrap(), 50000);
    }

    #[test]
    fn terminal_buffer_empty_input_returns_default() {
        assert_eq!(validate_terminal_buffer_lines("").unwrap(), 10000);
        assert_eq!(validate_terminal_buffer_lines("  ").unwrap(), 10000);
    }

    #[test]
    fn terminal_buffer_rejects_non_numeric() {
        assert_eq!(
            validate_terminal_buffer_lines("abc").unwrap_err(),
            TerminalBufferError::NotANumber
        );
        assert_eq!(
            validate_terminal_buffer_lines("12.5").unwrap_err(),
            TerminalBufferError::NotANumber
        );
        assert_eq!(
            validate_terminal_buffer_lines("-1").unwrap_err(),
            TerminalBufferError::NotANumber
        );
    }

    #[test]
    fn terminal_buffer_rejects_out_of_range() {
        assert_eq!(
            validate_terminal_buffer_lines("0").unwrap_err(),
            TerminalBufferError::OutOfRange
        );
        assert_eq!(
            validate_terminal_buffer_lines("999").unwrap_err(),
            TerminalBufferError::OutOfRange
        );
        assert_eq!(
            validate_terminal_buffer_lines("100001").unwrap_err(),
            TerminalBufferError::OutOfRange
        );
        assert_eq!(
            validate_terminal_buffer_lines("999999").unwrap_err(),
            TerminalBufferError::OutOfRange
        );
    }

    #[test]
    fn terminal_buffer_boundary_values_accepted() {
        assert_eq!(validate_terminal_buffer_lines("1000").unwrap(), 1000);
        assert_eq!(validate_terminal_buffer_lines("100000").unwrap(), 100000);
    }
}

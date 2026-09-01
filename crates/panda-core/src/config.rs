//! Host configuration model and TOML-backed persistence.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

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
}

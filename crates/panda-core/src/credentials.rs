//! 配置目录内的凭据文件。主机 TOML 仅保存引用，秘密不进入主机配置。

use std::collections::BTreeMap;
use std::path::PathBuf;

use aes_gcm::{
    aead::{rand_core::RngCore, Aead, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use argon2::Argon2;
use base64ct::{Base64, Encoding};
use serde::{Deserialize, Serialize};

use crate::{config::write_atomic, Error, Result};

#[derive(Debug, Default, Serialize, Deserialize)]
struct PlainCredentialsFile {
    #[serde(default = "version")]
    version: u8,
    #[serde(default)]
    entries: BTreeMap<String, String>,
}

fn version() -> u8 {
    1
}

/// 明文兼容凭据仓库。启用保护后，整个 TOML 负载会被 AEAD 信封包裹；
/// 此类型保证凭据与 hosts.toml 分离且所有写入原子完成。
pub struct CredentialStore {
    path: PathBuf,
    protection_key: std::sync::Mutex<Option<String>>,
}

impl CredentialStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            protection_key: std::sync::Mutex::new(None),
        }
    }

    fn read(&self) -> Result<PlainCredentialsFile> {
        match std::fs::read_to_string(&self.path) {
            Ok(text) => {
                let value: toml::Value =
                    toml::from_str(&text).map_err(|_| Error::InvalidCredentialFile)?;
                if value.get("mode").and_then(toml::Value::as_str) == Some("encrypted") {
                    let key = self
                        .protection_key
                        .lock()
                        .unwrap()
                        .clone()
                        .ok_or(Error::CredentialProtectionKeyRequired)?;
                    let salt = decode_field(&value, "salt")?;
                    let nonce = decode_field(&value, "nonce")?;
                    let ciphertext = decode_field(&value, "ciphertext")?;
                    if salt.len() != 16 || nonce.len() != 12 || ciphertext.is_empty() {
                        return Err(Error::InvalidCredentialFile);
                    }
                    let plaintext = decrypt(&key, &salt, &nonce, &ciphertext)?;
                    toml::from_str(
                        std::str::from_utf8(&plaintext)
                            .map_err(|_| Error::InvalidCredentialFile)?,
                    )
                    .map_err(|_| Error::InvalidCredentialFile)
                } else {
                    toml::from_str(&text).map_err(|_| Error::InvalidCredentialFile)
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Ok(PlainCredentialsFile::default())
            }
            Err(e) => Err(e.into()),
        }
    }

    fn write(&self, file: &PlainCredentialsFile) -> Result<()> {
        let plaintext = toml::to_string_pretty(file)?;
        if let Some(key) = self.protection_key.lock().unwrap().clone() {
            let mut salt = [0u8; 16];
            let mut nonce = [0u8; 12];
            OsRng.fill_bytes(&mut salt);
            OsRng.fill_bytes(&mut nonce);
            let ciphertext = encrypt(&key, &salt, &nonce, plaintext.as_bytes())?;
            let envelope = format!("version = 1\nmode = \"encrypted\"\nsalt = \"{}\"\nnonce = \"{}\"\nciphertext = \"{}\"\n", Base64::encode_string(&salt), Base64::encode_string(&nonce), Base64::encode_string(&ciphertext));
            write_atomic(&self.path, envelope.as_bytes())
        } else {
            write_atomic(&self.path, plaintext.as_bytes())
        }
    }

    /// 使用当前密钥解锁已有加密文件，并将其改写为新密钥保护（`None` 为明文）。
    /// 未加密的旧文件不要求当前密钥，确保历史配置可以直接迁移。
    pub fn set_protection_key(
        &self,
        current_key: Option<String>,
        new_key: Option<String>,
    ) -> Result<()> {
        let current_key = current_key.filter(|value| !value.is_empty());
        let new_key = new_key.filter(|value| !value.is_empty());
        if self.is_protected()? {
            let unlock_key = current_key
                .or_else(|| self.protection_key.lock().unwrap().clone())
                .ok_or(Error::CredentialProtectionKeyRequired)?;
            *self.protection_key.lock().unwrap() = Some(unlock_key);
        }

        let entries = match self.read() {
            Ok(entries) => entries,
            Err(error) => {
                *self.protection_key.lock().unwrap() = None;
                return Err(error);
            }
        };
        *self.protection_key.lock().unwrap() = new_key;
        self.write(&entries)
    }

    pub fn is_protected(&self) -> Result<bool> {
        match std::fs::read_to_string(&self.path) {
            Ok(text) => Ok(toml::from_str::<toml::Value>(&text)
                .map_err(|_| Error::InvalidCredentialFile)?
                .get("mode")
                .and_then(toml::Value::as_str)
                == Some("encrypted")),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    pub fn get(&self, reference: &str) -> Result<Option<String>> {
        Ok(self.read()?.entries.get(reference).cloned())
    }

    pub fn save(&self, reference: String, secret: String) -> Result<()> {
        if reference.is_empty() || secret.is_empty() {
            return Err(Error::Other(
                "credential reference and secret must be non-empty".into(),
            ));
        }
        let mut file = self.read()?;
        file.entries.insert(reference, secret);
        self.write(&file)
    }

    pub fn delete(&self, reference: &str) -> Result<()> {
        let mut file = self.read()?;
        file.entries.remove(reference);
        self.write(&file)
    }
}

fn derive_key(password: &str, salt: &[u8]) -> Result<[u8; 32]> {
    let mut key = [0u8; 32];
    Argon2::default()
        .hash_password_into(password.as_bytes(), salt, &mut key)
        .map_err(|_| Error::Other("credential key derivation failed".into()))?;
    Ok(key)
}
fn encrypt(password: &str, salt: &[u8], nonce: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    let key = derive_key(password, salt)?;
    Aes256Gcm::new_from_slice(&key)
        .map_err(|_| Error::Other("invalid credential key".into()))?
        .encrypt(Nonce::from_slice(nonce), plaintext)
        .map_err(|_| Error::Other("credential encryption failed".into()))
}
fn decrypt(password: &str, salt: &[u8], nonce: &[u8], ciphertext: &[u8]) -> Result<Vec<u8>> {
    let key = derive_key(password, salt)?;
    Aes256Gcm::new_from_slice(&key)
        .map_err(|_| Error::Other("invalid credential key".into()))?
        .decrypt(Nonce::from_slice(nonce), ciphertext)
        .map_err(|_| Error::CredentialUnlockFailed)
}

fn decode_field(value: &toml::Value, name: &str) -> Result<Vec<u8>> {
    let encoded = value
        .get(name)
        .and_then(toml::Value::as_str)
        .ok_or(Error::InvalidCredentialFile)?;
    Base64::decode_vec(encoded).map_err(|_| Error::InvalidCredentialFile)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saves_reads_overwrites_and_deletes() {
        let dir = tempfile::tempdir().unwrap();
        let store = CredentialStore::new(dir.path().join("credentials.toml"));
        assert_eq!(store.get("host.a.password").unwrap(), None);
        store
            .save("host.a.password".into(), "first".into())
            .unwrap();
        store
            .save("host.a.password".into(), "second".into())
            .unwrap();
        assert_eq!(
            store.get("host.a.password").unwrap().as_deref(),
            Some("second")
        );
        store.delete("host.a.password").unwrap();
        assert_eq!(store.get("host.a.password").unwrap(), None);
    }

    #[test]
    fn rejects_empty_sensitive_inputs() {
        let dir = tempfile::tempdir().unwrap();
        let store = CredentialStore::new(dir.path().join("credentials.toml"));
        assert!(store.save("".into(), "x".into()).is_err());
        assert!(store.save("ref".into(), "".into()).is_err());
    }

    #[test]
    fn encrypts_and_requires_the_matching_protection_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store
            .save("host.a.password".into(), "secret".into())
            .unwrap();
        store
            .set_protection_key(None, Some("protect".into()))
            .unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("mode = \"encrypted\""));
        assert!(!text.contains("secret"));
        assert!(store.is_protected().unwrap());

        let locked = CredentialStore::new(path.clone());
        assert!(matches!(
            locked.get("host.a.password"),
            Err(Error::CredentialProtectionKeyRequired)
        ));
        assert!(matches!(
            locked.set_protection_key(Some("wrong".into()), Some("wrong".into())),
            Err(Error::CredentialUnlockFailed)
        ));
        locked
            .set_protection_key(Some("protect".into()), Some("protect".into()))
            .unwrap();
        let reopened = CredentialStore::new(path);
        reopened
            .set_protection_key(Some("protect".into()), Some("protect".into()))
            .unwrap();
        assert_eq!(
            reopened.get("host.a.password").unwrap().as_deref(),
            Some("secret")
        );
    }

    #[test]
    fn migrates_plaintext_and_can_remove_protection_after_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        std::fs::write(
            &path,
            "version = 1\n[entries]\n\"host.a.password\" = \"legacy\"\n",
        )
        .unwrap();
        let store = CredentialStore::new(path.clone());
        assert_eq!(
            store.get("host.a.password").unwrap().as_deref(),
            Some("legacy")
        );
        store
            .set_protection_key(None, Some("old-key".into()))
            .unwrap();

        let reopened = CredentialStore::new(path.clone());
        reopened
            .set_protection_key(Some("old-key".into()), None)
            .unwrap();
        assert!(!reopened.is_protected().unwrap());
        assert_eq!(
            reopened.get("host.a.password").unwrap().as_deref(),
            Some("legacy")
        );
        assert!(std::fs::read_to_string(path).unwrap().contains("legacy"));
    }

    #[test]
    fn rejects_tampered_encrypted_envelope_without_panicking() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store
            .save("host.a.password".into(), "secret".into())
            .unwrap();
        store
            .set_protection_key(None, Some("protect".into()))
            .unwrap();
        let tampered = std::fs::read_to_string(&path)
            .unwrap()
            .replace("nonce = ", "nonce = \"bad\" # ");
        std::fs::write(&path, tampered).unwrap();

        let reopened = CredentialStore::new(path);
        assert!(matches!(
            reopened.set_protection_key(Some("protect".into()), Some("protect".into())),
            Err(Error::InvalidCredentialFile)
        ));
    }

    #[test]
    fn reports_malformed_legacy_file_as_invalid_credential_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        std::fs::write(&path, "[entries\n").unwrap();
        let store = CredentialStore::new(path);

        assert!(matches!(
            store.get("host.a.password"),
            Err(Error::InvalidCredentialFile)
        ));
        assert!(matches!(
            store.is_protected(),
            Err(Error::InvalidCredentialFile)
        ));
    }
}

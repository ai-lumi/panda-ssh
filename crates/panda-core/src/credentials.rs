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

use crate::Error;
use crate::Result;

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

/// 凭据保护的可信状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtectionStatus {
    /// 凭据文件为明文格式或不存在。
    Unprotected,
    /// 凭据文件已加密，但当前进程尚未提供正确密钥。
    ProtectedLocked,
    /// 凭据文件已加密，且当前进程已验证密钥可用。
    ProtectedUnlocked,
}

/// 保护动作的输入验证结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProtectionAction {
    /// 启用保护：新密钥非空且两次一致。
    Enable,
    /// 更换密钥：旧密钥非空、新密钥非空且两次一致。
    ChangeKey,
    /// 移除保护：旧密钥非空。
    Remove,
}

/// 验证保护动作的输入参数。
///
/// - `new_key` 和 `confirm_key` 均为 `None` 时视为移除操作；
/// - 否则要求 `new_key` 非空、与 `confirm_key` 一致；
/// - 不做 trim 或字符规范化，空白和 Unicode 按原值比较。
pub fn validate_protection_input(
    current_key: Option<&str>,
    new_key: Option<&str>,
    confirm_key: Option<&str>,
    is_protected: bool,
) -> std::result::Result<ProtectionAction, ProtectionInputError> {
    let new_key = new_key.filter(|k| !k.is_empty());
    let confirm_key = confirm_key.filter(|k| !k.is_empty());

    match (new_key, confirm_key) {
        (None, None) => {
            if !is_protected {
                return Err(ProtectionInputError::AlreadyUnprotected);
            }
            if current_key.is_none() || current_key == Some("") {
                return Err(ProtectionInputError::CurrentKeyRequired);
            }
            Ok(ProtectionAction::Remove)
        }
        (Some(new), Some(confirm)) => {
            if new != confirm {
                return Err(ProtectionInputError::ConfirmMismatch);
            }
            if is_protected {
                if current_key.is_none() || current_key == Some("") {
                    return Err(ProtectionInputError::CurrentKeyRequired);
                }
                Ok(ProtectionAction::ChangeKey)
            } else {
                Ok(ProtectionAction::Enable)
            }
        }
        (Some(_), None) => Err(ProtectionInputError::ConfirmMismatch),
        (None, Some(_)) => Err(ProtectionInputError::ConfirmMismatch),
    }
}

/// 保护动作输入验证错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProtectionInputError {
    /// 新密码与确认密码不一致。
    ConfirmMismatch,
    /// 更换或移除操作需要提供当前密码。
    CurrentKeyRequired,
    /// 凭据未受保护且未提供新密钥，无操作可执行。
    AlreadyUnprotected,
}

/// 凭据专属的原子写入：临时文件在写入秘密前即以 `0600` 创建，
/// 成功后 rename 替换目标，并再次确认最终文件权限。
/// 不修改通用 `write_atomic` 的其他调用方。
#[cfg(unix)]
fn write_atomic_restricted(path: &std::path::Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    // 清理旧版固定临时文件。remove_file 对符号链接执行 unlink，不会触及其目标。
    let legacy_tmp = path.with_extension("tmp");
    match std::fs::remove_file(&legacy_tmp) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }

    // 独占创建的随机名称不会复用或跟随旧版固定 `credentials.tmp` 等已有路径。
    let tmp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let mut file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&tmp)?;

    if let Err(error) = file.set_permissions(std::fs::Permissions::from_mode(0o600)) {
        drop(file);
        let _ = std::fs::remove_file(&tmp);
        return Err(error.into());
    }
    if let Err(error) = file.write_all(bytes) {
        drop(file);
        let _ = std::fs::remove_file(&tmp);
        return Err(error.into());
    }
    drop(file);
    if let Err(error) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(error.into());
    }
    if let Err(error) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
        return Err(error.into());
    }
    Ok(())
}

#[cfg(not(unix))]
fn write_atomic_restricted(path: &std::path::Path, bytes: &[u8]) -> Result<()> {
    crate::config::write_atomic(path, bytes)
}

/// 明文兼容凭据仓库。启用保护后，整个 TOML 负载会被 AEAD 信封包裹；
/// 此类型保证凭据与 hosts.toml 分离且所有写入原子完成。
///
/// 所有读改写操作（save/delete/set_protection_key/unlock_only）通过 `txn_lock`
/// 串行化，避免并发迁移覆盖已成功提交的凭据更新。
pub struct CredentialStore {
    path: PathBuf,
    protection_key: std::sync::Mutex<Option<String>>,
    txn_lock: std::sync::Mutex<()>,
}

impl CredentialStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            protection_key: std::sync::Mutex::new(None),
            txn_lock: std::sync::Mutex::new(()),
        }
    }

    /// 查询凭据保护的可信状态。
    ///
    /// - 文件不存在或为明文格式 → `Unprotected`
    /// - 文件已加密且内存密钥可解密 → `ProtectedUnlocked`
    /// - 文件已加密但无可用密钥 → `ProtectedLocked`
    /// - 格式损坏或 I/O 错误 → `Err`（不伪装为 `Unprotected`）
    pub fn protection_status(&self) -> Result<ProtectionStatus> {
        let _guard = self.txn_lock.lock().unwrap();
        self.protection_status_locked()
    }

    fn protection_status_locked(&self) -> Result<ProtectionStatus> {
        match std::fs::read_to_string(&self.path) {
            Ok(text) => {
                let value: toml::Value =
                    toml::from_str(&text).map_err(|_| Error::InvalidCredentialFile)?;
                if value.get("mode").and_then(toml::Value::as_str) != Some("encrypted") {
                    return Ok(ProtectionStatus::Unprotected);
                }
                let key = match self.protection_key.lock().unwrap().clone() {
                    Some(key) => key,
                    None => return Ok(ProtectionStatus::ProtectedLocked),
                };
                let salt = decode_field(&value, "salt")?;
                let nonce = decode_field(&value, "nonce")?;
                let ciphertext = decode_field(&value, "ciphertext")?;
                if salt.len() != 16 || nonce.len() != 12 || ciphertext.is_empty() {
                    return Err(Error::InvalidCredentialFile);
                }
                match decrypt(&key, &salt, &nonce, &ciphertext) {
                    Ok(plaintext) => {
                        toml::from_str::<PlainCredentialsFile>(
                            std::str::from_utf8(&plaintext)
                                .map_err(|_| Error::InvalidCredentialFile)?,
                        )
                        .map_err(|_| Error::InvalidCredentialFile)?;
                        Ok(ProtectionStatus::ProtectedUnlocked)
                    }
                    Err(_) => Ok(ProtectionStatus::ProtectedLocked),
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(ProtectionStatus::Unprotected),
            Err(e) => Err(e.into()),
        }
    }

    /// 只解锁：验证候选密钥能否解密现有凭据文件，成功则在内存中发布密钥。
    ///
    /// - 不改写凭据文件（字节和修改时间不变）
    /// - 错误候选密钥不覆盖此前有效的已解锁状态
    /// - 格式损坏或 I/O 错误返回 `Err`，不伪装为锁定
    pub fn unlock_only(&self, candidate_key: &str) -> Result<ProtectionStatus> {
        if candidate_key.is_empty() {
            return Err(Error::CredentialProtectionKeyRequired);
        }
        let _guard = self.txn_lock.lock().unwrap();

        match std::fs::read_to_string(&self.path) {
            Ok(text) => {
                let value: toml::Value =
                    toml::from_str(&text).map_err(|_| Error::InvalidCredentialFile)?;
                if value.get("mode").and_then(toml::Value::as_str) != Some("encrypted") {
                    return Ok(ProtectionStatus::Unprotected);
                }
                let salt = decode_field(&value, "salt")?;
                let nonce = decode_field(&value, "nonce")?;
                let ciphertext = decode_field(&value, "ciphertext")?;
                if salt.len() != 16 || nonce.len() != 12 || ciphertext.is_empty() {
                    return Err(Error::InvalidCredentialFile);
                }
                match decrypt(candidate_key, &salt, &nonce, &ciphertext) {
                    Ok(plaintext) => {
                        toml::from_str::<PlainCredentialsFile>(
                            std::str::from_utf8(&plaintext)
                                .map_err(|_| Error::InvalidCredentialFile)?,
                        )
                        .map_err(|_| Error::InvalidCredentialFile)?;
                        *self.protection_key.lock().unwrap() = Some(candidate_key.to_string());
                        Ok(ProtectionStatus::ProtectedUnlocked)
                    }
                    Err(_) => {
                        // 错误候选密钥不覆盖此前有效的已解锁状态
                        Ok(ProtectionStatus::ProtectedLocked)
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(ProtectionStatus::Unprotected),
            Err(e) => Err(e.into()),
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

    /// 使用当前内存密钥加密并原子写入凭据文件。
    /// 调用前必须已持有 `txn_lock`。
    fn write_locked(&self, file: &PlainCredentialsFile) -> Result<()> {
        let plaintext = toml::to_string_pretty(file)?;
        if let Some(key) = self.protection_key.lock().unwrap().clone() {
            let mut salt = [0u8; 16];
            let mut nonce = [0u8; 12];
            OsRng.fill_bytes(&mut salt);
            OsRng.fill_bytes(&mut nonce);
            let ciphertext = encrypt(&key, &salt, &nonce, plaintext.as_bytes())?;
            let envelope = format!("version = 1\nmode = \"encrypted\"\nsalt = \"{}\"\nnonce = \"{}\"\nciphertext = \"{}\"\n", Base64::encode_string(&salt), Base64::encode_string(&nonce), Base64::encode_string(&ciphertext));
            write_atomic_restricted(&self.path, envelope.as_bytes())
        } else {
            write_atomic_restricted(&self.path, plaintext.as_bytes())
        }
    }

    /// 在局部验证候选密钥并准备新信封，然后原子提交。
    ///
    /// - 提交前失败：保留原文件，丢弃候选密钥，保留调用前仍匹配的已解锁状态
    /// - 提交成功后：发布新内存密钥
    /// - 新旧密钥相同时仍重新加密并更新盐/nonce
    fn set_protection_key_validated(
        &self,
        current_key: Option<String>,
        new_key: Option<String>,
    ) -> Result<()> {
        let _guard = self.txn_lock.lock().unwrap();

        let was_protected = self.is_protected_locked()?;
        let previous_key = self.protection_key.lock().unwrap().clone();

        // 确定用于读取现有文件的密钥
        let read_key = if was_protected {
            let candidate = current_key
                .filter(|k| !k.is_empty())
                .or_else(|| previous_key.clone());
            match candidate {
                Some(key) => key,
                None => return Err(Error::CredentialProtectionKeyRequired),
            }
        } else {
            // 明文文件不需要 current_key
            String::new()
        };

        // 在局部读取并解密现有条目
        let entries = if was_protected {
            // 临时设置密钥用于读取
            *self.protection_key.lock().unwrap() = Some(read_key.clone());
            match self.read() {
                Ok(entries) => entries,
                Err(error) => {
                    // 恢复调用前的密钥状态
                    *self.protection_key.lock().unwrap() = previous_key.clone();
                    return Err(error);
                }
            }
        } else {
            match self.read() {
                Ok(entries) => entries,
                Err(error) => {
                    *self.protection_key.lock().unwrap() = previous_key.clone();
                    return Err(error);
                }
            }
        };

        // 准备新密钥
        let effective_new_key = new_key.filter(|k| !k.is_empty());

        // 如果有新密钥，先在局部验证加密可行
        if let Some(ref new_key_value) = effective_new_key {
            let mut salt = [0u8; 16];
            let mut nonce = [0u8; 12];
            OsRng.fill_bytes(&mut salt);
            OsRng.fill_bytes(&mut nonce);
            let test_plaintext = toml::to_string_pretty(&entries)?;
            if encrypt(new_key_value, &salt, &nonce, test_plaintext.as_bytes()).is_err() {
                // 加密失败，恢复原密钥
                *self.protection_key.lock().unwrap() = previous_key.clone();
                return Err(Error::Other("credential encryption failed".into()));
            }
        }

        // 设置新密钥并提交
        *self.protection_key.lock().unwrap() = effective_new_key.clone();
        match self.write_locked(&entries) {
            Ok(()) => Ok(()),
            Err(error) => {
                // 提交失败：恢复调用前的密钥状态
                *self.protection_key.lock().unwrap() = previous_key;
                Err(error)
            }
        }
    }

    /// 使用当前密钥解锁已有加密文件，并将其改写为新密钥保护（`None` 为明文）。
    /// 未加密的旧文件不要求当前密钥，确保历史配置可以直接迁移。
    pub fn set_protection_key(
        &self,
        current_key: Option<String>,
        new_key: Option<String>,
    ) -> Result<()> {
        self.set_protection_key_validated(current_key, new_key)
    }

    pub fn is_protected(&self) -> Result<bool> {
        let _guard = self.txn_lock.lock().unwrap();
        self.is_protected_locked()
    }

    fn is_protected_locked(&self) -> Result<bool> {
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
        let _guard = self.txn_lock.lock().unwrap();
        self.read().map(|file| file.entries.get(reference).cloned())
    }

    pub fn save(&self, reference: String, secret: String) -> Result<()> {
        if reference.is_empty() || secret.is_empty() {
            return Err(Error::Other(
                "credential reference and secret must be non-empty".into(),
            ));
        }
        let _guard = self.txn_lock.lock().unwrap();
        let mut file = self.read()?;
        file.entries.insert(reference, secret);
        self.write_locked(&file)
    }

    pub fn delete(&self, reference: &str) -> Result<()> {
        let _guard = self.txn_lock.lock().unwrap();
        let mut file = self.read()?;
        file.entries.remove(reference);
        self.write_locked(&file)
    }
}

/// 凭据解析结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolvedCredential {
    /// 凭据可用。
    Available {
        password: Option<String>,
        passphrase: Option<String>,
    },
    /// 需要密码(密码认证但未保存)。
    NeedsPassword,
    /// 需要私钥口令(公钥认证但口令不可读)。
    NeedsPassphrase,
}

/// 解析主机的凭据状态。
///
/// - 密码认证:如果 password_ref 存在且可读 → Available(password);否则 NeedsPassword
/// - 公钥认证:passphrase 可选。如果 passphrase_ref 存在且可读 → Available(passphrase);
///   如果无 passphrase_ref → Available(None);如果 passphrase_ref 存在但不可读 → NeedsPassphrase
pub fn credential_resolve(
    store: &CredentialStore,
    host: &crate::config::HostConfig,
) -> Result<ResolvedCredential> {
    match &host.auth {
        crate::config::AuthMethod::Password { password_ref } => match password_ref {
            Some(r) => match store.get(r)? {
                Some(password) => Ok(ResolvedCredential::Available {
                    password: Some(password),
                    passphrase: None,
                }),
                None => Ok(ResolvedCredential::NeedsPassword),
            },
            None => Ok(ResolvedCredential::NeedsPassword),
        },
        crate::config::AuthMethod::PublicKey { passphrase_ref, .. } => match passphrase_ref {
            Some(r) => match store.get(r) {
                Ok(Some(passphrase)) => Ok(ResolvedCredential::Available {
                    password: None,
                    passphrase: Some(passphrase),
                }),
                Ok(None) => Ok(ResolvedCredential::NeedsPassphrase),
                Err(_) => Ok(ResolvedCredential::NeedsPassphrase),
            },
            None => Ok(ResolvedCredential::Available {
                password: None,
                passphrase: None,
            }),
        },
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

    #[test]
    fn migration_interruption_does_not_corrupt_data() {
        // 模拟明文→加密迁移:写入过程中如果加密失败,
        // 原始明文数据不应被损坏(原子写入保证)。
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store
            .save("host.a.password".into(), "original".into())
            .unwrap();

        // 用错误的 current_key 尝试加密迁移:
        // 文件已加密但密钥不对,操作失败。
        store
            .set_protection_key(None, Some("correct-key".into()))
            .unwrap();
        let reopened = CredentialStore::new(path.clone());
        let result = reopened.set_protection_key(Some("wrong-key".into()), None);
        assert!(result.is_err());

        // 用正确密钥仍可恢复原始数据
        let recovered = CredentialStore::new(path.clone());
        recovered
            .set_protection_key(Some("correct-key".into()), None)
            .unwrap();
        assert_eq!(
            recovered.get("host.a.password").unwrap().as_deref(),
            Some("original")
        );
    }

    // --- credential_resolve ---

    fn password_host_with_ref(r: Option<&str>) -> crate::config::HostConfig {
        crate::config::HostConfig {
            id: "h1".into(),
            name: "test".into(),
            host: "example.com".into(),
            port: 22,
            username: "user".into(),
            auth: crate::config::AuthMethod::Password {
                password_ref: r.map(str::to_string),
            },
            notes: None,
            group_id: None,
        }
    }

    fn key_host_with_ref(r: Option<&str>) -> crate::config::HostConfig {
        crate::config::HostConfig {
            id: "h2".into(),
            name: "test".into(),
            host: "example.com".into(),
            port: 22,
            username: "user".into(),
            auth: crate::config::AuthMethod::PublicKey {
                key_path: "/keys/id_ed25519".into(),
                passphrase_ref: r.map(str::to_string),
            },
            notes: None,
            group_id: None,
        }
    }

    #[test]
    fn credential_resolve_password_with_saved_credential() {
        let dir = tempfile::tempdir().unwrap();
        let store = CredentialStore::new(dir.path().join("creds.toml"));
        store.save("ref1".into(), "secret123".into()).unwrap();
        let host = password_host_with_ref(Some("ref1"));
        let result = credential_resolve(&store, &host).unwrap();
        assert_eq!(
            result,
            ResolvedCredential::Available {
                password: Some("secret123".into()),
                passphrase: None,
            }
        );
    }

    #[test]
    fn credential_resolve_password_without_saved_credential() {
        let dir = tempfile::tempdir().unwrap();
        let store = CredentialStore::new(dir.path().join("creds.toml"));
        // 有 ref 但仓库中没有对应凭据
        let host = password_host_with_ref(Some("missing"));
        let result = credential_resolve(&store, &host).unwrap();
        assert_eq!(result, ResolvedCredential::NeedsPassword);
    }

    #[test]
    fn credential_resolve_password_without_ref() {
        let dir = tempfile::tempdir().unwrap();
        let store = CredentialStore::new(dir.path().join("creds.toml"));
        let host = password_host_with_ref(None);
        let result = credential_resolve(&store, &host).unwrap();
        assert_eq!(result, ResolvedCredential::NeedsPassword);
    }

    #[test]
    fn credential_resolve_public_key_without_passphrase() {
        let dir = tempfile::tempdir().unwrap();
        let store = CredentialStore::new(dir.path().join("creds.toml"));
        let host = key_host_with_ref(None);
        let result = credential_resolve(&store, &host).unwrap();
        assert_eq!(
            result,
            ResolvedCredential::Available {
                password: None,
                passphrase: None,
            }
        );
    }

    #[test]
    fn credential_resolve_public_key_with_saved_passphrase() {
        let dir = tempfile::tempdir().unwrap();
        let store = CredentialStore::new(dir.path().join("creds.toml"));
        store.save("pp_ref".into(), "passphrase123".into()).unwrap();
        let host = key_host_with_ref(Some("pp_ref"));
        let result = credential_resolve(&store, &host).unwrap();
        assert_eq!(
            result,
            ResolvedCredential::Available {
                password: None,
                passphrase: Some("passphrase123".into()),
            }
        );
    }

    #[test]
    fn credential_resolve_public_key_with_unreadable_passphrase() {
        let dir = tempfile::tempdir().unwrap();
        let store = CredentialStore::new(dir.path().join("creds.toml"));
        // ref 存在但仓库中没有对应凭据 → 不可读
        let host = key_host_with_ref(Some("missing_pp"));
        let result = credential_resolve(&store, &host).unwrap();
        assert_eq!(result, ResolvedCredential::NeedsPassphrase);
    }

    // --- Unix 文件权限测试 ---

    #[cfg(unix)]
    fn file_mode(path: &std::path::Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[cfg(unix)]
    #[test]
    fn unix_new_credential_file_has_restricted_permissions() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store
            .save("host.a.password".into(), "secret".into())
            .unwrap();
        assert_eq!(file_mode(&path), 0o600, "新建凭据文件权限应为 0600");
    }

    #[cfg(unix)]
    #[test]
    fn unix_overwrite_keeps_restricted_permissions() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store
            .save("host.a.password".into(), "first".into())
            .unwrap();
        store
            .save("host.a.password".into(), "second".into())
            .unwrap();
        assert_eq!(file_mode(&path), 0o600, "覆盖保存后权限应仍为 0600");
    }

    #[cfg(unix)]
    #[test]
    fn unix_loose_permissions_are_tightened_on_save() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        // 预置宽松权限的凭据文件
        std::fs::write(
            &path,
            "version = 1\n[entries]\n\"host.a.password\" = \"legacy\"\n",
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(file_mode(&path), 0o644);

        let store = CredentialStore::new(path.clone());
        store
            .save("host.a.password".into(), "updated".into())
            .unwrap();

        assert_eq!(file_mode(&path), 0o600, "保存后宽松权限应被收紧为 0600");
        // 内容与加密状态不变
        assert_eq!(
            store.get("host.a.password").unwrap().as_deref(),
            Some("updated")
        );
    }

    #[cfg(unix)]
    #[test]
    fn unix_leftover_temp_file_is_tightened() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let tmp = dir.path().join("credentials.tmp");
        // 模拟遗留的宽松权限临时文件
        std::fs::write(&tmp, "stale").unwrap();
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644)).unwrap();

        let store = CredentialStore::new(path.clone());
        store
            .save("host.a.password".into(), "secret".into())
            .unwrap();

        // 最终文件权限正确
        assert_eq!(file_mode(&path), 0o600);
        // 临时文件已被 rename 替换，不应残留
        assert!(!tmp.exists(), "临时文件应在原子替换后被清除");
    }

    #[cfg(unix)]
    #[test]
    fn unix_legacy_temp_symlink_is_not_followed() {
        use std::os::unix::fs::symlink;

        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(outside.path(), b"sentinel").unwrap();
        let path = dir.path().join("credentials.toml");
        let legacy_tmp = dir.path().join("credentials.tmp");
        symlink(outside.path(), &legacy_tmp).unwrap();

        CredentialStore::new(path.clone())
            .save("host.a.password".into(), "secret".into())
            .unwrap();

        assert_eq!(std::fs::read(outside.path()).unwrap(), b"sentinel");
        assert!(!std::fs::symlink_metadata(&legacy_tmp).is_ok());
        assert_eq!(file_mode(&path), 0o600);
    }

    // --- ProtectionStatus 与 unlock_only 测试 ---

    #[test]
    fn protection_status_unprotected_when_no_file() {
        let dir = tempfile::tempdir().unwrap();
        let store = CredentialStore::new(dir.path().join("credentials.toml"));
        assert_eq!(store.protection_status().unwrap(), ProtectionStatus::Unprotected);
    }

    #[test]
    fn protection_status_unprotected_when_plaintext() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        std::fs::write(&path, "version = 1\n[entries]\n\"host.a.password\" = \"secret\"\n").unwrap();
        let store = CredentialStore::new(path);
        assert_eq!(store.protection_status().unwrap(), ProtectionStatus::Unprotected);
    }

    #[test]
    fn protection_status_locked_after_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store.save("host.a.password".into(), "secret".into()).unwrap();
        store.set_protection_key(None, Some("protect".into())).unwrap();

        // 模拟重启：新建 store 实例，内存密钥为空
        let restarted = CredentialStore::new(path);
        assert_eq!(restarted.protection_status().unwrap(), ProtectionStatus::ProtectedLocked);
    }

    #[test]
    fn protection_status_unlocked_after_correct_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store.save("host.a.password".into(), "secret".into()).unwrap();
        store.set_protection_key(None, Some("protect".into())).unwrap();

        // 同一进程内已解锁
        assert_eq!(store.protection_status().unwrap(), ProtectionStatus::ProtectedUnlocked);
    }

    #[test]
    fn protection_status_does_not_mask_io_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        // 写入非法 TOML
        std::fs::write(&path, "[broken").unwrap();
        let store = CredentialStore::new(path);
        assert!(matches!(store.protection_status(), Err(Error::InvalidCredentialFile)));
    }

    #[test]
    fn unlock_only_succeeds_with_correct_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store.save("host.a.password".into(), "secret".into()).unwrap();
        store.set_protection_key(None, Some("protect".into())).unwrap();

        let before_bytes = std::fs::read(&path).unwrap();
        let before_mtime = std::fs::metadata(&path).unwrap().modified().unwrap();

        let restarted = CredentialStore::new(path.clone());
        assert_eq!(restarted.protection_status().unwrap(), ProtectionStatus::ProtectedLocked);

        let status = restarted.unlock_only("protect").unwrap();
        assert_eq!(status, ProtectionStatus::ProtectedUnlocked);

        // 文件未被改写
        let after_bytes = std::fs::read(&path).unwrap();
        assert_eq!(before_bytes, after_bytes, "unlock_only 不应改写文件");

        // 修改时间不变（macOS 文件系统精度为秒级，此处仅验证字节不变）
        let after_mtime = std::fs::metadata(&path).unwrap().modified().unwrap();
        assert_eq!(before_mtime, after_mtime, "unlock_only 不应改变修改时间");

        // 解锁后可读取凭据
        assert_eq!(
            restarted.get("host.a.password").unwrap().as_deref(),
            Some("secret")
        );
    }

    #[test]
    fn unlock_only_preserves_existing_state_on_wrong_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store.save("host.a.password".into(), "secret".into()).unwrap();
        store.set_protection_key(None, Some("correct".into())).unwrap();

        // 已解锁状态下提交错误候选密钥
        let status = store.unlock_only("wrong").unwrap();
        assert_eq!(status, ProtectionStatus::ProtectedLocked);

        // 原有效解锁状态应保持——但注意 unlock_only 对错误密钥返回 Locked 而非覆盖
        // 此处验证：错误密钥不替换可用密钥，原 store 仍可读取
        assert_eq!(
            store.get("host.a.password").unwrap().as_deref(),
            Some("secret")
        );
    }

    #[test]
    fn unlock_only_rejects_empty_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store.save("host.a.password".into(), "secret".into()).unwrap();
        store.set_protection_key(None, Some("protect".into())).unwrap();

        let restarted = CredentialStore::new(path);
        assert!(matches!(
            restarted.unlock_only(""),
            Err(Error::CredentialProtectionKeyRequired)
        ));
    }

    #[test]
    fn unlock_only_reports_corrupted_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        // 写入格式损坏的加密信封
        std::fs::write(&path, "version = 1\nmode = \"encrypted\"\nsalt = \"bad\"\n").unwrap();
        let store = CredentialStore::new(path);
        assert!(matches!(
            store.unlock_only("any-key"),
            Err(Error::InvalidCredentialFile)
        ));
    }

    #[test]
    fn unlock_only_with_unicode_and_whitespace_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store.save("host.a.password".into(), "secret".into()).unwrap();
        let unicode_key = " 密码 🐼 ";
        store.set_protection_key(None, Some(unicode_key.into())).unwrap();

        let restarted = CredentialStore::new(path);
        let status = restarted.unlock_only(unicode_key).unwrap();
        assert_eq!(status, ProtectionStatus::ProtectedUnlocked);
        assert_eq!(
            restarted.get("host.a.password").unwrap().as_deref(),
            Some("secret")
        );
    }

    // --- 输入验证测试 ---

    #[test]
    fn validate_enable_requires_non_empty_matching_keys() {
        assert_eq!(
            validate_protection_input(None, Some("new"), Some("new"), false).unwrap(),
            ProtectionAction::Enable
        );
        assert_eq!(
            validate_protection_input(None, Some("new"), Some("different"), false).unwrap_err(),
            ProtectionInputError::ConfirmMismatch
        );
        assert_eq!(
            validate_protection_input(None, Some("new"), None, false).unwrap_err(),
            ProtectionInputError::ConfirmMismatch
        );
        assert_eq!(
            validate_protection_input(None, None, None, false).unwrap_err(),
            ProtectionInputError::AlreadyUnprotected
        );
    }

    #[test]
    fn validate_change_requires_current_key() {
        assert_eq!(
            validate_protection_input(Some("old"), Some("new"), Some("new"), true).unwrap(),
            ProtectionAction::ChangeKey
        );
        assert_eq!(
            validate_protection_input(None, Some("new"), Some("new"), true).unwrap_err(),
            ProtectionInputError::CurrentKeyRequired
        );
        assert_eq!(
            validate_protection_input(Some(""), Some("new"), Some("new"), true).unwrap_err(),
            ProtectionInputError::CurrentKeyRequired
        );
    }

    #[test]
    fn validate_remove_requires_current_key_and_protection() {
        assert_eq!(
            validate_protection_input(Some("old"), None, None, true).unwrap(),
            ProtectionAction::Remove
        );
        assert_eq!(
            validate_protection_input(None, None, None, true).unwrap_err(),
            ProtectionInputError::CurrentKeyRequired
        );
        assert_eq!(
            validate_protection_input(Some("old"), None, None, false).unwrap_err(),
            ProtectionInputError::AlreadyUnprotected
        );
    }

    #[test]
    fn validate_does_not_trim_whitespace_or_unicode() {
        // 空白和 Unicode 按原值比较
        let key_with_spaces = "  key  ";
        assert_eq!(
            validate_protection_input(None, Some(key_with_spaces), Some(key_with_spaces), false).unwrap(),
            ProtectionAction::Enable
        );
        // 不同空白不应被视为一致
        assert_eq!(
            validate_protection_input(None, Some(" key"), Some("key "), false).unwrap_err(),
            ProtectionInputError::ConfirmMismatch
        );
    }

    // --- 事务安全与提交边界测试 ---

    #[test]
    fn same_key_reencrypts_with_new_salt_and_nonce() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store.save("host.a.password".into(), "secret".into()).unwrap();
        store.set_protection_key(None, Some("same-key".into())).unwrap();
        let first_content = std::fs::read_to_string(&path).unwrap();

        // 用相同密钥重新加密
        store.set_protection_key(Some("same-key".into()), Some("same-key".into())).unwrap();
        let second_content = std::fs::read_to_string(&path).unwrap();

        // 内容应不同（盐/nonce 已更新）
        assert_ne!(first_content, second_content, "相同密钥重新加密应产生不同密文");

        // 原密钥仍有效
        assert_eq!(
            store.get("host.a.password").unwrap().as_deref(),
            Some("secret")
        );
    }

    #[test]
    fn empty_store_can_be_protected() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        // 无文件时启用保护
        store.set_protection_key(None, Some("protect".into())).unwrap();
        assert!(store.is_protected().unwrap());
        assert_eq!(store.protection_status().unwrap(), ProtectionStatus::ProtectedUnlocked);

        // 后续保存立即受保护
        store.save("host.a.password".into(), "secret".into()).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("mode = \"encrypted\""));
        assert!(!text.contains("secret"));
    }

    #[test]
    fn migration_preserves_all_entries() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        store.save("host.a.password".into(), "pass1".into()).unwrap();
        store.save("host.b.passphrase".into(), "phrase2".into()).unwrap();
        store.save("host.c.password".into(), "密码三".into()).unwrap();

        store.set_protection_key(None, Some("protect".into())).unwrap();

        // 所有条目在解密后一致
        assert_eq!(store.get("host.a.password").unwrap().as_deref(), Some("pass1"));
        assert_eq!(store.get("host.b.passphrase").unwrap().as_deref(), Some("phrase2"));
        assert_eq!(store.get("host.c.password").unwrap().as_deref(), Some("密码三"));

        // 文件不含明文秘密
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains("pass1"));
        assert!(!text.contains("phrase2"));
        assert!(!text.contains("密码三"));
    }

    // --- 并发测试 ---

    #[test]
    fn concurrent_save_and_migration_serializes() {
        use std::sync::Arc;
        use std::thread;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.toml");
        let store = Arc::new(CredentialStore::new(path.clone()));

        // 先保存一些初始数据
        store.save("host.init.password".into(), "initial".into()).unwrap();

        let store2 = store.clone();
        let migration = thread::spawn(move || {
            store2.set_protection_key(None, Some("protect".into()))
        });

        // 主线程同时尝试保存
        let save_result = store.save("host.concurrent.password".into(), "concurrent".into());

        migration.join().unwrap().unwrap();

        // 无论保存是否在迁移前或后完成，最终两个条目都应存在
        if save_result.is_ok() {
            assert_eq!(store.get("host.concurrent.password").unwrap().as_deref(), Some("concurrent"));
        }
        assert_eq!(store.get("host.init.password").unwrap().as_deref(), Some("initial"));
    }
}

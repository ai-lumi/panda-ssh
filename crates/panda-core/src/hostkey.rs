//! Simplified OpenSSH `known_hosts` handling.
//!
//! Only non-hashed entries are supported. Each line is
//! `<host> <keytype> <base64>`, where `<host>` is the bare host for port 22
//! or `[host]:port` otherwise. Entries are keyed by `(host, keytype)`: one
//! host may hold one record per key type, and storing a new key for an
//! existing `(host, keytype)` replaces the old record.

use std::path::PathBuf;

use base64ct::{Base64, Encoding};
use sha2::{Digest, Sha256};

use crate::Error;
use crate::config::write_atomic;

/// Result of checking a server key against the stored entries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostKeyStatus {
    /// Stored key matches the presented one.
    Match,
    /// No entry for this host/port.
    Unknown,
    /// An entry exists but the presented key differs.
    Mismatch { stored: String },
}

/// File-level host key status (no connection needed).
///
/// Without a presented key only two outcomes are possible: `Unknown` (no
/// record) or `Known` (a record exists). A genuine `Mismatch` can only be
/// detected against a presented key — see [`KnownHosts::check`] and the
/// connect-time `HostKeyMismatch` error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KnownHostStatus {
    /// No record for this host/port (any key type).
    Unknown,
    /// A record exists; carries its SHA256 fingerprint and key type.
    Known { fingerprint: String, key_type: String },
}

/// SHA256 fingerprint of an OpenSSH public key string, in the colon-separated
/// hex form shown by the UI (`SHA256:ab:cd:…`). Hashes the base64-decoded
/// key blob, exactly like OpenSSH does.
pub fn fingerprint_sha256(openssh_key_str: &str) -> Result<String, Error> {
    let mut parts = openssh_key_str.split_whitespace();
    let (Some(_keytype), Some(b64)) = (parts.next(), parts.next()) else {
        return Err(Error::Other(format!(
            "malformed public key: {openssh_key_str:?}"
        )));
    };
    let blob = Base64::decode_vec(b64)
        .map_err(|e| Error::Other(format!("bad base64 in public key: {e}")))?;
    let digest = Sha256::digest(&blob);
    let hex = digest
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(":");
    Ok(format!("SHA256:{hex}"))
}

/// A known-hosts file.
pub struct KnownHosts {
    path: PathBuf,
}

impl KnownHosts {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    /// The known_hosts file this instance operates on.
    pub fn path(&self) -> &std::path::Path {
        &self.path
    }

    /// Read all entries as `(hostname_token, key)` pairs.
    pub fn load(&self) -> Result<Vec<(String, String)>, Error> {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            // Missing file means no known hosts yet.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        let mut entries = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut parts = line.split_whitespace();
            let (Some(host), Some(keytype), Some(base64)) =
                (parts.next(), parts.next(), parts.next())
            else {
                // Skip malformed lines rather than failing the whole file.
                continue;
            };
            entries.push((host.to_string(), format!("{keytype} {base64}")));
        }
        Ok(entries)
    }

    /// Check `openssh_key_str` (e.g. `ssh-ed25519 AAAA...`) for `host:port`.
    ///
    /// Entries are matched on `(host, keytype)`: a host with records but no
    /// record for this key type yields `Unknown`, not `Mismatch`.
    pub fn check(&self, host: &str, port: u16, openssh_key_str: &str) -> Result<HostKeyStatus, Error> {
        let token = host_token(host, port);
        let keytype = keytype_of(openssh_key_str);
        for (stored_host, stored_key) in self.load()? {
            if stored_host == token && keytype_of(&stored_key) == keytype {
                return Ok(if stored_key == openssh_key_str {
                    HostKeyStatus::Match
                } else {
                    HostKeyStatus::Mismatch { stored: stored_key }
                });
            }
        }
        Ok(HostKeyStatus::Unknown)
    }

    /// File-level status for `host:port`: `Unknown` when no record exists,
    /// otherwise `Known` with the first record's fingerprint and key type.
    ///
    /// A host may hold one record per key type; for display purposes the
    /// first record (file order) is reported.
    pub fn status(&self, host: &str, port: u16) -> Result<KnownHostStatus, Error> {
        let token = host_token(host, port);
        for (stored_host, stored_key) in self.load()? {
            if stored_host == token {
                return Ok(KnownHostStatus::Known {
                    fingerprint: fingerprint_sha256(&stored_key)?,
                    key_type: keytype_of(&stored_key).to_string(),
                });
            }
        }
        Ok(KnownHostStatus::Unknown)
    }

    /// Explicitly accept a presented key (TOFU confirmation): the key string
    /// is validated, then stored like [`store`](Self::store). Callers pass
    /// the key captured from a `Reject`-policy probe, not a fresh handshake.
    pub fn accept(&self, host: &str, port: u16, openssh_key_str: &str) -> Result<(), Error> {
        // Reuse the fingerprint computation as format validation: it rejects
        // strings that are not `<keytype> <base64>`.
        fingerprint_sha256(openssh_key_str)?;
        self.store(host, port, openssh_key_str)
    }

    /// Store the key for `host:port`; an existing record with the same
    /// key type is replaced, identical duplicates are skipped.
    pub fn store(&self, host: &str, port: u16, openssh_key_str: &str) -> Result<(), Error> {
        let token = host_token(host, port);
        if self.check(host, port, openssh_key_str)? == HostKeyStatus::Match {
            return Ok(());
        }
        let text = self.read_text()?;
        let keytype = keytype_of(openssh_key_str);
        let new_line = format!("{token} {openssh_key_str}");
        let mut replaced = false;
        let mut lines: Vec<String> = Vec::new();
        for line in text.lines() {
            // Replace the (host, keytype) record in place; drop duplicates.
            if line_matches(line, &token, keytype) {
                if !replaced {
                    lines.push(new_line.clone());
                    replaced = true;
                }
            } else {
                lines.push(line.to_string());
            }
        }
        if !replaced {
            lines.push(new_line);
        }
        if let Some(parent) = self.path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
            }
        }
        write_atomic(&self.path, format!("{}\n", lines.join("\n")).as_bytes())
    }

    /// Delete all records for `host:port` (every key type).
    pub fn remove(&self, host: &str, port: u16) -> Result<(), Error> {
        let token = host_token(host, port);
        let text = self.read_text()?;
        let lines: Vec<&str> = text
            .lines()
            .filter(|line| !line_matches_host(line, &token))
            .collect();
        if lines.len() == text.lines().count() {
            return Ok(());
        }
        let body = if lines.is_empty() {
            String::new()
        } else {
            format!("{}\n", lines.join("\n"))
        };
        write_atomic(&self.path, body.as_bytes())
    }

    /// Read the file contents; a missing file means "no known hosts yet".
    fn read_text(&self) -> Result<String, Error> {
        match std::fs::read_to_string(&self.path) {
            Ok(t) => Ok(t),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
            Err(e) => Err(e.into()),
        }
    }
}

/// The key type token (`ssh-ed25519`, `ssh-rsa`, ...) of an OpenSSH public
/// key string.
fn keytype_of(openssh_key_str: &str) -> &str {
    openssh_key_str.split_whitespace().next().unwrap_or("")
}

/// Whether a known_hosts line is the record for `token` + `keytype`.
fn line_matches(line: &str, token: &str, keytype: &str) -> bool {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return false;
    }
    let mut parts = line.split_whitespace();
    parts.next() == Some(token) && parts.next() == Some(keytype)
}

/// Whether a known_hosts line is any record for the host `token`.
fn line_matches_host(line: &str, token: &str) -> bool {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return false;
    }
    line.split_whitespace().next() == Some(token)
}

/// The host token used in known_hosts: bare host for port 22, `[host]:port` else.
fn host_token(host: &str, port: u16) -> String {
    if port == 22 {
        host.to_string()
    } else {
        format!("[{host}]:{port}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY_A: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample";
    // Same keytype as KEY_A but different key material.
    const KEY_A2: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChanged";
    const KEY_B: &str = "ssh-rsa AAAAB3NzaC1yc2EAAAAOther";

    #[test]
    fn store_and_match_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));

        assert_eq!(kh.check("example.com", 22, KEY_A).unwrap(), HostKeyStatus::Unknown);

        kh.store("example.com", 22, KEY_A).unwrap();
        assert_eq!(kh.check("example.com", 22, KEY_A).unwrap(), HostKeyStatus::Match);

        // Storing the same key again does not duplicate the line.
        kh.store("example.com", 22, KEY_A).unwrap();
        let entries = kh.load().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0], ("example.com".to_string(), KEY_A.to_string()));
    }

    #[test]
    fn mismatch_reports_stored_key() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));
        kh.store("example.com", 22, KEY_A).unwrap();

        // Same keytype, different key material → Mismatch.
        assert_eq!(
            kh.check("example.com", 22, KEY_A2).unwrap(),
            HostKeyStatus::Mismatch {
                stored: KEY_A.to_string(),
            }
        );
    }

    #[test]
    fn multiple_keytypes_coexist_for_same_host() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));
        kh.store("example.com", 22, KEY_A).unwrap();
        kh.store("example.com", 22, KEY_B).unwrap();

        assert_eq!(kh.check("example.com", 22, KEY_A).unwrap(), HostKeyStatus::Match);
        assert_eq!(kh.check("example.com", 22, KEY_B).unwrap(), HostKeyStatus::Match);
        assert_eq!(kh.load().unwrap().len(), 2);
    }

    #[test]
    fn known_host_with_new_keytype_is_unknown() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));
        kh.store("example.com", 22, KEY_A).unwrap();

        // Host has an ed25519 record; an rsa key is a new keytype, not a change.
        assert_eq!(kh.check("example.com", 22, KEY_B).unwrap(), HostKeyStatus::Unknown);
    }

    #[test]
    fn store_same_keytype_replaces_old_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let kh = KnownHosts::new(path.clone());
        kh.store("example.com", 22, KEY_A).unwrap();
        kh.store("example.com", 22, KEY_B).unwrap();
        kh.store("example.com", 22, KEY_A2).unwrap();

        // The old ed25519 record was replaced, the rsa one untouched.
        assert_eq!(
            kh.check("example.com", 22, KEY_A).unwrap(),
            HostKeyStatus::Mismatch {
                stored: KEY_A2.to_string(),
            }
        );
        assert_eq!(kh.check("example.com", 22, KEY_A2).unwrap(), HostKeyStatus::Match);
        assert_eq!(kh.check("example.com", 22, KEY_B).unwrap(), HostKeyStatus::Match);
        assert_eq!(kh.load().unwrap().len(), 2);

        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(!raw.contains(KEY_A.trim_start_matches("ssh-ed25519 ")));
        // No leftover temp file from the atomic write.
        assert!(!dir.path().join("known_hosts.tmp").exists());
    }

    #[test]
    fn remove_deletes_all_records_for_host() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));
        kh.store("example.com", 22, KEY_A).unwrap();
        kh.store("example.com", 22, KEY_B).unwrap();
        kh.store("other.com", 22, KEY_A).unwrap();

        kh.remove("example.com", 22).unwrap();
        assert_eq!(kh.check("example.com", 22, KEY_A).unwrap(), HostKeyStatus::Unknown);
        assert_eq!(kh.check("example.com", 22, KEY_B).unwrap(), HostKeyStatus::Unknown);
        // Other hosts are untouched; removing a missing host is a no-op.
        assert_eq!(kh.check("other.com", 22, KEY_A).unwrap(), HostKeyStatus::Match);
        kh.remove("example.com", 22).unwrap();
        kh.remove("absent.com", 22).unwrap();
    }

    #[test]
    fn bracket_form_for_non_default_port() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let kh = KnownHosts::new(path.clone());
        kh.store("example.com", 2222, KEY_A).unwrap();

        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(raw.contains("[example.com]:2222 ssh-ed25519"), "file was: {raw}");

        assert_eq!(kh.check("example.com", 2222, KEY_A).unwrap(), HostKeyStatus::Match);
        // Port 22 entry is a different host token.
        assert_eq!(kh.check("example.com", 22, KEY_A).unwrap(), HostKeyStatus::Unknown);
    }

    #[test]
    fn load_skips_comments_and_blank_lines() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        std::fs::write(
            &path,
            format!("# comment\n\nexample.com {KEY_A}\nmalformed\n"),
        )
        .unwrap();
        let kh = KnownHosts::new(path);
        let entries = kh.load().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "example.com");
    }

    #[test]
    fn store_creates_missing_parent_directories() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested").join("deeper").join("known_hosts");
        let kh = KnownHosts::new(path.clone());

        kh.store("example.com", 22, KEY_A).unwrap();
        assert!(path.exists());
        assert_eq!(kh.check("example.com", 22, KEY_A).unwrap(), HostKeyStatus::Match);
    }

    #[test]
    fn load_returns_error_for_non_utf8_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        std::fs::write(&path, [0xff, 0xfe, 0xfd]).unwrap();
        let kh = KnownHosts::new(path);
        assert!(kh.load().is_err());
    }

    #[test]
    fn status_unknown_without_record() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));
        assert_eq!(
            kh.status("example.com", 22).unwrap(),
            KnownHostStatus::Unknown
        );
    }

    #[test]
    fn status_known_returns_fingerprint_and_keytype() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));
        kh.store("example.com", 22, KEY_A).unwrap();

        assert_eq!(
            kh.status("example.com", 22).unwrap(),
            KnownHostStatus::Known {
                fingerprint: fingerprint_sha256(KEY_A).unwrap(),
                key_type: "ssh-ed25519".to_string(),
            }
        );
        // 指纹为 SHA256 冒号分隔格式。
        match kh.status("example.com", 22).unwrap() {
            KnownHostStatus::Known { fingerprint, .. } => {
                assert!(fingerprint.starts_with("SHA256:"), "got: {fingerprint}");
                assert!(fingerprint.contains(':'), "got: {fingerprint}");
            }
            other => panic!("expected Known, got {other:?}"),
        }
        // 其他端口仍是未知。
        assert_eq!(
            kh.status("example.com", 2222).unwrap(),
            KnownHostStatus::Unknown
        );
    }

    #[test]
    fn status_known_bracket_port() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));
        kh.store("example.com", 2222, KEY_A).unwrap();
        assert!(matches!(
            kh.status("example.com", 2222).unwrap(),
            KnownHostStatus::Known { .. }
        ));
    }

    #[test]
    fn status_returns_first_record_when_multiple_keytypes() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));
        kh.store("example.com", 22, KEY_A).unwrap();
        kh.store("example.com", 22, KEY_B).unwrap();

        // 一机多 keytype 时返回文件中第一条记录(ed25519 先存)。
        assert_eq!(
            kh.status("example.com", 22).unwrap(),
            KnownHostStatus::Known {
                fingerprint: fingerprint_sha256(KEY_A).unwrap(),
                key_type: "ssh-ed25519".to_string(),
            }
        );
    }

    #[test]
    fn fingerprint_sha256_matches_known_vector() {
        // 预期值由 python3 hashlib 对 base64 解码后的 key blob 求 SHA256 得出。
        assert_eq!(
            fingerprint_sha256(KEY_A).unwrap(),
            "SHA256:6d:ba:b2:24:37:ba:01:eb:ca:b5:16:b1:08:73:76:73:e5:86:27:1d:eb:a0:a9:df:c6:b5:38:d5:07:b8:8f:7c"
        );
    }

    #[test]
    fn fingerprint_sha256_rejects_malformed_key() {
        assert!(fingerprint_sha256("").is_err());
        assert!(fingerprint_sha256("ssh-ed25519").is_err());
        assert!(fingerprint_sha256("ssh-ed25519 !!!not-base64!!!").is_err());
    }

    #[test]
    fn accept_validates_and_stores_key() {
        let dir = tempfile::tempdir().unwrap();
        let kh = KnownHosts::new(dir.path().join("known_hosts"));

        // 非法密钥被拒绝,不落盘。
        assert!(kh.accept("example.com", 22, "garbage").is_err());
        assert!(kh.accept("example.com", 22, "ssh-ed25519 !!!").is_err());
        assert_eq!(
            kh.status("example.com", 22).unwrap(),
            KnownHostStatus::Unknown
        );

        // 合法密钥存储后状态变为 Known,重复 accept 不产生重复条目。
        kh.accept("example.com", 22, KEY_A).unwrap();
        assert!(matches!(
            kh.status("example.com", 22).unwrap(),
            KnownHostStatus::Known { .. }
        ));
        kh.accept("example.com", 22, KEY_A).unwrap();
        assert_eq!(kh.load().unwrap().len(), 1);
    }

    #[test]
    fn line_match_helpers_ignore_blank_and_comment_lines() {
        assert!(!line_matches("", "example.com", "ssh-ed25519"));
        assert!(!line_matches("# comment", "example.com", "ssh-ed25519"));
        assert!(!line_matches_host("", "example.com"));
        assert!(!line_matches_host("# comment", "example.com"));
    }
}

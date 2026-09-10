//! 连接前评估：综合主机密钥状态和凭据可用性，返回前端应执行的动作。
//!
//! 该模块提供纯函数 `preconnect_evaluate`，不依赖任何 IO 或全局状态，
//! 便于测试和复用。TOFU 并发序列化需要异步原语，放在 panda-ffi 层。

use crate::config::HostConfig;
use crate::credentials::ResolvedCredential;
use crate::hostkey::KnownHostStatus;

/// 连接前评估结果：前端据此决定弹哪个对话框或直接连接。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PreconnectAction {
    /// 密钥已知且凭据就绪，可直接连接。
    Proceed,
    /// 未知主机，需用户确认密钥指纹（TOFU）。
    ConfirmTofu,
    /// 密钥与已知记录不匹配，应阻断连接并展示告警。
    KeyMismatch {
        stored_fingerprint: String,
        presented_fingerprint: String,
    },
    /// 需要用户输入密码（密码认证但未保存）。
    AskPassword,
    /// 需要用户输入私钥口令（公钥认证但口令不可读）。
    AskPassphrase,
}

/// 探测到的呈现密钥信息（用于 TOFU 对话框展示）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PresentedKey {
    /// OpenSSH 公钥串（ssh-ed25519 AAAA...）。
    pub key: String,
    /// SHA256 冒号分隔指纹。
    pub fingerprint: String,
}

/// 连接前评估：综合主机密钥状态和凭据可用性，返回前端应执行的动作。
///
/// 评估顺序：
/// 1. 先检查主机密钥状态（Unknown → ConfirmTofu，Mismatch → KeyMismatch）
/// 2. 密钥已知时检查凭据可用性（NeedsPassword → AskPassword，NeedsPassphrase → AskPassphrase）
/// 3. 凭据就绪 → Proceed
pub fn preconnect_evaluate(
    _host: &HostConfig,
    host_key_status: &KnownHostStatus,
    credential_status: &ResolvedCredential,
) -> PreconnectAction {
    // 第一步：检查主机密钥状态
    match host_key_status {
        KnownHostStatus::Unknown => PreconnectAction::ConfirmTofu,
        KnownHostStatus::Known { .. } => {
            // 密钥已知时，检查凭据状态
            match credential_status {
                ResolvedCredential::Available { .. } => PreconnectAction::Proceed,
                ResolvedCredential::NeedsPassword => PreconnectAction::AskPassword,
                ResolvedCredential::NeedsPassphrase => PreconnectAction::AskPassphrase,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{AuthMethod, HostConfig};
    use crate::credentials::ResolvedCredential;
    use crate::hostkey::KnownHostStatus;

    fn make_host_config(auth: AuthMethod) -> HostConfig {
        HostConfig {
            id: "test-host".into(),
            name: "Test Host".into(),
            host: "example.com".into(),
            port: 22,
            username: "user".into(),
            auth,
            notes: None,
            group_id: None,
        }
    }

    #[test]
    fn known_host_with_available_credentials_returns_proceed() {
        let host = make_host_config(AuthMethod::Password {
            password_ref: Some("ref".into()),
        });
        let key_status = KnownHostStatus::Known {
            fingerprint: "SHA256:abc:123".into(),
            key_type: "ssh-ed25519".into(),
        };
        let cred_status = ResolvedCredential::Available {
            password: Some("secret".into()),
            passphrase: None,
        };

        let action = preconnect_evaluate(&host, &key_status, &cred_status);
        assert_eq!(action, PreconnectAction::Proceed);
    }

    #[test]
    fn known_host_with_public_key_and_no_passphrase_returns_proceed() {
        let host = make_host_config(AuthMethod::PublicKey {
            key_path: "/keys/id_ed25519".into(),
            passphrase_ref: None,
        });
        let key_status = KnownHostStatus::Known {
            fingerprint: "SHA256:abc:123".into(),
            key_type: "ssh-ed25519".into(),
        };
        let cred_status = ResolvedCredential::Available {
            password: None,
            passphrase: None,
        };

        let action = preconnect_evaluate(&host, &key_status, &cred_status);
        assert_eq!(action, PreconnectAction::Proceed);
    }

    #[test]
    fn unknown_host_returns_confirm_tofu() {
        let host = make_host_config(AuthMethod::Password {
            password_ref: Some("ref".into()),
        });
        let key_status = KnownHostStatus::Unknown;
        let cred_status = ResolvedCredential::Available {
            password: Some("secret".into()),
            passphrase: None,
        };

        let action = preconnect_evaluate(&host, &key_status, &cred_status);
        assert_eq!(action, PreconnectAction::ConfirmTofu);
    }

    #[test]
    fn unknown_host_with_missing_credentials_still_returns_confirm_tofu() {
        // 密钥状态优先于凭据状态：即使凭据缺失，未知主机也应先弹 TOFU 确认
        let host = make_host_config(AuthMethod::Password {
            password_ref: None,
        });
        let key_status = KnownHostStatus::Unknown;
        let cred_status = ResolvedCredential::NeedsPassword;

        let action = preconnect_evaluate(&host, &key_status, &cred_status);
        assert_eq!(action, PreconnectAction::ConfirmTofu);
    }

    #[test]
    fn known_host_needs_password_returns_ask_password() {
        let host = make_host_config(AuthMethod::Password {
            password_ref: None,
        });
        let key_status = KnownHostStatus::Known {
            fingerprint: "SHA256:abc:123".into(),
            key_type: "ssh-ed25519".into(),
        };
        let cred_status = ResolvedCredential::NeedsPassword;

        let action = preconnect_evaluate(&host, &key_status, &cred_status);
        assert_eq!(action, PreconnectAction::AskPassword);
    }

    #[test]
    fn known_host_needs_passphrase_returns_ask_passphrase() {
        let host = make_host_config(AuthMethod::PublicKey {
            key_path: "/keys/id_ed25519".into(),
            passphrase_ref: Some("missing_ref".into()),
        });
        let key_status = KnownHostStatus::Known {
            fingerprint: "SHA256:abc:123".into(),
            key_type: "ssh-ed25519".into(),
        };
        let cred_status = ResolvedCredential::NeedsPassphrase;

        let action = preconnect_evaluate(&host, &key_status, &cred_status);
        assert_eq!(action, PreconnectAction::AskPassphrase);
    }

    #[test]
    fn known_host_with_password_ref_but_missing_credential_returns_ask_password() {
        // 有 ref 但凭据仓库中没有对应条目
        let host = make_host_config(AuthMethod::Password {
            password_ref: Some("missing_ref".into()),
        });
        let key_status = KnownHostStatus::Known {
            fingerprint: "SHA256:abc:123".into(),
            key_type: "ssh-ed25519".into(),
        };
        let cred_status = ResolvedCredential::NeedsPassword;

        let action = preconnect_evaluate(&host, &key_status, &cred_status);
        assert_eq!(action, PreconnectAction::AskPassword);
    }

    #[test]
    fn known_host_with_passphrase_ref_but_missing_credential_returns_ask_passphrase() {
        // 有 ref 但凭据仓库中没有对应条目
        let host = make_host_config(AuthMethod::PublicKey {
            key_path: "/keys/id_ed25519".into(),
            passphrase_ref: Some("missing_ref".into()),
        });
        let key_status = KnownHostStatus::Known {
            fingerprint: "SHA256:abc:123".into(),
            key_type: "ssh-ed25519".into(),
        };
        let cred_status = ResolvedCredential::NeedsPassphrase;

        let action = preconnect_evaluate(&host, &key_status, &cred_status);
        assert_eq!(action, PreconnectAction::AskPassphrase);
    }
}

//! 凭据 FFI 的正常流程、错误密钥和主机删除清理。

use panda_ffi::{
    credential_protection_enabled, delete_credential, delete_host, init_store, read_credential,
    save_credential, save_host, set_credential_protection_key, AuthMethodEnum, HostConfigRecord,
    PandaError,
};
use uuid::Uuid;

fn fresh_dir() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("panda-ffi-credentials-{}", Uuid::new_v4()))
}

#[test]
fn credentials_are_saved_protected_migrated_and_deleted_with_host() {
    let dir = fresh_dir();
    std::fs::create_dir_all(&dir).unwrap();
    init_store(dir.to_string_lossy().into_owned()).unwrap();

    let password_ref = "host.credential-host.password".to_string();
    save_credential(password_ref.clone(), "secret".into()).unwrap();
    assert_eq!(
        read_credential(password_ref.clone()).unwrap().as_deref(),
        Some("secret")
    );
    assert!(!credential_protection_enabled().unwrap());

    set_credential_protection_key(None, Some("protect".into())).unwrap();
    assert!(credential_protection_enabled().unwrap());
    assert!(matches!(
        set_credential_protection_key(Some("wrong".into()), Some("new".into())),
        Err(PandaError::CredentialUnlockFailed)
    ));
    set_credential_protection_key(Some("protect".into()), None).unwrap();
    assert!(!credential_protection_enabled().unwrap());

    save_host(HostConfigRecord {
        id: "credential-host".into(),
        name: "凭据清理".into(),
        host: "example.com".into(),
        port: 22,
        username: "user".into(),
        auth: AuthMethodEnum::Password {
            password_ref: Some(password_ref.clone()),
        },
        notes: None,
        group_id: None,
    })
    .unwrap();
    delete_host("credential-host".into()).unwrap();
    assert_eq!(read_credential(password_ref).unwrap(), None);

    delete_credential("missing".into()).unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}
